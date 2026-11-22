-- Author: Roman Riazanov
-- calculate the BYTE addresses of the input, the weights, the bias and output
-- running pointers: each step adds a per-layer constant from layer_setup, no division or multiplication
-- the pointers move on the same edges as loop_nest, so the outputs belong to the term loop_nest shows
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity addr_gen is
    port (
    i_clk, i_rst : in std_logic;
    i_cfg        : in layer_cfg_t;                         -- latched config from layer_setup
    i_const      : in addr_const_t;                        -- steps from layer_setup
    i_start      : in std_logic;                           -- the i_start of loop_nest, only while it is idle
    i_step       : in std_logic;                           -- the i_step of loop_nest, only while it runs
    i_at_max     : in std_logic_vector(5 downto 0);        -- o_at_max of loop_nest
    o_x_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of x[c][iy][ix], not meaningful at padding
    o_x_valid    : out std_logic;                          -- 0 if (iy, ix) is outside the input: use 0, no read
    o_w_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of w[k][c][fy][fx]
    o_b_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of bias[k]
    o_out_addr   : out unsigned(AXI_ADDR_W-1 downto 0)    -- byte address of acc[k][oy][ox]
  );
end entity addr_gen;

architecture rtl of addr_gen is
    subtype addr_t is unsigned(AXI_ADDR_W-1 downto 0);
    subtype pos_t is integer range -8 to 2**17;   -- input row or column, negative in the top and left padding

    -- x pointer per loop level, 0 is the current term, level n is the term where all loops inside n are 0
    -- 1 start of the kernel row, 2 start of the channel, 3 start of the output pixel, 4 start of the output row
    type t_ptr_vec is array (0 to 4) of addr_t;
    signal s_px : t_ptr_vec;
    signal s_w_k, s_w : addr_t;      -- weights: start of output channel k, current term
    signal s_b : addr_t;
    signal s_out_k, s_out : addr_t;  -- output: start of output channel k, current pixel
    signal s_c_lane : natural range 0 to LANES-1;   -- c mod in_lanes
    signal s_k_lane : natural range 0 to LANES-1;   -- k mod out_lanes
    -- input row and column of the current term and of the window start
    signal s_iy_o, s_iy, s_ix_o, s_ix : pos_t;

    -- the loop that advances: lowest index not at its last value, 6 if all are (last term)
    function advancing(at_max : std_logic_vector(5 downto 0)) return natural is
    begin
        for i in 0 to 5 loop
            if at_max(i) = '0' then
                return i;
            end if;
        end loop;
        return 6;
    end function advancing;
begin

    process(i_clk)
        variable v_x, v_o : addr_t;
    begin
        if rising_edge(i_clk) then
            if i_start = '1' then
                s_px <= (others => i_const.x_org);
                s_w_k <= i_cfg.w_base;
                s_w <= i_cfg.w_base;
                s_b <= i_cfg.b_base;
                s_out_k <= i_cfg.out_base;
                s_out <= i_cfg.out_base;
                s_c_lane <= 0;
                s_k_lane <= 0;
                s_iy_o <= -i_cfg.pad;
                s_iy <= -i_cfg.pad;
                s_ix_o <= -i_cfg.pad;
                s_ix <= -i_cfg.pad;
            elsif i_step = '1' then
                case advancing(i_at_max) is
                    when 0 =>   -- fx
                        s_px(0) <= s_px(0) + i_const.x_fx;
                        s_w <= s_w + 1;
                        s_ix <= s_ix + 1;

                    when 1 =>   -- fy
                        v_x := s_px(1) + i_const.x_fy;
                        s_px(0 to 1) <= (others => v_x);
                        s_w <= s_w + 1;
                        s_iy <= s_iy + 1;
                        s_ix <= s_ix_o;

                    when 2 =>   -- c, the step is 1 inside a channel block
                        if s_c_lane = i_cfg.in_lanes - 1 then
                            v_x := s_px(2) + i_const.x_cblk;
                            s_c_lane <= 0;
                        else
                            v_x := s_px(2) + 1;
                            s_c_lane <= s_c_lane + 1;
                        end if;
                        s_px(0 to 2) <= (others => v_x);
                        s_w <= s_w + 1;
                        s_iy <= s_iy_o;
                        s_ix <= s_ix_o;

                    when 3 =>   -- ox, next output element
                        v_x := s_px(3) + i_const.x_ox;
                        s_px(0 to 3) <= (others => v_x);
                        s_c_lane <= 0;
                        s_w <= s_w_k;
                        s_out <= s_out + i_const.out_px;
                        s_iy <= s_iy_o;
                        s_ix_o <= s_ix_o + i_cfg.stride;
                        s_ix <= s_ix_o + i_cfg.stride;

                    when 4 =>   -- oy, the output rows are contiguous
                        v_x := s_px(4) + i_const.x_oy;
                        s_px <= (others => v_x);
                        s_c_lane <= 0;
                        s_w <= s_w_k;
                        s_out <= s_out + i_const.out_px;
                        s_iy_o <= s_iy_o + i_cfg.stride;
                        s_iy <= s_iy_o + i_cfg.stride;
                        s_ix_o <= -i_cfg.pad;
                        s_ix <= -i_cfg.pad;

                    when 5 =>   -- k, the step is 4 inside a channel block
                        s_px <= (others => i_const.x_org);
                        s_c_lane <= 0;
                        s_w_k <= s_w_k + i_const.w_k;
                        s_w <= s_w_k + i_const.w_k;
                        s_b <= s_b + 4;
                        if s_k_lane = i_cfg.out_lanes - 1 then
                            v_o := s_out_k + i_const.out_kblk;
                            s_k_lane <= 0;
                        else
                            v_o := s_out_k + 4;
                            s_k_lane <= s_k_lane + 1;
                        end if;
                        s_out_k <= v_o;
                        s_out <= v_o;
                        s_iy_o <= -i_cfg.pad;
                        s_iy <= -i_cfg.pad;
                        s_ix_o <= -i_cfg.pad;
                        s_ix <= -i_cfg.pad;

                    when others =>   -- last term, the layer ends
                        null;
                end case;
            end if;
            if i_rst = '1' then
                s_c_lane <= 0;
                s_k_lane <= 0;
            end if;
        end if;
    end process;

    o_x_addr <= s_px(0);
    o_x_valid <= '1' when s_iy >= 0 and s_iy < i_cfg.h and s_ix >= 0 and s_ix < i_cfg.w else '0';
    o_w_addr <= s_w;
    o_b_addr <= s_b;
    o_out_addr <= s_out;

end architecture rtl;
