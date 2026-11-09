-- Author: Olimjon Mirzayusupov
-- self-checking unit test for axi_master_rd against axi_mem_model (.gateflow/plans/axi-ddr-master.md, read master
-- test matrix r1-r5); the model checks the bus (A1-A5) and stops the simulation on any protocol violation
-- every stream has a driver (directed commands, then random commands of 1-256 beats at random beat-aligned
-- addresses of its own 64 KB window, preloaded through the backdoor) and a checker (random o_rsp ready, then per
-- beat: data byte-exact against the memory, command order, o_rsp_last only on each command's last beat, o_rsp_error
-- exactly for beats inside the error window of commands issued while i_err_en was on)
-- directed cases per stream: len 0 and 255, G_MAX_BURST beats (no split) and G_MAX_BURST + 1 (one split), a command
-- starting one beat before a 4 KB boundary, one ending exactly on a boundary, 40 single-beat commands back to back;
-- stream 0 also: the 40-beat example of docs/plans/axi-ddr-master.md section 9 and an error phase (straddling the
-- window start, inside, straddling the window end, then the window again with error injection off)
-- end checks: AR bursts and R beats seen by the model equal the TB's own split of every command, zero violations,
-- m_axi_rready = '1' on every clock from the second clock after reset (A6), and coverage counters that must not be 0:
-- commands split at 4 KB / at the burst limit / by both, error beats, the outstanding limit reached, plus ARREADY
-- stalls (ready < 100 %), out-of-order returns (G_REORDER, several streams) and credit pressure (o_rsp ready < 100 %);
-- outstanding bursts and reserved beats are tracked on the bus (lower bounds of the DUT's counters), because
-- VHDL-2008 external names fail at run time in this GHDL build
-- configurations (from vhdl/, after analysis and elaboration):
--   r1: ghdl -r --std=08 --workdir=<dir> tb_axi_master_rd -gG_N_RD=1 -gG_DATA_W=64 -gG_READY_PCT=100 -gG_RD_LAT_MAX=30 -gG_REORDER=false -gG_SEED=1
--   r2: ghdl -r --std=08 --workdir=<dir> tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_SEED=1
--   r3: ghdl -r --std=08 --workdir=<dir> tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=30 -gG_RD_LAT_MAX=40 -gG_REORDER=true -gG_SEED=1
--   r4: ghdl -r --std=08 --workdir=<dir> tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_RSP_READY_PCT=30 -gG_SEED=1
--   r5: ghdl -r --std=08 --workdir=<dir> tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=128 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_SEED=1
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/axi_pkg.vhd src/interface/sync_fifo.vhd src/interface/axi_skid.vhd \
--        src/interface/axi_master_rd.vhd tests/models/axi_mem_model.vhd tests/unit/interface/tb_axi_master_rd.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_axi_master_rd
--   then one of the configurations above
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;
use work.axi_pkg.all;
use work.axi_mem_model_pkg.all;
use work.axi_mem_model_shared.all;

entity tb_axi_master_rd is
    generic (
        G_N_RD          : positive := 1;
        G_DATA_W        : positive := 64;
        G_READY_PCT     : natural := 100;      -- model AR ready
        G_RD_LAT_MAX    : natural := 30;       -- model read latency 0..max
        G_REORDER       : boolean := false;    -- model returns out of order across IDs
        G_RSP_READY_PCT : natural := 100;      -- requester o_rsp ready
        G_GAP_PCT       : natural := 0;        -- model idle clocks between R beats
        G_ACCEPT        : positive := 8;       -- model outstanding reads
        G_MAX_OUTST     : positive := 8;       -- DUT
        G_FIFO_BEATS    : positive := 64;      -- DUT
        G_N_CMDS        : natural := 200;      -- random commands per stream
        G_SEED          : positive := 1
    );
end entity tb_axi_master_rd;

architecture sim of tb_axi_master_rd is
    constant C_PERIOD  : time := 5 ns;
    constant C_ID_W    : positive := 2;
    constant C_BYTES   : positive := G_DATA_W / 8;
    constant C_MAXB    : positive := 16;
    constant C_WIN     : natural := 16#10000#;        -- preloaded bytes per stream window
    constant C_ERR_LO  : natural := 16#10008100#;     -- error window, off any 4 KB boundary
    constant C_ERR_HI  : natural := 16#10008200#;
    constant C_TIMEOUT : natural := 4000000;          -- clocks

    -- commands from the driver to the checker of one stream
    type cmdq_pt is protected
        procedure push(addr : unsigned(31 downto 0); beats : positive; err : boolean);
        procedure pop(addr : out unsigned(31 downto 0); beats : out positive; err : out boolean);
        impure function count return natural;
    end protected cmdq_pt;

    type cmdq_pt is protected body
        constant C_D : positive := 4096;
        type a_arr_t is array (0 to C_D-1) of unsigned(31 downto 0);
        type n_arr_t is array (0 to C_D-1) of positive;
        type e_arr_t is array (0 to C_D-1) of boolean;
        variable v_a    : a_arr_t;
        variable v_n    : n_arr_t;
        variable v_e    : e_arr_t;
        variable v_head : natural := 0;
        variable v_cnt  : natural := 0;

        procedure push(addr : unsigned(31 downto 0); beats : positive; err : boolean) is
        begin
            assert v_cnt < C_D report "tb: command queue overflow" severity failure;
            v_a((v_head + v_cnt) mod C_D) := addr;
            v_n((v_head + v_cnt) mod C_D) := beats;
            v_e((v_head + v_cnt) mod C_D) := err;
            v_cnt := v_cnt + 1;
        end procedure push;

        procedure pop(addr : out unsigned(31 downto 0); beats : out positive; err : out boolean) is
        begin
            assert v_cnt > 0 report "tb: command queue underflow" severity failure;
            addr := v_a(v_head);
            beats := v_n(v_head);
            err := v_e(v_head);
            v_head := (v_head + 1) mod C_D;
            v_cnt := v_cnt - 1;
        end procedure pop;

        impure function count return natural is
        begin
            return v_cnt;
        end function count;
    end protected body cmdq_pt;

    type nat_arr_t is array (0 to G_N_RD-1) of natural;

    -- recognisable memory content: every byte depends on all address bytes
    function pat(a : unsigned(31 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((to_integer(a(7 downto 0)) + 3 * to_integer(a(15 downto 8))
               + 5 * to_integer(a(23 downto 16)) + 7 * to_integer(a(31 downto 24))) mod 256, 8));
    end function pat;

    function in_window(a : unsigned(31 downto 0)) return boolean is
    begin
        return a >= to_unsigned(C_ERR_LO, 32) and a < to_unsigned(C_ERR_HI, 32);
    end function in_window;

    function base_of(s : natural) return unsigned is
    begin
        return to_unsigned(16#10000000# * (s + 1), 32);
    end function base_of;

    constant C_Z_ID   : std_logic_vector(C_ID_W-1 downto 0) := (others => '0');
    constant C_Z_ADDR : std_logic_vector(31 downto 0) := (others => '0');
    constant C_Z_DATA : std_logic_vector(G_DATA_W-1 downto 0) := (others => '0');
    constant C_Z_STRB : std_logic_vector(C_BYTES-1 downto 0) := (others => '0');

    signal s_clk      : std_logic := '0';
    signal s_rst      : std_logic := '1';
    signal s_finished : boolean := false;
    signal s_start    : boolean := false;
    signal s_err_req  : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_err_en   : boolean;

    -- requester side of the DUT
    signal s_cmd_valid : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_cmd_ready : std_logic_vector(G_N_RD-1 downto 0);
    signal s_cmd_addr  : unsigned(G_N_RD*32-1 downto 0) := (others => '0');
    signal s_cmd_len   : unsigned(G_N_RD*8-1 downto 0) := (others => '0');
    signal s_rsp_valid : std_logic_vector(G_N_RD-1 downto 0);
    signal s_rsp_ready : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    signal s_rsp_data  : std_logic_vector(G_N_RD*G_DATA_W-1 downto 0);
    signal s_rsp_last  : std_logic_vector(G_N_RD-1 downto 0);
    signal s_rsp_error : std_logic_vector(G_N_RD-1 downto 0);

    -- AXI read channels
    signal s_arid    : std_logic_vector(C_ID_W-1 downto 0);
    signal s_araddr  : std_logic_vector(31 downto 0);
    signal s_arlen   : std_logic_vector(7 downto 0);
    signal s_arsize  : std_logic_vector(2 downto 0);
    signal s_arburst : std_logic_vector(1 downto 0);
    signal s_arlock  : std_logic;
    signal s_arcache : std_logic_vector(3 downto 0);
    signal s_arprot  : std_logic_vector(2 downto 0);
    signal s_arqos   : std_logic_vector(3 downto 0);
    signal s_arvalid : std_logic;
    signal s_arready : std_logic;
    signal s_rid     : std_logic_vector(C_ID_W-1 downto 0);
    signal s_rdata   : std_logic_vector(G_DATA_W-1 downto 0);
    signal s_rresp   : std_logic_vector(1 downto 0);
    signal s_rlast   : std_logic;
    signal s_rvalid  : std_logic;
    signal s_rready  : std_logic;

    -- bookkeeping, one element per stream (driver or checker of that stream)
    signal s_issued    : nat_arr_t := (others => 0);    -- commands accepted
    signal s_done      : nat_arr_t := (others => 0);    -- commands fully checked
    signal s_exp_burst : nat_arr_t := (others => 0);    -- AR bursts expected from the split
    signal s_exp_beats : nat_arr_t := (others => 0);
    signal s_cov_4k    : nat_arr_t := (others => 0);    -- commands split only at 4 KB
    signal s_cov_maxb  : nat_arr_t := (others => 0);    -- only at the burst limit
    signal s_cov_both  : nat_arr_t := (others => 0);    -- by both
    signal s_chk_err   : nat_arr_t := (others => 0);
    signal s_err_beats : nat_arr_t := (others => 0);
    signal s_drv_done  : std_logic_vector(G_N_RD-1 downto 0) := (others => '0');
    -- monitor
    signal s_mon_err    : natural := 0;
    signal s_cov_outst  : natural := 0;
    signal s_cov_credit : natural := 0;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;
    s_err_en <= s_err_req(0) = '1';

    u_dut : entity work.axi_master_rd
        generic map (
            G_N_RD       => G_N_RD,
            G_ID_W       => C_ID_W,
            G_DATA_W     => G_DATA_W,
            G_ADDR_W     => 32,
            G_MAX_BURST  => C_MAXB,
            G_MAX_OUTST  => G_MAX_OUTST,
            G_FIFO_BEATS => G_FIFO_BEATS
        )
        port map (
            i_clk         => s_clk,
            i_rst         => s_rst,
            i_cmd_valid   => s_cmd_valid,
            o_cmd_ready   => s_cmd_ready,
            i_cmd_addr    => s_cmd_addr,
            i_cmd_len     => s_cmd_len,
            o_rsp_valid   => s_rsp_valid,
            i_rsp_ready   => s_rsp_ready,
            o_rsp_data    => s_rsp_data,
            o_rsp_last    => s_rsp_last,
            o_rsp_error   => s_rsp_error,
            m_axi_arid    => s_arid,
            m_axi_araddr  => s_araddr,
            m_axi_arlen   => s_arlen,
            m_axi_arsize  => s_arsize,
            m_axi_arburst => s_arburst,
            m_axi_arlock  => s_arlock,
            m_axi_arcache => s_arcache,
            m_axi_arprot  => s_arprot,
            m_axi_arqos   => s_arqos,
            m_axi_arvalid => s_arvalid,
            m_axi_arready => s_arready,
            m_axi_rid     => s_rid,
            m_axi_rdata   => s_rdata,
            m_axi_rresp   => s_rresp,
            m_axi_rlast   => s_rlast,
            m_axi_rvalid  => s_rvalid,
            m_axi_rready  => s_rready
        );

    u_mem : entity work.axi_mem_model
        generic map (
            G_DATA_W            => G_DATA_W,
            G_ID_W              => C_ID_W,
            G_ADDR_W            => 32,
            G_MAX_BURST         => C_MAXB,
            G_READY_PCT         => G_READY_PCT,
            G_RD_LAT_MAX        => G_RD_LAT_MAX,
            G_REORDER           => G_REORDER,
            G_ACCEPT            => G_ACCEPT,
            G_RVALID_GAP_PCT    => G_GAP_PCT,
            G_ERR_ADDR_LO       => C_ERR_LO,
            G_ERR_ADDR_HI       => C_ERR_HI,
            G_FAIL_ON_VIOLATION => true,
            G_SEED              => G_SEED
        )
        port map (
            i_clk         => s_clk,
            i_rst         => s_rst,
            i_err_en      => s_err_en,
            s_axi_arid    => s_arid,
            s_axi_araddr  => s_araddr,
            s_axi_arlen   => s_arlen,
            s_axi_arsize  => s_arsize,
            s_axi_arburst => s_arburst,
            s_axi_arlock  => s_arlock,
            s_axi_arcache => s_arcache,
            s_axi_arprot  => s_arprot,
            s_axi_arqos   => s_arqos,
            s_axi_arvalid => s_arvalid,
            s_axi_arready => s_arready,
            s_axi_rid     => s_rid,
            s_axi_rdata   => s_rdata,
            s_axi_rresp   => s_rresp,
            s_axi_rlast   => s_rlast,
            s_axi_rvalid  => s_rvalid,
            s_axi_rready  => s_rready,
            s_axi_awid    => C_Z_ID,
            s_axi_awaddr  => C_Z_ADDR,
            s_axi_awlen   => x"00",
            s_axi_awsize  => "000",
            s_axi_awburst => "01",
            s_axi_awvalid => '0',
            s_axi_awready => open,
            s_axi_wdata   => C_Z_DATA,
            s_axi_wstrb   => C_Z_STRB,
            s_axi_wlast   => '0',
            s_axi_wvalid  => '0',
            s_axi_wready  => open,
            s_axi_bid     => open,
            s_axi_bresp   => open,
            s_axi_bvalid  => open,
            s_axi_bready  => '0'
        );

    -- monitor on the bus: A6, outstanding bursts and reserved beats per stream (bus-level lower bounds of the DUT's
    -- own counters, so the limits are checked exactly and the coverage can only undercount)
    mon : process(s_clk)
        variable v_since_rst : natural := 0;
        variable v_err       : natural := 0;
        variable v_inflight  : natural := 0;    -- AR handshakes minus RLAST handshakes
        variable v_resv      : nat_arr_t := (others => 0);    -- beats requested on the bus minus beats popped
        variable v_outst     : natural := 0;
        variable v_credit    : natural := 0;
        variable v_pressed   : boolean;
        variable v_id        : natural;
        variable v_pend      : natural;
    begin
        if rising_edge(s_clk) then
            if s_rst = '1' then
                v_since_rst := 0;
                v_inflight := 0;
                v_resv := (others => 0);
            else
                v_since_rst := v_since_rst + 1;
                if v_since_rst >= 2 and s_rready /= '1' then
                    v_err := v_err + 1;
                    report "ERROR: m_axi_rready is not 1 after reset (A6) at " & time'image(now) severity error;
                end if;
                -- a presented AR is already counted by the DUT
                v_pend := 0;
                if s_arvalid = '1' then
                    v_pend := 1;
                end if;
                if v_inflight + v_pend > G_MAX_OUTST then
                    v_err := v_err + 1;
                    report "ERROR: more than G_MAX_OUTST bursts in flight (A8) at " & time'image(now) severity error;
                elsif v_inflight + v_pend = G_MAX_OUTST then
                    v_outst := v_outst + 1;
                end if;
                if s_arvalid = '1' and s_arready = '1' then
                    v_inflight := v_inflight + 1;
                    v_id := to_integer(unsigned(s_arid));
                    if v_id < G_N_RD then
                        v_resv(v_id) := v_resv(v_id) + to_integer(unsigned(s_arlen)) + 1;
                    end if;
                end if;
                if s_rvalid = '1' and s_rready = '1' and s_rlast = '1' then
                    v_inflight := v_inflight - 1;
                end if;
                v_pressed := false;
                for i in 0 to G_N_RD - 1 loop
                    if s_rsp_valid(i) = '1' and s_rsp_ready(i) = '1' then
                        v_resv(i) := v_resv(i) - 1;
                    end if;
                    if v_resv(i) > G_FIFO_BEATS then
                        v_err := v_err + 1;
                        report "ERROR: stream " & integer'image(i) & " has more beats requested than its FIFO holds (credit) at "
                               & time'image(now) severity error;
                    end if;
                    if v_resv(i) > G_FIFO_BEATS - C_MAXB then
                        v_pressed := true;
                    end if;
                end loop;
                if v_pressed then
                    v_credit := v_credit + 1;
                end if;
            end if;
            s_mon_err <= v_err;
            s_cov_outst <= v_outst;
            s_cov_credit <= v_credit;
        end if;
    end process mon;

    gen_s : for s in 0 to G_N_RD - 1 generate
        shared variable sb : cmdq_pt;
        constant C_BASE : unsigned(31 downto 0) := base_of(s);
    begin
        -- driver: directed commands, random commands, and (stream 0) the error phase
        drv : process
            variable v_seed1  : positive := G_SEED + 101 * s;
            variable v_seed2  : positive := 7 + 13 * s;
            variable v_issued : natural := 0;
            variable v_bursts : natural := 0;
            variable v_beats  : natural := 0;
            variable v_c4k, v_cmb, v_cboth : natural := 0;
            variable v_r, v_nb, v_off, v_idle : natural;

            procedure rnd(lo, hi : natural; n : out natural) is
                variable v_x : real;
                variable v_n : natural;
            begin
                uniform(v_seed1, v_seed2, v_x);
                v_n := lo + natural(floor(v_x * real(hi - lo + 1)));
                if v_n > hi then
                    v_n := hi;
                end if;
                n := v_n;
            end procedure rnd;

            -- called at a falling edge: present the command, wait for the handshake, book the expected split
            procedure send(addr : unsigned(31 downto 0); beats : positive; err : boolean; idle : natural) is
                variable v_a    : unsigned(31 downto 0);
                variable v_left : natural;
                variable v_k    : natural;
                variable v_page : natural;
                variable v_x4k  : boolean := false;
                variable v_xmb  : boolean := false;
            begin
                s_cmd_addr((s + 1) * 32 - 1 downto s * 32) <= addr;
                s_cmd_len((s + 1) * 8 - 1 downto s * 8) <= to_unsigned(beats - 1, 8);
                s_cmd_valid(s) <= '1';
                loop
                    wait until rising_edge(s_clk);
                    exit when s_cmd_ready(s) = '1';
                end loop;
                sb.push(addr, beats, err);
                v_issued := v_issued + 1;
                v_beats := v_beats + beats;
                v_a := addr;
                v_left := beats;
                while v_left > 0 loop
                    v_k := burst_beats(v_a, v_left, C_MAXB, G_DATA_W);
                    v_page := beats_to_4k(v_a, G_DATA_W);
                    if v_k < v_left then
                        if v_k = v_page and v_page <= C_MAXB then
                            v_x4k := true;
                        else
                            v_xmb := true;
                        end if;
                    end if;
                    v_bursts := v_bursts + 1;
                    v_a := v_a + to_unsigned(v_k * C_BYTES, 32);
                    v_left := v_left - v_k;
                end loop;
                if v_x4k and v_xmb then
                    v_cboth := v_cboth + 1;
                elsif v_x4k then
                    v_c4k := v_c4k + 1;
                elsif v_xmb then
                    v_cmb := v_cmb + 1;
                end if;
                s_issued(s) <= v_issued;
                s_exp_burst(s) <= v_bursts;
                s_exp_beats(s) <= v_beats;
                s_cov_4k(s) <= v_c4k;
                s_cov_maxb(s) <= v_cmb;
                s_cov_both(s) <= v_cboth;
                wait until falling_edge(s_clk);
                if idle > 0 then
                    s_cmd_valid(s) <= '0';
                    for i in 1 to idle loop
                        wait until falling_edge(s_clk);
                    end loop;
                end if;
            end procedure send;

            procedure wait_checked is
            begin
                if s_done(s) /= v_issued then
                    wait until s_done(s) = v_issued;
                end if;
                wait until falling_edge(s_clk);
            end procedure wait_checked;
        begin
            wait until s_start;
            wait until falling_edge(s_clk);
            -- directed
            send(C_BASE + to_unsigned(16#100#, 32), 1, false, 0);
            send(C_BASE + to_unsigned(16#200#, 32), 256, false, 0);
            send(C_BASE + to_unsigned(16#1040#, 32), C_MAXB, false, 0);
            send(C_BASE + to_unsigned(16#2080#, 32), C_MAXB + 1, false, 0);
            send(C_BASE + to_unsigned(16#3000# - C_BYTES, 32), 21, false, 0);
            send(C_BASE + to_unsigned(16#5000# - 32 * C_BYTES, 32), 32, false, 0);
            send(C_BASE + to_unsigned(16#7000# - 4 * C_BYTES, 32), 8, false, 0);    -- split only at 4 KB: 4 + 4
            if s = 0 then
                send(x"10000FE0", 40, false, 0);
            end if;
            for i in 0 to 39 loop
                send(C_BASE + to_unsigned(16#6000# + i * C_BYTES, 32), 1, false, 0);
            end loop;
            -- random
            for i in 1 to G_N_CMDS loop
                rnd(0, 99, v_r);
                if v_r < 40 then
                    rnd(1, 16, v_nb);
                elsif v_r < 70 then
                    rnd(17, 64, v_nb);
                else
                    rnd(1, 256, v_nb);
                end if;
                rnd(0, C_WIN / C_BYTES - 256, v_off);
                rnd(0, 99, v_r);
                if v_r < 70 then
                    v_idle := 0;
                else
                    rnd(1, 5, v_idle);
                end if;
                send(C_BASE + to_unsigned(v_off * C_BYTES, 32), v_nb, false, v_idle);
            end loop;
            -- error phase on stream 0: every AR of these commands is issued while i_err_en is on
            if s = 0 then
                s_cmd_valid(s) <= '0';
                wait_checked;
                s_err_req(s) <= '1';       -- s = 0 here; indexing by s keeps one driver per element
                wait until falling_edge(s_clk);
                send(to_unsigned(C_ERR_LO - 2 * C_BYTES, 32), 6, true, 0);
                send(to_unsigned(C_ERR_LO, 32), 4, true, 0);
                send(to_unsigned(C_ERR_HI - 2 * C_BYTES, 32), 5, true, 0);
                s_cmd_valid(s) <= '0';
                wait_checked;
                s_err_req(s) <= '0';
                wait until falling_edge(s_clk);
                send(to_unsigned(C_ERR_LO, 32), 4, false, 0);
            end if;
            s_cmd_valid(s) <= '0';
            s_drv_done(s) <= '1';
            wait;
        end process drv;

        -- checker: random o_rsp ready, every beat against the memory and the command it belongs to
        chk : process
            variable v_seed1  : positive := G_SEED + 211 * s + 5;
            variable v_seed2  : positive := 3 + 17 * s;
            variable v_x      : real;
            variable v_addr   : unsigned(31 downto 0);
            variable v_baddr  : unsigned(31 downto 0);
            variable v_beats  : positive;
            variable v_err    : boolean;
            variable v_k      : natural := 0;
            variable v_active : boolean := false;
            variable v_exp    : std_logic_vector(G_DATA_W-1 downto 0);
            variable v_exp_e  : boolean;
            variable v_errs   : natural := 0;
            variable v_done   : natural := 0;
            variable v_ebeats : natural := 0;

            procedure fail(msg : string) is
            begin
                v_errs := v_errs + 1;
                report "ERROR: stream " & integer'image(s) & ": " & msg & " at " & time'image(now) severity error;
            end procedure fail;
        begin
            wait until falling_edge(s_clk);
            loop
                uniform(v_seed1, v_seed2, v_x);
                if v_x * 100.0 < real(G_RSP_READY_PCT) then
                    s_rsp_ready(s) <= '1';
                else
                    s_rsp_ready(s) <= '0';
                end if;
                wait until rising_edge(s_clk);
                if s_rsp_valid(s) = '1' and s_rsp_ready(s) = '1' then
                    if not v_active then
                        if sb.count = 0 then
                            fail("response beat without a command");
                        else
                            sb.pop(v_addr, v_beats, v_err);
                            v_k := 0;
                            v_active := true;
                        end if;
                    end if;
                    if v_active then
                        v_baddr := v_addr + to_unsigned(v_k * C_BYTES, 32);
                        mem_read(v_baddr, v_exp);
                        if s_rsp_data((s + 1) * G_DATA_W - 1 downto s * G_DATA_W) /= v_exp then
                            fail("data of beat " & integer'image(v_k) & " at " & to_hstring(v_baddr));
                        end if;
                        v_exp_e := v_err and in_window(v_baddr);
                        if (s_rsp_error(s) = '1') /= v_exp_e then
                            fail("o_rsp_error " & std_logic'image(s_rsp_error(s)) & " on beat at " & to_hstring(v_baddr));
                        end if;
                        if s_rsp_error(s) = '1' then
                            v_ebeats := v_ebeats + 1;
                        end if;
                        if (s_rsp_last(s) = '1') /= (v_k = v_beats - 1) then
                            fail("o_rsp_last " & std_logic'image(s_rsp_last(s)) & " on beat " & integer'image(v_k)
                                 & " of " & integer'image(v_beats));
                        end if;
                        v_k := v_k + 1;
                        if v_k = v_beats then
                            v_active := false;
                            v_done := v_done + 1;
                        end if;
                    end if;
                end if;
                s_done(s) <= v_done;
                s_chk_err(s) <= v_errs;
                s_err_beats(s) <= v_ebeats;
                exit when s_finished;
                wait until falling_edge(s_clk);
            end loop;
            wait;
        end process chk;
    end generate gen_s;

    -- control: preload, reset, start, wait for the end, final checks
    ctl : process
        variable v_n      : natural := 0;
        variable v_all    : boolean;
        variable v_errors : natural := 0;
        variable v_bursts, v_beats, v_c4k, v_cmb, v_cboth, v_ebeats, v_chk : natural := 0;
        variable v_a      : unsigned(31 downto 0);
        variable v_beat   : std_logic_vector(G_DATA_W-1 downto 0);

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                report "ERROR: " & msg severity error;
            end if;
        end procedure check;
    begin
        s_rst <= '1';
        for s in 0 to G_N_RD - 1 loop
            for b in 0 to C_WIN / C_BYTES - 1 loop
                v_a := base_of(s) + to_unsigned(b * C_BYTES, 32);
                for i in 0 to C_BYTES - 1 loop
                    v_beat(8 * i + 7 downto 8 * i) := pat(v_a + to_unsigned(i, 32));
                end loop;
                mem_write(v_a, v_beat);
            end loop;
        end loop;
        for i in 1 to 5 loop
            wait until falling_edge(s_clk);
        end loop;
        s_rst <= '0';
        for i in 1 to 3 loop
            wait until falling_edge(s_clk);
        end loop;
        s_start <= true;

        loop
            wait until rising_edge(s_clk);
            v_n := v_n + 1;
            v_all := s_drv_done = (s_drv_done'range => '1');
            for s in 0 to G_N_RD - 1 loop
                v_all := v_all and s_done(s) = s_issued(s);
            end loop;
            exit when v_all;
            if v_n > C_TIMEOUT then
                report "FAIL: timeout, commands still open" severity failure;
            end if;
        end loop;
        for i in 1 to 30 loop
            wait until rising_edge(s_clk);
        end loop;

        for s in 0 to G_N_RD - 1 loop
            v_bursts := v_bursts + s_exp_burst(s);
            v_beats := v_beats + s_exp_beats(s);
            v_c4k := v_c4k + s_cov_4k(s);
            v_cmb := v_cmb + s_cov_maxb(s);
            v_cboth := v_cboth + s_cov_both(s);
            v_ebeats := v_ebeats + s_err_beats(s);
            v_chk := v_chk + s_chk_err(s);
        end loop;
        check(v_chk = 0, integer'image(v_chk) & " scoreboard errors");
        check(s_mon_err = 0, integer'image(s_mon_err) & " monitor errors (A6, A8, credit)");
        check(axi_stats.get(ST_AR) = v_bursts, "AR bursts " & integer'image(axi_stats.get(ST_AR)) & ", expected " & integer'image(v_bursts));
        check(axi_stats.get(ST_R_BEATS) = v_beats, "R beats " & integer'image(axi_stats.get(ST_R_BEATS)) & ", expected " & integer'image(v_beats));
        check(axi_stats.get(ST_VIOLATION) = 0, "model violations");
        check(v_c4k > 0, "coverage: no command split only at 4 KB");
        check(v_cmb > 0, "coverage: no command split only at the burst limit");
        check(v_cboth > 0, "coverage: no command split by both");
        check(v_ebeats > 0 and axi_stats.get(ST_R_ERR) = v_ebeats, "coverage: error beats " & integer'image(v_ebeats)
              & ", model " & integer'image(axi_stats.get(ST_R_ERR)));
        check(s_cov_outst > 0, "coverage: the outstanding limit was never reached");
        if G_READY_PCT < 100 then
            check(axi_stats.get(ST_AR_STALL) > 0, "coverage: no ARREADY stall");
        end if;
        if G_REORDER and G_N_RD > 1 then
            check(axi_stats.get(ST_R_REORDER) > 0, "coverage: no out-of-order return");
        end if;
        if G_RSP_READY_PCT < 100 then
            check(s_cov_credit > 0, "coverage: no credit pressure (less than one burst of credit left)");
        end if;

        report "r: streams " & integer'image(G_N_RD) & ", " & integer'image(G_DATA_W) & " bit, ready " & integer'image(G_READY_PCT)
               & " %, latency <= " & integer'image(G_RD_LAT_MAX) & ", rsp ready " & integer'image(G_RSP_READY_PCT) & " %, seed "
               & integer'image(G_SEED) & ": bursts " & integer'image(v_bursts) & ", beats " & integer'image(v_beats)
               & ", split 4k/max/both " & integer'image(v_c4k) & "/" & integer'image(v_cmb) & "/" & integer'image(v_cboth)
               & ", error beats " & integer'image(v_ebeats) & ", reorders " & integer'image(axi_stats.get(ST_R_REORDER))
               & ", AR stalls " & integer'image(axi_stats.get(ST_AR_STALL)) & ", clocks at outstanding limit "
               & integer'image(s_cov_outst) & ", credit pressure clocks " & integer'image(s_cov_credit) & ", "
               & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process ctl;
end architecture sim;
