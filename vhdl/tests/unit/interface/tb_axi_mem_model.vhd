-- Author: Olimjon Mirzayusupov
-- self-test of axi_mem_model (tests/models/axi_mem_model_pkg.vhd, axi_mem_model_shared.vhd, axi_mem_model.vhd), the reference that the AXI master testbenches rely on
-- a directed AXI master (one channel action at a time, ready/valid driven at falling edges) checks:
--   backdoor write/read and the x"A5" fill, a write burst then a read burst of the same data, byte strobes,
--   W beats before their AW, out-of-order returns across IDs with order kept inside an ID, SLVERR only while
--   i_err_en is on and only for beats inside the window (an erroring write beat is not written), the acceptance
--   limit, the stall and 4 KB statistics, and zero violations for all of that
-- negative tests (G_FAIL_ON_VIOLATION = false): every protocol check of the model must count its violation:
--   burst type, size, length, 4 KB crossing, alignment, WLAST early and late, write outside the regions,
--   AR payload change before the handshake, X on a valid
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/axi_pkg.vhd tests/models/axi_mem_model_pkg.vhd tests/models/axi_mem_model_shared.vhd tests/models/axi_mem_model.vhd \
--        tests/unit/interface/tb_axi_mem_model.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_axi_mem_model
--   ghdl -r --std=08 --workdir=<dir> tb_axi_mem_model -gG_DATA_W=128 -gG_SEED=2
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;
use work.axi_pkg.all;
use work.axi_mem_model_pkg.all;
use work.axi_mem_model_shared.all;

entity tb_axi_mem_model is
    generic (
        G_DATA_W : positive := 64;
        G_SEED   : positive := 1
    );
end entity tb_axi_mem_model;

architecture sim of tb_axi_mem_model is
    constant C_PERIOD : time := 5 ns;
    constant C_ID_W   : positive := 2;
    constant C_BYTES  : positive := G_DATA_W / 8;
    constant C_ACCEPT : positive := 4;
    constant C_ERR_LO : natural := 16#10008100#;     -- not on a 4 KB boundary, so a burst can straddle the window start
    constant C_ERR_HI : natural := 16#10008200#;
    constant C_SIZE   : std_logic_vector(2 downto 0) := axi_size(G_DATA_W);
    constant C_ONES   : std_logic_vector(C_BYTES-1 downto 0) := (others => '1');

    signal s_clk    : std_logic := '0';
    signal s_rst    : std_logic := '1';
    signal s_err_en : boolean := false;
    signal s_finished : boolean := false;

    signal s_arid    : std_logic_vector(C_ID_W-1 downto 0) := (others => '0');
    signal s_araddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_arlen   : std_logic_vector(7 downto 0) := (others => '0');
    signal s_arsize  : std_logic_vector(2 downto 0) := C_SIZE;
    signal s_arburst : std_logic_vector(1 downto 0) := AXI_BURST_INCR;
    signal s_arvalid : std_logic := '0';
    signal s_arready : std_logic;
    signal s_rid     : std_logic_vector(C_ID_W-1 downto 0);
    signal s_rdata   : std_logic_vector(G_DATA_W-1 downto 0);
    signal s_rresp   : std_logic_vector(1 downto 0);
    signal s_rlast   : std_logic;
    signal s_rvalid  : std_logic;
    signal s_rready  : std_logic := '0';
    signal s_awid    : std_logic_vector(C_ID_W-1 downto 0) := (others => '0');
    signal s_awaddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal s_awlen   : std_logic_vector(7 downto 0) := (others => '0');
    signal s_awsize  : std_logic_vector(2 downto 0) := C_SIZE;
    signal s_awburst : std_logic_vector(1 downto 0) := AXI_BURST_INCR;
    signal s_awvalid : std_logic := '0';
    signal s_awready : std_logic;
    signal s_wdata   : std_logic_vector(G_DATA_W-1 downto 0) := (others => '0');
    signal s_wstrb   : std_logic_vector(C_BYTES-1 downto 0) := (others => '0');
    signal s_wlast   : std_logic := '0';
    signal s_wvalid  : std_logic := '0';
    signal s_wready  : std_logic;
    signal s_bid     : std_logic_vector(C_ID_W-1 downto 0);
    signal s_bresp   : std_logic_vector(1 downto 0);
    signal s_bvalid  : std_logic;
    signal s_bready  : std_logic := '0';

    -- a recognisable beat: byte i = (address + i + salt) mod 256
    function pattern(addr : unsigned(31 downto 0); salt : natural) return std_logic_vector is
        variable v : std_logic_vector(G_DATA_W-1 downto 0);
    begin
        for i in 0 to C_BYTES - 1 loop
            v(8 * i + 7 downto 8 * i) := std_logic_vector(to_unsigned((to_integer(addr(7 downto 0)) + i + salt) mod 256, 8));
        end loop;
        return v;
    end function pattern;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;

    u_mem : entity work.axi_mem_model
        generic map (
            G_DATA_W            => G_DATA_W,
            G_ID_W              => C_ID_W,
            G_ADDR_W            => 32,
            G_MAX_BURST         => 16,
            G_READY_PCT         => 70,
            G_RD_LAT_MAX        => 6,
            G_WR_LAT_MAX        => 6,
            G_REORDER           => true,
            G_ACCEPT            => C_ACCEPT,
            G_RVALID_GAP_PCT    => 10,
            G_ERR_ADDR_LO       => C_ERR_LO,
            G_ERR_ADDR_HI       => C_ERR_HI,
            G_FAIL_ON_VIOLATION => false,
            G_SEED              => G_SEED
        )
        port map (
            i_clk => s_clk, i_rst => s_rst, i_err_en => s_err_en,
            s_axi_arid => s_arid, s_axi_araddr => s_araddr, s_axi_arlen => s_arlen, s_axi_arsize => s_arsize,
            s_axi_arburst => s_arburst, s_axi_arvalid => s_arvalid, s_axi_arready => s_arready,
            s_axi_rid => s_rid, s_axi_rdata => s_rdata, s_axi_rresp => s_rresp, s_axi_rlast => s_rlast,
            s_axi_rvalid => s_rvalid, s_axi_rready => s_rready,
            s_axi_awid => s_awid, s_axi_awaddr => s_awaddr, s_axi_awlen => s_awlen, s_axi_awsize => s_awsize,
            s_axi_awburst => s_awburst, s_axi_awvalid => s_awvalid, s_axi_awready => s_awready,
            s_axi_wdata => s_wdata, s_axi_wstrb => s_wstrb, s_axi_wlast => s_wlast, s_axi_wvalid => s_wvalid,
            s_axi_wready => s_wready,
            s_axi_bid => s_bid, s_axi_bresp => s_bresp, s_axi_bvalid => s_bvalid, s_axi_bready => s_bready
        );

    process
        variable v_errors : natural := 0;
        variable v_ok     : boolean;
        variable v_id     : natural;
        variable v_data   : std_logic_vector(G_DATA_W-1 downto 0);
        variable v_exp    : std_logic_vector(G_DATA_W-1 downto 0);
        variable v_resp   : std_logic_vector(1 downto 0);
        variable v_last   : std_logic;
        variable v_addr   : unsigned(31 downto 0);
        variable v_base   : unsigned(31 downto 0);
        variable v_cnt0, v_cnt1, v_ooo : natural;
        variable v_before : natural;
        variable v_half   : std_logic_vector(C_BYTES-1 downto 0);

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                report "ERROR: " & msg & " at " & time'image(now) severity error;
            end if;
        end procedure check;

        procedure idle(n : natural) is
        begin
            for i in 1 to n loop
                wait until falling_edge(s_clk);
            end loop;
        end procedure idle;

        -- present an AR and keep it until the handshake
        procedure ar(id : natural; addr : unsigned(31 downto 0); len : natural;
                     burst : std_logic_vector(1 downto 0) := AXI_BURST_INCR; size : std_logic_vector(2 downto 0) := C_SIZE) is
        begin
            wait until falling_edge(s_clk);
            s_arid <= std_logic_vector(to_unsigned(id, C_ID_W));
            s_araddr <= std_logic_vector(addr);
            s_arlen <= std_logic_vector(to_unsigned(len, 8));
            s_arburst <= burst;
            s_arsize <= size;
            s_arvalid <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_arready = '1';
            end loop;
            wait until falling_edge(s_clk);
            s_arvalid <= '0';
            s_arburst <= AXI_BURST_INCR;
            s_arsize <= C_SIZE;
        end procedure ar;

        procedure aw(id : natural; addr : unsigned(31 downto 0); len : natural) is
        begin
            wait until falling_edge(s_clk);
            s_awid <= std_logic_vector(to_unsigned(id, C_ID_W));
            s_awaddr <= std_logic_vector(addr);
            s_awlen <= std_logic_vector(to_unsigned(len, 8));
            s_awvalid <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_awready = '1';
            end loop;
            wait until falling_edge(s_clk);
            s_awvalid <= '0';
        end procedure aw;

        procedure w(data : std_logic_vector; strb : std_logic_vector; last : std_logic) is
        begin
            wait until falling_edge(s_clk);
            s_wdata <= data;
            s_wstrb <= strb;
            s_wlast <= last;
            s_wvalid <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_wready = '1';
            end loop;
            wait until falling_edge(s_clk);
            s_wvalid <= '0';
        end procedure w;

        -- take one R beat
        procedure r(id : out natural; data : out std_logic_vector; resp : out std_logic_vector; last : out std_logic) is
        begin
            wait until falling_edge(s_clk);
            s_rready <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_rvalid = '1';
            end loop;
            id := to_integer(unsigned(s_rid));
            data := s_rdata;
            resp := s_rresp;
            last := s_rlast;
            wait until falling_edge(s_clk);
            s_rready <= '0';
        end procedure r;

        procedure b(id : out natural; resp : out std_logic_vector) is
        begin
            wait until falling_edge(s_clk);
            s_bready <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_bvalid = '1';
            end loop;
            id := to_integer(unsigned(s_bid));
            resp := s_bresp;
            wait until falling_edge(s_clk);
            s_bready <= '0';
        end procedure b;

        procedure reset_model is
        begin
            wait until falling_edge(s_clk);
            s_arvalid <= '0';
            s_awvalid <= '0';
            s_wvalid <= '0';
            s_rready <= '0';
            s_bready <= '0';
            s_rst <= '1';
            idle(2);
            s_rst <= '0';
            idle(1);
        end procedure reset_model;

        -- negative test: the counter of v must rise by at least one
        procedure expect_violation(v : violation_t; before : natural) is
        begin
            idle(3);
            check(axi_stats.violations(v) > before, "violation " & violation_t'image(v) & " was not detected");
        end procedure expect_violation;
    begin
        s_rst <= '1';
        idle(3);
        s_rst <= '0';
        idle(1);

        -- backdoor and the x"A5" fill
        v_base := x"10000000";
        for i in 0 to 255 loop
            mem_write(v_base + to_unsigned(i * C_BYTES, 32), pattern(v_base + to_unsigned(i * C_BYTES, 32), 0));
        end loop;
        mem_read(v_base + to_unsigned(5 * C_BYTES, 32), v_data);
        check(v_data = pattern(v_base + to_unsigned(5 * C_BYTES, 32), 0), "backdoor read back");
        mem_read(x"10020000", v_data);
        for i in 0 to C_BYTES - 1 loop
            check(v_data(8 * i + 7 downto 8 * i) = x"A5", "unwritten byte does not read x""A5""");
        end loop;

        -- write burst of 4 beats, then read it back over AXI and through the backdoor
        v_addr := x"10001100";
        aw(0, v_addr, 3);
        for k in 0 to 3 loop
            if k = 3 then
                v_last := '1';
            else
                v_last := '0';
            end if;
            w(pattern(v_addr + to_unsigned(k * C_BYTES, 32), 7), C_ONES, v_last);
        end loop;
        b(v_id, v_resp);
        check(v_id = 0 and v_resp = "00", "write burst response");
        for k in 0 to 3 loop
            mem_read(v_addr + to_unsigned(k * C_BYTES, 32), v_data);
            check(v_data = pattern(v_addr + to_unsigned(k * C_BYTES, 32), 7), "backdoor after the write burst, beat " & integer'image(k));
        end loop;
        ar(1, v_addr, 3);
        for k in 0 to 3 loop
            r(v_id, v_data, v_resp, v_last);
            check(v_id = 1 and v_resp = "00", "read burst id or response");
            check(v_data = pattern(v_addr + to_unsigned(k * C_BYTES, 32), 7), "read burst data, beat " & integer'image(k));
            check((v_last = '1') = (k = 3), "read burst RLAST, beat " & integer'image(k));
        end loop;

        -- strobes: only the low half of the beat is written
        v_addr := x"10001200";
        v_half := (others => '0');
        v_half(C_BYTES / 2 - 1 downto 0) := (others => '1');
        aw(0, v_addr, 0);
        w(pattern(v_addr, 99), v_half, '1');
        b(v_id, v_resp);
        mem_read(v_addr, v_data);
        v_exp := pattern(v_addr, 99);
        for i in 0 to C_BYTES - 1 loop
            if i < C_BYTES / 2 then
                check(v_data(8 * i + 7 downto 8 * i) = v_exp(8 * i + 7 downto 8 * i), "strobed byte " & integer'image(i));
            else
                check(v_data(8 * i + 7 downto 8 * i) = x"A5", "byte without strobe was written: " & integer'image(i));
            end if;
        end loop;

        -- W beats before their AW
        v_addr := x"10001300";
        w(pattern(v_addr, 3), C_ONES, '0');
        w(pattern(v_addr + to_unsigned(C_BYTES, 32), 3), C_ONES, '1');
        aw(2, v_addr, 1);
        b(v_id, v_resp);
        check(v_id = 2 and v_resp = "00", "W before AW: response");
        mem_read(v_addr + to_unsigned(C_BYTES, 32), v_data);
        check(v_data = pattern(v_addr + to_unsigned(C_BYTES, 32), 3), "W before AW: data");

        -- out of order across IDs, in order inside an ID
        v_ooo := 0;
        for t in 0 to 39 loop
            ar(0, v_base, 3);
            ar(1, v_base + to_unsigned(64 * C_BYTES, 32), 0);
            v_cnt0 := 0;
            v_cnt1 := 0;
            for k in 0 to 4 loop
                r(v_id, v_data, v_resp, v_last);
                if v_id = 0 then
                    check(v_data = pattern(v_base + to_unsigned(v_cnt0 * C_BYTES, 32), 0), "ID 0 beat out of order or wrong");
                    check((v_last = '1') = (v_cnt0 = 3), "ID 0 RLAST");
                    v_cnt0 := v_cnt0 + 1;
                else
                    check(v_id = 1 and v_data = pattern(v_base + to_unsigned(64 * C_BYTES, 32), 0), "ID 1 beat wrong");
                    if v_cnt0 = 0 then
                        v_ooo := v_ooo + 1;      -- the younger ID 1 burst came first
                    end if;
                    v_cnt1 := v_cnt1 + 1;
                end if;
            end loop;
            check(v_cnt0 = 4 and v_cnt1 = 1, "beat count per ID");
        end loop;
        check(v_ooo > 0 and axi_stats.get(ST_R_REORDER) > 0, "no out-of-order return in 40 tries");

        -- error injection: only while i_err_en is on, only for beats inside the window
        wait until falling_edge(s_clk);
        s_err_en <= true;
        v_addr := to_unsigned(C_ERR_LO, 32) - to_unsigned(2 * C_BYTES, 32);
        ar(0, v_addr, 3);
        for k in 0 to 3 loop
            r(v_id, v_data, v_resp, v_last);
            if k < 2 then
                check(v_resp = "00", "beat before the error window answered " & to_string(v_resp));
            else
                check(v_resp = "10", "beat inside the error window answered " & to_string(v_resp));
            end if;
        end loop;
        aw(0, to_unsigned(C_ERR_LO, 32), 0);
        w(pattern(to_unsigned(C_ERR_LO, 32), 1), C_ONES, '1');
        b(v_id, v_resp);
        check(v_resp = "10", "write inside the error window answered " & to_string(v_resp));
        mem_read(to_unsigned(C_ERR_LO, 32), v_data);
        check(v_data(7 downto 0) = x"A5", "an erroring write beat was written");
        wait until falling_edge(s_clk);
        s_err_en <= false;
        ar(0, v_addr, 3);
        for k in 0 to 3 loop
            r(v_id, v_data, v_resp, v_last);
            check(v_resp = "00", "error answered with i_err_en off");
        end loop;
        check(axi_stats.get(ST_R_ERR) >= 2 and axi_stats.get(ST_B_ERR) >= 1, "error statistics");

        -- acceptance limit: C_ACCEPT reads outstanding, the next AR must wait until one burst is returned
        for k in 0 to C_ACCEPT - 1 loop
            ar(0, v_base + to_unsigned(k * C_BYTES, 32), 0);
        end loop;
        wait until falling_edge(s_clk);
        s_araddr <= std_logic_vector(v_base);
        s_arlen <= (others => '0');
        s_arvalid <= '1';
        v_ok := true;
        for i in 1 to 20 loop
            wait until rising_edge(s_clk);
            if s_arready = '1' then
                v_ok := false;
            end if;
        end loop;
        check(v_ok, "an AR was accepted beyond the acceptance limit");
        r(v_id, v_data, v_resp, v_last);          -- one burst returned, room for one more
        loop
            wait until rising_edge(s_clk);
            exit when s_arready = '1';
        end loop;
        wait until falling_edge(s_clk);
        s_arvalid <= '0';
        for k in 1 to C_ACCEPT loop
            r(v_id, v_data, v_resp, v_last);
        end loop;
        check(axi_stats.get(ST_RD_FULL) > 0, "acceptance limit statistic");

        -- more single-beat writes, so AW and W stalls are certain to show up at 70 % ready
        for k in 0 to 23 loop
            v_addr := x"10002000" + to_unsigned(k * C_BYTES, 32);
            aw(k mod 4, v_addr, 0);
            w(pattern(v_addr, 5), C_ONES, '1');
            b(v_id, v_resp);
            check(v_id = k mod 4 and v_resp = "00", "single-beat write response");
            mem_read(v_addr, v_data);
            check(v_data = pattern(v_addr, 5), "single-beat write data");
        end loop;

        -- a burst that ends exactly on a 4 KB boundary, then the statistics of the clean part
        ar(0, x"10001000" - to_unsigned(4 * C_BYTES, 32), 3);
        for k in 0 to 3 loop
            r(v_id, v_data, v_resp, v_last);
        end loop;
        check(axi_stats.get(ST_PAGE_END) > 0, "4 KB end statistic");
        check(axi_stats.get(ST_AR_STALL) > 0 and axi_stats.get(ST_AW_STALL) > 0 and axi_stats.get(ST_W_STALL) > 0,
              "no ready stall seen at 70 % ready");
        check(axi_stats.get(ST_VIOLATION) = 0, "violations in the clean part: " & integer'image(axi_stats.get(ST_VIOLATION)));

        -- negative tests: every check must count its violation
        reset_model;
        v_before := axi_stats.violations(VIO_BURST);
        ar(0, v_base, 0, burst => "00");
        r(v_id, v_data, v_resp, v_last);
        expect_violation(VIO_BURST, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_SIZE);
        ar(0, v_base, 0, size => "001");
        r(v_id, v_data, v_resp, v_last);
        expect_violation(VIO_SIZE, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_LEN);
        ar(0, v_base, 16);
        expect_violation(VIO_LEN, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_4K);
        ar(0, x"10001000" - to_unsigned(C_BYTES, 32), 1);
        expect_violation(VIO_4K, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_UNALIGNED);
        ar(0, x"10000004", 0);
        expect_violation(VIO_UNALIGNED, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_WLAST);
        aw(0, x"10001400", 1);
        w(pattern(v_base, 0), C_ONES, '1');        -- early WLAST
        w(pattern(v_base, 0), C_ONES, '0');        -- missing WLAST on the last beat
        idle(3);
        check(axi_stats.violations(VIO_WLAST) >= v_before + 2, "early and missing WLAST were not both detected");

        reset_model;
        v_before := axi_stats.violations(VIO_WRITE_OUTSIDE);
        aw(0, x"50000000", 0);
        w(pattern(v_base, 0), C_ONES, '1');
        expect_violation(VIO_WRITE_OUTSIDE, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_AR_UNSTABLE);
        loop
            -- present an AR; if it is not taken at the first edge, change its address before the handshake
            wait until falling_edge(s_clk);
            s_araddr <= std_logic_vector(v_base);
            s_arlen <= (others => '0');
            s_arvalid <= '1';
            wait until rising_edge(s_clk);
            if s_arready = '1' then
                wait until falling_edge(s_clk);
                s_arvalid <= '0';
                reset_model;
            else
                wait until falling_edge(s_clk);
                s_araddr <= std_logic_vector(v_base + to_unsigned(C_BYTES, 32));
                loop
                    wait until rising_edge(s_clk);
                    exit when s_arready = '1';
                end loop;
                wait until falling_edge(s_clk);
                s_arvalid <= '0';
                exit;
            end if;
        end loop;
        expect_violation(VIO_AR_UNSTABLE, v_before);

        reset_model;
        v_before := axi_stats.violations(VIO_X);
        wait until falling_edge(s_clk);
        s_arvalid <= 'X';
        wait until falling_edge(s_clk);
        s_arvalid <= '0';
        expect_violation(VIO_X, v_before);

        reset_model;
        report integer'image(G_DATA_W) & " bit: AR " & integer'image(axi_stats.get(ST_AR)) & ", R beats "
               & integer'image(axi_stats.get(ST_R_BEATS)) & ", AW " & integer'image(axi_stats.get(ST_AW))
               & ", W beats " & integer'image(axi_stats.get(ST_W_BEATS)) & ", B " & integer'image(axi_stats.get(ST_B))
               & ", reorders " & integer'image(axi_stats.get(ST_R_REORDER)) & ", violations (negative tests) "
               & integer'image(axi_stats.get(ST_VIOLATION)) & ", " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process;
end architecture sim;
