-- per-layer setup: latches the config and computes oh, ow and the address steps for addr_gen
-- one operation per clock so no division or chained multiplication sits in a single path
-- oh and ow by repeated subtraction, o_done comes max(oh, ow) + 4 clocks after the edge that takes i_start
-- the config must be valid: all sizes at least 1, h + 2*pad >= fy, w + 2*pad >= fx
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity layer_setup is
    port (
        i_clk, i_rst : in std_logic;
        i_cfg   : in layer_cfg_t;
        i_start : in std_logic;     -- latch i_cfg and compute, ignored while busy
        o_busy  : out std_logic;
        o_done  : out std_logic;    -- one clock, o_cfg and o_const hold from here until the next start
        o_cfg   : out layer_cfg_t;  -- i_cfg as latched at start
        o_const : out addr_const_t
    );
end entity layer_setup;

architecture rtl of layer_setup is
    subtype addr_t is unsigned(AXI_ADDR_W-1 downto 0);
    subtype dim_t is natural range 0 to 2**17 - 1;   -- h + 2*pad fits 17 bits (16 bit registers)

    type t_state is (S_IDLE, S_DIV, S_MUL1, S_MUL2, S_MUL3, S_MUL4);
    signal s_state : t_state;
    signal s_done  : std_logic;
    signal s_cfg   : layer_cfg_t;
    signal s_const : addr_const_t;

    -- divider: remainder and quotient of (h + 2*pad - fy) / stride, same for x
    signal s_ny, s_nx, s_qy, s_qx : dim_t;

    -- products, one register level each
    signal s_hw, s_wl, s_sl, s_cfy, s_ohow, s_pw : addr_t;
    signal s_hwl, s_ohowl, s_pwp, s_pwpl : addr_t;

    function u16(n : natural) return unsigned is
    begin
        return to_unsigned(n, 16);
    end function u16;

    function u5(n : natural) return unsigned is
    begin
        return to_unsigned(n, 5);
    end function u5;

    function u3(n : natural) return unsigned is
    begin
        return to_unsigned(n, 3);
    end function u3;
begin

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            s_done <= '0';
            case s_state is
                when S_IDLE =>
                    if i_start = '1' then
                        s_cfg <= i_cfg;
                        s_ny <= i_cfg.h + 2 * i_cfg.pad - i_cfg.fy;
                        s_nx <= i_cfg.w + 2 * i_cfg.pad - i_cfg.fx;
                        s_qy <= 0;
                        s_qx <= 0;
                        s_state <= S_DIV;
                    end if;

                when S_DIV =>
                    if s_ny >= s_cfg.stride then
                        s_ny <= s_ny - s_cfg.stride;
                        s_qy <= s_qy + 1;
                    end if;
                    if s_nx >= s_cfg.stride then
                        s_nx <= s_nx - s_cfg.stride;
                        s_qx <= s_qx + 1;
                    end if;
                    if s_ny < s_cfg.stride and s_nx < s_cfg.stride then
                        s_state <= S_MUL1;
                    end if;

                when S_MUL1 =>
                    s_const.oh <= s_qy + 1;
                    s_const.ow <= s_qx + 1;
                    s_hw <= u16(s_cfg.h) * u16(s_cfg.w);
                    s_wl <= resize(u16(s_cfg.w) * u5(s_cfg.in_lanes), AXI_ADDR_W);
                    s_sl <= resize(u3(s_cfg.stride) * u5(s_cfg.in_lanes), AXI_ADDR_W);
                    s_cfy <= resize(u16(s_cfg.c) * u3(s_cfg.fy), AXI_ADDR_W);
                    s_ohow <= resize(to_unsigned(s_qy + 1, 17) * to_unsigned(s_qx + 1, 17), AXI_ADDR_W);
                    s_pw <= resize(u3(s_cfg.pad) * u16(s_cfg.w), AXI_ADDR_W);
                    s_const.x_fx <= resize(u5(s_cfg.in_lanes), AXI_ADDR_W);
                    s_const.out_px <= shift_left(resize(u5(s_cfg.out_lanes), AXI_ADDR_W), 2);
                    s_state <= S_MUL2;

                when S_MUL2 =>
                    s_hwl <= resize(s_hw * u5(s_cfg.in_lanes), AXI_ADDR_W);
                    s_const.x_fy <= s_wl;
                    s_const.x_ox <= s_sl;
                    s_const.x_oy <= resize(s_wl * u3(s_cfg.stride), AXI_ADDR_W);
                    s_const.w_k <= resize(s_cfy * u3(s_cfg.fx), AXI_ADDR_W);
                    s_ohowl <= resize(s_ohow * u5(s_cfg.out_lanes), AXI_ADDR_W);
                    s_pwp <= s_pw + s_cfg.pad;
                    s_state <= S_MUL3;

                when S_MUL3 =>
                    s_const.x_cblk <= s_hwl - (s_cfg.in_lanes - 1);
                    s_const.out_kblk <= shift_left(s_ohowl - (s_cfg.out_lanes - 1), 2);
                    s_pwpl <= resize(s_pwp * u5(s_cfg.in_lanes), AXI_ADDR_W);
                    s_state <= S_MUL4;

                when S_MUL4 =>
                    s_const.x_org <= s_cfg.in_base - s_pwpl;
                    s_done <= '1';
                    s_state <= S_IDLE;
            end case;

            if i_rst = '1' then
                s_state <= S_IDLE;
                s_done <= '0';
            end if;
        end if;
    end process;

    o_busy <= '0' when s_state = S_IDLE else '1';
    o_done <= s_done;
    o_cfg <= s_cfg;
    o_const <= s_const;
end architecture rtl;
