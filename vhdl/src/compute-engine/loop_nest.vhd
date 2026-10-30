-- Author: Roman Riazanov
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;


entity loop_nest is
    port (
        i_clk, i_rst : in std_logic;
        i_cfg : in layer_cfg_t;
        i_start : in std_logic; -- begin layer
        i_step : in std_logic;  -- advance to the next iteration
        o_k, o_oy, o_ox, o_c, o_fy, o_fx : out natural;   -- current indices 
        -- k: output channel, oy/ox: row/col of output pixel, c: input channel, fy/fx: row/col of kernel winfdow
        o_first_mac, o_last_mac : out std_logic;    -- first / last iteration of the current output element
        o_last_output : out std_logic;    -- last output element of the layer
        o_running : out std_logic
    );
end entity loop_nest;

architecture rtl of loop_nest is
    signal s_running : std_logic;
    signal s_k, s_oy, s_ox, s_c, s_fy, s_fx : natural;
    -- last index of each loop, latched at start so i_cfg may change during the run
    signal s_k_max, s_oy_max, s_ox_max, s_c_max, s_fy_max, s_fx_max : natural;
    signal s_first_mac, s_last_mac, s_last_output : std_logic;
    
begin

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rst = '1' then
                s_running <= '0';
            elsif s_running = '0' then
                if i_start = '1' then
                    s_running <= '1';
                    s_k <= 0;
                    s_oy <= 0;
                    s_ox <= 0;
                    s_c <= 0;
                    s_fy <= 0;
                    s_fx <= 0;
                    s_k_max <= i_cfg.k - 1;
                    s_oy_max <= out_dim(i_cfg.h, i_cfg.fy, i_cfg.stride, i_cfg.pad) - 1;
                    s_ox_max <= out_dim(i_cfg.w, i_cfg.fx, i_cfg.stride, i_cfg.pad) - 1;
                    s_c_max <= i_cfg.c - 1;
                    s_fy_max <= i_cfg.fy - 1;
                    s_fx_max <= i_cfg.fx - 1;
                end if;
            elsif i_step = '1' then
                -- odometer, fx is the fastest loop and k the slowest
                if s_fx /= s_fx_max then
                    s_fx <= s_fx + 1;
                else
                    s_fx <= 0;
                    if s_fy /= s_fy_max then
                        s_fy <= s_fy + 1;
                    else
                        s_fy <= 0;
                        if s_c /= s_c_max then
                            s_c <= s_c + 1;
                        else
                            s_c <= 0;
                            if s_ox /= s_ox_max then
                                s_ox <= s_ox + 1;
                            else
                                s_ox <= 0;
                                if s_oy /= s_oy_max then
                                    s_oy <= s_oy + 1;
                                else
                                    s_oy <= 0;
                                    if s_k /= s_k_max then
                                        s_k <= s_k + 1;
                                    else
                                        s_running <= '0';   -- the accepted term was the last one
                                    end if;
                                end if;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    s_first_mac <= '1' when s_c = 0 and s_fy = 0 and s_fx = 0 else '0';
    s_last_mac <= '1' when s_c = s_c_max and s_fy = s_fy_max and s_fx = s_fx_max else '0';
    s_last_output <= '1' when s_last_mac = '1' and s_ox = s_ox_max and s_oy = s_oy_max and s_k = s_k_max else '0';


    o_k <= s_k;
    o_oy <= s_oy;
    o_ox <= s_ox;
    o_c <= s_c;
    o_fy <= s_fy;
    o_fx <= s_fx;
    -- flags are 0 while idle
    o_first_mac <= s_first_mac and s_running;
    o_last_mac <= s_last_mac and s_running;
    o_last_output <= s_last_output and s_running;
    o_running <= s_running;
end architecture rtl;
