-- Author: Roman Riazanov
-- calculate the BYTE addresses of the input, the weights, the bias and output
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity addr_gen is
    port (
    i_cfg        : in layer_cfg_t;
    i_k, i_oy, i_ox, i_c, i_fy, i_fx : in natural;
    o_x_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of x[c][iy][ix]
    o_x_valid    : out std_logic;                          -- 0 if (iy, ix) is outside the input: use 0, no read
    o_w_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of w[k][c][fy][fx]
    o_b_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of bias[k]
    o_out_addr   : out unsigned(AXI_ADDR_W-1 downto 0)    -- byte address of acc[k][oy][ox]
  );
end entity addr_gen;

architecture rtl of addr_gen is
begin

    process(i_cfg, i_k, i_oy, i_ox, i_c, i_fy, i_fx)
        variable v_oh, v_ow : natural; -- output height and width
        variable v_iy, v_ix : integer; -- input pixel
        variable v_valid    : boolean;
    begin
        v_oh := out_dim(i_cfg.h, i_cfg.fy, i_cfg.stride, i_cfg.pad);
        v_ow := out_dim(i_cfg.w, i_cfg.fx, i_cfg.stride, i_cfg.pad);
        v_iy := i_oy * i_cfg.stride - i_cfg.pad + i_fy;
        v_ix := i_ox * i_cfg.stride - i_cfg.pad + i_fx;
        v_valid := v_iy >= 0 and v_iy < i_cfg.h and v_ix >= 0 and v_ix < i_cfg.w;

        if v_valid then
            o_x_valid <= '1';
            o_x_addr <= i_cfg.in_base + to_unsigned(elem_addr(i_c, v_iy, v_ix, i_cfg.h, i_cfg.w, i_cfg.in_lanes), AXI_ADDR_W);
        else
            o_x_valid <= '0';
            o_x_addr <= i_cfg.in_base;
        end if;

        -- weights are plain [K][C][FY][FX], int8
        o_w_addr <= i_cfg.w_base + to_unsigned(((i_k * i_cfg.c + i_c) * i_cfg.fy + i_fy) * i_cfg.fx + i_fx, AXI_ADDR_W);
        
        -- bias int32
        o_b_addr <= i_cfg.b_base + to_unsigned(4 * i_k, AXI_ADDR_W);
        
        -- accumulators int32
        o_out_addr <= i_cfg.out_base + to_unsigned(4 * elem_addr(i_k, i_oy, i_ox, v_oh, v_ow, i_cfg.out_lanes), AXI_ADDR_W);
    end process;

end architecture rtl;
