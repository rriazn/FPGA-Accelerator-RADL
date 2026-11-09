-- Author: Olimjon Mirzayusupov
-- axi_pkg: AXI4 constants, the per-board AXI limits and the burst split rule of axi_master_rd and axi_master_wr
-- the board is selected by camus_pkg.BOARD (docs/plans/axi-ddr-master.md section 3), nothing else here is board specific
-- burst_beats is the split rule used inside both masters: a burst never crosses a 4 KB page (AXI rule) and never
-- exceeds the burst limit (16 beats on the AXI3 HP port of the ZedBoard); requesters never call it
-- addresses are byte addresses and beat aligned, the masters assert that
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;

package axi_pkg is
    -- per-board AXI limits, indexed by camus_pkg.BOARD
    type board_bool_t is array (board_t) of boolean;
    type board_slv4_t is array (board_t) of std_logic_vector(3 downto 0);
    constant AXI_MAX_BURST_BY_BOARD : board_nat_t  := (ZEDBOARD => 16,     ULTRA96 => 16);      -- AXI3 limit; AXI4 allows up to 256
    constant AXI_PORT_AXI3_BY_BOARD : board_bool_t := (ZEDBOARD => true,   ULTRA96 => false);   -- informational
    constant AXI_ID_W_MAX_BY_BOARD  : board_nat_t  := (ZEDBOARD => 6,      ULTRA96 => 6);       -- ID bits of the HP port, check in Vivado
    constant AXI_AXCACHE_BY_BOARD   : board_slv4_t := (ZEDBOARD => "0011", ULTRA96 => "0011");  -- HP port, normal non-cacheable bufferable

    constant AXI_MAX_BURST : natural                      := AXI_MAX_BURST_BY_BOARD(BOARD);
    constant AXI_PORT_AXI3 : boolean                      := AXI_PORT_AXI3_BY_BOARD(BOARD);
    constant AXI_ID_W_MAX  : natural                      := AXI_ID_W_MAX_BY_BOARD(BOARD);
    constant AXI_AXCACHE   : std_logic_vector(3 downto 0) := AXI_AXCACHE_BY_BOARD(BOARD);

    constant AXI_BURST_INCR : std_logic_vector(1 downto 0) := "01";
    constant AXI_PAGE_BYTES : natural := 4096;    -- a burst must not cross this boundary

    -- ceil(log2 n), clog2(1) = 0
    function clog2(n : positive) return natural;
    -- AxSIZE for full-width beats of data_w bits: log2(data_w / 8)
    function axi_size(data_w : positive) return std_logic_vector;
    -- beats from addr up to the next 4 KB boundary (addr is taken beat aligned)
    function beats_to_4k(addr : unsigned; data_w : positive) return positive;
    -- split rule: beats of the next burst = min(beats_left, max_burst, beats_to_4k(addr)), 0 when beats_left = 0
    function burst_beats(addr : unsigned; beats_left : natural; max_burst : positive; data_w : positive) return natural;
    -- true if a burst of len + 1 beats starting at addr crosses a 4 KB boundary (for assertions and the memory model)
    function crosses_4k(addr : unsigned; len : unsigned; data_w : positive) return boolean;
end package axi_pkg;

package body axi_pkg is

    function clog2(n : positive) return natural is
        variable r : natural := 0;
        variable v : positive := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function clog2;

    function axi_size(data_w : positive) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(clog2(data_w / 8), 3));
    end function axi_size;

    function beats_to_4k(addr : unsigned; data_w : positive) return positive is
        constant C_BEAT_BYTES : positive := data_w / 8;
        variable v_a   : unsigned(addr'length-1 downto 0);
        variable v_off : natural;
    begin
        v_a := addr;
        if v_a'length >= 12 then
            v_off := to_integer(v_a(11 downto 0));    -- offset inside the 4 KB page
        else
            v_off := to_integer(v_a);
        end if;
        v_off := v_off - v_off mod C_BEAT_BYTES;      -- beat aligned, so the result is at least 1
        return (AXI_PAGE_BYTES - v_off) / C_BEAT_BYTES;
    end function beats_to_4k;

    function burst_beats(addr : unsigned; beats_left : natural; max_burst : positive; data_w : positive) return natural is
        variable v_n : natural;
        variable v_page : positive;
    begin
        v_n := beats_left;
        if max_burst < v_n then
            v_n := max_burst;
        end if;
        v_page := beats_to_4k(addr, data_w);
        if v_page < v_n then
            v_n := v_page;
        end if;
        return v_n;
    end function burst_beats;

    function crosses_4k(addr : unsigned; len : unsigned; data_w : positive) return boolean is
    begin
        return to_integer(len) + 1 > beats_to_4k(addr, data_w);
    end function crosses_4k;

end package body axi_pkg;
