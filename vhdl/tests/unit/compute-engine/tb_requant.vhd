-- self-checking unit testbench for requant
-- directed cases (rounding ties, clipping, extremes), a random sweep against an independent reference,
-- a reset in flight, and one layer of golden vectors (input <layer>_<G_IN>.mem, expected <layer>_rq.mem)
-- run from vhdl/ (GHDL, VHDL-2008), G_LAYER = none skips the golden part, m0 and shift are in build/export/layers.txt:
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/requant.vhd tests/unit/compute-engine/tb_requant.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_requant -gG_LAYER=stem -gG_M0=56454 -gG_SHIFT=23
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.camus_pkg.all;

entity tb_requant is
    generic (
        G_LAYER  : string := "none";
        G_FRAME  : string := "f000";
        G_IN     : string := "acc";       -- input file suffix, b1skip uses "in"
        G_M0     : natural := 56454;
        G_SHIFT  : natural := 23;
        G_EXPORT : string := "../build/export";
        G_RANDOM : natural := 20000
    );
end entity tb_requant;

architecture sim of tb_requant is
    constant C_PERIOD : time := 5 ns;   -- 200 MHz
    constant C_LATENCY : natural := 2;  -- clocks from i_valid to o_valid

    signal s_clk   : std_logic := '0';
    signal s_rst   : std_logic := '1';
    signal s_valid : std_logic := '0';
    signal s_acc   : acc_t := (others => '0');
    signal s_m0    : unsigned(MULT_W-1 downto 0) := (others => '0');
    signal s_shift : unsigned(5 downto 0) := to_unsigned(16, 6);
    signal s_exp   : acc_t := (others => '0');   -- expected unclipped result of the input in s_acc
    signal s_o_valid : std_logic;
    signal s_o_wide  : signed(ACC_W-1 downto 0);
    signal s_o_relu  : act_t;
    signal s_stim_done : boolean := false;
    signal s_finished  : boolean := false;

    -- independent reference: floor division instead of the shift of the design
    function ref_wide(a : acc_t; m0 : natural; sh : natural) return acc_t is
        variable v_num, v_den, v_q, v_r : signed(63 downto 0);
    begin
        v_num := resize(a * to_signed(m0, 18), 64) + shift_left(to_signed(1, 64), sh - 1);
        v_den := shift_left(to_signed(1, 64), sh);
        v_q := v_num / v_den;      -- truncates toward zero
        v_r := v_num rem v_den;
        if v_num < 0 and v_r /= 0 then
            v_q := v_q - 1;
        end if;
        return resize(v_q, ACC_W);
    end function ref_wide;

    function ref_clip(w : acc_t) return natural is
    begin
        if w < 0 then
            return 0;
        elsif w > 127 then
            return 127;
        end if;
        return to_integer(w);
    end function ref_clip;

    -- hex value of any width, sign extended to 32 bit
    function parse_hex(s : string) return acc_t is
        variable v : unsigned(31 downto 0) := (others => '0');
        variable d, n : natural := 0;
        variable c : character;
    begin
        for i in s'range loop
            c := s(i);
            if c >= '0' and c <= '9' then
                d := character'pos(c) - character'pos('0');
            elsif c >= 'a' and c <= 'f' then
                d := character'pos(c) - character'pos('a') + 10;
            elsif c >= 'A' and c <= 'F' then
                d := character'pos(c) - character'pos('A') + 10;
            else
                next;
            end if;
            v := shift_left(v, 4) or to_unsigned(d, 32);
            n := n + 1;
        end loop;
        if n > 0 and n < 8 and v(4 * n - 1) = '1' then
            v := v or shift_left(not to_unsigned(0, 32), 4 * n);
        end if;
        return signed(v);
    end function parse_hex;
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

    dut : entity work.requant
        port map (
            i_clk => s_clk, i_rst => s_rst, i_valid => s_valid, i_acc => s_acc, i_m0 => s_m0, i_shift => s_shift,
            o_valid => s_o_valid, o_y_wide => s_o_wide, o_y_relu8 => s_o_relu
        );

    -- checker: model of the pipeline, the expected value of every input is delayed by C_LATENCY clocks
    checker : process
        variable v_m_v : std_logic_vector(1 to C_LATENCY) := (others => '0');
        type t_exp is array (1 to C_LATENCY) of acc_t;
        variable v_m_w : t_exp := (others => (others => '0'));
        variable v_in, v_out, v_dropped, v_errors : natural := 0;
    begin
        loop
            wait until rising_edge(s_clk);
            -- the outputs now belong to the input that was sampled C_LATENCY edges ago
            if s_o_valid /= v_m_v(C_LATENCY) then
                if v_errors < 5 then
                    report "o_valid is " & std_logic'image(s_o_valid) & ", expected " & std_logic'image(v_m_v(C_LATENCY)) severity error;
                end if;
                v_errors := v_errors + 1;
            elsif v_m_v(C_LATENCY) = '1' then
                v_out := v_out + 1;
                if s_o_wide /= v_m_w(C_LATENCY) or to_integer(s_o_relu) /= ref_clip(v_m_w(C_LATENCY)) then
                    if v_errors < 5 then
                        report "got " & integer'image(to_integer(s_o_wide)) & " / " & integer'image(to_integer(s_o_relu))
                               & ", expected " & integer'image(to_integer(v_m_w(C_LATENCY))) & " / " & integer'image(ref_clip(v_m_w(C_LATENCY)))
                               severity error;
                    end if;
                    v_errors := v_errors + 1;
                end if;
            end if;
            for k in C_LATENCY downto 2 loop
                v_m_v(k) := v_m_v(k - 1);
                v_m_w(k) := v_m_w(k - 1);
            end loop;
            v_m_v(1) := s_valid;
            v_m_w(1) := s_exp;
            if s_valid = '1' then
                v_in := v_in + 1;
            end if;
            if s_rst = '1' then
                -- everything in flight is dropped
                for k in 1 to C_LATENCY loop
                    if v_m_v(k) = '1' then
                        v_dropped := v_dropped + 1;
                    end if;
                end loop;
                v_m_v := (others => '0');
            end if;
            if s_stim_done then
                exit;
            end if;
        end loop;
        report "latency " & integer'image(C_LATENCY) & ", layer " & G_LAYER & ": " & integer'image(v_in) & " inputs, "
               & integer'image(v_out) & " outputs checked, " & integer'image(v_dropped) & " dropped by reset, "
               & integer'image(v_errors) & " errors";
        if v_errors > 0 or v_in /= v_out + v_dropped then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process checker;

    stim : process
        variable v_seed1, v_seed2 : positive := 7;
        variable v_r : real;
        variable v_a_int, v_sh_int : integer;
        variable v_m0, v_max : natural;

        procedure rand(lo, hi : integer; v : out integer) is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            v := integer(floor(real(lo) + r * (real(hi) - real(lo) + 1.0)));
        end procedure rand;

        -- one input per clock, the expected unclipped result is given by the caller
        procedure send(a : acc_t; m0 : natural; sh : natural; e : acc_t) is
        begin
            s_valid <= '1';
            s_acc <= a;
            s_m0 <= to_unsigned(m0, MULT_W);
            s_shift <= to_unsigned(sh, 6);
            s_exp <= e;
            wait until rising_edge(s_clk);
        end procedure send;

        procedure idle(n : natural) is
        begin
            s_valid <= '0';
            for i in 1 to n loop
                wait until rising_edge(s_clk);
            end loop;
        end procedure idle;

        -- directed case with a hand computed result, the reference model has to agree
        procedure hand(a : integer; m0 : natural; sh : natural; e : integer) is
        begin
            assert ref_wide(to_signed(a, ACC_W), m0, sh) = to_signed(e, ACC_W)
                report "reference model disagrees with the hand value for acc " & integer'image(a) severity failure;
            send(to_signed(a, ACC_W), m0, sh, to_signed(e, ACC_W));
        end procedure hand;

        procedure check(a : acc_t; m0 : natural; sh : natural) is
        begin
            send(a, m0, sh, ref_wide(a, m0, sh));
        end procedure check;

        file f_in, f_rq : text;
        variable st_in, st_rq : file_open_status;
        variable l_in, l_rq : line;
        variable v_n : natural := 0;
    begin
        s_rst <= '1';
        wait for 3 * C_PERIOD;
        wait until rising_edge(s_clk);
        s_rst <= '0';

        -- hand computed cases: example from the stem layer, ties round up, clipping
        hand(1206, 56454, 23, 8);
        hand(0, 56454, 23, 0);
        hand(1, 32768, 16, 1);        -- 0.5 -> 1
        hand(-1, 32768, 16, 0);       -- -0.5 -> 0
        hand(3, 32768, 16, 2);        -- 1.5 -> 2
        hand(-3, 32768, 16, -1);      -- -1.5 -> -1
        hand(200, 32768, 15, 200);    -- above 127, the unclipped value must survive
        hand(127, 32768, 15, 127);
        hand(128, 32768, 15, 128);
        hand(-5, 32768, 15, -5);
        hand(5, 1, 1, 3);             -- shift 1: (5 + 1) >> 1
        hand(-5, 1, 1, -2);           -- (-5 + 1) >> 1 = -2
        idle(2);

        -- extremes: largest and smallest acc with the largest m0, and a long stream of the same value
        check(to_signed(2147483647, ACC_W), 65535, 16);
        check(to_signed(-2147483647 - 1, ACC_W), 65535, 16);
        check(to_signed(2147483647, ACC_W), 65535, 26);
        check(to_signed(-2147483647 - 1, ACC_W), 65535, 26);
        check(to_signed(131071, ACC_W), 65535, 16);
        check(to_signed(-131072, ACC_W), 65535, 16);
        idle(1);

        -- every shift of the export range and beyond, with every kind of value
        for sh in 1 to 30 loop
            v_max := 65535;
            if sh < 16 then
                v_max := 2 ** sh - 1;   -- keeps m0 / 2^shift below 1 so the result fits 32 bit
            end if;
            for j in 1 to 20 loop
                rand(1, v_max, v_m0);
                rand(-2 ** 17, 2 ** 17, v_a_int);
                check(to_signed(v_a_int, ACC_W), v_m0, sh);
            end loop;
        end loop;
        idle(2);

        -- random sweep with gaps
        for i in 1 to G_RANDOM loop
            rand(16, 30, v_sh_int);
            rand(1, 65535, v_m0);
            uniform(v_seed1, v_seed2, v_r);
            if v_r < 0.1 then
                -- full range, the product needs the whole 48 bit
                rand(-2147483647, 2147483647, v_a_int);
            else
                rand(-2 ** 17, 2 ** 17, v_a_int);
            end if;
            check(to_signed(v_a_int, ACC_W), v_m0, v_sh_int);
            uniform(v_seed1, v_seed2, v_r);
            if v_r < 0.3 then
                rand(1, 4, v_n);
                idle(v_n);
            end if;
        end loop;
        idle(C_LATENCY + 2);

        -- reset in flight: the items in the pipeline and one input during reset are dropped, the valid output goes low
        for i in 1 to 6 loop
            hand(100 * i, 56454, 16, (100 * i * 56454 + 32768) / 65536);
        end loop;
        s_rst <= '1';
        hand(777, 56454, 16, (777 * 56454 + 32768) / 65536);   -- an input during reset is dropped as well
        s_rst <= '0';
        idle(C_LATENCY + 2);
        hand(1206, 56454, 23, 8);     -- it still works afterwards
        idle(C_LATENCY + 2);

        -- golden vectors of one layer
        if G_LAYER /= "none" then
            file_open(st_in, f_in, G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_" & G_IN & ".mem", read_mode);
            file_open(st_rq, f_rq, G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_rq.mem", read_mode);
            assert st_in = open_ok and st_rq = open_ok report "cannot open the golden files of " & G_LAYER severity failure;
            v_n := 0;
            while not endfile(f_in) and not endfile(f_rq) loop
                readline(f_in, l_in);
                readline(f_rq, l_rq);
                send(parse_hex(l_in.all), G_M0, G_SHIFT, parse_hex(l_rq.all));
                v_n := v_n + 1;
                if v_n mod 7 = 0 then
                    idle(1);        -- bubbles in the stream
                end if;
            end loop;
            assert endfile(f_in) and endfile(f_rq) report "golden files differ in length" severity failure;
            file_close(f_in);
            file_close(f_rq);
        end if;

        idle(C_LATENCY + 3);
        s_stim_done <= true;
        wait;
    end process stim;

end architecture sim;
