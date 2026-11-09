-- Author: Olimjon Mirzayusupov
-- self-checking unit test for sync_fifo against its contract (.gateflow/plans/axi-ddr-master.md section F4)
-- a model is compared at every rising edge with the outputs left by the previous edge:
--   o_rd_valid = (words held > 0), o_rd_data = oldest word, o_count = words held, o_wr_ready = (words held < G_DEPTH)
-- so a word written into an empty FIFO must be visible one clock later, and o_count must move at the same edge as
-- the write or the pop; a monitor checks that the outputs only change right after a rising edge (flip-flops)
-- phases: reset, fill with the reader stopped, drain, full-speed streaming (throughput), random traffic,
-- reset while holding data; a pending write is held until it is accepted (valid/ready source)
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e), for example with depths 1, 2, 3 and 64:
--   ghdl -a --std=08 --workdir=<dir> src/interface/sync_fifo.vhd tests/unit/interface/tb_sync_fifo.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_sync_fifo
--   ghdl -r --std=08 --workdir=<dir> tb_sync_fifo -gG_DEPTH=64 -gG_SEED=3
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_sync_fifo is
    generic (
        G_DEPTH  : positive := 4;
        G_SEED   : positive := 1;
        G_RANDOM : natural := 20000      -- clocks of random traffic
    );
end entity tb_sync_fifo;

architecture sim of tb_sync_fifo is
    constant C_PERIOD : time := 5 ns;
    constant C_WIDTH  : positive := 16;

    signal s_clk      : std_logic := '0';
    signal s_rst      : std_logic := '1';
    signal s_wr_valid : std_logic := '0';
    signal s_wr_ready : std_logic;
    signal s_wr_data  : std_logic_vector(C_WIDTH-1 downto 0) := (others => '0');
    signal s_rd_valid : std_logic;
    signal s_rd_ready : std_logic := '0';
    signal s_rd_data  : std_logic_vector(C_WIDTH-1 downto 0);
    signal s_count    : natural range 0 to G_DEPTH;
    signal s_finished : boolean := false;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;

    u_dut : entity work.sync_fifo
        generic map (
            G_WIDTH => C_WIDTH,
            G_DEPTH => G_DEPTH
        )
        port map (
            i_clk      => s_clk,
            i_rst      => s_rst,
            i_wr_valid => s_wr_valid,
            o_wr_ready => s_wr_ready,
            i_wr_data  => s_wr_data,
            o_rd_valid => s_rd_valid,
            i_rd_ready => s_rd_ready,
            o_rd_data  => s_rd_data,
            o_count    => s_count
        );

    -- the outputs come from flip-flops, so they may only change in the delta cycles of a rising edge;
    -- the stimulus changes at falling edges, where a combinational path would show up
    process(s_wr_ready, s_rd_valid, s_rd_data, s_count)
    begin
        if now > 0 ns then
            assert s_clk = '1' and s_clk'last_event = 0 ns
                report "an output changed between rising edges" severity failure;
        end if;
    end process;

    process
        type model_t is array (0 to G_DEPTH-1) of std_logic_vector(C_WIDTH-1 downto 0);
        variable v_q      : model_t;
        variable v_head   : natural range 0 to G_DEPTH-1 := 0;
        variable v_n      : natural range 0 to G_DEPTH := 0;
        variable v_next   : natural := 0;
        variable v_errors : natural := 0;
        variable v_seed1  : positive := G_SEED;
        variable v_seed2  : positive := 4711;
        variable v_pops   : natural := 0;
        variable v_full   : natural := 0;
        variable v_bypass : natural := 0;
        variable v_both   : natural := 0;
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
        -- then drive new inputs at the falling edge (a write that was not accepted stays pending)
        procedure step(wr_pct, rd_pct : natural) is
            variable v_push, v_pop, v_hit : boolean;
        begin
            wait until rising_edge(s_clk);
            check(s_count = v_n, "o_count " & integer'image(s_count) & ", model " & integer'image(v_n));
            check((s_wr_ready = '1') = (v_n < G_DEPTH), "o_wr_ready");
            check((s_rd_valid = '1') = (v_n > 0), "o_rd_valid");
            if v_n > 0 and s_rd_valid = '1' then
                check(s_rd_data = v_q(v_head), "o_rd_data");
            end if;
            v_push := s_wr_valid = '1' and s_wr_ready = '1';
            v_pop := s_rd_valid = '1' and s_rd_ready = '1';
            if v_push and v_n = 0 then
                v_bypass := v_bypass + 1;
            end if;
            if v_push and v_pop then
                v_both := v_both + 1;
            end if;
            if v_pop then
                v_head := (v_head + 1) mod G_DEPTH;
                v_n := v_n - 1;
                v_pops := v_pops + 1;
            end if;
            if v_push then
                v_q((v_head + v_n) mod G_DEPTH) := s_wr_data;
                v_n := v_n + 1;
                v_next := v_next + 1;
            end if;
            if v_n = G_DEPTH then
                v_full := v_full + 1;
            end if;

            wait until falling_edge(s_clk);
            if not (s_wr_valid = '1' and not v_push) then
                roll(wr_pct, v_hit);
                if v_hit then
                    s_wr_valid <= '1';
                else
                    s_wr_valid <= '0';
                end if;
                s_wr_data <= std_logic_vector(to_unsigned(v_next mod 2 ** C_WIDTH, C_WIDTH));
            end if;
            roll(rd_pct, v_hit);
            if v_hit then
                s_rd_ready <= '1';
            else
                s_rd_ready <= '0';
            end if;
        end procedure step;
    begin
        -- reset: everything idle, o_wr_ready low
        s_rst <= '1';
        for i in 1 to 3 loop
            wait until rising_edge(s_clk);
        end loop;
        wait until falling_edge(s_clk);
        check(s_wr_ready = '0' and s_rd_valid = '0' and s_count = 0, "outputs during reset");
        s_rst <= '0';
        wait until rising_edge(s_clk);    -- first edge out of reset, o_wr_ready rises here
        wait until falling_edge(s_clk);

        -- fill with the reader stopped, then drain
        for i in 1 to G_DEPTH + 4 loop
            step(100, 0);
        end loop;
        check(v_n = G_DEPTH, "not full after the fill phase");
        for i in 1 to G_DEPTH + 6 loop
            step(0, 100);
        end loop;
        check(v_n = 0, "not empty after the drain phase");

        -- full-speed streaming, both sides always ready
        for i in 1 to 10 loop
            step(100, 100);
        end loop;
        v_start := v_pops;
        for i in 1 to 1000 loop
            step(100, 100);
        end loop;
        if G_DEPTH >= 2 then
            check(v_pops - v_start >= 999, "below one word per clock: " & integer'image(v_pops - v_start) & " in 1000");
        else
            check(v_pops - v_start >= 499 and v_pops - v_start <= 501,
                  "depth 1 must give one word per two clocks: " & integer'image(v_pops - v_start) & " in 1000");
        end if;
        for i in 1 to G_DEPTH + 6 loop
            step(0, 100);
        end loop;

        -- random traffic with changing write and read rates
        for i in 1 to G_RANDOM loop
            case (i / 500) mod 5 is
                when 0 => step(50, 50);
                when 1 => step(90, 30);
                when 2 => step(30, 90);
                when 3 => step(100, 100);
                when others => step(70, 70);
            end case;
        end loop;

        -- reset while the FIFO holds data
        for i in 1 to G_DEPTH + 2 loop
            step(100, 0);
        end loop;
        check(v_n > 0, "no data held before the second reset");
        s_wr_valid <= '0';
        s_rst <= '1';
        wait until rising_edge(s_clk);
        wait until rising_edge(s_clk);
        wait until falling_edge(s_clk);
        check(s_count = 0 and s_rd_valid = '0' and s_wr_ready = '0', "outputs after a reset with data");
        s_rst <= '0';
        v_n := 0;
        v_head := 0;
        wait until rising_edge(s_clk);
        wait until falling_edge(s_clk);
        for i in 1 to 500 loop
            step(60, 60);
        end loop;
        for i in 1 to G_DEPTH + 6 loop
            step(0, 100);
        end loop;

        check(v_full > 0, "the FIFO was never full");
        check(v_bypass > 0, "no write into an empty FIFO");
        if G_DEPTH >= 2 then
            check(v_both > 0, "no clock with a write and a read together");
        end if;
        report "depth " & integer'image(G_DEPTH) & ": " & integer'image(v_pops) & " words read, full in "
               & integer'image(v_full) & " clocks, " & integer'image(v_bypass) & " writes into an empty FIFO, "
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
