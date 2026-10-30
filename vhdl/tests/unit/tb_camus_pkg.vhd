-- unit test for the functions of camus_pkg
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd tests/unit/tb_camus_pkg.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_camus_pkg
library ieee;
use ieee.numeric_std.all;

use work.camus_pkg.all;

entity tb_camus_pkg is
end entity tb_camus_pkg;

architecture sim of tb_camus_pkg is
begin
    process
    begin
        -- output sizes of the ResNet-8 layers (input 112)
        assert out_dim(112, 3, 2, 1) = 56 report "stem" severity failure;
        assert out_dim(56, 3, 1, 1) = 56 report "b1 conv" severity failure;
        assert out_dim(56, 3, 2, 1) = 28 report "b2c1" severity failure;
        assert out_dim(56, 1, 2, 0) = 28 report "b2sc" severity failure;
        assert out_dim(28, 3, 2, 1) = 14 report "b3c1" severity failure;
        assert out_dim(28, 1, 2, 0) = 14 report "b3sc" severity failure;
        assert out_dim(1, 1, 1, 0) = 1 report "1x1" severity failure;

        -- layout [C/L][H][W][L], L = 16
        assert elem_addr(0, 0, 0, 4, 5, 16) = 0 report "origin" severity failure;
        assert elem_addr(1, 0, 0, 4, 5, 16) = 1 report "channel in the block" severity failure;
        assert elem_addr(0, 0, 1, 4, 5, 16) = 16 report "next pixel" severity failure;
        assert elem_addr(0, 1, 0, 4, 5, 16) = 80 report "next row" severity failure;
        assert elem_addr(16, 0, 0, 4, 5, 16) = 320 report "next channel block" severity failure;
        assert elem_addr(17, 2, 3, 4, 5, 16) = 529 report "mixed" severity failure;
        -- L = 1 is the plain [H][W] image
        assert elem_addr(0, 2, 3, 4, 5, 1) = 13 report "plain image" severity failure;

        report "PASS";
        wait;
    end process;
end architecture sim;
