-- Author: Olimjon Mirzayusupov
-- axi_mem_model_shared: the one memory (axi_mem) and the statistics (axi_stats) of a simulation with axi_mem_model,
-- and the backdoor procedures mem_write / mem_read (little endian, byte i of the data at addr + i); simulation only
-- a package of its own so that the protected bodies of axi_mem_model_pkg are elaborated before these shared variables
-- are created (GHDL warns otherwise); a testbench uses it to preload and check the memory and to read the statistics
-- for its coverage checks; one model instance per simulation
-- compile order: tests/models/axi_mem_model_pkg.vhd, this file, tests/models/axi_mem_model.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.axi_mem_model_pkg.all;

package axi_mem_model_shared is
    shared variable axi_mem   : mem_pt;
    shared variable axi_stats : stats_pt;

    -- backdoor, little endian: byte i of data (bits 8i+7..8i) is at addr + i, the AXI byte-lane order
    procedure mem_write(addr : unsigned; data : std_logic_vector);
    procedure mem_read(addr : unsigned; data : out std_logic_vector);
end package axi_mem_model_shared;

package body axi_mem_model_shared is

    procedure mem_write(addr : unsigned; data : std_logic_vector) is
        variable v_d : std_logic_vector(data'length-1 downto 0) := data;
    begin
        for i in 0 to data'length / 8 - 1 loop
            axi_mem.write_byte(resize(addr, 32) + to_unsigned(i, 32), v_d(8 * i + 7 downto 8 * i));
        end loop;
    end procedure mem_write;

    procedure mem_read(addr : unsigned; data : out std_logic_vector) is
        variable v_d : std_logic_vector(data'length-1 downto 0);
    begin
        for i in 0 to data'length / 8 - 1 loop
            v_d(8 * i + 7 downto 8 * i) := axi_mem.read_byte(resize(addr, 32) + to_unsigned(i, 32));
        end loop;
        data := v_d;
    end procedure mem_read;

end package body axi_mem_model_shared;
