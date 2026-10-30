-- integration test: loop_nest + addr_gen + mac_int8 (conv_core_v1) against the hardware golden vectors
-- the memories are VHDL arrays loaded from build/export, the int32 results are compared with <layer>_acc.mem
-- run from vhdl/ (GHDL, VHDL-2008), layer is stem, b1c1, b1c2, b2c1, b2c2, b2sc, b3c1, b3c2 or b3sc, frame is f000 or f016:
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/{loop_nest,addr_gen,mac_int8,conv_core_v1}.vhd tests/integration/tb_conv_core_v1.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_conv_core_v1 -gG_LAYER=stem -gG_FRAME=f000
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.camus_pkg.all;

entity tb_conv_core_v1 is
    generic (
        G_LAYER  : string := "stem";
        G_FRAME  : string := "f000";
        G_EXPORT : string := "../build/export"
    );
end entity tb_conv_core_v1;

architecture sim of tb_conv_core_v1 is
    constant C_PERIOD   : time := 5 ns;   -- 200 MHz
    constant C_IN_BASE  : natural := 16#10000000#;
    constant C_W_BASE   : natural := 16#20000000#;
    constant C_B_BASE   : natural := 16#30000000#;
    constant C_OUT_BASE : natural := 16#40000000#;
    constant C_MEM_SIZE : natural := 65536;

    type t_shape is record
        k, c, h, w, fy, fx, stride, pad, inl, outl : natural;
    end record;

    function get_shape(name : string) return t_shape is
    begin
        if    name = "stem" then return (16, 1, 112, 112, 3, 3, 2, 1, 1, 16);
        elsif name = "b1c1" then return (16, 16, 56, 56, 3, 3, 1, 1, 16, 16);
        elsif name = "b1c2" then return (16, 16, 56, 56, 3, 3, 1, 1, 16, 16);
        elsif name = "b2c1" then return (32, 16, 56, 56, 3, 3, 2, 1, 16, 16);
        elsif name = "b2c2" then return (32, 32, 28, 28, 3, 3, 1, 1, 16, 16);
        elsif name = "b2sc" then return (32, 16, 56, 56, 1, 1, 2, 0, 16, 16);
        elsif name = "b3c1" then return (64, 32, 28, 28, 3, 3, 2, 1, 16, 16);
        elsif name = "b3c2" then return (64, 64, 14, 14, 3, 3, 1, 1, 16, 16);
        elsif name = "b3sc" then return (64, 32, 28, 28, 1, 1, 2, 0, 16, 16);
        end if;
        report "unknown layer " & name severity failure;
        return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    end function get_shape;

    constant C_SHAPE : t_shape := get_shape(G_LAYER);
    constant C_OH    : natural := (C_SHAPE.h + 2 * C_SHAPE.pad - C_SHAPE.fy) / C_SHAPE.stride + 1;
    constant C_OW    : natural := (C_SHAPE.w + 2 * C_SHAPE.pad - C_SHAPE.fx) / C_SHAPE.stride + 1;
    constant C_TERMS : natural := C_SHAPE.k * C_OH * C_OW * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx;
    constant C_OUTS  : natural := C_SHAPE.k * C_OH * C_OW;

    signal s_clk, s_rst, s_start : std_logic := '0';
    signal s_cfg : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => to_unsigned(C_IN_BASE, AXI_ADDR_W), w_base => to_unsigned(C_W_BASE, AXI_ADDR_W),
        b_base => to_unsigned(C_B_BASE, AXI_ADDR_W), out_base => to_unsigned(C_OUT_BASE, AXI_ADDR_W));
    signal s_busy, s_core_done : std_logic;
    signal s_cycles : unsigned(31 downto 0);
    signal s_x_addr, s_w_addr, s_b_addr, s_out_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_x_data, s_w_data : act_t := (others => '0');
    signal s_b_data, s_out_data : acc_t := (others => '0');
    signal s_out_we, s_x_rd : std_logic;
    signal s_loaded, s_finished : boolean := false;
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

    dut : entity work.conv_core_v1
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start,
            o_busy => s_busy, o_done => s_core_done, o_cycles => s_cycles,
            o_x_addr => s_x_addr, o_x_rd => s_x_rd, o_w_addr => s_w_addr, o_b_addr => s_b_addr,
            i_x_data => s_x_data, i_w_data => s_w_data, i_b_data => s_b_data,
            o_out_we => s_out_we, o_out_addr => s_out_addr, o_out_data => s_out_data
        );

    -- memories with a one cycle read latency, written results are compared when the core is done
    memories : process
        type t_i8_mem is array (0 to C_MEM_SIZE - 1) of act_t;
        type t_i32_mem is array (0 to C_MEM_SIZE - 1) of acc_t;
        type t_bool_mem is array (0 to C_MEM_SIZE - 1) of boolean;
        variable v_x_mem, v_w_mem : t_i8_mem;
        variable v_b_mem, v_exp_mem, v_out_mem : t_i32_mem;
        variable v_written : t_bool_mem := (others => false);
        variable v_n_x, v_n_w, v_n_b, v_n_exp, v_idx : natural;
        variable v_writes, v_errors, v_first_bad : natural := 0;

        procedure load_i8(path : string; mem : inout t_i8_mem; n : out natural) is
            file f : text;
            variable st : file_open_status;
            variable l : line;
            variable v : std_logic_vector(7 downto 0);
            variable i : natural := 0;
        begin
            file_open(st, f, path, read_mode);
            assert st = open_ok report "cannot open " & path severity failure;
            while not endfile(f) loop
                readline(f, l);
                hread(l, v);
                mem(i) := signed(v);
                i := i + 1;
            end loop;
            file_close(f);
            n := i;
        end procedure load_i8;

        procedure load_i32(path : string; mem : inout t_i32_mem; n : out natural) is
            file f : text;
            variable st : file_open_status;
            variable l : line;
            variable v : std_logic_vector(31 downto 0);
            variable i : natural := 0;
        begin
            file_open(st, f, path, read_mode);
            assert st = open_ok report "cannot open " & path severity failure;
            while not endfile(f) loop
                readline(f, l);
                hread(l, v);
                mem(i) := signed(v);
                i := i + 1;
            end loop;
            file_close(f);
            n := i;
        end procedure load_i32;
    begin
        load_i8(G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_in.mem", v_x_mem, v_n_x);
        load_i8(G_EXPORT & "/" & G_LAYER & "_w.mem", v_w_mem, v_n_w);
        load_i32(G_EXPORT & "/" & G_LAYER & "_b.mem", v_b_mem, v_n_b);
        load_i32(G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_acc.mem", v_exp_mem, v_n_exp);
        assert v_n_x = C_SHAPE.c * C_SHAPE.h * C_SHAPE.w report "input size " & integer'image(v_n_x) severity failure;
        assert v_n_w = C_SHAPE.k * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx report "weight count " & integer'image(v_n_w) severity failure;
        assert v_n_b = C_SHAPE.k report "bias count " & integer'image(v_n_b) severity failure;
        assert v_n_exp = C_OUTS report "expected count " & integer'image(v_n_exp) severity failure;
        s_loaded <= true;

        loop
            wait until rising_edge(s_clk);
            -- reads, the address is sampled now and the data shows up after this edge
            -- without a read request the data is poison, so a missing padding mask shows up
            if s_x_rd /= '1' then
                s_x_data <= to_signed(85, ACT_W);
            elsif to_integer(s_x_addr) - C_IN_BASE < v_n_x and to_integer(s_x_addr) >= C_IN_BASE then
                s_x_data <= v_x_mem(to_integer(s_x_addr) - C_IN_BASE);
            else
                report "input read outside the array, address " & integer'image(to_integer(s_x_addr)) severity failure;
            end if;
            if to_integer(s_w_addr) - C_W_BASE < v_n_w and to_integer(s_w_addr) >= C_W_BASE then
                s_w_data <= v_w_mem(to_integer(s_w_addr) - C_W_BASE);
            end if;
            if to_integer(s_b_addr) - C_B_BASE < 4 * v_n_b and to_integer(s_b_addr) >= C_B_BASE then
                s_b_data <= v_b_mem((to_integer(s_b_addr) - C_B_BASE) / 4);
            end if;
            -- writes
            if s_out_we = '1' then
                if to_integer(s_out_addr) < C_OUT_BASE or (to_integer(s_out_addr) - C_OUT_BASE) / 4 >= v_n_exp then
                    report "write outside the result array, address " & integer'image(to_integer(s_out_addr)) severity failure;
                end if;
                v_idx := (to_integer(s_out_addr) - C_OUT_BASE) / 4;
                if v_written(v_idx) then
                    report "result " & integer'image(v_idx) & " written twice" severity error;
                    v_errors := v_errors + 1;
                end if;
                v_written(v_idx) := true;
                v_out_mem(v_idx) := s_out_data;
                v_writes := v_writes + 1;
            end if;
            if s_core_done = '1' then
                exit;
            end if;
        end loop;

        -- compare
        for i in 0 to v_n_exp - 1 loop
            if not v_written(i) then
                v_errors := v_errors + 1;
                if v_first_bad = 0 then v_first_bad := i + 1; end if;
            elsif v_out_mem(i) /= v_exp_mem(i) then
                if v_errors < 5 then
                    report "result " & integer'image(i) & ": got " & integer'image(to_integer(v_out_mem(i)))
                           & ", expected " & integer'image(to_integer(v_exp_mem(i))) severity error;
                end if;
                v_errors := v_errors + 1;
            end if;
        end loop;
        report G_LAYER & " " & G_FRAME & ": " & integer'image(v_writes) & " results written, "
               & integer'image(v_n_exp) & " expected, " & integer'image(v_errors) & " errors, "
               & integer'image(to_integer(s_cycles)) & " cycles for " & integer'image(C_TERMS) & " MACs";
        if v_errors > 0 or v_writes /= v_n_exp then
            report "FAIL" severity failure;
        elsif to_integer(s_cycles) < C_TERMS or to_integer(s_cycles) > C_TERMS + 8 then
            report "FAIL, cycle count out of range" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process memories;

    stim : process
    begin
        s_rst <= '1';
        wait for 3 * C_PERIOD;
        wait until rising_edge(s_clk);
        s_rst <= '0';
        if not s_loaded then
            wait until s_loaded;
        end if;
        s_cfg.k <= C_SHAPE.k;
        s_cfg.c <= C_SHAPE.c;
        s_cfg.h <= C_SHAPE.h;
        s_cfg.w <= C_SHAPE.w;
        s_cfg.fy <= C_SHAPE.fy;
        s_cfg.fx <= C_SHAPE.fx;
        s_cfg.stride <= C_SHAPE.stride;
        s_cfg.pad <= C_SHAPE.pad;
        s_cfg.in_lanes <= C_SHAPE.inl;
        s_cfg.out_lanes <= C_SHAPE.outl;
        wait until rising_edge(s_clk);
        s_start <= '1';
        wait until rising_edge(s_clk);
        s_start <= '0';
        wait for (C_TERMS + 1000) * C_PERIOD;
        if not s_finished then
            report "timeout, the core did not finish" severity failure;
        end if;
        wait;
    end process stim;

end architecture sim;
