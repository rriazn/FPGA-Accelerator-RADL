-- Author: Roman Riazanov
-- self-checking unit testbench for weight_rom, reference image from rom_image_pkg (not from the RTL init function)
-- needs build/export from python/export.py
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> ../build/export/quant_pkg.vhd src/camus_pkg.vhd tests/models/rom_image_pkg.vhd src/compute-engine/weight_rom.vhd tests/unit/compute-engine/tb_weight_rom.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_weight_rom
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;
use work.quant_pkg.all;
use work.rom_image_pkg.all;

entity tb_weight_rom is
    generic (
        G_EXPORT : string := "../build/export"
    );
end entity tb_weight_rom;

architecture sim of tb_weight_rom is
    constant C_PERIOD : time := 5 ns;

    signal s_clk    : std_logic := '0';
    signal s_en     : std_logic := '0';
    signal s_w_addr : unsigned(AXI_ADDR_W - 1 downto 0) := (others => '0');
    signal s_b_addr : unsigned(AXI_ADDR_W - 1 downto 0) := (others => '0');
    signal s_w_data : act_t;
    signal s_b_data : acc_t;
    signal s_done   : boolean := false;
begin

    clk_gen : process
    begin
        while not s_done loop
            s_clk <= '0';
            wait for C_PERIOD / 2;
            s_clk <= '1';
            wait for C_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    dut : entity work.weight_rom
        generic map (
            G_W_INIT  => G_EXPORT & "/w_rom.mem",
            G_B_INIT  => G_EXPORT & "/b_rom.mem",
            G_W_BYTES => W_ROM_BYTES,
            G_B_WORDS => B_ROM_WORDS
        )
        port map (
            i_clk    => s_clk,
            i_en     => s_en,
            i_w_addr => s_w_addr,
            i_b_addr => s_b_addr,
            o_w_data => s_w_data,
            o_b_data => s_b_data
        );

    stim : process
        constant C_W_REF : i8_vec(0 to W_ROM_BYTES - 1)  := read_i8_mem(G_EXPORT & "/w_rom.mem", W_ROM_BYTES);
        constant C_B_REF : i32_vec(0 to B_ROM_WORDS - 1) := read_i32_mem(G_EXPORT & "/b_rom.mem", B_ROM_WORDS);

        variable v_seed1, v_seed2 : positive := 1;
        variable v_w_off, v_b_off : natural;
        variable v_w_nz, v_b_nz   : natural;
        variable v_prev_w         : act_t;
        variable v_prev_b         : acc_t;
        variable v_r              : real;
        variable v_n              : natural;

        procedure fail(msg : string) is
        begin
            report "FAIL: " & msg severity failure;
        end procedure fail;

        -- one enabled clock: inputs change after the last edge, the next edge samples, outputs are checked 1 ns later
        procedure read_both(w_addr, b_addr : unsigned(AXI_ADDR_W - 1 downto 0)) is
        begin
            s_en <= '1';
            s_w_addr <= w_addr;
            s_b_addr <= b_addr;
            wait until rising_edge(s_clk);
            wait for 1 ns;
        end procedure read_both;

        procedure chk_w(exp : act_t; what : string) is
        begin
            if s_w_data /= exp then
                fail(what & ": w " & integer'image(to_integer(s_w_data)) & ", expected " & integer'image(to_integer(exp)));
            end if;
        end procedure chk_w;

        procedure chk_b(exp : acc_t; what : string) is
        begin
            if s_b_data /= exp then
                fail(what & ": b " & integer'image(to_integer(s_b_data)) & ", expected " & integer'image(to_integer(exp)));
            end if;
        end procedure chk_b;

        function ua(v : natural) return unsigned is
        begin
            return to_unsigned(v, AXI_ADDR_W);
        end function ua;
    begin
        wait until rising_edge(s_clk);
        wait for 1 ns;

        -- first non-zero entries, so that a read of 0 after them proves the output was replaced
        v_w_nz := 0;
        while C_W_REF(v_w_nz) = 0 loop
            v_w_nz := v_w_nz + 1;
        end loop;
        v_b_nz := 0;
        while C_B_REF(v_b_nz) = 0 loop
            v_b_nz := v_b_nz + 1;
        end loop;

        -- every weight byte, the bias word follows along (offset 0)
        for i in 0 to W_ROM_BYTES - 1 loop
            read_both(ua(i), ua(4 * (i mod B_ROM_WORDS)));
            chk_w(C_W_REF(i), "weight " & integer'image(i));
            chk_b(C_B_REF(i mod B_ROM_WORDS), "bias via weight sweep " & integer'image(i));
        end loop;

        -- every bias word at all four byte offsets (bits 1:0 are ignored)
        for i in 0 to B_ROM_WORDS - 1 loop
            for o in 0 to 3 loop
                read_both(ua(0), ua(4 * i + o));
                chk_b(C_B_REF(i), "bias " & integer'image(i) & " offset " & integer'image(o));
            end loop;
        end loop;

        -- hold: i_en = 0 for 0 to 20 clocks with changing addresses, outputs keep their value
        for rep in 0 to 199 loop
            uniform(v_seed1, v_seed2, v_r);
            v_w_off := natural(floor(v_r * real(W_ROM_BYTES)));
            uniform(v_seed1, v_seed2, v_r);
            v_b_off := natural(floor(v_r * real(B_ROM_WORDS)));
            read_both(ua(v_w_off), ua(4 * v_b_off));
            chk_w(C_W_REF(v_w_off), "hold setup w");
            chk_b(C_B_REF(v_b_off), "hold setup b");
            v_prev_w := s_w_data;
            v_prev_b := s_b_data;
            uniform(v_seed1, v_seed2, v_r);
            v_n := natural(floor(v_r * 21.0));
            for c in 1 to v_n loop
                s_en <= '0';
                uniform(v_seed1, v_seed2, v_r);
                s_w_addr <= ua(natural(floor(v_r * real(W_ROM_BYTES))));
                uniform(v_seed1, v_seed2, v_r);
                s_b_addr <= ua(4 * natural(floor(v_r * real(B_ROM_WORDS))));
                wait until rising_edge(s_clk);
                wait for 1 ns;
                chk_w(v_prev_w, "hold w, rep " & integer'image(rep));
                chk_b(v_prev_b, "hold b, rep " & integer'image(rep));
            end loop;
        end loop;

        -- out of range reads 0, also with the full 32 bit address (no to_integer overflow)
        read_both(ua(v_w_nz), ua(4 * v_b_nz));
        chk_w(C_W_REF(v_w_nz), "pre out of range w");
        chk_b(C_B_REF(v_b_nz), "pre out of range b");
        read_both(ua(W_ROM_BYTES), ua(4 * B_ROM_WORDS));
        chk_w(to_signed(0, ACT_W), "w_addr = W_ROM_BYTES");
        chk_b(to_signed(0, ACC_W), "b_addr = 4 * B_ROM_WORDS");
        read_both(ua(v_w_nz), ua(4 * v_b_nz));
        read_both(x"FFFFFFFF", x"FFFFFFFF");
        chk_w(to_signed(0, ACT_W), "w_addr = 0xFFFFFFFF");
        chk_b(to_signed(0, ACC_W), "b_addr = 0xFFFFFFFF");
        read_both(ua(v_w_nz), ua(4 * v_b_nz));
        read_both(x"80000000", x"80000003");
        chk_w(to_signed(0, ACT_W), "w_addr = 0x80000000");
        chk_b(to_signed(0, ACC_W), "b_addr = 0x80000003");
        read_both(ua(W_ROM_BYTES + 1), ua(4 * B_ROM_WORDS + 3));
        chk_w(to_signed(0, ACT_W), "w_addr = W_ROM_BYTES + 1");
        chk_b(to_signed(0, ACC_W), "b_addr = 4 * B_ROM_WORDS + 3");
        -- the last valid entries still read, and an out of range read with i_en = 0 holds
        read_both(ua(W_ROM_BYTES - 1), ua(4 * (B_ROM_WORDS - 1)));
        chk_w(C_W_REF(W_ROM_BYTES - 1), "last weight");
        chk_b(C_B_REF(B_ROM_WORDS - 1), "last bias");
        s_en <= '0';
        s_w_addr <= ua(W_ROM_BYTES);
        s_b_addr <= x"FFFFFFFF";
        wait until rising_edge(s_clk);
        wait for 1 ns;
        chk_w(C_W_REF(W_ROM_BYTES - 1), "hold out of range w");
        chk_b(C_B_REF(B_ROM_WORDS - 1), "hold out of range b");

        -- rom_map.txt: first and last layer
        rom_map_lookup(G_EXPORT & "/rom_map.txt", "stem", v_w_off, v_b_off);
        if v_w_off /= 0 or v_b_off /= 0 then
            fail("rom_map stem");
        end if;
        rom_map_lookup(G_EXPORT & "/rom_map.txt", "b3sc", v_w_off, v_b_off);
        if v_w_off /= W_ROM_BYTES - 2048 or v_b_off /= 4 * (B_ROM_WORDS - 64) then
            fail("rom_map b3sc: " & integer'image(v_w_off) & " " & integer'image(v_b_off));
        end if;

        s_en <= '0';
        wait for 4 * C_PERIOD;
        report "PASS";
        s_done <= true;
        wait;
    end process stim;

end architecture sim;
