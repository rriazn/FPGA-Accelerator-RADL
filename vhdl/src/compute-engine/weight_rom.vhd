-- Author: Roman Riazanov
-- weight_rom: conv weights (int8, byte addressed) and biases (int32, word addressed) in two ROMs
-- init from the .mem files
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use std.textio.all;

use work.camus_pkg.all;

entity weight_rom is
    generic (
        G_W_INIT : string; -- path of w_rom.mem
        G_B_INIT : string; -- path of b_rom.mem
        G_W_BYTES : positive; -- W_ROM_BYTES
        G_B_WORDS : positive -- B_ROM_WORDS
    );
    port (
        i_clk : in  std_logic;
        i_en : in  std_logic; -- 1 samples both addresses, 0 holds both outputs
        i_w_addr : in  unsigned(AXI_ADDR_W - 1 downto 0); -- byte offset
        i_b_addr : in  unsigned(AXI_ADDR_W - 1 downto 0); -- byte offset, bits 1:0 ignored
        o_w_data : out act_t; -- clock after i_en, 0 if i_w_addr >= G_W_BYTES
        o_b_data : out acc_t -- clock after i_en, 0 if i_b_addr/4 >= G_B_WORDS
    );
end entity weight_rom;

architecture rtl of weight_rom is
    type t_w_rom is array (0 to G_W_BYTES - 1) of act_t;
    type t_b_rom is array (0 to G_B_WORDS - 1) of acc_t;

    -- address bits needed for an index, at most 31 so that to_integer cannot overflow
    function addr_bits(n : positive) return positive is
        variable v_b : positive := 1;
    begin
        while v_b < 31 and 2 ** v_b < n loop
            v_b := v_b + 1;
        end loop;
        return v_b;
    end function addr_bits;

    constant C_W_AW : positive := addr_bits(G_W_BYTES);
    constant C_B_AW : positive := addr_bits(G_B_WORDS);

    function is_blank(s : string) return boolean is
    begin
        for i in s'range loop
            if s(i) /= ' ' and s(i) /= HT and s(i) /= CR and s(i) /= LF then
                return false;
            end if;
        end loop;
        return true;
    end function is_blank;

    -- exactly G_W_BYTES non-empty lines, else elaboration fails (no silent ROM of zeros)
    impure function init_w return t_w_rom is
        file f : text;
        variable v_st  : file_open_status;
        variable v_l   : line;
        variable v_v   : std_logic_vector(ACT_W - 1 downto 0);
        variable v_rom : t_w_rom := (others => (others => '0'));
        variable v_i   : natural := 0;
    begin
        file_open(v_st, f, G_W_INIT, read_mode);
        assert v_st = open_ok report "weight_rom: cannot open " & G_W_INIT severity failure;
        while not endfile(f) loop
            readline(f, v_l);
            if not is_blank(v_l.all) then
                assert v_i < G_W_BYTES report "weight_rom: " & G_W_INIT & " has more than "
                    & integer'image(G_W_BYTES) & " lines" severity failure;
                hread(v_l, v_v);
                v_rom(v_i) := signed(v_v);
                v_i := v_i + 1;
            end if;
        end loop;
        file_close(f);
        assert v_i = G_W_BYTES report "weight_rom: " & G_W_INIT & " has " & integer'image(v_i)
            & " lines, expected " & integer'image(G_W_BYTES) severity failure;
        return v_rom;
    end function init_w;

    impure function init_b return t_b_rom is
        file f : text;
        variable v_st  : file_open_status;
        variable v_l   : line;
        variable v_v   : std_logic_vector(ACC_W - 1 downto 0);
        variable v_rom : t_b_rom := (others => (others => '0'));
        variable v_i   : natural := 0;
    begin
        file_open(v_st, f, G_B_INIT, read_mode);
        assert v_st = open_ok report "weight_rom: cannot open " & G_B_INIT severity failure;
        while not endfile(f) loop
            readline(f, v_l);
            if not is_blank(v_l.all) then
                assert v_i < G_B_WORDS report "weight_rom: " & G_B_INIT & " has more than "
                    & integer'image(G_B_WORDS) & " lines" severity failure;
                hread(v_l, v_v);
                v_rom(v_i) := signed(v_v);
                v_i := v_i + 1;
            end if;
        end loop;
        file_close(f);
        assert v_i = G_B_WORDS report "weight_rom: " & G_B_INIT & " has " & integer'image(v_i)
            & " lines, expected " & integer'image(G_B_WORDS) severity failure;
        return v_rom;
    end function init_b;

    constant C_W_ROM : t_w_rom := init_w;
    constant C_B_ROM : t_b_rom := init_b;

    attribute rom_style : string;
    attribute rom_style of C_W_ROM : constant is "block";
    attribute rom_style of C_B_ROM : constant is "block";

    signal s_w_data : act_t := (others => '0');
    signal s_b_data : acc_t := (others => '0');
begin

    process(i_clk)
        variable v_b_word : unsigned(AXI_ADDR_W - 3 downto 0);
    begin
        if rising_edge(i_clk) then
            if i_en = '1' then
                -- compare the full address first, convert only the low bits
                if i_w_addr < G_W_BYTES then
                    s_w_data <= C_W_ROM(to_integer(i_w_addr(C_W_AW - 1 downto 0)));
                else
                    s_w_data <= (others => '0');
                end if;
                v_b_word := i_b_addr(AXI_ADDR_W - 1 downto 2);
                if v_b_word < G_B_WORDS then
                    s_b_data <= C_B_ROM(to_integer(v_b_word(C_B_AW - 1 downto 0)));
                else
                    s_b_data <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    o_w_data <= s_w_data;
    o_b_data <= s_b_data;
end architecture rtl;
