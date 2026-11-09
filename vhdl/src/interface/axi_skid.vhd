-- Author: Olimjon Mirzayusupov
-- axi_skid: two-entry register slice for one valid/ready channel (AR, AW or W of the AXI4 masters)
-- o_valid and o_ready both come straight from flip-flops, so no combinational path crosses the slice and the
-- m_axi_*valid outputs of the masters are flip-flops (requirement R2 in docs/plans/axi-ddr-master.md)
-- one transfer per clock when both sides are ready; the second entry (skid) catches the word accepted in the clock
-- where the downstream stalls, because o_ready can only fall one clock later
-- o_data is held stable while o_valid = '1' and i_ready = '0', as AXI requires
-- states: EMPTY (o_ready 1, o_valid 0), ONE (1, 1), TWO (0, 1)
library ieee;
use ieee.std_logic_1164.all;

entity axi_skid is
    generic (
        G_WIDTH : positive
    );
    port (
        i_clk, i_rst : in std_logic;
        -- upstream
        i_valid : in  std_logic;
        o_ready : out std_logic;
        i_data  : in  std_logic_vector(G_WIDTH-1 downto 0);
        -- downstream
        o_valid : out std_logic;
        i_ready : in  std_logic;
        o_data  : out std_logic_vector(G_WIDTH-1 downto 0)
    );
end entity axi_skid;

architecture rtl of axi_skid is
    signal s_out_v  : std_logic := '0';
    signal s_out_d  : std_logic_vector(G_WIDTH-1 downto 0) := (others => '0');
    signal s_skid_v : std_logic := '0';
    signal s_skid_d : std_logic_vector(G_WIDTH-1 downto 0) := (others => '0');
    signal s_rdy    : std_logic := '0';
begin
    o_valid <= s_out_v;
    o_data <= s_out_d;
    o_ready <= s_rdy;

    process(i_clk)
        variable v_in, v_out : boolean;
        variable v_skid_v : std_logic;
    begin
        if rising_edge(i_clk) then
            v_in := i_valid = '1' and s_rdy = '1';     -- upstream handshake (never while the skid is full)
            v_out := s_out_v = '1' and i_ready = '1';  -- downstream handshake
            v_skid_v := s_skid_v;

            if s_out_v = '0' or v_out then
                -- the output register is free after this edge: the skid word goes first, else the new word
                if s_skid_v = '1' then
                    s_out_d <= s_skid_d;
                    s_out_v <= '1';
                    v_skid_v := '0';
                elsif v_in then
                    s_out_d <= i_data;
                    s_out_v <= '1';
                else
                    s_out_v <= '0';
                end if;
            elsif v_in then
                -- the output is stalled: park the accepted word in the skid register
                s_skid_d <= i_data;
                v_skid_v := '1';
            end if;
            s_skid_v <= v_skid_v;
            s_rdy <= not v_skid_v;

            if i_rst = '1' then
                s_out_v <= '0';
                s_skid_v <= '0';
                s_rdy <= '0';
            end if;
        end if;
    end process;
end architecture rtl;
