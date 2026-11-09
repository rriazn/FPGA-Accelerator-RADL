-- Author: Olimjon Mirzayusupov
-- sync_fifo: synchronous first-word-fall-through FIFO with a registered output, used inside axi_master_rd / axi_master_wr
-- contract (the masters rely on it, see .gateflow/plans/axi-ddr-master.md section F4):
--   a word written at edge E into an empty FIFO is on o_rd_data with o_rd_valid = '1' from edge E+1 (bypass)
--   o_count is the number of words held, output register included, updated at the same edge as the write or pop
--   o_wr_ready is '1' when the count after the current edge is below G_DEPTH
--   o_wr_ready, o_rd_valid, o_rd_data and o_count all come straight from flip-flops
--   a write and a read are valid/ready handshakes; i_wr_valid while o_wr_ready = '0' is a stall, not a write
--   one word per clock when G_DEPTH >= 2 and both sides are ready, one word per two clocks when G_DEPTH = 1
-- storage: an array with asynchronous read (LUTRAM) in front of the output register, meant for depths up to about 64
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sync_fifo is
    generic (
        G_WIDTH : positive;
        G_DEPTH : positive     -- words, output register included
    );
    port (
        i_clk, i_rst : in std_logic;
        i_wr_valid   : in  std_logic;
        o_wr_ready   : out std_logic;
        i_wr_data    : in  std_logic_vector(G_WIDTH-1 downto 0);
        o_rd_valid   : out std_logic;
        i_rd_ready   : in  std_logic;
        o_rd_data    : out std_logic_vector(G_WIDTH-1 downto 0);
        o_count      : out natural range 0 to G_DEPTH
    );
end entity sync_fifo;

architecture rtl of sync_fifo is
    function max_pos(a, b : integer) return positive is
    begin
        if a > b then
            return a;
        end if;
        return b;
    end function max_pos;

    -- the output register holds one word, the array the others (one entry at least, unused when G_DEPTH = 1)
    constant C_MEM_DEPTH : positive := max_pos(G_DEPTH - 1, 1);
    type mem_t is array (0 to C_MEM_DEPTH-1) of std_logic_vector(G_WIDTH-1 downto 0);

    signal s_mem     : mem_t;
    signal s_wp      : natural range 0 to C_MEM_DEPTH-1 := 0;
    signal s_rp      : natural range 0 to C_MEM_DEPTH-1 := 0;
    signal s_mem_cnt : natural range 0 to C_MEM_DEPTH := 0;
    signal s_out_v   : std_logic := '0';
    signal s_out_d   : std_logic_vector(G_WIDTH-1 downto 0) := (others => '0');
    signal s_count   : natural range 0 to G_DEPTH := 0;
    signal s_wr_rdy  : std_logic := '0';
begin
    o_wr_ready <= s_wr_rdy;
    o_rd_valid <= s_out_v;
    o_rd_data <= s_out_d;
    o_count <= s_count;

    process(i_clk)
        variable v_push, v_pop : boolean;
        variable v_to_mem, v_from_mem : boolean;
        variable v_count : natural range 0 to G_DEPTH;
    begin
        if rising_edge(i_clk) then
            v_push := i_wr_valid = '1' and s_wr_rdy = '1';
            v_pop := s_out_v = '1' and i_rd_ready = '1';
            v_to_mem := false;
            v_from_mem := false;

            -- the output register is free after this edge: refill it from the array, else straight from the input
            -- invariant: the array is empty whenever the output register is empty
            if s_out_v = '0' or v_pop then
                if s_mem_cnt > 0 then
                    s_out_d <= s_mem(s_rp);
                    s_out_v <= '1';
                    v_from_mem := true;
                    v_to_mem := v_push;
                elsif v_push then
                    s_out_d <= i_wr_data;
                    s_out_v <= '1';
                else
                    s_out_v <= '0';
                end if;
            else
                v_to_mem := v_push;
            end if;

            assert not (v_to_mem and not v_from_mem and s_mem_cnt = C_MEM_DEPTH)
                report "sync_fifo: array overflow" severity failure;

            if v_to_mem then
                s_mem(s_wp) <= i_wr_data;
                s_wp <= (s_wp + 1) mod C_MEM_DEPTH;
            end if;
            if v_from_mem then
                s_rp <= (s_rp + 1) mod C_MEM_DEPTH;
            end if;
            if v_to_mem and not v_from_mem then
                s_mem_cnt <= s_mem_cnt + 1;
            elsif v_from_mem and not v_to_mem then
                s_mem_cnt <= s_mem_cnt - 1;
            end if;

            -- words held after this edge, the ready flag follows from it
            v_count := s_count;
            if v_push and not v_pop then
                v_count := v_count + 1;
            elsif v_pop and not v_push then
                v_count := v_count - 1;
            end if;
            s_count <= v_count;
            if v_count < G_DEPTH then
                s_wr_rdy <= '1';
            else
                s_wr_rdy <= '0';
            end if;

            if i_rst = '1' then
                s_wp <= 0;
                s_rp <= 0;
                s_mem_cnt <= 0;
                s_out_v <= '0';
                s_count <= 0;
                s_wr_rdy <= '0';
            end if;
        end if;
    end process;
end architecture rtl;
