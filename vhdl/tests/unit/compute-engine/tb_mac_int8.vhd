-- self-checking unit testbench for mac_int8
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/mac_int8.vhd tests/unit/compute-engine/tb_mac_int8.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_mac_int8
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;

entity tb_mac_int8 is
end entity tb_mac_int8;

architecture sim of tb_mac_int8 is
    constant C_PERIOD : time := 5 ns;   -- 200 MHz

    signal s_clk   : std_logic := '0';
    signal s_rst   : std_logic := '1';
    signal s_en    : std_logic := '0';
    signal s_first : std_logic := '0';
    signal s_last  : std_logic := '0';
    signal s_bias  : acc_t := (others => '0');
    signal s_a     : act_t := (others => '0');
    signal s_b     : act_t := (others => '0');
    signal s_acc   : acc_t;
    signal s_valid : std_logic;
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

    dut : entity work.mac_int8
        port map (
            i_clk   => s_clk,
            i_rst   => s_rst,
            i_en    => s_en,
            i_first => s_first,
            i_last  => s_last,
            i_bias  => s_bias,
            i_a     => s_a,
            i_b     => s_b,
            o_acc   => s_acc,
            o_acc_valid => s_valid
        );

    stim : process
        variable v_exp    : integer := 0;
        variable v_known  : boolean := false;   -- model is valid once a first term was accepted
        variable v_valid_prev : std_logic := '0';   -- o_acc_valid expected from the previous cycle
        variable v_checks : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := 1;
        variable v_seed2  : positive := 2;

        impure function rand(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            return lo + integer(floor(r * real(hi - lo + 1)));
        end function rand;

        -- drive one clock cycle, update the model and compare after the edge
        -- o_acc_valid must be 1 exactly one cycle after a cycle with en and last
        procedure step(en, first : std_logic; bias, a, b : integer; last : std_logic := '0') is
            variable v_valid_exp : std_logic;
        begin
            s_en    <= en;
            s_first <= first;
            s_last  <= last;
            s_bias  <= to_signed(bias, ACC_W);
            s_a     <= to_signed(a, ACT_W);
            s_b     <= to_signed(b, ACT_W);
            -- outputs are registered: they must not react to the new inputs before the edge
            wait for 2 ns;
            v_checks := v_checks + 1;
            if s_valid /= v_valid_prev or (v_known and to_integer(s_acc) /= v_exp) then
                v_errors := v_errors + 1;
                report "outputs changed before the clock edge at " & time'image(now) severity error;
            end if;
            wait until rising_edge(s_clk);
            wait for 1 ns;
            if en = '1' then
                if first = '1' then
                    v_exp   := bias + a * b;
                    v_known := true;
                elsif v_known then
                    v_exp := v_exp + a * b;
                end if;
            end if;
            if v_known then
                v_checks := v_checks + 1;
                if to_integer(s_acc) /= v_exp then
                    v_errors := v_errors + 1;
                    report "mismatch at " & time'image(now) & ": expected " & integer'image(v_exp)
                           & ", got " & integer'image(to_integer(s_acc)) severity error;
                end if;
            end if;
            v_valid_exp := en and last;
            v_valid_prev := v_valid_exp;
            v_checks := v_checks + 1;
            if s_valid /= v_valid_exp then
                v_errors := v_errors + 1;
                report "o_acc_valid mismatch at " & time'image(now) & ": expected " & std_logic'image(v_valid_exp)
                       & ", got " & std_logic'image(s_valid) severity error;
            end if;
        end procedure step;

        procedure reset is
        begin
            s_rst <= '1';
            s_en  <= '0';
            wait until rising_edge(s_clk);
            wait until rising_edge(s_clk);
            wait for 1 ns;
            s_rst   <= '0';
            v_known := false;
            v_valid_prev := '0';
        end procedure reset;

        variable v_len : integer;
    begin
        reset;

        -- directed: sum, hold with en = 0, first ignored with en = 0
        step('1', '1', 100, 3, 4);       -- 112
        step('1', '0', 0, -2, 5);        -- 102
        step('0', '0', 0, 99, 99);       -- hold 102
        step('1', '0', 0, 7, 7, '1');    -- 151, valid
        step('0', '1', 555, 1, 1, '1');  -- first and last ignored with en = 0, hold 151, no valid
        step('0', '0', 0, 0, 0);         -- valid stays 0
        step('1', '1', -20, 0, 0);       -- new sum, -20

        -- extremes
        step('1', '1', 0, -128, -128);   -- 16384
        step('1', '0', 0, -128, 127);    -- 128
        step('1', '1', 1073741824, 127, 127);
        step('1', '0', 0, 127, 127);
        step('1', '1', -1073741824, -128, 127);
        step('1', '0', 0, -128, 127);

        -- reset in the middle of a sum, then a new sum must start cleanly
        step('1', '1', 50, 2, 2);
        reset;
        step('1', '1', 7, 1, 1);
        step('1', '0', 0, 3, 3);

        -- the sum passes through exactly 0 and continues (non-zero bias on non-first cycles is ignored)
        step('1', '1', 0, 5, 5);         -- 25
        step('1', '0', 1000, -5, 5);     -- 0
        step('1', '0', 1000, 3, 3);      -- 9
        step('1', '1', -25, 5, 5);       -- 0 from the first term
        step('1', '0', 1000, 4, 4);      -- 16

        -- random sums with gaps, random bias on non-first cycles (must be ignored)
        for n in 1 to 2000 loop
            v_len := rand(1, 40);
            for t in 1 to v_len loop
                while rand(0, 3) = 0 loop
                    step('0', std_logic'val(rand(2, 3)), rand(-1000000, 1000000), rand(-128, 127), rand(-128, 127),
                         std_logic'val(rand(2, 3)));
                end loop;
                if t = 1 then
                    step('1', '1', rand(-1000000, 1000000), rand(-128, 127), rand(-128, 127),
                         std_logic'val(rand(2, 3)));
                else
                    step('1', '0', rand(-1000000, 1000000), rand(-128, 127), rand(-128, 127),
                         std_logic'val(rand(2, 3)));
                end if;
            end loop;
        end loop;

        -- small values, so that running sums hit 0 often
        for n in 1 to 500 loop
            v_len := rand(2, 20);
            for t in 1 to v_len loop
                if t = 1 then
                    step('1', '1', rand(-3, 3), rand(-2, 2), rand(-2, 2));
                else
                    step('1', '0', rand(-1000, 1000), rand(-2, 2), rand(-2, 2));
                end if;
            end loop;
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
