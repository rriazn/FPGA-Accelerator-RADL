-- self-checking unit testbench for loop_nest, compares against a plain nested-loop model
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/loop_nest.vhd tests/unit/compute-engine/tb_loop_nest.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_loop_nest
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;

entity tb_loop_nest is
end entity tb_loop_nest;

architecture sim of tb_loop_nest is
    constant C_PERIOD : time := 5 ns;   -- 200 MHz

    signal s_clk   : std_logic := '0';
    signal s_rst   : std_logic := '1';
    signal s_start : std_logic := '0';
    signal s_step  : std_logic := '0';
    signal s_cfg   : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => (others => '0'), w_base => (others => '0'),
        b_base => (others => '0'), out_base => (others => '0'));
    signal s_k, s_oy, s_ox, s_c, s_fy, s_fx : natural;
    signal s_first, s_last, s_last_out, s_running : std_logic;
    signal s_done  : boolean := false;
begin

    clk_gen : process
    begin
        while not s_done loop
            s_clk <= '0';
            wait for C_PERIOD / 2;
            s_clk <= '1';
            wait for C_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    dut : entity work.loop_nest
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start, i_step => s_step,
            o_k => s_k, o_oy => s_oy, o_ox => s_ox, o_c => s_c, o_fy => s_fy, o_fx => s_fx,
            o_first_mac => s_first, o_last_mac => s_last, o_last_output => s_last_out,
            o_running => s_running
        );

    stim : process
        variable v_checks : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := 3;
        variable v_seed2  : positive := 7;

        impure function rand(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            return lo + integer(floor(r * real(hi - lo + 1)));
        end function rand;

        procedure tick is
        begin
            wait until rising_edge(s_clk);
            wait for 1 ns;
        end procedure tick;

        procedure fail(msg : string) is
        begin
            v_errors := v_errors + 1;
            report msg & " at " & time'image(now) severity error;
        end procedure fail;

        procedure do_reset is
        begin
            s_rst <= '1';
            s_step <= '0';
            s_start <= '0';
            tick;
            tick;
            s_rst <= '0';
        end procedure do_reset;

        -- one layer: k out channels, c in channels, h x w input, fy x fx kernel
        -- stall: random cycles with i_step = 0 between terms
        -- noise: random i_start pulses while running, they must be ignored
        procedure run_layer(p_k, p_c, p_h, p_w, p_fy, p_fx, p_stride, p_pad : natural; stall, noise : boolean) is
            constant oh : natural := (p_h + 2 * p_pad - p_fy) / p_stride + 1;
            constant ow : natural := (p_w + 2 * p_pad - p_fx) / p_stride + 1;
            variable v_n_first, v_n_last, v_n_lastout, v_terms : natural := 0;
            variable v_last_term : boolean;
            variable v_gap : integer;

            -- compare the current outputs with the model term
            procedure check_term(k, oy, ox, c, fy, fx : natural) is
                variable e_first, e_last, e_lastout : std_logic;
            begin
                e_first := '1' when (c = 0 and fy = 0 and fx = 0) else '0';
                e_last := '1' when (c = p_c - 1 and fy = p_fy - 1 and fx = p_fx - 1) else '0';
                e_lastout := '1' when (e_last = '1' and ox = ow - 1 and oy = oh - 1 and k = p_k - 1) else '0';
                v_checks := v_checks + 1;
                if s_running /= '1' then
                    fail("not running");
                elsif s_k /= k or s_oy /= oy or s_ox /= ox or s_c /= c or s_fy /= fy or s_fx /= fx then
                    fail("index mismatch, expected k/oy/ox/c/fy/fx " & integer'image(k) & "/" & integer'image(oy)
                         & "/" & integer'image(ox) & "/" & integer'image(c) & "/" & integer'image(fy) & "/"
                         & integer'image(fx) & ", got " & integer'image(s_k) & "/" & integer'image(s_oy) & "/"
                         & integer'image(s_ox) & "/" & integer'image(s_c) & "/" & integer'image(s_fy) & "/"
                         & integer'image(s_fx));
                elsif s_first /= e_first or s_last /= e_last or s_last_out /= e_lastout then
                    fail("flag mismatch at k/oy/ox/c/fy/fx " & integer'image(k) & "/" & integer'image(oy)
                         & "/" & integer'image(ox) & "/" & integer'image(c) & "/" & integer'image(fy) & "/"
                         & integer'image(fx));
                end if;
            end procedure check_term;
        begin
            s_cfg.k <= p_k;
            s_cfg.c <= p_c;
            s_cfg.h <= p_h;
            s_cfg.w <= p_w;
            s_cfg.fy <= p_fy;
            s_cfg.fx <= p_fx;
            s_cfg.stride <= p_stride;
            s_cfg.pad <= p_pad;
            s_step <= '0';
            s_start <= '1';
            tick;
            s_start <= '0';
            -- the shape is latched at start, changing i_cfg now must not matter
            s_cfg.k <= 1;
            s_cfg.c <= 1;
            s_cfg.h <= 1;
            s_cfg.w <= 1;
            s_cfg.fy <= 1;
            s_cfg.fx <= 1;
            s_cfg.stride <= 1;
            s_cfg.pad <= 0;

            for k in 0 to p_k - 1 loop
                for oy in 0 to oh - 1 loop
                    for ox in 0 to ow - 1 loop
                        for c in 0 to p_c - 1 loop
                            for fy in 0 to p_fy - 1 loop
                                for fx in 0 to p_fx - 1 loop
                                    v_last_term := (k = p_k - 1 and oy = oh - 1 and ox = ow - 1
                                                    and c = p_c - 1 and fy = p_fy - 1 and fx = p_fx - 1);
                                    if noise and not v_last_term then
                                        s_start <= '1' when rand(0, 1) = 1 else '0';
                                    else
                                        s_start <= '0';
                                    end if;
                                    check_term(k, oy, ox, c, fy, fx);
                                    if stall then
                                        v_gap := rand(-2, 3);
                                        while v_gap > 0 loop
                                            s_step <= '0';
                                            tick;
                                            check_term(k, oy, ox, c, fy, fx);   -- outputs hold while stalled
                                            v_gap := v_gap - 1;
                                        end loop;
                                    end if;
                                    s_step <= '1';
                                    if s_first = '1' then v_n_first := v_n_first + 1; end if;
                                    if s_last = '1' then v_n_last := v_n_last + 1; end if;
                                    if s_last_out = '1' then v_n_lastout := v_n_lastout + 1; end if;
                                    v_terms := v_terms + 1;
                                    tick;
                                end loop;
                            end loop;
                        end loop;
                    end loop;
                end loop;
            end loop;
            s_step <= '0';
            s_start <= '0';

            -- counts seen on the outputs
            v_checks := v_checks + 1;
            if v_n_first /= p_k * oh * ow or v_n_last /= p_k * oh * ow or v_n_lastout /= 1
               or v_terms /= p_k * oh * ow * p_c * p_fy * p_fx then
                fail("flag counts: first " & integer'image(v_n_first) & ", last " & integer'image(v_n_last)
                     & ", last_output " & integer'image(v_n_lastout) & ", terms " & integer'image(v_terms));
            end if;
            -- finished: idle, flags low
            v_checks := v_checks + 1;
            if s_running /= '0' or s_first /= '0' or s_last /= '0' or s_last_out /= '0' then
                fail("not idle after the last term");
            end if;
        end procedure run_layer;

        variable v_fy, v_fx, v_pad, v_h, v_w : integer;
    begin
        do_reset;
        tick;

        -- idle: i_step must do nothing
        s_step <= '1';
        tick;
        tick;
        s_step <= '0';
        v_checks := v_checks + 1;
        if s_running /= '0' then fail("started without i_start"); end if;

        -- degenerate layers
        run_layer(1, 1, 1, 1, 1, 1, 1, 0, false, false);   -- one term, first = last = last_output
        run_layer(1, 1, 1, 1, 3, 3, 1, 1, false, false);   -- 3x3 on a 1x1 image
        run_layer(2, 2, 1, 1, 1, 1, 1, 0, false, false);   -- the worked example, 4 terms

        -- reduced shapes of the real layers
        run_layer(3, 1, 8, 8, 3, 3, 2, 1, false, false);   -- stem like
        run_layer(2, 4, 6, 6, 3, 3, 1, 1, true, false);    -- block conv like
        run_layer(4, 16, 8, 8, 3, 3, 2, 1, false, false);  -- stride 2, 16 in channels
        run_layer(4, 16, 8, 8, 1, 1, 2, 0, true, true);    -- 1x1 shortcut like
        run_layer(2, 3, 5, 6, 3, 3, 1, 1, true, true);     -- non square

        -- full size stem, 451584 terms
        run_layer(16, 1, 112, 112, 3, 3, 2, 1, false, false);

        -- reset in the middle of a layer, then a new layer must run cleanly
        s_cfg.k <= 2; s_cfg.c <= 2; s_cfg.h <= 4; s_cfg.w <= 4; s_cfg.fy <= 3; s_cfg.fx <= 3;
        s_cfg.stride <= 1; s_cfg.pad <= 1;
        s_start <= '1';
        tick;
        s_start <= '0';
        s_step <= '1';
        tick;
        tick;
        tick;
        do_reset;
        v_checks := v_checks + 1;
        if s_running /= '0' then fail("running after reset"); end if;
        run_layer(2, 2, 4, 4, 3, 3, 1, 1, true, false);

        -- random small layers with stalls and start noise
        for n in 1 to 300 loop
            v_fy := 2 * rand(0, 1) + 1;
            v_fx := 2 * rand(0, 1) + 1;
            v_pad := rand(0, 1);
            v_h := rand(maximum(1, v_fy - 2 * v_pad), 9);
            v_w := rand(maximum(1, v_fx - 2 * v_pad), 9);
            run_layer(rand(1, 4), rand(1, 5), v_h, v_w, v_fy, v_fx, rand(1, 2), v_pad, rand(0, 1) = 1, rand(0, 1) = 1);
        end loop;

        report integer'image(v_checks) & " checks, " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_done <= true;
        wait;
    end process stim;

end architecture sim;
