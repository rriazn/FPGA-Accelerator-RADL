-- Author: Roman Riazanov
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity mac_int8 is
    port (
        i_clk, i_rst : in std_logic;
        i_en : in std_logic;
        i_first, i_last : in std_logic; -- last/first term of the current output element
        i_bias : in acc_t;
        i_a, i_b : in act_t;
        o_acc : out acc_t;
        o_acc_valid : out std_logic
    );
end entity mac_int8;

architecture rtl of mac_int8 is
    signal s_acc : acc_t;
    signal s_acc_valid : std_logic;
begin

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            s_acc_valid <= i_en and i_last;
            if i_rst = '1' then
                s_acc <= (others => '0');
                s_acc_valid <= '0';
            elsif i_en = '1' then
                if i_first = '1' then
                    s_acc <= i_bias + resize(i_a * i_b, i_bias'length);
                else
                    s_acc <= s_acc + resize(i_a * i_b, i_bias'length);
                end if;
            end if;
        end if;
    end process;

    o_acc <= s_acc;
    o_acc_valid <= s_acc_valid;
end architecture rtl;
