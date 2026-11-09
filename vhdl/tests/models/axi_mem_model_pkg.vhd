-- Author: Olimjon Mirzayusupov
-- axi_mem_model_pkg: types of the testbench side of axi_mem_model, simulation only (.gateflow/plans/axi-ddr-master.md F7)
-- mem_pt: the sparse byte memory (4 KB pages allocated on the first write, unwritten bytes read as x"A5")
-- stats_pt: the statistics, counted per stat_t, and the protocol violations per violation_t (literals VIO_*)
-- the objects themselves and the backdoor procedures are in axi_mem_model_shared (tests/models/axi_mem_model_shared.vhd)
-- compile order: this file, tests/models/axi_mem_model_shared.vhd, tests/models/axi_mem_model.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package axi_mem_model_pkg is
    type mem_pt is protected
        procedure write_byte(addr : unsigned; b : std_logic_vector);
        impure function read_byte(addr : unsigned) return std_logic_vector;
        procedure clear;
    end protected mem_pt;

    type stat_t is (ST_AR, ST_AW, ST_R_BEATS, ST_W_BEATS, ST_B, ST_R_REORDER, ST_B_REORDER,
                    ST_AR_STALL, ST_AW_STALL, ST_W_STALL, ST_R_ERR, ST_B_ERR,
                    ST_RD_FULL, ST_WR_FULL, ST_PAGE_END, ST_VIOLATION);
    type violation_t is (VIO_AR_UNSTABLE, VIO_AW_UNSTABLE, VIO_W_UNSTABLE, VIO_BURST, VIO_SIZE, VIO_LEN, VIO_4K,
                         VIO_UNALIGNED, VIO_WLAST, VIO_WRITE_OUTSIDE, VIO_X);

    type stats_pt is protected
        procedure add(s : stat_t; n : natural := 1);
        procedure add_violation(v : violation_t);
        impure function get(s : stat_t) return natural;
        impure function violations(v : violation_t) return natural;
        procedure clear;
    end protected stats_pt;

end package axi_mem_model_pkg;

package body axi_mem_model_pkg is

    type mem_pt is protected body
        constant C_HASH : positive := 1024;
        type page_t is array (0 to 4095) of natural range 0 to 255;
        type page_ptr_t is access page_t;
        type node_t;
        type node_ptr_t is access node_t;
        type node_t is record
            page_no : natural;
            data    : page_ptr_t;
            next_n  : node_ptr_t;
        end record;
        type table_t is array (0 to C_HASH-1) of node_ptr_t;
        variable v_table : table_t := (others => null);

        impure function find(page_no : natural; create : boolean) return page_ptr_t is
            variable v_n : node_ptr_t := v_table(page_no mod C_HASH);
        begin
            while v_n /= null loop
                if v_n.page_no = page_no then
                    return v_n.data;
                end if;
                v_n := v_n.next_n;
            end loop;
            if not create then
                return null;
            end if;
            v_n := new node_t'(page_no, new page_t'(others => 16#A5#), v_table(page_no mod C_HASH));
            v_table(page_no mod C_HASH) := v_n;
            return v_n.data;
        end function find;

        procedure write_byte(addr : unsigned; b : std_logic_vector) is
            variable v_a : unsigned(31 downto 0) := resize(addr, 32);
            variable v_p : page_ptr_t;
        begin
            v_p := find(to_integer(v_a(31 downto 12)), true);
            v_p(to_integer(v_a(11 downto 0))) := to_integer(unsigned(b));
        end procedure write_byte;

        impure function read_byte(addr : unsigned) return std_logic_vector is
            variable v_a : unsigned(31 downto 0) := resize(addr, 32);
            variable v_p : page_ptr_t;
        begin
            v_p := find(to_integer(v_a(31 downto 12)), false);
            if v_p = null then
                return x"A5";
            end if;
            return std_logic_vector(to_unsigned(v_p(to_integer(v_a(11 downto 0))), 8));
        end function read_byte;

        procedure clear is
        begin
            v_table := (others => null);
        end procedure clear;
    end protected body mem_pt;

    type stats_pt is protected body
        type stat_arr_t is array (stat_t) of natural;
        type viol_arr_t is array (violation_t) of natural;
        variable v_stat : stat_arr_t := (others => 0);
        variable v_viol : viol_arr_t := (others => 0);

        procedure add(s : stat_t; n : natural := 1) is
        begin
            v_stat(s) := v_stat(s) + n;
        end procedure add;

        procedure add_violation(v : violation_t) is
        begin
            v_viol(v) := v_viol(v) + 1;
            v_stat(ST_VIOLATION) := v_stat(ST_VIOLATION) + 1;
        end procedure add_violation;

        impure function get(s : stat_t) return natural is
        begin
            return v_stat(s);
        end function get;

        impure function violations(v : violation_t) return natural is
        begin
            return v_viol(v);
        end function violations;

        procedure clear is
        begin
            v_stat := (others => 0);
            v_viol := (others => 0);
        end procedure clear;
    end protected body stats_pt;

end package body axi_mem_model_pkg;
