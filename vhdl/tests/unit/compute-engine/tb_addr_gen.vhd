-- self-checking unit testbench for addr_gen, driven by the real layer_setup and loop_nest
-- every term (stalled cycles too) is compared with the plain formulas: elem_addr for x and out, [K][C][FY][FX] for w
-- plus hand computed offsets and the property that every output slot is written once
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/{layer_setup,loop_nest,addr_gen}.vhd tests/unit/compute-engine/tb_addr_gen.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_addr_gen
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;

entity tb_addr_gen is
end entity tb_addr_gen;

architecture sim of tb_addr_gen is
    constant C_PERIOD : time := 5 ns;
    constant C_IDLE_CFG : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => (others => '0'), w_base => (others => '0'),
        b_base => (others => '0'), out_base => (others => '0'));

    signal s_clk   : std_logic := '0';
    signal s_rst   : std_logic := '1';
    signal s_start : std_logic := '0';
    signal s_step  : std_logic := '0';
    signal s_cfg   : layer_cfg_t := C_IDLE_CFG;

    signal s_setup_done : std_logic;
    signal s_lcfg  : layer_cfg_t;
    signal s_const : addr_const_t;
    signal s_k, s_oy, s_ox, s_c, s_fy, s_fx : natural;
    signal s_at_max : std_logic_vector(5 downto 0);
    signal s_first, s_last, s_last_out, s_running : std_logic;
    signal s_addr_step : std_logic;
    signal s_x_addr, s_w_addr, s_b_addr, s_out_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_x_valid : std_logic;
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

    -- wired as in conv_core_v1
    u_setup : entity work.layer_setup
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start,
            o_busy => open, o_done => s_setup_done, o_cfg => s_lcfg, o_const => s_const
        );

    u_loop : entity work.loop_nest
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_lcfg, i_oh => s_const.oh, i_ow => s_const.ow,
            i_start => s_setup_done, i_step => s_step,
            o_k => s_k, o_oy => s_oy, o_ox => s_ox, o_c => s_c, o_fy => s_fy, o_fx => s_fx,
            o_at_max => s_at_max,
            o_first_mac => s_first, o_last_mac => s_last, o_last_output => s_last_out,
            o_running => s_running
        );

    s_addr_step <= s_step and s_running;

    dut : entity work.addr_gen
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_lcfg, i_const => s_const,
            i_start => s_setup_done, i_step => s_addr_step, i_at_max => s_at_max,
            o_x_addr => s_x_addr, o_x_valid => s_x_valid, o_w_addr => s_w_addr,
            o_b_addr => s_b_addr, o_out_addr => s_out_addr
        );

    stim : process
        -- a hand computed term: indices and the expected offsets from the bases, -1 is not checked
        type t_spot is record
            k, oy, ox, c, fy, fx : integer;
            xo, wo, bo, oo : integer;
        end record;
        type t_spot_vec is array (natural range <>) of t_spot;
        constant C_NO_SPOTS : t_spot_vec(0 to 0) := (others => (others => -1));

        type t_bool_vec is array (natural range <>) of boolean;
        variable v_seen   : t_bool_vec(0 to 65535);
        variable v_checks : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := 5;
        variable v_seed2  : positive := 17;

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

        -- one layer through the chain; stall: random cycles with i_step = 0
        procedure run_cfg(cfg : layer_cfg_t; stall : boolean; spots : t_spot_vec) is
            constant oh : natural := (cfg.h + 2 * cfg.pad - cfg.fy) / cfg.stride + 1;
            constant ow : natural := (cfg.w + 2 * cfg.pad - cfg.fx) / cfg.stride + 1;
            constant n_terms : natural := cfg.k * oh * ow * cfg.c * cfg.fy * cfg.fx;
            -- output slots including the unused lanes of the last channel block
            constant n_slots : natural := (cfg.k + cfg.out_lanes - 1) / cfg.out_lanes * cfg.out_lanes * oh * ow;
            variable v_terms, v_wait, v_slot : natural := 0;
            variable v_iy, v_ix : integer;
            variable v_valid, v_step : boolean;
            variable v_garbage : layer_cfg_t;

            -- compare the addresses with the formulas for the indices loop_nest shows
            procedure check_term is
                variable e_x, e_w, e_b, e_out : unsigned(AXI_ADDR_W-1 downto 0);
            begin
                v_iy := s_oy * cfg.stride - cfg.pad + s_fy;
                v_ix := s_ox * cfg.stride - cfg.pad + s_fx;
                v_valid := v_iy >= 0 and v_iy < cfg.h and v_ix >= 0 and v_ix < cfg.w;
                e_w := cfg.w_base + u(((s_k * cfg.c + s_c) * cfg.fy + s_fy) * cfg.fx + s_fx);
                e_b := cfg.b_base + u(4 * s_k);
                e_out := cfg.out_base + u(4 * elem_addr(s_k, s_oy, s_ox, oh, ow, cfg.out_lanes));
                v_checks := v_checks + 1;
                if (s_x_valid = '1') /= v_valid or s_w_addr /= e_w or s_b_addr /= e_b or s_out_addr /= e_out then
                    v_errors := v_errors + 1;
                elsif v_valid then
                    e_x := cfg.in_base + u(elem_addr(s_c, v_iy, v_ix, cfg.h, cfg.w, cfg.in_lanes));
                    if s_x_addr /= e_x then
                        v_errors := v_errors + 1;
                    end if;
                end if;
            end procedure check_term;

            procedure check_spots is
            begin
                for i in spots'range loop
                    if spots(i).k = s_k and spots(i).oy = s_oy and spots(i).ox = s_ox
                       and spots(i).c = s_c and spots(i).fy = s_fy and spots(i).fx = s_fx then
                        check((s_x_valid = '1') = (spots(i).xo >= 0), "spot " & integer'image(i) & ": x valid");
                        if spots(i).xo >= 0 then
                            check(s_x_addr - cfg.in_base = u(spots(i).xo), "spot " & integer'image(i) & ": x offset");
                        end if;
                        if spots(i).wo >= 0 then
                            check(s_w_addr - cfg.w_base = u(spots(i).wo), "spot " & integer'image(i) & ": w offset");
                        end if;
                        if spots(i).bo >= 0 then
                            check(s_b_addr - cfg.b_base = u(spots(i).bo), "spot " & integer'image(i) & ": b offset");
                        end if;
                        if spots(i).oo >= 0 then
                            check(s_out_addr - cfg.out_base = u(spots(i).oo), "spot " & integer'image(i) & ": out offset");
                        end if;
                    end if;
                end loop;
            end procedure check_spots;

            variable v_err0 : natural;
        begin
            assert n_slots <= v_seen'length report "layer too large for the slot check" severity failure;
            for i in 0 to n_slots - 1 loop
                v_seen(i) := false;
            end loop;
            s_cfg <= cfg;
            s_step <= '0';
            s_start <= '1';
            tick;
            s_start <= '0';
            -- latched at start, a different config now must not matter
            v_garbage := C_IDLE_CFG;
            v_garbage.in_base := rand_addr;
            s_cfg <= v_garbage;
            -- the first term comes after the setup
            while s_running /= '1' loop
                tick;
                v_wait := v_wait + 1;
                if v_wait > 2**17 + 100 then
                    report "layer does not start" severity failure;
                end if;
            end loop;
            check(v_wait = maximum(oh, ow) + 5, "setup took " & integer'image(v_wait) & " clocks");

            while s_running = '1' loop
                v_err0 := v_errors;
                check_term;
                if v_errors /= v_err0 and v_errors <= 20 then
                    report "address mismatch at k/oy/ox/c/fy/fx " & integer'image(s_k) & "/" & integer'image(s_oy)
                           & "/" & integer'image(s_ox) & "/" & integer'image(s_c) & "/" & integer'image(s_fy)
                           & "/" & integer'image(s_fx) & " valid " & std_logic'image(s_x_valid)
                           & " x " & integer'image(to_integer(s_x_addr - cfg.in_base))
                           & " w " & integer'image(to_integer(s_w_addr - cfg.w_base))
                           & " out " & integer'image(to_integer(s_out_addr - cfg.out_base)) severity error;
                end if;
                check_spots;
                v_step := not (stall and rand(0, 2) = 0);
                if v_step then
                    s_step <= '1';
                    v_terms := v_terms + 1;
                    -- every output slot is used by exactly one output element
                    if s_first = '1' then
                        v_slot := to_integer(s_out_addr - cfg.out_base) / 4;
                        if v_slot >= n_slots then
                            check(false, "output slot " & integer'image(v_slot) & " out of range");
                        else
                            check(not v_seen(v_slot), "output slot " & integer'image(v_slot) & " used twice");
                            v_seen(v_slot) := true;
                        end if;
                    end if;
                else
                    s_step <= '0';
                end if;
                tick;
            end loop;
            s_step <= '0';
            check(v_terms = n_terms, "terms " & integer'image(v_terms) & ", expected " & integer'image(n_terms));
        end procedure run_cfg;

        procedure run_shape(k, c, h, w, fy, fx, stride, pad, inl, outl : natural; stall : boolean;
                            spots : t_spot_vec) is
            variable v_cfg : layer_cfg_t;
        begin
            v_cfg := (c => c, k => k, h => h, w => w, fy => fy, fx => fx, stride => stride, pad => pad,
                      in_lanes => inl, out_lanes => outl,
                      in_base => x"10000000", w_base => x"20000000", b_base => x"30000000", out_base => x"40000000");
            run_cfg(v_cfg, stall, spots);
        end procedure run_shape;

        variable v_cfg : layer_cfg_t;
    begin
        tick;
        tick;
        s_rst <= '0';
        tick;

        -- stem: input 112x112x1 plain, 16 output channels, 3x3, stride 2, pad 1
        -- spots: k, oy, ox, c, fy, fx, then x, w, b, out offsets (x = -1: padding)
        run_shape(16, 1, 112, 112, 3, 3, 2, 1, 1, 16, false, (
            (5, 0, 1, 0, 1, 1, 2, 49, 20, 84),
            (5, 0, 1, 0, 0, 1, -1, 46, 20, 84),           -- top padding row
            (5, 0, 0, 0, 1, 0, -1, 48, 20, 20),           -- left padding column
            (15, 55, 55, 0, 2, 2, 12543, 143, 60, 200700), -- last term of the last output
            (0, 0, 0, 0, 0, 0, -1, 0, 0, 0),
            (3, 0, 0, 0, 0, 0, -1, 27, 12, 12)));
        -- blocked input layout: c = 3 at (iy, ix) = (2, 3), channel 17 at (4, 5)
        run_shape(1, 16, 56, 56, 3, 3, 1, 1, 16, 16, true, (0 => (0, 1, 2, 3, 2, 2, 1843, -1, 0, -1)));
        run_shape(1, 32, 28, 28, 3, 3, 1, 1, 16, 16, false, (0 => (0, 5, 6, 17, 0, 0, 14417, -1, 0, -1)));
        -- 5x5 input, 3x3, stride 2, pad 1: rows are padding for (oy, fy) = (0, 0) and (2, 2)
        run_shape(1, 1, 5, 5, 3, 3, 2, 1, 1, 16, true, (
            (0, 0, 1, 0, 0, 1, -1, -1, -1, -1),
            (0, 1, 1, 0, 0, 1, 7, -1, -1, -1),
            (0, 2, 1, 0, 2, 1, -1, -1, -1, -1)));

        -- full ResNet-8 shortcut layers, reduced versions of the others
        run_shape(32, 16, 56, 56, 1, 1, 2, 0, 16, 16, false, C_NO_SPOTS);   -- b2sc
        run_shape(64, 32, 28, 28, 1, 1, 2, 0, 16, 16, false, C_NO_SPOTS);   -- b3sc
        run_shape(17, 33, 6, 5, 3, 3, 1, 1, 16, 16, true, C_NO_SPOTS);      -- b1c1 like, partial blocks
        run_shape(18, 20, 9, 8, 3, 3, 2, 1, 16, 16, true, C_NO_SPOTS);      -- b2c1 like
        run_shape(16, 3, 7, 9, 3, 3, 2, 1, 1, 16, false, C_NO_SPOTS);       -- odd shape
        run_shape(1, 1, 1, 1, 1, 1, 1, 0, 1, 1, false, C_NO_SPOTS);         -- one term
        run_shape(2, 2, 1, 1, 3, 3, 1, 1, 16, 16, true, C_NO_SPOTS);        -- kernel larger than the input

        -- reset in the middle of a layer, then a new layer must run cleanly
        v_cfg := (c => 4, k => 3, h => 6, w => 6, fy => 3, fx => 3, stride => 1, pad => 1,
                  in_lanes => 16, out_lanes => 16,
                  in_base => x"10000000", w_base => x"20000000", b_base => x"30000000", out_base => x"40000000");
        s_cfg <= v_cfg;
        s_start <= '1';
        tick;
        s_start <= '0';
        s_step <= '1';
        for i in 1 to 200 loop
            tick;
        end loop;
        s_rst <= '1';
        tick;
        s_rst <= '0';
        s_step <= '0';
        check(s_running = '0', "running after reset");
        run_cfg(v_cfg, true, C_NO_SPOTS);

        -- random small layers: lanes 1 to 16, strides up to 4, bases anywhere (x_org may wrap)
        for n in 1 to 400 loop
            v_cfg.fy := rand(1, 5);
            v_cfg.fx := rand(1, 5);
            v_cfg.pad := rand(0, 2);
            v_cfg.stride := rand(1, 4);
            v_cfg.h := rand(maximum(1, v_cfg.fy - 2 * v_cfg.pad), 10);
            v_cfg.w := rand(maximum(1, v_cfg.fx - 2 * v_cfg.pad), 10);
            v_cfg.c := rand(1, 20);
            v_cfg.k := rand(1, 20);
            v_cfg.in_lanes := rand(1, 16);
            v_cfg.out_lanes := rand(1, 16);
            v_cfg.in_base := rand_addr;
            v_cfg.w_base := rand_addr;
            v_cfg.b_base := rand_addr;
            v_cfg.out_base := rand_addr;
            if n mod 50 = 0 then
                v_cfg.in_base := (others => '0');   -- the start pointer wraps below 0
            end if;
            run_cfg(v_cfg, rand(0, 1) = 1, C_NO_SPOTS);
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
