-- Author: Olimjon Mirzayusupov
-- axi_master_rd: AXI4 read master between the requesters of the accelerator and DDR (docs/plans/axi-ddr-master.md
-- section 6, .gateflow/plans/axi-ddr-master.md section F5)
-- requesters: G_N_RD read streams, stream s uses bit s / slice s of the flattened ports; a command is a whole
--   transfer of len + 1 beats (1 to 256) at a beat-aligned byte address that must not run past the top of the
--   address space; responses come back per stream in command order, o_rsp_last on the last beat of each command,
--   o_rsp_error = RRESP(1) per beat (SLVERR or DECERR, the burst is not aborted)
-- splitting: one command slot per stream holds (addr, beats left); the next burst has
--   burst_beats(addr, beats left, G_MAX_BURST, G_DATA_W) beats, so no burst crosses a 4 KB page or exceeds the
--   burst limit; the size is precomputed into a register one clock after the slot changes (at most one AR per two
--   clocks per stream), and a final-burst tag per burst marks the last burst of a command
-- IDs: ARID = stream number; bursts of one stream return in order, different streams may return out of order;
--   R beats are routed by RID into one FIFO per stream, so no reorder buffer is needed
-- credits: a burst is issued only if the stream FIFO has room for all its beats (credit counter per stream, given
--   back on every pop to the requester), so RREADY is a flip-flop held at 1 after reset and R is never back-pressured
-- arbitration: round robin over the eligible streams, at most G_MAX_OUTST bursts in flight over all streams
-- handshakes: m_axi_arvalid comes from the output flip-flop of axi_skid u_ar, m_axi_rready is a flip-flop,
--   o_cmd_ready and o_rsp_valid are flip-flops; AR fields other than id, addr and len are constants
-- one clock: i_clk, synchronous active-high reset i_rst
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;
use work.axi_pkg.all;

entity axi_master_rd is
    generic (
        G_N_RD       : positive := 1;                           -- read streams = ARIDs
        G_ID_W       : positive := 2;                           -- 2**G_ID_W >= G_N_RD, <= AXI_ID_W_MAX (asserted)
        G_DATA_W     : positive := AXI_DATA_W;                  -- 64 ZedBoard, 128 Ultra96
        G_ADDR_W     : positive := AXI_ADDR_W;
        G_MAX_BURST  : positive := AXI_MAX_BURST;               -- the splitter cuts bursts to this many beats, <= 256 (asserted)
        G_MAX_OUTST  : positive := 8;                           -- AR bursts in flight, all streams (TD-1)
        G_FIFO_BEATS : positive := 64;                          -- per stream = credit pool, >= G_MAX_BURST (asserted, TD-1)
        G_AXCACHE    : std_logic_vector(3 downto 0) := AXI_AXCACHE
    );
    port (
        i_clk, i_rst  : in  std_logic;
        -- requesters: stream s uses bit s / slice s; one command = up to 256 beats at any beat-aligned address
        i_cmd_valid   : in  std_logic_vector(G_N_RD-1 downto 0);
        o_cmd_ready   : out std_logic_vector(G_N_RD-1 downto 0);
        i_cmd_addr    : in  unsigned(G_N_RD*G_ADDR_W-1 downto 0);     -- byte address, beat aligned
        i_cmd_len     : in  unsigned(G_N_RD*8-1 downto 0);            -- beats - 1 of the whole transfer
        o_rsp_valid   : out std_logic_vector(G_N_RD-1 downto 0);
        i_rsp_ready   : in  std_logic_vector(G_N_RD-1 downto 0);
        o_rsp_data    : out std_logic_vector(G_N_RD*G_DATA_W-1 downto 0);
        o_rsp_last    : out std_logic_vector(G_N_RD-1 downto 0);      -- last beat of the command
        o_rsp_error   : out std_logic_vector(G_N_RD-1 downto 0);      -- RRESP(1) = '1' on this beat
        -- AXI4 AR
        m_axi_arid    : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_araddr  : out std_logic_vector(G_ADDR_W-1 downto 0);
        m_axi_arlen   : out std_logic_vector(7 downto 0);
        m_axi_arsize  : out std_logic_vector(2 downto 0);
        m_axi_arburst : out std_logic_vector(1 downto 0);
        m_axi_arlock  : out std_logic;
        m_axi_arcache : out std_logic_vector(3 downto 0);
        m_axi_arprot  : out std_logic_vector(2 downto 0);
        m_axi_arqos   : out std_logic_vector(3 downto 0);
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        -- AXI4 R
        m_axi_rid     : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_rdata   : in  std_logic_vector(G_DATA_W-1 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rlast   : in  std_logic;
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic
    );
end entity axi_master_rd;

architecture rtl of axi_master_rd is
    constant C_BYTES : positive := G_DATA_W / 8;
    constant C_OFF_W : natural := clog2(C_BYTES);
    constant C_RF_W  : positive := G_DATA_W + 2;                -- FIFO word: data & error & last
    constant C_AR_W  : positive := G_ID_W + G_ADDR_W + 8;       -- skid word: id & addr & len

    type addr_arr_t is array (0 to G_N_RD-1) of unsigned(G_ADDR_W-1 downto 0);
    type beats_arr_t is array (0 to G_N_RD-1) of natural range 0 to 256;
    type credit_arr_t is array (0 to G_N_RD-1) of natural range 0 to G_FIFO_BEATS;
    type rf_arr_t is array (0 to G_N_RD-1) of std_logic_vector(C_RF_W-1 downto 0);
    type tq_arr_t is array (0 to G_N_RD-1) of std_logic_vector(0 downto 0);

    -- command slots and splitters, one per stream
    signal s_addr      : addr_arr_t := (others => (others => '0'));
    signal s_left      : beats_arr_t := (others => 0);
    signal s_n         : beats_arr_t := (others => 0);         -- beats of the next burst, valid when s_n_ok
    signal s_slot_v    : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_n_ok      : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_cmd_rdy   : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_credit    : credit_arr_t := (others => G_FIFO_BEATS);
    signal s_outst     : natural range 0 to G_MAX_OUTST := 0;
    signal s_rr_ptr    : natural range 0 to G_N_RD-1 := 0;
    -- issue, combinational from flip-flops
    signal s_issue     : std_logic;
    signal s_grant     : natural range 0 to G_N_RD-1;
    signal s_final     : std_logic;
    signal s_ar_in     : std_logic_vector(C_AR_W-1 downto 0);
    signal s_ar_rdy    : std_logic;
    signal s_ar_out    : std_logic_vector(C_AR_W-1 downto 0);
    -- R capture
    signal s_rready    : std_logic := '0';
    signal s_r_v       : std_logic := '0';
    signal s_r_id      : std_logic_vector(G_ID_W-1 downto 0) := (others => '0');
    signal s_r_data    : std_logic_vector(G_DATA_W-1 downto 0) := (others => '0');
    signal s_r_resp    : std_logic_vector(1 downto 0) := "00";
    signal s_r_last    : std_logic := '0';
    -- per-stream FIFOs
    signal s_rf_we     : std_logic_vector(G_N_RD-1 downto 0);
    signal s_rf_wr_rdy : std_logic_vector(G_N_RD-1 downto 0);
    signal s_rf_wd     : rf_arr_t;
    signal s_rf_rd_v   : std_logic_vector(G_N_RD-1 downto 0);
    signal s_rf_rd     : rf_arr_t;
    signal s_pop       : std_logic_vector(G_N_RD-1 downto 0);
    signal s_tq_we     : std_logic_vector(G_N_RD-1 downto 0);
    signal s_tq_wr_rdy : std_logic_vector(G_N_RD-1 downto 0);
    signal s_tq_rd_v   : std_logic_vector(G_N_RD-1 downto 0);
    signal s_tq_rd     : tq_arr_t;
    signal s_tq_pop    : std_logic_vector(G_N_RD-1 downto 0);
begin
    assert 2 ** G_ID_W >= G_N_RD report "axi_master_rd: G_ID_W too small for G_N_RD streams" severity failure;
    assert G_ID_W <= AXI_ID_W_MAX report "axi_master_rd: G_ID_W exceeds the ID bits of the port" severity failure;
    assert G_MAX_BURST <= 256 report "axi_master_rd: G_MAX_BURST must be at most 256" severity failure;
    assert G_FIFO_BEATS >= G_MAX_BURST report "axi_master_rd: G_FIFO_BEATS must be at least G_MAX_BURST" severity failure;
    assert G_DATA_W >= 32 and 2 ** clog2(G_DATA_W) = G_DATA_W report "axi_master_rd: G_DATA_W must be a power of two >= 32" severity failure;
    assert G_ADDR_W >= 12 report "axi_master_rd: G_ADDR_W must be at least 12" severity failure;

    -- AR channel: constants, and id & addr & len from the skid
    m_axi_arid <= s_ar_out(C_AR_W-1 downto G_ADDR_W + 8);
    m_axi_araddr <= s_ar_out(G_ADDR_W + 7 downto 8);
    m_axi_arlen <= s_ar_out(7 downto 0);
    m_axi_arsize <= axi_size(G_DATA_W);
    m_axi_arburst <= AXI_BURST_INCR;
    m_axi_arlock <= '0';
    m_axi_arcache <= G_AXCACHE;
    m_axi_arprot <= "000";
    m_axi_arqos <= "0000";
    m_axi_rready <= s_rready;
    o_cmd_ready <= s_cmd_rdy;

    u_ar : entity work.axi_skid
        generic map (
            G_WIDTH => C_AR_W
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_valid => s_issue,
            o_ready => s_ar_rdy,
            i_data  => s_ar_in,
            o_valid => m_axi_arvalid,
            i_ready => m_axi_arready,
            o_data  => s_ar_out
        );

    -- round-robin grant over the eligible streams, from flip-flops only
    process(all)
        variable v_found : boolean;
        variable v_idx   : natural range 0 to G_N_RD-1;
    begin
        v_found := false;
        v_idx := 0;
        for i in 0 to G_N_RD - 1 loop
            v_idx := (s_rr_ptr + i) mod G_N_RD;
            if s_slot_v(v_idx) = '1' and s_n_ok(v_idx) = '1' and s_credit(v_idx) >= s_n(v_idx)
               and s_outst < G_MAX_OUTST and s_tq_wr_rdy(v_idx) = '1' then
                v_found := true;
                exit;
            end if;
        end loop;
        if v_found and s_ar_rdy = '1' then
            s_issue <= '1';
        else
            s_issue <= '0';
        end if;
        s_grant <= v_idx;
        if s_left(v_idx) = s_n(v_idx) then
            s_final <= '1';
        else
            s_final <= '0';
        end if;
        if s_n(v_idx) > 0 then
            s_ar_in <= std_logic_vector(to_unsigned(v_idx, G_ID_W)) & std_logic_vector(s_addr(v_idx))
                       & std_logic_vector(to_unsigned(s_n(v_idx) - 1, 8));
        else
            s_ar_in <= (others => '0');
        end if;
    end process;

    -- per stream: beat FIFO (data & error & last) and final-burst tag queue
    gen_stream : for s in 0 to G_N_RD - 1 generate
        s_rf_we(s) <= '1' when s_r_v = '1' and to_integer(unsigned(s_r_id)) = s else '0';
        s_rf_wd(s) <= s_r_data & s_r_resp(1) & (s_r_last and s_tq_rd(s)(0));
        s_tq_pop(s) <= s_rf_we(s) and s_r_last;
        s_tq_we(s) <= '1' when s_issue = '1' and s_grant = s else '0';
        s_pop(s) <= s_rf_rd_v(s) and i_rsp_ready(s);
        o_rsp_valid(s) <= s_rf_rd_v(s);
        o_rsp_data((s + 1) * G_DATA_W - 1 downto s * G_DATA_W) <= s_rf_rd(s)(C_RF_W-1 downto 2);
        o_rsp_error(s) <= s_rf_rd(s)(1);
        o_rsp_last(s) <= s_rf_rd(s)(0);

        u_rf : entity work.sync_fifo
            generic map (
                G_WIDTH => C_RF_W,
                G_DEPTH => G_FIFO_BEATS
            )
            port map (
                i_clk      => i_clk,
                i_rst      => i_rst,
                i_wr_valid => s_rf_we(s),
                o_wr_ready => s_rf_wr_rdy(s),
                i_wr_data  => s_rf_wd(s),
                o_rd_valid => s_rf_rd_v(s),
                i_rd_ready => i_rsp_ready(s),
                o_rd_data  => s_rf_rd(s),
                o_count    => open
            );

        u_tq : entity work.sync_fifo
            generic map (
                G_WIDTH => 1,
                G_DEPTH => G_MAX_OUTST
            )
            port map (
                i_clk        => i_clk,
                i_rst        => i_rst,
                i_wr_valid   => s_tq_we(s),
                o_wr_ready   => s_tq_wr_rdy(s),
                i_wr_data(0) => s_final,
                o_rd_valid   => s_tq_rd_v(s),
                i_rd_ready   => s_tq_pop(s),
                o_rd_data    => s_tq_rd(s),
                o_count      => open
            );
    end generate gen_stream;

    process(i_clk)
        variable v_acc, v_iss : boolean;
        variable v_slot_next  : std_logic;
        variable v_credit     : integer;
        variable v_outst      : integer;
        variable v_cmd_addr   : unsigned(G_ADDR_W-1 downto 0);
        variable v_cmd_beats  : natural range 1 to 256;
        variable v_end        : unsigned(G_ADDR_W downto 0);
    begin
        if rising_edge(i_clk) then
            -- bursts in flight: +1 per issue, -1 per RLAST
            v_outst := s_outst;
            if s_issue = '1' then
                v_outst := v_outst + 1;
                s_rr_ptr <= (s_grant + 1) mod G_N_RD;
            end if;
            if s_r_v = '1' and s_r_last = '1' then
                v_outst := v_outst - 1;
            end if;
            assert v_outst >= 0 and v_outst <= G_MAX_OUTST report "axi_master_rd: outstanding count out of range" severity failure;
            s_outst <= v_outst;

            for s in 0 to G_N_RD - 1 loop
                v_acc := i_cmd_valid(s) = '1' and s_cmd_rdy(s) = '1';
                v_iss := s_issue = '1' and s_grant = s;
                v_slot_next := s_slot_v(s);
                v_credit := s_credit(s);
                if v_iss then
                    v_credit := v_credit - s_n(s);
                    s_addr(s) <= s_addr(s) + to_unsigned(s_n(s) * C_BYTES, G_ADDR_W);
                    s_left(s) <= s_left(s) - s_n(s);
                    if s_left(s) = s_n(s) then
                        v_slot_next := '0';
                    end if;
                end if;
                if s_pop(s) = '1' then
                    v_credit := v_credit + 1;
                end if;
                assert v_credit >= 0 and v_credit <= G_FIFO_BEATS report "axi_master_rd: credit out of range" severity failure;
                s_credit(s) <= v_credit;
                if v_acc then
                    v_cmd_addr := i_cmd_addr((s + 1) * G_ADDR_W - 1 downto s * G_ADDR_W);
                    v_cmd_beats := to_integer(i_cmd_len((s + 1) * 8 - 1 downto s * 8)) + 1;
                    s_addr(s) <= v_cmd_addr;
                    s_left(s) <= v_cmd_beats;
                    v_slot_next := '1';
                    assert to_integer(v_cmd_addr(C_OFF_W-1 downto 0)) = 0
                        report "axi_master_rd: command address is not beat aligned" severity failure;
                    v_end := resize(v_cmd_addr, G_ADDR_W + 1) + to_unsigned(v_cmd_beats * C_BYTES, G_ADDR_W + 1);
                    -- end address at most 2**G_ADDR_W: the carry bit may only be set with all lower bits zero
                    assert v_end(G_ADDR_W) = '0' or v_end(G_ADDR_W-1 downto 0) = 0
                        report "axi_master_rd: command runs past the top of the address space" severity failure;
                end if;
                s_slot_v(s) <= v_slot_next;
                s_cmd_rdy(s) <= not v_slot_next;
                -- next burst size, valid one clock after the slot settles
                s_n(s) <= burst_beats(s_addr(s), s_left(s), G_MAX_BURST, G_DATA_W);
                if v_acc or v_iss then
                    s_n_ok(s) <= '0';
                else
                    s_n_ok(s) <= s_slot_v(s);
                end if;
            end loop;

            -- R capture: RREADY is held at 1, every beat is registered once and written into its stream FIFO
            s_rready <= '1';
            s_r_v <= m_axi_rvalid and s_rready;
            s_r_id <= m_axi_rid;
            s_r_data <= m_axi_rdata;
            s_r_resp <= m_axi_rresp;
            s_r_last <= m_axi_rlast;

            -- run-time checks of the beat written in this clock (A7, A12)
            if s_r_v = '1' then
                assert to_integer(unsigned(s_r_id)) < G_N_RD report "axi_master_rd: RID of no stream" severity failure;
                assert s_r_resp /= "01" report "axi_master_rd: unexpected EXOKAY" severity failure;
                for s in 0 to G_N_RD - 1 loop
                    if s_rf_we(s) = '1' then
                        assert s_rf_wr_rdy(s) = '1' report "axi_master_rd: stream FIFO full on an R beat (credit error)" severity failure;
                        if s_r_last = '1' then
                            assert s_tq_rd_v(s) = '1' report "axi_master_rd: no final-burst tag at RLAST" severity failure;
                        end if;
                    end if;
                end loop;
            end if;

            if i_rst = '1' then
                s_slot_v <= (others => '0');
                s_n_ok <= (others => '0');
                s_cmd_rdy <= (others => '0');
                s_credit <= (others => G_FIFO_BEATS);
                s_outst <= 0;
                s_rr_ptr <= 0;
                s_rready <= '0';
                s_r_v <= '0';
            end if;
        end if;
    end process;
end architecture rtl;
