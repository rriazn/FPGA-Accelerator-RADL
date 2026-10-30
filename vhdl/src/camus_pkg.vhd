-- Author: Roman Riazanov
library ieee;
use ieee.numeric_std.all;

package camus_pkg is
    constant AXI_ADDR_W : natural := 32;   -- width of AXI addresses
    -- Widths shared by all modules
    constant LANES      : natural := 16;     -- channels per block in the [C/16][H][W][16] layout, one output channel per PE lane
    constant ACT_W      : natural := 8;      -- activation and weight width, int8 with zero point 0
    constant ACC_W      : natural := 32;     -- accumulator width, int32 as in quantize.py (observed |acc| < 2^17)
    constant MULT_W     : natural := 16;     -- requant multiplier m0 width
    subtype  act_t is signed(ACT_W-1 downto 0);   -- one int8 activation or weight
    subtype  acc_t is signed(ACC_W-1 downto 0);   -- one int32 accumulator, bias included

    -- Shape and addresses of one conv layer, written by the ARM through axi_lite_regs
    type layer_cfg_t is record
        c, k, h, w       : natural;            -- input channels, output channels, input height and width
        fy, fx           : natural range 1 to 7;   -- kernel height and width
        stride        : natural range 1 to 7;   -- stride (1 or 2 in resnet-8)
        pad      : natural range 0 to 7;   -- symmetric zero padding (1 for 3x3, 0 for 1x1)
        in_lanes, out_lanes : natural range 1 to LANES;   -- L of the input and output layout: 16, or 1 for the raw frame
        in_base, w_base, b_base, out_base : unsigned(AXI_ADDR_W-1 downto 0);   -- DDR byte addresses of input, weights, bias, output
    end record;

    -- Output size of a conv along one axis: (i + 2p - f) / s + 1, i input size, f kernel, s stride, p pad
    function out_dim(i, f, s, p : natural) return natural;
    -- Element index of channel c at (y, x) in an h x w map: (((c / l) * h + y) * w + x) * l + c mod l, l = 16 or 1
    function elem_addr(c, y, x, h, w, l : natural) return natural;
end package camus_pkg;

package body camus_pkg is

    function out_dim(i, f, s, p : natural) return natural is
    begin
        return (i + 2 * p - f) / s + 1;
    end function out_dim;

    function elem_addr(c, y, x, h, w, l : natural) return natural is
    begin
        return (((c / l) * h + y) * w + x) * l + c mod l;
    end function elem_addr;

end package body camus_pkg;
