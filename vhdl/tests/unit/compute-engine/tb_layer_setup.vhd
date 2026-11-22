-- self-checking unit testbench for layer_setup: oh, ow, every address step, the latched config and the setup length
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/layer_setup.vhd tests/unit/compute-engine/tb_layer_setup.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_layer_setup
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;

entity tb_layer_setup is
end entity tb_layer_setup;

architecture sim of tb_layer_setup is
    constant C_PERIOD : time := 5 ns;
    constant C_IDLE_CFG : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 1, out_lanes => 1,
        in_base => (others => '0'), w_base => (others => '0'),
        b_base => (others => '0'), out_base => (others => '0'));

    signal s_clk   : std_logic := '0';
    signal s_rst   : std_logic := '1';
    signal s_start : std_logic := '0';
    signal s_cfg   : layer_cfg_t := C_IDLE_CFG;
    signal s_busy, s_done : std_logic;
    signal s_lcfg  : layer_cfg_t;
    signal s_const : addr_const_t;
    signal s_finished : boolean := false;
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

    dut : entity work.layer_setup
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start,
            o_busy => s_busy, o_done => s_done, o_cfg => s_lcfg, o_const => s_const
        );

    stim : process
        variable v_checks : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := 11;
        variable v_seed2  : positive := 29;

        impure function rand(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            return lo + integer(floor(r * real(hi - lo + 1)));
        end function rand;

        impure function rand_addr return unsigned is
        begin
            return to_unsigned(rand(0, 65535), 16) & to_unsigned(rand(0, 65535), 16);
        end function rand_addr;

        procedure tick is
        begin
            wait until rising_edge(s_clk);
            wait for 1 ns;
        end procedure tick;

        procedure check(cond : boolean; msg : string) is
        begin
            v_checks := v_checks + 1;
            if not cond then
                v_errors := v_errors + 1;
                if v_errors <= 20 then
                    report msg & " at " & time'image(now) severity error;
                end if;
            end if;
        end procedure check;

        function u(n : natural) return unsigned is
        begin
            return to_unsigned(n, AXI_ADDR_W);
        end function u;

        -- start one setup, check the outputs and the number of clocks
        -- noise: a second start with another config while busy, it must be ignored
        procedure run_cfg(cfg : layer_cfg_t; noise : boolean) is
            constant oh : natural := (cfg.h + 2 * cfg.pad - cfg.fy) / cfg.stride + 1;
            constant ow : natural := (cfg.w + 2 * cfg.pad - cfg.fx) / cfg.stride + 1;
            constant inl : natural := cfg.in_lanes;
            constant outl : natural := cfg.out_lanes;
            variable v_n : natural := 0;
            variable v_other : layer_cfg_t;
        begin
            s_cfg <= cfg;
            s_start <= '1';
            tick;
            s_start <= '0';
            -- latched at start, a different config now must not matter
            v_other := cfg;
            v_other.h := cfg.h + 3;
            v_other.w := cfg.w + 5;
            v_other.stride := 1;
            v_other.in_lanes := 1 + (inl mod 16);
            v_other.in_base := cfg.in_base + 4096;
            s_cfg <= v_other;
            while s_done /= '1' loop
                check(s_busy = '1', "not busy before done");
                if noise and v_n = 1 then
                    s_start <= '1';
                else
                    s_start <= '0';
                end if;
                tick;
                v_n := v_n + 1;
                if v_n > 2**17 + 100 then
                    report "no done" severity failure;
                end if;
            end loop;
            s_start <= '0';
            check(s_busy = '0', "busy together with done");
            check(v_n = maximum(oh, ow) + 4, "setup length " & integer'image(v_n) & ", expected "
                  & integer'image(maximum(oh, ow) + 4));
            check(s_lcfg = cfg, "latched config");
            check(s_const.oh = oh and s_const.ow = ow, "oh/ow " & integer'image(s_const.oh) & "/"
                  & integer'image(s_const.ow) & ", expected " & integer'image(oh) & "/" & integer'image(ow));
            check(s_const.x_org = cfg.in_base - u((cfg.pad * cfg.w + cfg.pad) * inl), "x_org");
            check(s_const.x_fx = u(inl), "x_fx");
            check(s_const.x_fy = u(cfg.w * inl), "x_fy");
            check(s_const.x_cblk = u(cfg.h * cfg.w * inl - (inl - 1)), "x_cblk");
            check(s_const.x_ox = u(cfg.stride * inl), "x_ox");
            check(s_const.x_oy = u(cfg.stride * cfg.w * inl), "x_oy");
            check(s_const.w_k = u(cfg.c * cfg.fy * cfg.fx), "w_k");
            check(s_const.out_px = u(4 * outl), "out_px");
            check(s_const.out_kblk = u(4 * (oh * ow * outl - (outl - 1))), "out_kblk");
            -- done is one clock, the outputs hold afterwards
            tick;
            check(s_done = '0', "done longer than one clock");
            check(s_const.oh = oh and s_lcfg = cfg, "outputs do not hold after done");
            tick;
        end procedure run_cfg;

        procedure run_shape(k, c, h, w, fy, fx, stride, pad, inl, outl : natural) is
            variable v_cfg : layer_cfg_t;
        begin
            v_cfg := (c => c, k => k, h => h, w => w, fy => fy, fx => fx, stride => stride, pad => pad,
                      in_lanes => inl, out_lanes => outl,
                      in_base => x"10000000", w_base => x"20000000", b_base => x"30000000", out_base => x"40000000");
            run_cfg(v_cfg, false);
        end procedure run_shape;

        variable v_cfg : layer_cfg_t;
    begin
        tick;
        tick;
        s_rst <= '0';
        tick;
        check(s_busy = '0' and s_done = '0', "idle after reset");

        -- the ResNet-8 conv layers: k, c, h, w, fy, fx, stride, pad, in lanes, out lanes
        run_shape(16, 1, 112, 112, 3, 3, 2, 1, 1, 16);   -- stem
        run_shape(16, 16, 56, 56, 3, 3, 1, 1, 16, 16);   -- b1c1, b1c2
        run_shape(32, 16, 56, 56, 3, 3, 2, 1, 16, 16);   -- b2c1
        run_shape(32, 32, 28, 28, 3, 3, 1, 1, 16, 16);   -- b2c2
        run_shape(32, 16, 56, 56, 1, 1, 2, 0, 16, 16);   -- b2sc
        run_shape(64, 32, 28, 28, 3, 3, 2, 1, 16, 16);   -- b3c1
        run_shape(64, 64, 14, 14, 3, 3, 1, 1, 16, 16);   -- b3c2
        run_shape(64, 32, 28, 28, 1, 1, 2, 0, 16, 16);   -- b3sc

        -- corner cases: one output, kernel larger than the input, largest stride and pad
        run_shape(1, 1, 1, 1, 1, 1, 1, 0, 1, 1);
        run_shape(1, 1, 1, 1, 3, 3, 1, 1, 16, 16);
        run_shape(3, 5, 9, 4, 7, 2, 7, 7, 3, 5);
        run_shape(2, 2, 1, 200, 1, 7, 1, 3, 16, 1);

        -- a start while busy is ignored
        v_cfg := (c => 3, k => 4, h => 20, w => 11, fy => 3, fx => 3, stride => 2, pad => 1,
                  in_lanes => 16, out_lanes => 16,
                  in_base => x"00000004", w_base => x"20000000", b_base => x"30000000", out_base => x"40000000");
        run_cfg(v_cfg, true);

        -- reset during the setup, then a clean setup
        s_cfg <= v_cfg;
        s_start <= '1';
        tick;
        s_start <= '0';
        tick;
        tick;
        s_rst <= '1';
        tick;
        s_rst <= '0';
        check(s_busy = '0' and s_done = '0', "idle after reset in the setup");
        for i in 1 to 30 loop
            tick;
            check(s_done = '0', "done after reset");
        end loop;
        run_cfg(v_cfg, false);

        -- random valid configs, lanes 1 to 16, bases anywhere (x_org may wrap)
        for n in 1 to 500 loop
            v_cfg.fy := rand(1, 7);
            v_cfg.fx := rand(1, 7);
            v_cfg.pad := rand(0, 7);
            v_cfg.stride := rand(1, 7);
            v_cfg.h := rand(maximum(1, v_cfg.fy - 2 * v_cfg.pad), 70);
            v_cfg.w := rand(maximum(1, v_cfg.fx - 2 * v_cfg.pad), 70);
            v_cfg.c := rand(1, 100);
            v_cfg.k := rand(1, 100);
            v_cfg.in_lanes := rand(1, 16);
            v_cfg.out_lanes := rand(1, 16);
            v_cfg.in_base := rand_addr;
            v_cfg.w_base := rand_addr;
            v_cfg.b_base := rand_addr;
            v_cfg.out_base := rand_addr;
            run_cfg(v_cfg, rand(0, 1) = 1);
        end loop;

        report integer'image(v_checks) & " checks, " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process stim;

end architecture sim;
