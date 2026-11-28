-- Author: Roman Riazanov
-- rom_image_pkg: simulation only, reads the weight/bias ROM images and rom_map.txt written by export.py
-- the readers fail if the file is missing or has a different number of lines than expected
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use std.textio.all;

use work.camus_pkg.all;

package rom_image_pkg is
    type i8_vec is array (natural range <>) of act_t;
    type i32_vec is array (natural range <>) of acc_t;

    -- one hex value per line, exactly n non-empty lines
    impure function read_i8_mem(path : string; n : positive) return i8_vec;
    impure function read_i32_mem(path : string; n : positive) return i32_vec;
    -- byte offsets of a conv layer in the two images, fails with a report if the name is missing
    procedure rom_map_lookup(path, name : string; variable w_off, b_off : out natural);
end package rom_image_pkg;

package body rom_image_pkg is

    function is_blank(s : string) return boolean is
    begin
        for i in s'range loop
            if s(i) /= ' ' and s(i) /= HT and s(i) /= CR and s(i) /= LF then
                return false;
            end if;
        end loop;
        return true;
    end function is_blank;

    -- idx-th (0-based) blank separated token of s, empty if there is none
    function token(s : string; idx : natural) return string is
        variable v_i   : integer := s'left;
        variable v_n   : natural := 0;
        variable v_lo  : integer;
    begin
        while v_i <= s'right loop
            while v_i <= s'right and (s(v_i) = ' ' or s(v_i) = HT or s(v_i) = CR or s(v_i) = LF) loop
                v_i := v_i + 1;
            end loop;
            exit when v_i > s'right;
            v_lo := v_i;
            while v_i <= s'right and not (s(v_i) = ' ' or s(v_i) = HT or s(v_i) = CR or s(v_i) = LF) loop
                v_i := v_i + 1;
            end loop;
            if v_n = idx then
                return s(v_lo to v_i - 1);
            end if;
            v_n := v_n + 1;
        end loop;
        return "";
    end function token;

    impure function read_i8_mem(path : string; n : positive) return i8_vec is
        file f : text;
        variable v_st  : file_open_status;
        variable v_l   : line;
        variable v_v   : std_logic_vector(7 downto 0);
        variable v_mem : i8_vec(0 to n - 1);
        variable v_i   : natural := 0;
    begin
        file_open(v_st, f, path, read_mode);
        assert v_st = open_ok report "cannot open " & path severity failure;
        while not endfile(f) loop
            readline(f, v_l);
            if not is_blank(v_l.all) then
                assert v_i < n report path & " has more than " & integer'image(n) & " lines" severity failure;
                hread(v_l, v_v);
                v_mem(v_i) := signed(v_v);
                v_i := v_i + 1;
            end if;
        end loop;
        file_close(f);
        assert v_i = n report path & " has " & integer'image(v_i) & " lines, expected " & integer'image(n)
            severity failure;
        return v_mem;
    end function read_i8_mem;

    impure function read_i32_mem(path : string; n : positive) return i32_vec is
        file f : text;
        variable v_st  : file_open_status;
        variable v_l   : line;
        variable v_v   : std_logic_vector(31 downto 0);
        variable v_mem : i32_vec(0 to n - 1);
        variable v_i   : natural := 0;
    begin
        file_open(v_st, f, path, read_mode);
        assert v_st = open_ok report "cannot open " & path severity failure;
        while not endfile(f) loop
            readline(f, v_l);
            if not is_blank(v_l.all) then
                assert v_i < n report path & " has more than " & integer'image(n) & " lines" severity failure;
                hread(v_l, v_v);
                v_mem(v_i) := signed(v_v);
                v_i := v_i + 1;
            end if;
        end loop;
        file_close(f);
        assert v_i = n report path & " has " & integer'image(v_i) & " lines, expected " & integer'image(n)
            severity failure;
        return v_mem;
    end function read_i32_mem;

    procedure rom_map_lookup(path, name : string; variable w_off, b_off : out natural) is
        file f : text;
        variable v_st    : file_open_status;
        variable v_l     : line;
        variable v_found : boolean := false;
    begin
        file_open(v_st, f, path, read_mode);
        assert v_st = open_ok report "cannot open " & path severity failure;
        while not endfile(f) and not v_found loop
            readline(f, v_l);
            -- the header line starts with '#', so it never equals a layer name
            if token(v_l.all, 0) = name then
                w_off := natural'value(token(v_l.all, 1));
                b_off := natural'value(token(v_l.all, 3));
                v_found := true;
            end if;
        end loop;
        file_close(f);
        assert v_found report "layer " & name & " not in " & path severity failure;
    end procedure rom_map_lookup;

end package body rom_image_pkg;
