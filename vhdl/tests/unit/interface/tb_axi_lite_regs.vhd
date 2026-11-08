-- self-checking unit testbench for axi_lite_regs
-- directed cases (reset values, masks, clamps, byte strobes, start, busy lock, flags, soft reset, unmapped offsets),
-- AXI handshake delays, a random read and write sweep against a model, and a protocol monitor on all channels
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/interface/axi_lite_regs.vhd tests/unit/interface/tb_axi_lite_regs.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_axi_lite_regs
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;

entity tb_axi_lite_regs is
    generic (
        G_RANDOM : natural := 3000
    );
end entity tb_axi_lite_regs;

architecture sim of tb_axi_lite_regs is
    constant C_PERIOD : time := 5 ns;   -- 200 MHz
    constant C_ADDR_W : natural := 8;

    -- byte offsets, written out again here on purpose so the testbench does not share them with the design
    constant A_CTRL      : natural := 16#00#;
    constant A_STATUS    : natural := 16#04#;
    constant A_C         : natural := 16#08#;
    constant A_K         : natural := 16#0C#;
    constant A_H         : natural := 16#10#;
    constant A_W         : natural := 16#14#;
    constant A_FY        : natural := 16#18#;
    constant A_FX        : natural := 16#1C#;
    constant A_STRIDE    : natural := 16#20#;
    constant A_PAD       : natural := 16#24#;
    constant A_IN_LANES  : natural := 16#28#;
    constant A_OUT_LANES : natural := 16#2C#;
    constant A_IN_BASE   : natural := 16#30#;
    constant A_W_BASE    : natural := 16#34#;
    constant A_B_BASE    : natural := 16#38#;
    constant A_OUT_BASE  : natural := 16#3C#;
    constant A_CYCLES    : natural := 16#40#;

    signal s_clk : std_logic := '0';
    signal s_rst : std_logic := '1';

    signal s_awaddr  : std_logic_vector(C_ADDR_W-1 downto 0) := (others => '0');
    signal s_awvalid : std_logic := '0';
    signal s_awready : std_logic;
    signal s_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal s_wstrb   : std_logic_vector(3 downto 0) := (others => '0');
    signal s_wvalid  : std_logic := '0';
    signal s_wready  : std_logic;
    signal s_bresp   : std_logic_vector(1 downto 0);
    signal s_bvalid  : std_logic;
    signal s_bready  : std_logic := '0';
    signal s_araddr  : std_logic_vector(C_ADDR_W-1 downto 0) := (others => '0');
    signal s_arvalid : std_logic := '0';
    signal s_arready : std_logic;
    signal s_rdata   : std_logic_vector(31 downto 0);
    signal s_rresp   : std_logic_vector(1 downto 0);
    signal s_rvalid  : std_logic;
    signal s_rready  : std_logic := '0';

    signal s_cfg      : layer_cfg_t;
    signal s_start    : std_logic;
    signal s_soft_rst : std_logic;
    signal s_busy     : std_logic := '0';
    signal s_done     : std_logic := '0';
    signal s_error    : std_logic := '0';
    signal s_cycles   : unsigned(31 downto 0) := x"00001234";

    signal s_start_cnt : natural := 0;
    signal s_soft_cnt  : natural := 0;
    signal s_stim_done : boolean := false;
    signal s_finished  : boolean := false;

    type regs_t is array (0 to 16) of std_logic_vector(31 downto 0);

    -- bits that exist in a layer register, by word index
    function mask_of(idx : natural) return std_logic_vector is
    begin
        case idx is
            when 2 | 3 | 4 | 5 => return x"0000FFFF";
            when 6 | 7 | 8 | 9 => return x"00000007";
            when 10 | 11 => return x"0000001F";
            when others => return x"FFFFFFFF";
        end case;
    end function mask_of;

    function clamp(v : std_logic_vector(31 downto 0); lo, hi : natural) return natural is
        variable n : natural := to_integer(unsigned(v(15 downto 0)));
    begin
        if n < lo then
            return lo;
        elsif n > hi then
            return hi;
        end if;
        return n;
    end function clamp;
begin

    clk_gen : process
    begin
        while not s_finished loop
            s_clk <= '0';
            wait for C_PERIOD / 2;
            s_clk <= '1';
            wait for C_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    dut : entity work.axi_lite_regs
        generic map (G_ADDR_W => C_ADDR_W)
        port map (
            i_clk => s_clk, i_rst => s_rst,
            s_axi_awaddr => s_awaddr, s_axi_awvalid => s_awvalid, s_axi_awready => s_awready,
            s_axi_wdata => s_wdata, s_axi_wstrb => s_wstrb, s_axi_wvalid => s_wvalid, s_axi_wready => s_wready,
            s_axi_bresp => s_bresp, s_axi_bvalid => s_bvalid, s_axi_bready => s_bready,
            s_axi_araddr => s_araddr, s_axi_arvalid => s_arvalid, s_axi_arready => s_arready,
            s_axi_rdata => s_rdata, s_axi_rresp => s_rresp, s_axi_rvalid => s_rvalid, s_axi_rready => s_rready,
            o_cfg => s_cfg, o_start => s_start, o_soft_rst => s_soft_rst,
            i_busy => s_busy, i_done => s_done, i_error => s_error, i_cycles => s_cycles
        );

    -- monitor: protocol rules that hold in every cycle, and the pulse counters
    monitor : process
        variable v_bv, v_br, v_rv, v_rr, v_start, v_soft : std_logic := '0';
        variable v_rd : std_logic_vector(31 downto 0) := (others => '0');
    begin
        loop
            wait until rising_edge(s_clk);
            -- a response that was not accepted has to stay, with the same data
            if v_bv = '1' and v_br = '0' then
                assert s_bvalid = '1' report "bvalid dropped before bready" severity failure;
            end if;
            if v_rv = '1' and v_rr = '0' then
                assert s_rvalid = '1' report "rvalid dropped before rready" severity failure;
                assert s_rdata = v_rd report "rdata changed while rvalid waits" severity failure;
            end if;
            assert s_bresp = "00" and s_rresp = "00" report "response is not OKAY" severity failure;
            assert s_awready = s_wready report "awready and wready differ" severity failure;
            -- start and soft reset are one clock pulses
            assert not (v_start = '1' and s_start = '1') report "o_start is longer than one clock" severity failure;
            assert not (v_soft = '1' and s_soft_rst = '1') report "o_soft_rst is longer than one clock" severity failure;
            if s_start = '1' then
                s_start_cnt <= s_start_cnt + 1;
            end if;
            if s_soft_rst = '1' then
                s_soft_cnt <= s_soft_cnt + 1;
            end if;
            assert not (s_bvalid = '1' and s_awready = '1') report "awready while a response is pending" severity failure;
            assert not (s_rvalid = '1' and s_arready = '1') report "arready while a response is pending" severity failure;
            v_bv := s_bvalid;
            v_br := s_bready;
            v_rv := s_rvalid;
            v_rr := s_rready;
            v_rd := s_rdata;
            v_start := s_start;
            v_soft := s_soft_rst;
            exit when s_stim_done;
        end loop;
        wait;
    end process monitor;

    stim : process
        variable v_seed1, v_seed2 : positive := 11;
        variable v_errors : natural := 0;
        variable v_data : std_logic_vector(31 downto 0);
        variable v_model : regs_t := (others => (others => '0'));
        variable v_n, v_idx, v_dly1, v_dly2, v_dly3 : integer;
        variable v_starts, v_softs : natural;
        variable v_strb : std_logic_vector(3 downto 0);
        variable v_wd : std_logic_vector(31 downto 0);

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                if v_errors <= 10 then
                    report msg severity error;
                end if;
            end if;
        end procedure check;

        procedure rand(lo, hi : integer; v : out integer) is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            v := integer(floor(real(lo) + r * (real(hi) - real(lo) + 1.0)));
        end procedure rand;

        procedure idle(n : natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(s_clk);
            end loop;
        end procedure idle;

        -- one write with its own delays for AW, W and the B response, returns after the B handshake
        procedure wr(addr : natural; data : std_logic_vector(31 downto 0); strb : std_logic_vector(3 downto 0) := "1111";
                     aw_dly : natural := 0; w_dly : natural := 0; b_dly : natural := 0) is
            variable v_cyc : natural := 0;
            variable v_aw, v_w, v_b : boolean := false;
        begin
            while not v_b loop
                if v_cyc = aw_dly then
                    s_awvalid <= '1';
                    s_awaddr <= std_logic_vector(to_unsigned(addr, C_ADDR_W));
                end if;
                if v_cyc = w_dly then
                    s_wvalid <= '1';
                    s_wdata <= data;
                    s_wstrb <= strb;
                end if;
                if v_cyc = b_dly then
                    s_bready <= '1';
                end if;
                wait until rising_edge(s_clk);
                -- the values read here are those of the edge that just happened
                if s_bvalid = '1' and s_bready = '1' then
                    check(v_aw and v_w, "bvalid before address and data were accepted");
                    v_b := true;
                    s_bready <= '0';
                end if;
                if s_awvalid = '1' and s_awready = '1' then
                    v_aw := true;
                    s_awvalid <= '0';
                end if;
                if s_wvalid = '1' and s_wready = '1' then
                    v_w := true;
                    s_wvalid <= '0';
                end if;
                v_cyc := v_cyc + 1;
                assert v_cyc < 200 report "write timed out" severity failure;
            end loop;
        end procedure wr;

        procedure rd(addr : natural; data : out std_logic_vector(31 downto 0); ar_dly : natural := 0; r_dly : natural := 0) is
            variable v_cyc : natural := 0;
            variable v_ar, v_r : boolean := false;
        begin
            while not v_r loop
                if v_cyc = ar_dly then
                    s_arvalid <= '1';
                    s_araddr <= std_logic_vector(to_unsigned(addr, C_ADDR_W));
                end if;
                if v_cyc = r_dly then
                    s_rready <= '1';
                end if;
                wait until rising_edge(s_clk);
                if s_rvalid = '1' and s_rready = '1' then
                    check(v_ar, "rvalid before the address was accepted");
                    data := s_rdata;
                    v_r := true;
                    s_rready <= '0';
                end if;
                if s_arvalid = '1' and s_arready = '1' then
                    v_ar := true;
                    s_arvalid <= '0';
                end if;
                v_cyc := v_cyc + 1;
                assert v_cyc < 200 report "read timed out" severity failure;
            end loop;
        end procedure rd;

        -- read and compare
        procedure expect(addr : natural; e : std_logic_vector(31 downto 0); msg : string) is
            variable v_d : std_logic_vector(31 downto 0);
        begin
            rd(addr, v_d);
            check(v_d = e, msg & ": read " & to_hstring(v_d) & ", expected " & to_hstring(e));
        end procedure expect;

        procedure expect(addr : natural; e : natural; msg : string) is
        begin
            expect(addr, std_logic_vector(to_unsigned(e, 32)), msg);
        end procedure expect;

        procedure wr32(addr : natural; value : natural) is
        begin
            wr(addr, std_logic_vector(to_unsigned(value, 32)));
        end procedure wr32;

        -- o_cfg against the model, the model holds the register values
        procedure check_cfg(m : regs_t; msg : string) is
        begin
            check(s_cfg.c = to_integer(unsigned(m(2)(15 downto 0))), msg & ": cfg.c");
            check(s_cfg.k = to_integer(unsigned(m(3)(15 downto 0))), msg & ": cfg.k");
            check(s_cfg.h = to_integer(unsigned(m(4)(15 downto 0))), msg & ": cfg.h");
            check(s_cfg.w = to_integer(unsigned(m(5)(15 downto 0))), msg & ": cfg.w");
            check(s_cfg.fy = clamp(m(6), 1, 7), msg & ": cfg.fy");
            check(s_cfg.fx = clamp(m(7), 1, 7), msg & ": cfg.fx");
            check(s_cfg.stride = clamp(m(8), 1, 7), msg & ": cfg.stride");
            check(s_cfg.pad = clamp(m(9), 0, 7), msg & ": cfg.pad");
            check(s_cfg.in_lanes = clamp(m(10), 1, LANES), msg & ": cfg.in_lanes");
            check(s_cfg.out_lanes = clamp(m(11), 1, LANES), msg & ": cfg.out_lanes");
            check(std_logic_vector(s_cfg.in_base) = m(12), msg & ": cfg.in_base");
            check(std_logic_vector(s_cfg.w_base) = m(13), msg & ": cfg.w_base");
            check(std_logic_vector(s_cfg.b_base) = m(14), msg & ": cfg.b_base");
            check(std_logic_vector(s_cfg.out_base) = m(15), msg & ": cfg.out_base");
        end procedure check_cfg;

        procedure pulse_done is
        begin
            s_done <= '1';
            idle(1);
            s_done <= '0';
        end procedure pulse_done;

        procedure pulse_error is
        begin
            s_error <= '1';
            idle(1);
            s_error <= '0';
        end procedure pulse_error;
    begin
        -- reset
        s_rst <= '1';
        idle(3);
        s_rst <= '0';
        idle(2);

        -- values after reset
        for i in 2 to 15 loop
            expect(i * 4, 0, "reset value of offset " & integer'image(i * 4));
        end loop;
        expect(A_CTRL, 0, "CTRL reads 0");
        expect(A_STATUS, 0, "STATUS after reset");
        expect(A_CYCLES, 16#1234#, "CYCLES");
        s_cycles <= x"FFFFFFFF";
        idle(1);
        expect(A_CYCLES, x"FFFFFFFF", "CYCLES full width");
        s_cycles <= x"00001234";
        check(s_cfg.fy = 1 and s_cfg.fx = 1 and s_cfg.stride = 1 and s_cfg.in_lanes = 1 and s_cfg.out_lanes = 1,
              "illegal reset values reach the datapath");
        check_cfg(v_model, "after reset");

        -- the stem layer of the ResNet-8, written and read back
        wr32(A_C, 1);
        wr32(A_K, 16);
        wr32(A_H, 112);
        wr32(A_W, 112);
        wr32(A_FY, 3);
        wr32(A_FX, 3);
        wr32(A_STRIDE, 1);
        wr32(A_PAD, 1);
        wr32(A_IN_LANES, 1);
        wr32(A_OUT_LANES, 16);
        wr(A_IN_BASE, x"10000000");
        wr(A_W_BASE, x"10100000");
        wr(A_B_BASE, x"10200000");
        wr(A_OUT_BASE, x"7FFFFFF0");
        expect(A_C, 1, "C");
        expect(A_K, 16, "K");
        expect(A_H, 112, "H");
        expect(A_W, 112, "W");
        expect(A_FY, 3, "FY");
        expect(A_FX, 3, "FX");
        expect(A_STRIDE, 1, "STRIDE");
        expect(A_PAD, 1, "PAD");
        expect(A_IN_LANES, 1, "IN_LANES");
        expect(A_OUT_LANES, 16, "OUT_LANES");
        expect(A_IN_BASE, 16#10000000#, "IN_BASE");
        expect(A_W_BASE, 16#10100000#, "W_BASE");
        expect(A_B_BASE, 16#10200000#, "B_BASE");
        expect(A_OUT_BASE, 16#7FFFFFF0#, "OUT_BASE");
        idle(1);
        check(s_cfg.c = 1 and s_cfg.k = 16 and s_cfg.h = 112 and s_cfg.w = 112, "cfg shape");
        check(s_cfg.fy = 3 and s_cfg.fx = 3 and s_cfg.stride = 1 and s_cfg.pad = 1, "cfg kernel");
        check(s_cfg.in_lanes = 1 and s_cfg.out_lanes = 16, "cfg lanes");
        check(s_cfg.in_base = x"10000000" and s_cfg.w_base = x"10100000", "cfg input and weight address");
        check(s_cfg.b_base = x"10200000" and s_cfg.out_base = x"7FFFFFF0", "cfg bias and output address");
        v_model := (2 => x"00000001", 3 => x"00000010", 4 => x"00000070", 5 => x"00000070", 6 => x"00000003",
                    7 => x"00000003", 8 => x"00000001", 9 => x"00000001", 10 => x"00000001", 11 => x"00000010",
                    12 => x"10000000", 13 => x"10100000", 14 => x"10200000", 15 => x"7FFFFFF0", others => (others => '0'));

        -- unused bits do not exist, readback shows the stored value
        wr(A_C, x"FFFFFFFF");
        expect(A_C, 16#FFFF#, "C mask");
        wr(A_FY, x"FFFFFFFF");
        expect(A_FY, 7, "FY mask");
        wr(A_IN_LANES, x"FFFFFFFF");
        expect(A_IN_LANES, 31, "IN_LANES mask");
        idle(1);
        check(s_cfg.c = 65535, "cfg.c wide");
        check(s_cfg.fy = 7, "cfg.fy at the upper limit");
        check(s_cfg.in_lanes = LANES, "cfg.in_lanes clamped to LANES");

        -- zero in a register with a lower limit of 1 reads back as written and reaches the datapath as 1
        wr32(A_FY, 0);
        wr32(A_FX, 0);
        wr32(A_STRIDE, 0);
        wr32(A_IN_LANES, 0);
        wr32(A_OUT_LANES, 0);
        wr32(A_PAD, 0);
        expect(A_FY, 0, "FY zero reads back");
        idle(1);
        check(s_cfg.fy = 1 and s_cfg.fx = 1 and s_cfg.stride = 1, "zero kernel and stride are clamped to 1");
        check(s_cfg.in_lanes = 1 and s_cfg.out_lanes = 1, "zero lanes are clamped to 1");
        check(s_cfg.pad = 0, "zero pad stays 0");
        wr32(A_OUT_LANES, 20);
        idle(1);
        check(s_cfg.out_lanes = 16, "out_lanes 20 is clamped to 16");
        wr32(A_C, 1);
        wr32(A_FY, 3);
        wr32(A_FX, 3);
        wr32(A_STRIDE, 1);
        wr32(A_PAD, 1);
        wr32(A_IN_LANES, 1);
        wr32(A_OUT_LANES, 16);

        -- byte strobes
        wr(A_IN_BASE, x"AABBCCDD");
        wr(A_IN_BASE, x"11223344", "0101");
        expect(A_IN_BASE, x"AA22CC44", "strobe 0101");
        wr(A_IN_BASE, x"99887766", "1000");
        expect(A_IN_BASE, x"9922CC44", "strobe 1000");
        wr(A_IN_BASE, x"FFFFFFFF", "0000");
        expect(A_IN_BASE, x"9922CC44", "strobe 0000 changes nothing");
        wr(A_IN_BASE, x"10000000");

        -- handshake delays: address first, data first, late response acceptance, same cycle
        wr(A_K, x"00000020", aw_dly => 4);
        wr(A_K, x"00000021", w_dly => 4);
        wr(A_K, x"00000022", aw_dly => 2, w_dly => 5, b_dly => 6);
        wr(A_K, x"00000023", b_dly => 9);
        expect(A_K, 16#23#, "K after delayed writes");
        rd(A_K, v_data, ar_dly => 3);
        check(v_data = x"00000023", "delayed address on read");
        rd(A_K, v_data, r_dly => 7);
        check(v_data = x"00000023", "delayed rready");
        rd(A_K, v_data, ar_dly => 2, r_dly => 4);
        check(v_data = x"00000023", "both delayed");
        wr32(A_K, 16);

        -- read only and unmapped offsets
        wr(A_STATUS, x"FFFFFFFF");
        wr(A_CYCLES, x"FFFFFFFF");
        wr(16#44#, x"FFFFFFFF");
        wr(16#7C#, x"FFFFFFFF");
        wr(16#80#, x"FFFFFFFF");
        wr(16#FC#, x"FFFFFFFF");
        expect(A_STATUS, 0, "STATUS ignores writes");
        expect(A_CYCLES, 16#1234#, "CYCLES ignores writes");
        expect(16#44#, 0, "reserved 44");
        expect(16#7C#, 0, "reserved 7C");
        expect(16#80#, 0, "reserved 80");
        expect(16#FC#, 0, "reserved FC");
        idle(1);
        check_cfg(v_model, "unmapped writes");

        -- start: one pulse, done and error are cleared
        v_starts := s_start_cnt;
        v_softs := s_soft_cnt;
        pulse_done;
        pulse_error;
        expect(A_STATUS, 6, "done and error set");
        idle(5);
        expect(A_STATUS, 6, "done and error are sticky");
        wr32(A_CTRL, 1);
        idle(3);
        check(s_start_cnt = v_starts + 1, "start gives one pulse");
        check(s_soft_cnt = v_softs, "start gives no soft reset");
        expect(A_STATUS, 0, "start clears done and error");
        expect(A_CTRL, 0, "CTRL reads 0 after start");
        check_cfg(v_model, "after start");

        -- start needs wstrb(0)
        v_starts := s_start_cnt;
        wr(A_CTRL, x"00000001", "1110");
        idle(3);
        check(s_start_cnt = v_starts, "no start without wstrb(0)");
        wr(A_CTRL, x"00000000");
        idle(3);
        check(s_start_cnt = v_starts, "writing 0 does not start");
        v_softs := s_soft_cnt;
        wr(A_CTRL, x"FFFFFFFC");
        idle(3);
        check(s_start_cnt = v_starts and s_soft_cnt = v_softs, "other CTRL bits do nothing");

        -- busy: layer registers are locked, start is refused and sets error
        v_starts := s_start_cnt;
        s_busy <= '1';
        idle(1);
        pulse_done;
        wr32(A_C, 99);
        wr(A_OUT_BASE, x"DEADBEEF");
        expect(A_C, 1, "C is locked while busy");
        expect(A_OUT_BASE, 16#7FFFFFF0#, "OUT_BASE is locked while busy");
        idle(1);
        check_cfg(v_model, "busy lock");
        expect(A_STATUS, 3, "busy and done, no error yet");
        wr32(A_CTRL, 1);
        idle(3);
        check(s_start_cnt = v_starts, "start while busy is not forwarded");
        expect(A_STATUS, 7, "start while busy sets error and keeps done");
        -- soft reset is allowed while busy and clears the flags, the layer registers stay
        v_softs := s_soft_cnt;
        wr32(A_CTRL, 2);
        idle(3);
        check(s_soft_cnt = v_softs + 1, "soft reset gives one pulse");
        expect(A_STATUS, 1, "soft reset clears done and error");
        idle(1);
        check_cfg(v_model, "after soft reset");
        s_busy <= '0';
        idle(2);
        -- soft reset wins over start
        v_starts := s_start_cnt;
        v_softs := s_soft_cnt;
        wr32(A_CTRL, 3);
        idle(3);
        check(s_start_cnt = v_starts and s_soft_cnt = v_softs + 1, "soft reset wins over start");

        -- i_error and i_done set their flags, a set in the clock of a clear is kept
        pulse_error;
        expect(A_STATUS, 4, "error from the accelerator");
        pulse_done;
        expect(A_STATUS, 6, "done after error");
        wr32(A_CTRL, 1);
        idle(3);
        expect(A_STATUS, 0, "next start clears both");

        -- random sweep on the layer registers against the model
        for i in 1 to G_RANDOM loop
            rand(2, 15, v_idx);
            rand(0, 1, v_n);
            rand(0, 3, v_dly1);
            rand(0, 3, v_dly2);
            rand(0, 3, v_dly3);
            if v_n = 0 then
                rand(0, 65535, v_n);
                v_wd(15 downto 0) := std_logic_vector(to_unsigned(v_n, 16));
                rand(0, 65535, v_n);
                v_wd(31 downto 16) := std_logic_vector(to_unsigned(v_n, 16));
                rand(1, 15, v_n);
                v_strb := std_logic_vector(to_unsigned(v_n, 4));
                if i mod 7 = 0 then
                    v_strb := "1111";
                end if;
                wr(v_idx * 4, v_wd, v_strb, v_dly1, v_dly2, v_dly3);
                for b in 0 to 3 loop
                    if v_strb(b) = '1' then
                        v_model(v_idx)(8 * b + 7 downto 8 * b) := v_wd(8 * b + 7 downto 8 * b);
                    end if;
                end loop;
                v_model(v_idx) := v_model(v_idx) and mask_of(v_idx);
            else
                rd(v_idx * 4, v_data, v_dly1, v_dly2);
                check(v_data = v_model(v_idx), "random read of offset " & integer'image(v_idx * 4));
            end if;
        end loop;
        idle(1);
        check_cfg(v_model, "after the random sweep");

        -- reset clears everything
        pulse_done;
        s_rst <= '1';
        idle(2);
        s_rst <= '0';
        idle(2);
        expect(A_STATUS, 0, "STATUS after reset 2");
        expect(A_IN_BASE, 0, "IN_BASE after reset 2");
        expect(A_C, 0, "C after reset 2");
        v_model := (others => (others => '0'));
        check_cfg(v_model, "after reset 2");

        -- the registers still work
        wr32(A_H, 28);
        expect(A_H, 28, "write after reset");

        idle(4);
        report "starts " & integer'image(s_start_cnt) & ", soft resets " & integer'image(s_soft_cnt) & ", " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_stim_done <= true;
        idle(2);
        s_finished <= true;
        wait;
    end process stim;

end architecture sim;
