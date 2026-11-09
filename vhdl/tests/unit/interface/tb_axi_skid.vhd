-- Author: Olimjon Mirzayusupov
-- self-checking unit test for axi_skid (two-entry register slice, .gateflow/plans/axi-ddr-master.md section F3)
-- a two-word model is compared at every rising edge with the outputs left by the previous edge:
--   o_valid = (words held > 0), o_data = oldest word, o_ready = (words held < 2)
-- so nothing is lost or duplicated, the order is kept and o_data stays stable while o_valid and not i_ready;
-- a monitor checks that o_valid, o_ready and o_data only change right after a rising edge (flip-flops, requirement R2)
-- phases: reset, full-speed streaming (one transfer per clock), stall and release (state TWO), random traffic,
-- reset while holding data; the source holds valid and data until accepted, as an AXI master must
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/interface/axi_skid.vhd tests/unit/interface/tb_axi_skid.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_axi_skid
--   ghdl -r --std=08 --workdir=<dir> tb_axi_skid -gG_SEED=3
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_axi_skid is
    generic (
        G_SEED   : positive := 1;
        G_RANDOM : natural := 20000      -- clocks of random traffic
    );
end entity tb_axi_skid;

architecture sim of tb_axi_skid is
    constant C_PERIOD : time := 5 ns;
    constant C_WIDTH  : positive := 16;
    constant C_DEPTH  : positive := 2;

    signal s_clk      : std_logic := '0';
    signal s_rst      : std_logic := '1';
    signal s_in_valid : std_logic := '0';
    signal s_in_ready : std_logic;
    signal s_in_data  : std_logic_vector(C_WIDTH-1 downto 0) := (others => '0');
    signal s_out_valid : std_logic;
    signal s_out_ready : std_logic := '0';
    signal s_out_data  : std_logic_vector(C_WIDTH-1 downto 0);
    signal s_finished : boolean := false;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;

    u_dut : entity work.axi_skid
        generic map (
            G_WIDTH => C_WIDTH
        )
        port map (
            i_clk   => s_clk,
            i_rst   => s_rst,
            i_valid => s_in_valid,
            o_ready => s_in_ready,
            i_data  => s_in_data,
            o_valid => s_out_valid,
            i_ready => s_out_ready,
            o_data  => s_out_data
        );

    -- o_valid, o_ready and o_data come from flip-flops: they may only change in the delta cycles of a rising edge
    process(s_in_ready, s_out_valid, s_out_data)
    begin
        if now > 0 ns then
            assert s_clk = '1' and s_clk'last_event = 0 ns
                report "an output changed between rising edges" severity failure;
        end if;
    end process;

    process
        type model_t is array (0 to C_DEPTH-1) of std_logic_vector(C_WIDTH-1 downto 0);
        variable v_q      : model_t;
        variable v_head   : natural range 0 to C_DEPTH-1 := 0;
        variable v_n      : natural range 0 to C_DEPTH := 0;
        variable v_next   : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := G_SEED;
        variable v_seed2  : positive := 4242;
        variable v_outs   : natural := 0;
        variable v_two    : natural := 0;
        variable v_start  : natural;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                report "ERROR: " & msg & " at " & time'image(now) severity error;
            end if;
        end procedure check;

        procedure roll(pct : natural; hit : out boolean) is
            variable v_r : real;
        begin
            uniform(v_seed1, v_seed2, v_r);
            hit := v_r * 100.0 < real(pct);
        end procedure roll;

        -- one clock: check the outputs left by the previous edge, apply this edge's handshakes to the model,
        -- then drive new inputs at the falling edge (the source holds valid and data until accepted)
        procedure step(in_pct, out_pct : natural) is
            variable v_in, v_out, v_hit : boolean;
        begin
            wait until rising_edge(s_clk);
            check((s_in_ready = '1') = (v_n < C_DEPTH), "o_ready");
            check((s_out_valid = '1') = (v_n > 0), "o_valid");
            if v_n > 0 and s_out_valid = '1' then
                check(s_out_data = v_q(v_head), "o_data");
            end if;
            v_in := s_in_valid = '1' and s_in_ready = '1';
            v_out := s_out_valid = '1' and s_out_ready = '1';
            if v_out then
                v_head := (v_head + 1) mod C_DEPTH;
                v_n := v_n - 1;
                v_outs := v_outs + 1;
            end if;
            if v_in then
                v_q((v_head + v_n) mod C_DEPTH) := s_in_data;
                v_n := v_n + 1;
                v_next := v_next + 1;
            end if;
            if v_n = C_DEPTH then
                v_two := v_two + 1;
            end if;

            wait until falling_edge(s_clk);
            if not (s_in_valid = '1' and not v_in) then
                roll(in_pct, v_hit);
                if v_hit then
                    s_in_valid <= '1';
                else
                    s_in_valid <= '0';
                end if;
                s_in_data <= std_logic_vector(to_unsigned(v_next mod 2 ** C_WIDTH, C_WIDTH));
            end if;
            roll(out_pct, v_hit);
            if v_hit then
                s_out_ready <= '1';
            else
                s_out_ready <= '0';
            end if;
        end procedure step;
    begin
        -- reset: both handshakes low
        s_rst <= '1';
        for i in 1 to 3 loop
            wait until rising_edge(s_clk);
        end loop;
        wait until falling_edge(s_clk);
        check(s_in_ready = '0' and s_out_valid = '0', "outputs during reset");
        s_rst <= '0';
        wait until rising_edge(s_clk);    -- first edge out of reset, o_ready rises here
        wait until falling_edge(s_clk);

        -- full-speed streaming: one transfer per clock
        for i in 1 to 10 loop
            step(100, 100);
        end loop;
        v_start := v_outs;
        for i in 1 to 1000 loop
            step(100, 100);
        end loop;
        check(v_outs - v_start >= 999, "below one transfer per clock: " & integer'image(v_outs - v_start) & " in 1000");

        -- stall the downstream with the source busy (fills the skid, state TWO), then release
        for i in 1 to 5 loop
            step(100, 0);
        end loop;
        check(v_n = C_DEPTH, "the skid did not fill");
        for i in 1 to 5 loop
            step(0, 100);
        end loop;
        check(v_n = 0, "not empty after the release");

        -- random traffic with changing rates
        for i in 1 to G_RANDOM loop
            case (i / 500) mod 5 is
                when 0 => step(50, 50);
                when 1 => step(90, 30);
                when 2 => step(30, 90);
                when 3 => step(100, 100);
                when others => step(70, 70);
            end case;
        end loop;

        -- reset while holding data
        for i in 1 to 4 loop
            step(100, 0);
        end loop;
        check(v_n > 0, "no data held before the second reset");
        s_in_valid <= '0';
        s_rst <= '1';
        wait until rising_edge(s_clk);
        wait until rising_edge(s_clk);
        wait until falling_edge(s_clk);
        check(s_in_ready = '0' and s_out_valid = '0', "outputs after a reset with data");
        s_rst <= '0';
        v_n := 0;
        v_head := 0;
        wait until rising_edge(s_clk);
        wait until falling_edge(s_clk);
        for i in 1 to 500 loop
            step(60, 60);
        end loop;
        for i in 1 to 6 loop
            step(0, 100);
        end loop;

        check(v_two > 0, "state TWO never reached");
        report integer'image(v_outs) & " transfers, two words held in " & integer'image(v_two) & " clocks, "
               & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process;
end architecture sim;
