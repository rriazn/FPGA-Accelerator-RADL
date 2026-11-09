-- Author: Olimjon Mirzayusupov
-- self-checking unit test for axi_pkg: clog2, axi_size, the per-board constants, beats_to_4k, burst_beats, crosses_4k
-- beats_to_4k, burst_beats and crosses_4k are compared with a beat-by-beat reference at every beat-aligned offset of a
-- 4 KB page, for 64 and 128 bit and three page bases; whole transfers are split with burst_beats and every burst is
-- checked (legal length, no 4 KB crossing, the bursts add up); the 40-beat example of docs/plans/axi-ddr-master.md
-- section 9 is checked burst by burst
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/axi_pkg.vhd tests/unit/tb_axi_pkg.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_axi_pkg
--   ghdl -r --std=08 --workdir=<dir> tb_axi_pkg
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;
use work.axi_pkg.all;

entity tb_axi_pkg is
end entity tb_axi_pkg;

architecture sim of tb_axi_pkg is
    type nat_list_t is array (natural range <>) of natural;
    type addr_list_t is array (natural range <>) of unsigned(31 downto 0);

    constant C_WIDTHS : nat_list_t := (64, 128);
    constant C_BASES  : addr_list_t := (x"00000000", x"10000000", x"FFFFF000");
    constant C_LEFT   : nat_list_t := (0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65,
                                       127, 128, 129, 255, 256, 257, 300);
    constant C_MAXB   : nat_list_t := (1, 2, 16, 256);
    constant C_STARTS : nat_list_t := (0, 8, 16, 2048, 4000, 4064, 4080, 4088);    -- byte offsets in a page
    constant C_TOTALS : nat_list_t := (1, 2, 15, 16, 17, 40, 255, 256);
begin
    process
        variable v_errors : natural := 0;
        variable v_checks : natural := 0;
        variable v_bytes, v_ref, v_exp, v_a, v_n, v_left, v_bursts, v_sum : natural;
        variable v_addr : unsigned(31 downto 0);

        procedure check(cond : boolean; msg : string) is
        begin
            v_checks := v_checks + 1;
            if not cond then
                v_errors := v_errors + 1;
                report "ERROR: " & msg severity error;
            end if;
        end procedure check;

        function min3(a, b, c : natural) return natural is
            variable v : natural := a;
        begin
            if b < v then
                v := b;
            end if;
            if c < v then
                v := c;
            end if;
            return v;
        end function min3;
    begin
        -- clog2 and axi_size
        check(clog2(1) = 0 and clog2(2) = 1 and clog2(3) = 2 and clog2(4) = 2, "clog2 small");
        check(clog2(5) = 3 and clog2(16) = 4 and clog2(17) = 5 and clog2(256) = 8, "clog2 large");
        check(axi_size(32) = "010" and axi_size(64) = "011" and axi_size(128) = "100", "axi_size");

        -- per-board tables (both entries) and the values selected by BOARD
        check(AXI_DATA_W_BY_BOARD(ZEDBOARD) = 64 and AXI_DATA_W_BY_BOARD(ULTRA96) = 128, "data width table");
        check(AXI_MAX_BURST_BY_BOARD(ZEDBOARD) = 16 and AXI_MAX_BURST_BY_BOARD(ULTRA96) = 16, "max burst table");
        check(AXI_PORT_AXI3_BY_BOARD(ZEDBOARD) and not AXI_PORT_AXI3_BY_BOARD(ULTRA96), "AXI3 table");
        check(AXI_ID_W_MAX_BY_BOARD(ZEDBOARD) = 6 and AXI_ID_W_MAX_BY_BOARD(ULTRA96) = 6, "ID width table");
        check(AXI_AXCACHE_BY_BOARD(ZEDBOARD) = "0011" and AXI_AXCACHE_BY_BOARD(ULTRA96) = "0011", "AxCACHE table");
        check(AXI_DATA_W = AXI_DATA_W_BY_BOARD(BOARD), "AXI_DATA_W follows BOARD");
        check(AXI_MAX_BURST = AXI_MAX_BURST_BY_BOARD(BOARD), "AXI_MAX_BURST follows BOARD");
        check(AXI_PORT_AXI3 = AXI_PORT_AXI3_BY_BOARD(BOARD), "AXI_PORT_AXI3 follows BOARD");
        check(AXI_ID_W_MAX = AXI_ID_W_MAX_BY_BOARD(BOARD), "AXI_ID_W_MAX follows BOARD");
        check(AXI_AXCACHE = AXI_AXCACHE_BY_BOARD(BOARD), "AXI_AXCACHE follows BOARD");

        -- every beat-aligned offset of a page, against a beat-by-beat reference
        for w in C_WIDTHS'range loop
            v_bytes := C_WIDTHS(w) / 8;
            for b in C_BASES'range loop
                for off_beat in 0 to 4096 / v_bytes - 1 loop
                    v_addr := C_BASES(b) + to_unsigned(off_beat * v_bytes, 32);
                    -- reference: walk beat by beat up to the page end
                    v_ref := 0;
                    v_a := off_beat * v_bytes;
                    while v_a < 4096 loop
                        v_ref := v_ref + 1;
                        v_a := v_a + v_bytes;
                    end loop;
                    check(beats_to_4k(v_addr, C_WIDTHS(w)) = v_ref,
                          "beats_to_4k at offset " & integer'image(off_beat * v_bytes) & ", " & integer'image(C_WIDTHS(w)) & " bit");
                    for l in C_LEFT'range loop
                        for m in C_MAXB'range loop
                            v_exp := min3(C_LEFT(l), C_MAXB(m), v_ref);
                            check(burst_beats(v_addr, C_LEFT(l), C_MAXB(m), C_WIDTHS(w)) = v_exp,
                                  "burst_beats at offset " & integer'image(off_beat * v_bytes) & ", left " & integer'image(C_LEFT(l))
                                  & ", max " & integer'image(C_MAXB(m)) & ", " & integer'image(C_WIDTHS(w)) & " bit");
                        end loop;
                    end loop;
                    for len in 0 to 255 loop
                        check(crosses_4k(v_addr, to_unsigned(len, 8), C_WIDTHS(w)) = (off_beat * v_bytes + (len + 1) * v_bytes > 4096),
                              "crosses_4k at offset " & integer'image(off_beat * v_bytes) & ", len " & integer'image(len)
                              & ", " & integer'image(C_WIDTHS(w)) & " bit");
                    end loop;
                end loop;
            end loop;
        end loop;

        -- whole transfers split with burst_beats: every burst legal, nothing lost
        for w in C_WIDTHS'range loop
            v_bytes := C_WIDTHS(w) / 8;
            for m in 1 to 2 loop
                for s in C_STARTS'range loop
                    for t in C_TOTALS'range loop
                        v_addr := x"10000000" + to_unsigned(C_STARTS(s) - C_STARTS(s) mod v_bytes, 32);
                        v_left := C_TOTALS(t);
                        v_bursts := 0;
                        v_sum := 0;
                        while v_left > 0 loop
                            v_n := burst_beats(v_addr, v_left, C_MAXB(m + 1), C_WIDTHS(w));
                            check(v_n >= 1 and v_n <= C_MAXB(m + 1), "split burst length out of range");
                            check(not crosses_4k(v_addr, to_unsigned(v_n - 1, 8), C_WIDTHS(w)), "split burst crosses 4 KB");
                            v_addr := v_addr + to_unsigned(v_n * v_bytes, 32);
                            v_left := v_left - v_n;
                            v_sum := v_sum + v_n;
                            v_bursts := v_bursts + 1;
                            exit when v_n = 0;
                        end loop;
                        check(v_sum = C_TOTALS(t), "split bursts do not add up");
                        check(v_bursts >= (C_TOTALS(t) + C_MAXB(m + 1) - 1) / C_MAXB(m + 1), "too few bursts");
                    end loop;
                end loop;
            end loop;
        end loop;
        check(burst_beats(x"10000000", 0, 16, 64) = 0, "burst_beats with nothing left");

        -- the documented example: 40 beats at 0x1000_0FE0, 64 bit, max 16 -> 4, 16, 16, 4
        v_addr := x"10000FE0";
        v_n := burst_beats(v_addr, 40, 16, 64);
        check(v_n = 4, "example burst 1");
        v_addr := v_addr + to_unsigned(v_n * 8, 32);
        check(v_addr = x"10001000", "example address 2");
        v_n := burst_beats(v_addr, 36, 16, 64);
        check(v_n = 16, "example burst 2");
        v_addr := v_addr + to_unsigned(v_n * 8, 32);
        check(v_addr = x"10001080", "example address 3");
        v_n := burst_beats(v_addr, 20, 16, 64);
        check(v_n = 16, "example burst 3");
        v_addr := v_addr + to_unsigned(v_n * 8, 32);
        check(v_addr = x"10001100", "example address 4");
        v_n := burst_beats(v_addr, 4, 16, 64);
        check(v_n = 4, "example burst 4");

        report "board " & board_t'image(BOARD) & ", " & integer'image(v_checks) & " checks, " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        wait;
    end process;
end architecture sim;
