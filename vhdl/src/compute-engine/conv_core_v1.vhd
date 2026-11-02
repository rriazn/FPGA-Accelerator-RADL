-- Author: Roman Riazanov
-- v1 convolution core: one MAC per clock, plain synchronous memory ports
-- computes acc = bias + sum(x * w) per output element and writes it as int32
-- conv_engine_v1 later wraps this core with the AXI master
-- i_ce freezes the whole core, the read ports behave like a BRAM with an enable:
--   i_ce = 1: the address is sampled and the data shows up in the next cycle
--   i_ce = 0: nothing moves, the data inputs must keep the value of the last i_ce = 1 cycle
-- o_out_we is a one cycle strobe that cannot be stalled, the writer must absorb it
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity conv_core_v1 is
    port (
        i_clk, i_rst : in std_logic;
        i_ce : in std_logic;                        -- clock enable, 0 stalls the core
        i_cfg : in layer_cfg_t;
        i_start : in std_logic;
        o_busy : out std_logic;
        o_done : out std_logic;                     -- one cycle, after the last result is written
        o_cycles : out unsigned(31 downto 0);       -- clocks from start until done, stalled clocks included
        -- synchronous read ports, the data is valid in the cycle after the address (see i_ce)
        o_term_valid : out std_logic;               -- the addresses belong to a real term, 0 while idle or flushing
        o_x_addr, o_w_addr, o_b_addr : out unsigned(AXI_ADDR_W-1 downto 0);
        o_x_rd : out std_logic;                     -- 0 for padding positions, the input is not read there
        i_x_data, i_w_data : in act_t;
        i_b_data : in acc_t;
        -- write port for the int32 results
        o_out_we : out std_logic;
        o_out_addr : out unsigned(AXI_ADDR_W-1 downto 0);
        o_out_data : out acc_t
    );
end entity conv_core_v1;

architecture rtl of conv_core_v1 is
    -- stage 0: loop_nest and addr_gen, the memories sample the addresses at the clock edge
    signal s_k, s_oy, s_ox, s_c, s_fy, s_fx : natural;
    signal s_first, s_last, s_last_out, s_running : std_logic;
    signal s_x_addr, s_w_addr, s_b_addr, s_out_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_x_valid : std_logic;
    signal s_mac_en : std_logic;

    -- stage 1: the read data arrives, the control of the same term is delayed to match
    signal s_en_d1, s_first_d1, s_last_d1, s_x_valid_d1, s_last_out_d1 : std_logic := '0';
    signal s_out_addr_d1 : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_a : act_t;

    -- stage 2: the mac result
    signal s_acc : acc_t;
    signal s_acc_valid : std_logic;
    signal s_last_out_d2 : std_logic := '0';
    signal s_out_addr_d2 : unsigned(AXI_ADDR_W-1 downto 0);

    signal s_busy : std_logic := '0';
    signal s_cycles : unsigned(31 downto 0) := (others => '0');
begin

    u_loop : entity work.loop_nest
        port map (
            i_clk => i_clk, i_rst => i_rst, i_cfg => i_cfg, i_start => i_start, i_step => i_ce,
            o_k => s_k, o_oy => s_oy, o_ox => s_ox, o_c => s_c, o_fy => s_fy, o_fx => s_fx,
            o_first_mac => s_first, o_last_mac => s_last, o_last_output => s_last_out,
            o_running => s_running
        );

    u_addr : entity work.addr_gen
        port map (
            i_cfg => i_cfg, i_k => s_k, i_oy => s_oy, i_ox => s_ox, i_c => s_c, i_fy => s_fy, i_fx => s_fx,
            o_x_addr => s_x_addr, o_x_valid => s_x_valid, o_w_addr => s_w_addr,
            o_b_addr => s_b_addr, o_out_addr => s_out_addr
        );

    o_x_addr <= s_x_addr;
    o_x_rd <= s_x_valid and s_running;
    o_term_valid <= s_running;
    o_w_addr <= s_w_addr;
    o_b_addr <= s_b_addr;

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_ce = '1' then
                s_en_d1 <= s_running;
                s_first_d1 <= s_first;
                s_last_d1 <= s_last;
                s_x_valid_d1 <= s_x_valid;
                s_last_out_d1 <= s_last_out;
                s_out_addr_d1 <= s_out_addr;
            end if;
            -- stage 2 is only used in the cycle after a ce = 1 edge (the result strobe lasts one cycle), so no enable
            s_last_out_d2 <= s_last_out_d1;
            s_out_addr_d2 <= s_out_addr_d1;
            if i_rst = '1' then
                s_en_d1 <= '0';
                s_last_out_d1 <= '0';
                s_last_out_d2 <= '0';
            end if;
        end if;
    end process;

    -- padding positions contribute 0
    s_a <= i_x_data when s_x_valid_d1 = '1' else (others => '0');

    s_mac_en <= s_en_d1 and i_ce;

    u_mac : entity work.mac_int8
        port map (
            i_clk => i_clk, i_rst => i_rst, i_en => s_mac_en, i_first => s_first_d1, i_last => s_last_d1,
            i_bias => i_b_data, i_a => s_a, i_b => i_w_data,
            o_acc => s_acc, o_acc_valid => s_acc_valid
        );

    o_out_we <= s_acc_valid;
    o_out_addr <= s_out_addr_d2;
    o_out_data <= s_acc;

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            o_done <= '0';
            if i_rst = '1' then
                s_busy <= '0';
            elsif s_busy = '0' then
                if i_start = '1' then
                    s_busy <= '1';
                    s_cycles <= (others => '0');
                end if;
            else
                s_cycles <= s_cycles + 1;
                if s_acc_valid = '1' and s_last_out_d2 = '1' then
                    s_busy <= '0';
                    o_done <= '1';
                end if;
            end if;
        end if;
    end process;

    o_busy <= s_busy;
    o_cycles <= s_cycles;
end architecture rtl;
