-- Author: Roman Riazanov
-- requant: y = (acc * m0 + 2^(shift-1)) >> shift, round half up, arithmetic shift
-- bit-exact to requant() in python/quantize.py, shift must be at least 1
-- two outputs: the unclipped value (for the residual add) and the value clipped to 0..127 (ReLU)
-- latency 2 clocks: product register, then output register (rounding add, shift and clip in between)
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity requant is
    port (
        i_clk, i_rst : in std_logic;
        i_valid : in std_logic;
        i_acc : in acc_t;
        i_m0 : in unsigned(MULT_W-1 downto 0);
        i_shift : in unsigned(5 downto 0);       -- 16 to 26 in the current export
        o_valid : out std_logic;
        o_y_wide : out signed(ACC_W-1 downto 0); -- unclipped
        o_y_relu8 : out act_t                    -- clipped to 0..127
    );
end entity requant;

architecture rtl of requant is
    -- a 32 bit acc times a 16 bit unsigned m0 fits 48 bits, also with the rounding constant added
    constant C_PROD_W : natural := ACC_W + MULT_W;
    subtype prod_t is signed(C_PROD_W-1 downto 0);

    -- stage 1: product
    signal s_prod : prod_t;
    signal s_shift : unsigned(5 downto 0);
    signal s_valid : std_logic := '0';

    -- between the stages: rounding add and arithmetic shift, the result fits in ACC_W bits because m0 / 2^shift < 1
    signal s_round : prod_t;
    signal s_wide_in : signed(ACC_W-1 downto 0);

    -- stage 2: output
    signal s_valid_out : std_logic := '0';
    signal s_wide_out : signed(ACC_W-1 downto 0);
    signal s_relu_out : act_t;
begin

    -- 2^(shift-1), for shift 0 the index wraps to 63 and the constant shifts out to 0
    s_round <= shift_left(to_signed(1, C_PROD_W), to_integer(s_shift - 1));
    s_wide_in <= resize(shift_right(s_prod + s_round, to_integer(s_shift)), ACC_W);

    process(i_clk)
    begin
        if rising_edge(i_clk) then
            -- m0 is unsigned, the extra zero bit keeps it positive in the signed product
            s_prod <= resize(i_acc * signed('0' & i_m0), C_PROD_W);
            s_shift <= i_shift;
            s_valid <= i_valid;

            s_wide_out <= s_wide_in;
            if s_wide_in < 0 then
                s_relu_out <= (others => '0');
            elsif s_wide_in > 127 then
                s_relu_out <= to_signed(127, ACT_W);
            else
                s_relu_out <= resize(s_wide_in, ACT_W);
            end if;
            s_valid_out <= s_valid;

            if i_rst = '1' then
                s_valid <= '0';
                s_valid_out <= '0';
            end if;
        end if;
    end process;

    o_valid <= s_valid_out;
    o_y_wide <= s_wide_out;
    o_y_relu8 <= s_relu_out;
end architecture rtl;
