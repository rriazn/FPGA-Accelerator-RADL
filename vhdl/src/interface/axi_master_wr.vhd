-- Author: Olimjon Mirzayusupov
-- axi_master_wr: AXI4 write master for one write requester (the result path), see docs/plans/axi-ddr-master.md
-- section 7 and .gateflow/plans/axi-ddr-master.md section F6
-- requester side: a command (beat-aligned byte address, len = beats - 1 of the whole transfer, up to 256 beats) and a
--   data stream (data, strobes, last on the command's last beat) with independent valid/ready handshakes; data may
--   come before its command, but the data of command k must not be held back until command k+1 is accepted
-- the master splits each command into bursts with axi_pkg.burst_beats (never across a 4 KB page, at most G_MAX_BURST
--   beats) and issues AW for a burst only when all of its beats are in the W FIFO and not claimed by an earlier AW,
--   so the PS write path is never held open waiting for PL data; W does not wait for the AW handshake
-- the master makes WLAST itself; the requester's i_wlast is only checked in simulation (A11)
-- o_done pulses for one clock per command after the B of its final burst; o_error comes with it and is '1' when any
--   burst of the command answered SLVERR or DECERR (BRESP(1) = '1')
-- m_axi_awvalid and m_axi_wvalid come from axi_skid output registers, m_axi_bready is a flip-flop held at 1 after
--   reset, B is registered once before it is used; AWID is 0 (one write stream), AxSIZE is the full data width
-- at most G_MAX_OUTST bursts wait for their B; the FIFOs follow the sync_fifo contract (plan section F4)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;
use work.axi_pkg.all;

entity axi_master_wr is
    generic (
        G_ID_W       : positive := 2;                           -- same as the read master (one bundle)
        G_DATA_W     : positive := AXI_DATA_W;
        G_ADDR_W     : positive := AXI_ADDR_W;
        G_MAX_BURST  : positive := AXI_MAX_BURST;               -- <= 256 (asserted)
        G_MAX_OUTST  : positive := 8;                           -- AW bursts waiting for B (TD-1)
        G_FIFO_BEATS : positive := 32;                          -- W data FIFO, >= G_MAX_BURST (asserted, TD-1)
        G_AXCACHE    : std_logic_vector(3 downto 0) := AXI_AXCACHE
    );
    port (
        i_clk, i_rst  : in  std_logic;
        -- requester
        i_cmd_valid   : in  std_logic;
        o_cmd_ready   : out std_logic;                          -- FF
        i_cmd_addr    : in  unsigned(G_ADDR_W-1 downto 0);      -- byte address, beat aligned
        i_cmd_len     : in  unsigned(7 downto 0);               -- beats - 1 of the whole transfer, the master splits it
        i_wdata_valid : in  std_logic;
        o_wdata_ready : out std_logic;                          -- FF
        i_wdata       : in  std_logic_vector(G_DATA_W-1 downto 0);
        i_wstrb       : in  std_logic_vector(G_DATA_W/8-1 downto 0);
        i_wlast       : in  std_logic;                          -- last beat of the command; only checked (A11)
        o_done        : out std_logic;                          -- one clock per command, after the B of its final burst
        o_error       : out std_logic;                          -- with o_done: BRESP(1) = '1' in any burst of the command
        -- AXI4 AW
        m_axi_awid    : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_awaddr  : out std_logic_vector(G_ADDR_W-1 downto 0);
        m_axi_awlen   : out std_logic_vector(7 downto 0);
        m_axi_awsize  : out std_logic_vector(2 downto 0);
        m_axi_awburst : out std_logic_vector(1 downto 0);
        m_axi_awlock  : out std_logic;
        m_axi_awcache : out std_logic_vector(3 downto 0);
        m_axi_awprot  : out std_logic_vector(2 downto 0);
        m_axi_awqos   : out std_logic_vector(3 downto 0);
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        -- AXI4 W
        m_axi_wdata   : out std_logic_vector(G_DATA_W-1 downto 0);
        m_axi_wstrb   : out std_logic_vector(G_DATA_W/8-1 downto 0);
        m_axi_wlast   : out std_logic;
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        -- AXI4 B
        m_axi_bid     : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic
    );
end entity axi_master_wr;

architecture rtl of axi_master_wr is
    constant C_BYTES : positive := G_DATA_W / 8;
    constant C_OFF_W : natural := clog2(C_BYTES);
    constant C_WF_W  : positive := G_DATA_W + C_BYTES;          -- W FIFO word: data & strobes
    constant C_AW_W  : positive := G_ADDR_W + 8;                -- AW skid word: address & len
    constant C_W_W   : positive := G_DATA_W + C_BYTES + 1;      -- W skid word: data & strobes & last

    type wstate_t is (W_IDLE, W_BURST);

    -- command slot and splitter
    signal s_slot_v   : std_logic := '0';
    signal s_cmd_rdy  : std_logic := '0';
    signal s_addr     : unsigned(G_ADDR_W-1 downto 0) := (others => '0');
    signal s_left     : natural range 0 to 256 := 0;            -- beats of the command not yet issued
    signal s_n        : natural range 0 to 256 := 0;            -- beats of the next burst, registered
    signal s_n_ok     : std_logic := '0';                       -- s_n belongs to the current slot contents
    signal s_final    : std_logic;
    signal s_issue    : std_logic;
    signal s_len_v    : std_logic_vector(7 downto 0);
    -- accounting
    signal s_claimed  : natural range 0 to G_FIFO_BEATS := 0;   -- W FIFO beats owned by issued AWs
    signal s_outst    : natural range 0 to G_MAX_OUTST := 0;    -- issued bursts waiting for B
    -- W data FIFO
    signal s_wf_din   : std_logic_vector(C_WF_W-1 downto 0);
    signal s_wf_dout  : std_logic_vector(C_WF_W-1 downto 0);
    signal s_wf_wrdy  : std_logic;
    signal s_wf_valid : std_logic;
    signal s_wf_count : natural range 0 to G_FIFO_BEATS;
    -- burst length queue (W emitter) and final-burst tag queue (o_done)
    signal s_lenq_wrdy  : std_logic;
    signal s_lenq_valid : std_logic;
    signal s_lenq_dout  : std_logic_vector(7 downto 0);
    signal s_lenq_pop   : std_logic;
    signal s_dq_din     : std_logic_vector(0 downto 0);
    signal s_dq_dout    : std_logic_vector(0 downto 0);
    signal s_dq_wrdy    : std_logic;
    signal s_dq_valid   : std_logic;
    -- AW and W skids
    signal s_aw_din   : std_logic_vector(C_AW_W-1 downto 0);
    signal s_aw_dout  : std_logic_vector(C_AW_W-1 downto 0);
    signal s_aw_rdy   : std_logic;
    signal s_w_din    : std_logic_vector(C_W_W-1 downto 0);
    signal s_w_dout   : std_logic_vector(C_W_W-1 downto 0);
    signal s_w_rdy    : std_logic;
    signal s_w_push   : std_logic;
    signal s_w_last   : std_logic;
    -- W emitter
    signal s_wstate   : wstate_t := W_IDLE;
    signal s_cnt      : natural range 0 to 255 := 0;            -- beats left in the burst after the current one
    -- B
    signal s_bready   : std_logic := '0';
    signal s_b_v      : std_logic := '0';
    signal s_b_id     : std_logic_vector(G_ID_W-1 downto 0) := (others => '0');
    signal s_b_resp   : std_logic_vector(1 downto 0) := "00";
    signal s_err_acc  : std_logic := '0';
    signal s_done     : std_logic := '0';
    signal s_error    : std_logic := '0';
begin
    assert G_ID_W <= AXI_ID_W_MAX report "axi_master_wr: G_ID_W is wider than the port's ID" severity failure;
    assert G_MAX_BURST <= 256 report "axi_master_wr: G_MAX_BURST must be at most 256" severity failure;
    assert G_FIFO_BEATS >= G_MAX_BURST report "axi_master_wr: G_FIFO_BEATS must be at least G_MAX_BURST" severity failure;
    assert G_DATA_W >= 32 and 2 ** clog2(G_DATA_W) = G_DATA_W
        report "axi_master_wr: G_DATA_W must be a power of two of at least 32" severity failure;

    o_cmd_ready <= s_cmd_rdy;
    o_wdata_ready <= s_wf_wrdy;
    o_done <= s_done;
    o_error <= s_error;

    -- issue a burst: decided from flip-flops only, the result is registered in u_aw, u_lenq and u_dq
    s_final <= '1' when s_left = s_n else '0';
    s_issue <= '1' when s_slot_v = '1' and s_n_ok = '1' and s_n > 0 and s_wf_count - s_claimed >= s_n
                        and s_outst < G_MAX_OUTST and s_aw_rdy = '1' and s_lenq_wrdy = '1' and s_dq_wrdy = '1' else '0';
    s_len_v <= std_logic_vector(resize(to_unsigned(s_n, 9) - 1, 8));
    s_aw_din <= std_logic_vector(s_addr) & s_len_v;
    s_dq_din(0) <= s_final;

    -- W emitter handshakes
    s_w_push <= '1' when s_wstate = W_BURST and s_wf_valid = '1' and s_w_rdy = '1' else '0';
    s_w_last <= '1' when s_cnt = 0 else '0';
    s_w_din <= s_wf_dout & s_w_last;
    s_lenq_pop <= '1' when s_lenq_valid = '1' and (s_wstate = W_IDLE or (s_w_push = '1' and s_cnt = 0)) else '0';

    s_wf_din <= i_wdata & i_wstrb;

    u_wf : entity work.sync_fifo
        generic map (
            G_WIDTH => C_WF_W,
            G_DEPTH => G_FIFO_BEATS
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_wr_valid => i_wdata_valid,
            o_wr_ready => s_wf_wrdy,
            i_wr_data  => s_wf_din,
            o_rd_valid => s_wf_valid,
            i_rd_ready => s_w_push,
            o_rd_data  => s_wf_dout,
            o_count    => s_wf_count
        );

    u_lenq : entity work.sync_fifo
        generic map (
            G_WIDTH => 8,
            G_DEPTH => G_MAX_OUTST
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_wr_valid => s_issue,
            o_wr_ready => s_lenq_wrdy,
            i_wr_data  => s_len_v,
            o_rd_valid => s_lenq_valid,
            i_rd_ready => s_lenq_pop,
            o_rd_data  => s_lenq_dout,
            o_count    => open
        );

    u_dq : entity work.sync_fifo
        generic map (
            G_WIDTH => 1,
            G_DEPTH => G_MAX_OUTST
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_wr_valid => s_issue,
            o_wr_ready => s_dq_wrdy,
            i_wr_data  => s_dq_din,
            o_rd_valid => s_dq_valid,
            i_rd_ready => s_b_v,
            o_rd_data  => s_dq_dout,
            o_count    => open
        );

    u_aw : entity work.axi_skid
        generic map (
            G_WIDTH => C_AW_W
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_valid => s_issue,
            o_ready => s_aw_rdy,
            i_data  => s_aw_din,
            o_valid => m_axi_awvalid,
            i_ready => m_axi_awready,
            o_data  => s_aw_dout
        );

    u_w : entity work.axi_skid
        generic map (
            G_WIDTH => C_W_W
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_valid => s_w_push,
            o_ready => s_w_rdy,
            i_data  => s_w_din,
            o_valid => m_axi_wvalid,
            i_ready => m_axi_wready,
            o_data  => s_w_dout
        );

    -- AXI fields: constants, or straight from the skid output registers
    m_axi_awid <= (others => '0');
    m_axi_awaddr <= s_aw_dout(C_AW_W-1 downto 8);
    m_axi_awlen <= s_aw_dout(7 downto 0);
    m_axi_awsize <= axi_size(G_DATA_W);
    m_axi_awburst <= AXI_BURST_INCR;
    m_axi_awlock <= '0';
    m_axi_awcache <= G_AXCACHE;
    m_axi_awprot <= "000";
    m_axi_awqos <= "0000";
    m_axi_wdata <= s_w_dout(C_W_W-1 downto C_BYTES + 1);
    m_axi_wstrb <= s_w_dout(C_BYTES downto 1);
    m_axi_wlast <= s_w_dout(0);
    m_axi_bready <= s_bready;

    process(i_clk)
        variable v_accept  : boolean;
        variable v_issue   : boolean;
        variable v_slot_v  : std_logic;
        variable v_claimed : integer;
        variable v_outst   : integer;
        variable v_err     : std_logic;
        variable v_end     : unsigned(G_ADDR_W downto 0);
    begin
        if rising_edge(i_clk) then
            v_accept := i_cmd_valid = '1' and s_cmd_rdy = '1';
            v_issue := s_issue = '1';

            -- command slot and splitter: a new command, or the next burst of the current one
            v_slot_v := s_slot_v;
            if v_accept then
                s_addr <= i_cmd_addr;
                s_left <= to_integer(i_cmd_len) + 1;
                v_slot_v := '1';
                assert i_cmd_addr(C_OFF_W-1 downto 0) = 0
                    report "axi_master_wr: command address is not beat aligned" severity failure;
                v_end := resize(i_cmd_addr, G_ADDR_W + 1) + to_unsigned((to_integer(i_cmd_len) + 1) * C_BYTES, G_ADDR_W + 1);
                assert v_end <= shift_left(to_unsigned(1, G_ADDR_W + 1), G_ADDR_W)
                    report "axi_master_wr: command runs past the top of the address space" severity failure;
            elsif v_issue then
                s_addr <= s_addr + to_unsigned(s_n * C_BYTES, G_ADDR_W);
                s_left <= s_left - s_n;
                if s_final = '1' then
                    v_slot_v := '0';
                end if;
            end if;
            s_slot_v <= v_slot_v;
            s_cmd_rdy <= not v_slot_v;
            -- next burst size from the slot as it is now; valid one clock after any change of the slot
            s_n <= burst_beats(s_addr, s_left, G_MAX_BURST, G_DATA_W);
            if v_accept or v_issue then
                s_n_ok <= '0';
            else
                s_n_ok <= s_slot_v;
            end if;

            -- claimed W FIFO beats: + n at issue, - 1 per beat sent; outstanding bursts: + 1 at issue, - 1 per B
            v_claimed := s_claimed;
            if v_issue then
                v_claimed := v_claimed + s_n;
            end if;
            if s_w_push = '1' then
                v_claimed := v_claimed - 1;
            end if;
            s_claimed <= v_claimed;
            v_outst := s_outst;
            if v_issue then
                v_outst := v_outst + 1;
            end if;
            if s_b_v = '1' then
                v_outst := v_outst - 1;
            end if;
            s_outst <= v_outst;

            -- W emitter: one burst after the other, the next length is loaded with the last beat (no bubble)
            case s_wstate is
                when W_IDLE =>
                    if s_lenq_valid = '1' then
                        s_cnt <= to_integer(unsigned(s_lenq_dout));
                        s_wstate <= W_BURST;
                    end if;
                when W_BURST =>
                    if s_w_push = '1' then
                        if s_cnt = 0 then
                            if s_lenq_valid = '1' then
                                s_cnt <= to_integer(unsigned(s_lenq_dout));
                            else
                                s_wstate <= W_IDLE;
                            end if;
                        else
                            s_cnt <= s_cnt - 1;
                        end if;
                    end if;
            end case;

            -- B: registered once, then the tag says whether it closes a command
            s_bready <= '1';
            s_b_v <= m_axi_bvalid and s_bready;
            s_b_id <= m_axi_bid;
            s_b_resp <= m_axi_bresp;
            s_done <= '0';
            s_error <= '0';
            if s_b_v = '1' then
                assert s_dq_valid = '1' report "axi_master_wr: B without a final-burst tag (A12)" severity failure;
                assert unsigned(s_b_id) = 0 report "axi_master_wr: BID is not 0 (A12)" severity failure;
                assert s_b_resp /= "01" report "axi_master_wr: EXOKAY response (A12)" severity failure;
                v_err := s_err_acc or s_b_resp(1);
                if s_dq_dout(0) = '1' then
                    s_done <= '1';
                    s_error <= v_err;
                    s_err_acc <= '0';
                else
                    s_err_acc <= v_err;
                end if;
            end if;

            if i_rst = '1' then
                s_slot_v <= '0';
                s_cmd_rdy <= '0';
                s_n_ok <= '0';
                s_claimed <= 0;
                s_outst <= 0;
                s_wstate <= W_IDLE;
                s_bready <= '0';
                s_b_v <= '0';
                s_err_acc <= '0';
                s_done <= '0';
                s_error <= '0';
            end if;
        end if;
    end process;

    -- A11, simulation only: the requester's i_wlast must close each command after len + 1 accepted beats;
    -- command lengths and data lengths are queued separately, so data may come before, after or with its command
    -- pragma translate_off
    process(i_clk)
        constant C_QN : positive := 1024;
        type q_t is array (0 to C_QN-1) of natural;
        variable v_cq, v_dq : q_t;
        variable v_ch, v_cn, v_dh, v_dn : natural := 0;
        variable v_beats : natural := 0;
    begin
        if rising_edge(i_clk) then
            if i_rst = '1' then
                v_ch := 0;
                v_cn := 0;
                v_dh := 0;
                v_dn := 0;
                v_beats := 0;
            else
                if i_cmd_valid = '1' and s_cmd_rdy = '1' then
                    v_cq((v_ch + v_cn) mod C_QN) := to_integer(i_cmd_len) + 1;
                    v_cn := v_cn + 1;
                end if;
                if i_wdata_valid = '1' and s_wf_wrdy = '1' then
                    v_beats := v_beats + 1;
                    if i_wlast = '1' then
                        v_dq((v_dh + v_dn) mod C_QN) := v_beats;
                        v_dn := v_dn + 1;
                        v_beats := 0;
                    end if;
                end if;
                while v_cn > 0 and v_dn > 0 loop
                    assert v_cq(v_ch) = v_dq(v_dh)
                        report "axi_master_wr: i_wlast after " & integer'image(v_dq(v_dh)) & " beats, the command has "
                               & integer'image(v_cq(v_ch)) & " (A11)" severity failure;
                    v_ch := (v_ch + 1) mod C_QN;
                    v_cn := v_cn - 1;
                    v_dh := (v_dh + 1) mod C_QN;
                    v_dn := v_dn - 1;
                end loop;
                -- the data of the oldest open command already ran past its length without i_wlast
                assert not (v_cn > 0 and v_dn = 0 and v_beats > v_cq(v_ch))
                    report "axi_master_wr: no i_wlast on the last beat of a command (A11)" severity failure;
            end if;
        end if;
    end process;
    -- pragma translate_on
end architecture rtl;
