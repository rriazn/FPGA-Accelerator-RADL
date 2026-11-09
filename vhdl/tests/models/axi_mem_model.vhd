-- Author: Olimjon Mirzayusupov
-- axi_mem_model: simulation-only AXI4 slave memory for the testbenches of the AXI DDR masters
-- (.gateflow/plans/axi-ddr-master.md section F7); compile tests/models/axi_mem_model_pkg.vhd and
-- tests/models/axi_mem_model_shared.vhd first
-- memory: the shared variable axi_mem of package axi_mem_model_shared, so a testbench preloads and checks it through
--   the backdoor procedures mem_write / mem_read; one model instance per simulation
-- regions: 4 regions of G_REGION_BYTES at G_BASE_0..3; an AXI write outside every region is a violation,
--   an AXI read outside returns whatever the memory holds (x"A5" if never written)
-- behaviour: random AR/AW/W ready (G_READY_PCT), random read and write latency, out-of-order returns across IDs
--   (G_REORDER, always in order within an ID), at most G_ACCEPT outstanding reads and G_ACCEPT outstanding writes,
--   random gaps between R beats, SLVERR for beats inside [G_ERR_ADDR_LO, G_ERR_ADDR_HI) while i_err_en is true
--   (an erroring write beat is not written), W beats may arrive before their AW
-- checks (violation_t): AR/AW/W valid and payload stable until the handshake, INCR bursts, full-width size,
--   at most G_MAX_BURST beats, beat-aligned addresses, no 4 KB crossing, WLAST exactly on the last beat,
--   no write outside the regions, no X on the master's valids and readys;
--   G_FAIL_ON_VIOLATION stops the simulation, otherwise the violation is counted (for negative tests)
-- statistics (shared variable axi_stats in axi_mem_model_shared): handshakes, stalls, reorders, errors, acceptance-limit cycles, bursts that
--   end exactly on a 4 KB boundary and violations, for the coverage checks of the testbenches
-- addresses are 32 bit; region bases and the error window are naturals, so they must be below 0x8000_0000
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;
use work.axi_pkg.all;
use work.axi_mem_model_pkg.all;
use work.axi_mem_model_shared.all;

entity axi_mem_model is
    generic (
        G_DATA_W            : positive := AXI_DATA_W;
        G_ID_W              : positive := 2;
        G_ADDR_W            : positive := AXI_ADDR_W;      -- must be 32
        G_MAX_BURST         : positive := AXI_MAX_BURST;   -- longer bursts are a violation (16 = the ZedBoard's AXI3 port)
        G_REGION_BYTES      : positive := 262144;          -- 256 KB per region
        G_BASE_0            : natural := 16#10000000#;
        G_BASE_1            : natural := 16#20000000#;
        G_BASE_2            : natural := 16#30000000#;
        G_BASE_3            : natural := 16#40000000#;
        G_READY_PCT         : natural := 70;               -- chance per clock that AR, AW and W ready are high
        G_RD_LAT_MAX        : natural := 3;                -- extra clocks from the AR handshake to the first beat, 0..max
        G_WR_LAT_MAX        : natural := 3;                -- extra clocks from the last W beat to B, 0..max
        G_REORDER           : boolean := true;             -- out of order across IDs
        G_ACCEPT            : positive := 8;               -- outstanding reads, and outstanding writes
        G_RVALID_GAP_PCT    : natural := 0;                -- chance of an idle clock after each R beat
        G_ERR_ADDR_LO       : natural := 0;                -- SLVERR window [lo, hi), empty when lo >= hi
        G_ERR_ADDR_HI       : natural := 0;
        G_FAIL_ON_VIOLATION : boolean := true;
        G_SEED              : positive := 1
    );
    port (
        i_clk, i_rst  : in  std_logic;
        i_err_en      : in  boolean := false;              -- SLVERR in the window only while true
        -- AXI4 slave, read address
        s_axi_arid    : in  std_logic_vector(G_ID_W-1 downto 0);
        s_axi_araddr  : in  std_logic_vector(G_ADDR_W-1 downto 0);
        s_axi_arlen   : in  std_logic_vector(7 downto 0);
        s_axi_arsize  : in  std_logic_vector(2 downto 0);
        s_axi_arburst : in  std_logic_vector(1 downto 0);
        s_axi_arlock  : in  std_logic := '0';
        s_axi_arcache : in  std_logic_vector(3 downto 0) := "0000";
        s_axi_arprot  : in  std_logic_vector(2 downto 0) := "000";
        s_axi_arqos   : in  std_logic_vector(3 downto 0) := "0000";
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        -- read data
        s_axi_rid     : out std_logic_vector(G_ID_W-1 downto 0);
        s_axi_rdata   : out std_logic_vector(G_DATA_W-1 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rlast   : out std_logic;
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;
        -- write address
        s_axi_awid    : in  std_logic_vector(G_ID_W-1 downto 0);
        s_axi_awaddr  : in  std_logic_vector(G_ADDR_W-1 downto 0);
        s_axi_awlen   : in  std_logic_vector(7 downto 0);
        s_axi_awsize  : in  std_logic_vector(2 downto 0);
        s_axi_awburst : in  std_logic_vector(1 downto 0);
        s_axi_awlock  : in  std_logic := '0';
        s_axi_awcache : in  std_logic_vector(3 downto 0) := "0000";
        s_axi_awprot  : in  std_logic_vector(2 downto 0) := "000";
        s_axi_awqos   : in  std_logic_vector(3 downto 0) := "0000";
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        -- write data
        s_axi_wdata   : in  std_logic_vector(G_DATA_W-1 downto 0);
        s_axi_wstrb   : in  std_logic_vector(G_DATA_W/8-1 downto 0);
        s_axi_wlast   : in  std_logic;
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        -- write response
        s_axi_bid     : out std_logic_vector(G_ID_W-1 downto 0);
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic
    );
end entity axi_mem_model;

architecture sim of axi_mem_model is
    constant C_BYTES : positive := G_DATA_W / 8;
    constant C_OFF_W : natural := clog2(C_BYTES);
    constant C_N_ID  : positive := 2 ** G_ID_W;
    constant C_QD    : positive := G_ACCEPT + 1;      -- per-ID queue depth, outstanding is bounded by G_ACCEPT
    constant C_WQ    : positive := 4096;              -- W beats that may wait for their AW
    constant C_A_W   : positive := G_ID_W + G_ADDR_W + 8 + 3 + 2;
    constant C_W_W   : positive := G_DATA_W + C_BYTES + 1;

    type rb_t is record
        addr  : unsigned(31 downto 0);
        len   : natural;
        ready : natural;     -- first clock at which the first beat may be presented
        seq   : natural;     -- global acceptance order
        err   : boolean;     -- error injection was on at the handshake
    end record;
    type rq_t is array (0 to C_N_ID-1, 0 to C_QD-1) of rb_t;
    type bb_t is record
        err   : boolean;
        ready : natural;
        seq   : natural;
    end record;
    type bq_t is array (0 to C_N_ID-1, 0 to C_QD-1) of bb_t;
    type aw_t is record
        id   : natural;
        addr : unsigned(31 downto 0);
        len  : natural;
        err  : boolean;
    end record;
    type awq_t is array (0 to C_QD-1) of aw_t;
    type nat_arr_t is array (natural range <>) of natural;
    type wd_arr_t is array (0 to C_WQ-1) of std_logic_vector(G_DATA_W-1 downto 0);
    type ws_arr_t is array (0 to C_WQ-1) of std_logic_vector(C_BYTES-1 downto 0);
    type wl_arr_t is array (0 to C_WQ-1) of std_logic;
    type bases_t is array (0 to 3) of natural;
    constant C_BASES : bases_t := (G_BASE_0, G_BASE_1, G_BASE_2, G_BASE_3);

    signal s_arready : std_logic := '0';
    signal s_awready : std_logic := '0';
    signal s_wready  : std_logic := '0';
    signal s_rvalid  : std_logic := '0';
    signal s_rid     : std_logic_vector(G_ID_W-1 downto 0) := (others => '0');
    signal s_rdata   : std_logic_vector(G_DATA_W-1 downto 0) := (others => '0');
    signal s_rresp   : std_logic_vector(1 downto 0) := "00";
    signal s_rlast   : std_logic := '0';
    signal s_bvalid  : std_logic := '0';
    signal s_bid     : std_logic_vector(G_ID_W-1 downto 0) := (others => '0');
    signal s_bresp   : std_logic_vector(1 downto 0) := "00";

    function in_region(a : unsigned(31 downto 0)) return boolean is
    begin
        for i in C_BASES'range loop
            if a >= to_unsigned(C_BASES(i), 32) and a - to_unsigned(C_BASES(i), 32) < to_unsigned(G_REGION_BYTES, 32) then
                return true;
            end if;
        end loop;
        return false;
    end function in_region;

    function in_err(a : unsigned(31 downto 0)) return boolean is
    begin
        return G_ERR_ADDR_LO < G_ERR_ADDR_HI and a >= to_unsigned(G_ERR_ADDR_LO, 32) and a < to_unsigned(G_ERR_ADDR_HI, 32);
    end function in_err;
begin
    assert G_ADDR_W = 32 report "axi_mem_model: G_ADDR_W must be 32" severity failure;
    assert G_DATA_W >= 16 and 2 ** clog2(G_DATA_W) = G_DATA_W report "axi_mem_model: G_DATA_W must be a power of two >= 16" severity failure;

    s_axi_arready <= s_arready;
    s_axi_awready <= s_awready;
    s_axi_wready <= s_wready;
    s_axi_rvalid <= s_rvalid;
    s_axi_rid <= s_rid;
    s_axi_rdata <= s_rdata;
    s_axi_rresp <= s_rresp;
    s_axi_rlast <= s_rlast;
    s_axi_bvalid <= s_bvalid;
    s_axi_bid <= s_bid;
    s_axi_bresp <= s_bresp;

    process(i_clk)
        variable v_seed1 : positive := G_SEED;
        variable v_seed2 : positive := 977;
        variable v_cycle : natural := 0;
        variable v_seq   : natural := 0;
        variable v_hit   : boolean;
        variable v_lat   : natural;
        -- read side
        variable v_rq       : rq_t;
        variable v_rq_head  : nat_arr_t(0 to C_N_ID-1) := (others => 0);
        variable v_rq_cnt   : nat_arr_t(0 to C_N_ID-1) := (others => 0);
        variable v_rd_outst : natural := 0;
        variable v_r_act    : boolean := false;      -- a burst is being returned
        variable v_r_id     : natural := 0;
        variable v_r_beat   : natural := 0;
        variable v_r_err    : boolean := false;      -- the beat on the bus answers SLVERR
        variable v_r_gap    : boolean := false;
        -- write side
        variable v_awq      : awq_t;
        variable v_awq_head : natural := 0;
        variable v_awq_cnt  : natural := 0;
        variable v_wd       : wd_arr_t;
        variable v_ws       : ws_arr_t;
        variable v_wl       : wl_arr_t;
        variable v_wq_head  : natural := 0;
        variable v_wq_cnt   : natural := 0;
        variable v_w_beat   : natural := 0;          -- beats of the oldest AW burst already written
        variable v_w_err    : boolean := false;
        variable v_bq       : bq_t;
        variable v_bq_head  : nat_arr_t(0 to C_N_ID-1) := (others => 0);
        variable v_bq_cnt   : nat_arr_t(0 to C_N_ID-1) := (others => 0);
        variable v_wr_outst : natural := 0;          -- AW accepted, B not yet taken
        variable v_b_id     : natural := 0;
        -- handshake stability
        variable v_ar_pend, v_aw_pend, v_w_pend : boolean := false;
        variable v_ar_last, v_aw_last, v_ar_now, v_aw_now : std_logic_vector(C_A_W-1 downto 0);
        variable v_w_last, v_w_now : std_logic_vector(C_W_W-1 downto 0);
        -- scratch
        variable v_ar_hs, v_aw_hs, v_w_hs, v_r_hs, v_b_hs : boolean;
        variable v_id, v_slot, v_pick, v_min_seq, v_oldest, v_n_cand : natural;
        variable v_found, v_outside : boolean;
        variable v_addr : unsigned(31 downto 0);
        variable v_beat : std_logic_vector(G_DATA_W-1 downto 0);
        variable v_aw   : aw_t;

        procedure violation(v : violation_t; msg : string) is
        begin
            axi_stats.add_violation(v);
            if G_FAIL_ON_VIOLATION then
                report "axi_mem_model: " & violation_t'image(v) & ": " & msg severity failure;
            else
                report "axi_mem_model: " & violation_t'image(v) & ": " & msg severity warning;
            end if;
        end procedure violation;

        procedure roll(pct : natural; hit : out boolean) is
            variable v_r : real;
        begin
            uniform(v_seed1, v_seed2, v_r);
            hit := v_r * 100.0 < real(pct);
        end procedure roll;

        procedure rand_upto(max : natural; n : out natural) is
            variable v_r : real;
            variable v_n : natural;
        begin
            uniform(v_seed1, v_seed2, v_r);
            v_n := natural(floor(v_r * real(max + 1)));
            if v_n > max then
                v_n := max;
            end if;
            n := v_n;
        end procedure rand_upto;

        procedure check_burst(kind : string; addr, len, size, burst : std_logic_vector) is
            variable v_a : unsigned(31 downto 0);
            variable v_len : natural;
        begin
            v_a := resize(unsigned(addr), 32);
            v_len := to_integer(unsigned(len));
            if burst /= AXI_BURST_INCR then
                violation(VIO_BURST, kind & " burst type is not INCR");
            end if;
            if size /= axi_size(G_DATA_W) then
                violation(VIO_SIZE, kind & " size is not the full data width");
            end if;
            if v_len + 1 > G_MAX_BURST then
                violation(VIO_LEN, kind & " burst of " & integer'image(v_len + 1) & " beats, limit " & integer'image(G_MAX_BURST));
            end if;
            if to_integer(v_a(C_OFF_W-1 downto 0)) /= 0 then
                violation(VIO_UNALIGNED, kind & " address " & to_hstring(v_a) & " is not beat aligned");
            elsif crosses_4k(v_a, unsigned(len), G_DATA_W) then
                violation(VIO_4K, kind & " burst at " & to_hstring(v_a) & " crosses a 4 KB boundary");
            end if;
            if to_integer(v_a(11 downto 0)) + (v_len + 1) * C_BYTES = 4096 then
                axi_stats.add(ST_PAGE_END);
            end if;
        end procedure check_burst;
    begin
        if rising_edge(i_clk) then
            v_cycle := v_cycle + 1;
            if i_rst = '1' then
                v_rq_head := (others => 0);
                v_rq_cnt := (others => 0);
                v_rd_outst := 0;
                v_r_act := false;
                v_r_gap := false;
                v_awq_head := 0;
                v_awq_cnt := 0;
                v_wq_head := 0;
                v_wq_cnt := 0;
                v_w_beat := 0;
                v_w_err := false;
                v_bq_head := (others => 0);
                v_bq_cnt := (others => 0);
                v_wr_outst := 0;
                v_ar_pend := false;
                v_aw_pend := false;
                v_w_pend := false;
                s_arready <= '0';
                s_awready <= '0';
                s_wready <= '0';
                s_rvalid <= '0';
                s_rlast <= '0';
                s_bvalid <= '0';
            else
                if is_x(s_axi_arvalid) or is_x(s_axi_awvalid) or is_x(s_axi_wvalid) or is_x(s_axi_rready) or is_x(s_axi_bready) then
                    violation(VIO_X, "X on a valid or ready of the master");
                end if;

                -- handshakes of the clock that ends at this edge
                v_ar_hs := s_axi_arvalid = '1' and s_arready = '1';
                v_aw_hs := s_axi_awvalid = '1' and s_awready = '1';
                v_w_hs := s_axi_wvalid = '1' and s_wready = '1';
                v_r_hs := s_rvalid = '1' and s_axi_rready = '1';
                v_b_hs := s_bvalid = '1' and s_axi_bready = '1';

                -- AR: stable until the handshake, then queued per ID with a random latency
                v_ar_now := s_axi_arid & s_axi_araddr & s_axi_arlen & s_axi_arsize & s_axi_arburst;
                if v_ar_pend and (s_axi_arvalid /= '1' or v_ar_now /= v_ar_last) then
                    violation(VIO_AR_UNSTABLE, "AR valid or payload changed before the handshake");
                end if;
                v_ar_pend := s_axi_arvalid = '1' and not v_ar_hs;
                v_ar_last := v_ar_now;
                if v_ar_pend then
                    axi_stats.add(ST_AR_STALL);
                end if;
                if v_ar_hs then
                    check_burst("AR", s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst);
                    v_id := to_integer(unsigned(s_axi_arid));
                    assert v_rq_cnt(v_id) < C_QD report "axi_mem_model: read queue overflow" severity failure;
                    rand_upto(G_RD_LAT_MAX, v_lat);
                    v_slot := (v_rq_head(v_id) + v_rq_cnt(v_id)) mod C_QD;
                    v_rq(v_id, v_slot) := (addr => resize(unsigned(s_axi_araddr), 32), len => to_integer(unsigned(s_axi_arlen)),
                                           ready => v_cycle + 1 + v_lat, seq => v_seq, err => i_err_en);
                    v_seq := v_seq + 1;
                    v_rq_cnt(v_id) := v_rq_cnt(v_id) + 1;
                    v_rd_outst := v_rd_outst + 1;
                    axi_stats.add(ST_AR);
                end if;

                -- AW: same checks, queued in order
                v_aw_now := s_axi_awid & s_axi_awaddr & s_axi_awlen & s_axi_awsize & s_axi_awburst;
                if v_aw_pend and (s_axi_awvalid /= '1' or v_aw_now /= v_aw_last) then
                    violation(VIO_AW_UNSTABLE, "AW valid or payload changed before the handshake");
                end if;
                v_aw_pend := s_axi_awvalid = '1' and not v_aw_hs;
                v_aw_last := v_aw_now;
                if v_aw_pend then
                    axi_stats.add(ST_AW_STALL);
                end if;
                if v_aw_hs then
                    check_burst("AW", s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst);
                    assert v_awq_cnt < C_QD report "axi_mem_model: write address queue overflow" severity failure;
                    v_awq((v_awq_head + v_awq_cnt) mod C_QD) := (id => to_integer(unsigned(s_axi_awid)),
                        addr => resize(unsigned(s_axi_awaddr), 32), len => to_integer(unsigned(s_axi_awlen)), err => i_err_en);
                    v_awq_cnt := v_awq_cnt + 1;
                    v_wr_outst := v_wr_outst + 1;
                    axi_stats.add(ST_AW);
                end if;

                -- W: stable until the handshake, beats queue up (they may come before their AW)
                v_w_now := s_axi_wdata & s_axi_wstrb & s_axi_wlast;
                if v_w_pend and (s_axi_wvalid /= '1' or v_w_now /= v_w_last) then
                    violation(VIO_W_UNSTABLE, "W valid or payload changed before the handshake");
                end if;
                v_w_pend := s_axi_wvalid = '1' and not v_w_hs;
                v_w_last := v_w_now;
                if v_w_pend then
                    axi_stats.add(ST_W_STALL);
                end if;
                if v_w_hs then
                    assert v_wq_cnt < C_WQ report "axi_mem_model: write data queue overflow" severity failure;
                    v_slot := (v_wq_head + v_wq_cnt) mod C_WQ;
                    v_wd(v_slot) := s_axi_wdata;
                    v_ws(v_slot) := s_axi_wstrb;
                    v_wl(v_slot) := s_axi_wlast;
                    v_wq_cnt := v_wq_cnt + 1;
                    axi_stats.add(ST_W_BEATS);
                end if;

                -- match W beats to AW bursts in order, write the memory, queue B after the last beat
                while v_awq_cnt > 0 and v_wq_cnt > 0 loop
                    v_aw := v_awq(v_awq_head);
                    v_addr := v_aw.addr + to_unsigned(v_w_beat * C_BYTES, 32);
                    if (v_wl(v_wq_head) = '1') /= (v_w_beat = v_aw.len) then
                        violation(VIO_WLAST, "WLAST is " & std_logic'image(v_wl(v_wq_head)) & " on beat " & integer'image(v_w_beat + 1)
                                  & " of a burst of " & integer'image(v_aw.len + 1));
                    end if;
                    if v_aw.err and in_err(v_addr) then
                        v_w_err := true;
                    else
                        v_outside := false;
                        for i in 0 to C_BYTES - 1 loop
                            if v_ws(v_wq_head)(i) = '1' then
                                if in_region(v_addr + to_unsigned(i, 32)) then
                                    axi_mem.write_byte(v_addr + to_unsigned(i, 32), v_wd(v_wq_head)(8 * i + 7 downto 8 * i));
                                else
                                    v_outside := true;
                                end if;
                            end if;
                        end loop;
                        if v_outside then
                            violation(VIO_WRITE_OUTSIDE, "write outside every region at " & to_hstring(v_addr));
                        end if;
                    end if;
                    v_wq_head := (v_wq_head + 1) mod C_WQ;
                    v_wq_cnt := v_wq_cnt - 1;
                    if v_w_beat = v_aw.len then
                        rand_upto(G_WR_LAT_MAX, v_lat);
                        v_slot := (v_bq_head(v_aw.id) + v_bq_cnt(v_aw.id)) mod C_QD;
                        v_bq(v_aw.id, v_slot) := (err => v_w_err, ready => v_cycle + 1 + v_lat, seq => v_seq);
                        v_seq := v_seq + 1;
                        v_bq_cnt(v_aw.id) := v_bq_cnt(v_aw.id) + 1;
                        v_awq_head := (v_awq_head + 1) mod C_QD;
                        v_awq_cnt := v_awq_cnt - 1;
                        v_w_beat := 0;
                        v_w_err := false;
                    else
                        v_w_beat := v_w_beat + 1;
                    end if;
                end loop;

                -- R: the beat on the bus was taken
                if v_r_hs then
                    axi_stats.add(ST_R_BEATS);
                    if v_r_err then
                        axi_stats.add(ST_R_ERR);
                    end if;
                    if v_r_beat = v_rq(v_r_id, v_rq_head(v_r_id)).len then
                        v_rq_head(v_r_id) := (v_rq_head(v_r_id) + 1) mod C_QD;
                        v_rq_cnt(v_r_id) := v_rq_cnt(v_r_id) - 1;
                        v_rd_outst := v_rd_outst - 1;
                        v_r_act := false;
                    else
                        v_r_beat := v_r_beat + 1;
                    end if;
                    roll(G_RVALID_GAP_PCT, v_r_gap);
                end if;
                -- R: hold the beat, insert a gap, or present the next beat (picking a burst if none is active)
                if s_rvalid = '1' and not v_r_hs then
                    null;
                elsif v_r_gap then
                    s_rvalid <= '0';
                    v_r_gap := false;
                else
                    if not v_r_act then
                        v_min_seq := natural'high;
                        v_oldest := 0;
                        v_n_cand := 0;
                        for i in 0 to C_N_ID - 1 loop
                            if v_rq_cnt(i) > 0 then
                                if v_rq(i, v_rq_head(i)).seq < v_min_seq then
                                    v_min_seq := v_rq(i, v_rq_head(i)).seq;
                                    v_oldest := i;
                                end if;
                                if v_rq(i, v_rq_head(i)).ready <= v_cycle then
                                    v_n_cand := v_n_cand + 1;
                                end if;
                            end if;
                        end loop;
                        if G_REORDER then
                            if v_n_cand > 0 then
                                rand_upto(v_n_cand - 1, v_pick);
                                for i in 0 to C_N_ID - 1 loop
                                    if v_rq_cnt(i) > 0 and v_rq(i, v_rq_head(i)).ready <= v_cycle then
                                        if v_pick = 0 then
                                            v_r_id := i;
                                            v_r_act := true;
                                            exit;
                                        end if;
                                        v_pick := v_pick - 1;
                                    end if;
                                end loop;
                            end if;
                        elsif v_min_seq /= natural'high and v_rq(v_oldest, v_rq_head(v_oldest)).ready <= v_cycle then
                            v_r_id := v_oldest;
                            v_r_act := true;
                        end if;
                        if v_r_act then
                            v_r_beat := 0;
                            if v_rq(v_r_id, v_rq_head(v_r_id)).seq /= v_min_seq then
                                axi_stats.add(ST_R_REORDER);
                            end if;
                        end if;
                    end if;
                    if v_r_act then
                        v_addr := v_rq(v_r_id, v_rq_head(v_r_id)).addr + to_unsigned(v_r_beat * C_BYTES, 32);
                        for i in 0 to C_BYTES - 1 loop
                            v_beat(8 * i + 7 downto 8 * i) := axi_mem.read_byte(v_addr + to_unsigned(i, 32));
                        end loop;
                        v_r_err := v_rq(v_r_id, v_rq_head(v_r_id)).err and in_err(v_addr);
                        s_rdata <= v_beat;
                        s_rid <= std_logic_vector(to_unsigned(v_r_id, G_ID_W));
                        if v_r_err then
                            s_rresp <= "10";
                        else
                            s_rresp <= "00";
                        end if;
                        if v_r_beat = v_rq(v_r_id, v_rq_head(v_r_id)).len then
                            s_rlast <= '1';
                        else
                            s_rlast <= '0';
                        end if;
                        s_rvalid <= '1';
                    else
                        s_rvalid <= '0';
                        s_rlast <= '0';
                    end if;
                end if;

                -- B: the response on the bus was taken
                if v_b_hs then
                    axi_stats.add(ST_B);
                    if v_bq(v_b_id, v_bq_head(v_b_id)).err then
                        axi_stats.add(ST_B_ERR);
                    end if;
                    v_bq_head(v_b_id) := (v_bq_head(v_b_id) + 1) mod C_QD;
                    v_bq_cnt(v_b_id) := v_bq_cnt(v_b_id) - 1;
                    v_wr_outst := v_wr_outst - 1;
                end if;
                -- B: hold, or present the next response whose latency has passed
                if s_bvalid = '1' and not v_b_hs then
                    null;
                else
                    v_min_seq := natural'high;
                    v_oldest := 0;
                    v_n_cand := 0;
                    for i in 0 to C_N_ID - 1 loop
                        if v_bq_cnt(i) > 0 then
                            if v_bq(i, v_bq_head(i)).seq < v_min_seq then
                                v_min_seq := v_bq(i, v_bq_head(i)).seq;
                                v_oldest := i;
                            end if;
                            if v_bq(i, v_bq_head(i)).ready <= v_cycle then
                                v_n_cand := v_n_cand + 1;
                            end if;
                        end if;
                    end loop;
                    v_found := false;
                    if G_REORDER then
                        if v_n_cand > 0 then
                            rand_upto(v_n_cand - 1, v_pick);
                            for i in 0 to C_N_ID - 1 loop
                                if v_bq_cnt(i) > 0 and v_bq(i, v_bq_head(i)).ready <= v_cycle then
                                    if v_pick = 0 then
                                        v_b_id := i;
                                        v_found := true;
                                        exit;
                                    end if;
                                    v_pick := v_pick - 1;
                                end if;
                            end loop;
                        end if;
                    elsif v_min_seq /= natural'high and v_bq(v_oldest, v_bq_head(v_oldest)).ready <= v_cycle then
                        v_b_id := v_oldest;
                        v_found := true;
                    end if;
                    if v_found then
                        if v_bq(v_b_id, v_bq_head(v_b_id)).seq /= v_min_seq then
                            axi_stats.add(ST_B_REORDER);
                        end if;
                        s_bid <= std_logic_vector(to_unsigned(v_b_id, G_ID_W));
                        if v_bq(v_b_id, v_bq_head(v_b_id)).err then
                            s_bresp <= "10";
                        else
                            s_bresp <= "00";
                        end if;
                        s_bvalid <= '1';
                    else
                        s_bvalid <= '0';
                    end if;
                end if;

                -- readys for the next clock: random, closed while the acceptance limit is reached
                if v_rd_outst >= G_ACCEPT then
                    s_arready <= '0';
                    if s_axi_arvalid = '1' then
                        axi_stats.add(ST_RD_FULL);
                    end if;
                else
                    roll(G_READY_PCT, v_hit);
                    s_arready <= '1' when v_hit else '0';
                end if;
                if v_wr_outst >= G_ACCEPT then
                    s_awready <= '0';
                    if s_axi_awvalid = '1' then
                        axi_stats.add(ST_WR_FULL);
                    end if;
                else
                    roll(G_READY_PCT, v_hit);
                    s_awready <= '1' when v_hit else '0';
                end if;
                if v_wq_cnt >= C_WQ - 1 then
                    s_wready <= '0';
                else
                    roll(G_READY_PCT, v_hit);
                    s_wready <= '1' when v_hit else '0';
                end if;
            end if;
        end if;
    end process;
end architecture sim;
