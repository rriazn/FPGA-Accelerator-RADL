-- Author: Roman Riazanov
-- conv_engine_v1: conv_core_v1 with the command ports of axi_master_rd and axi_master_wr
-- per MAC term: read x (not at padding), w and the bias (first term of an output only), then one i_ce pulse
-- one read command at a time, in order, addresses are aligned to the beat here (assumption, see vhdl-modules.md)
-- results go through a small fifo to axi_master_wr, one write command at a time, i_ce drops before the fifo is full
-- o_done comes after the last write response, o_error is a pulse together with it if any response was not OKAY
-- v1 does not abort on an error, the layer runs to the end
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

use work.camus_pkg.all;

entity conv_engine_v1 is
    generic (
        G_FIFO_DEPTH : natural := 8      -- result fifo, at least 4
    );
    port (
        i_clk, i_rst : in std_logic;
        i_cfg : in layer_cfg_t;
        i_start : in std_logic;
        o_busy, o_done, o_error : out std_logic;     -- done and error are one clock pulses
        o_cycles : out unsigned(31 downto 0);        -- clocks from start until done, write drain included
        -- axi_master_rd command and response
        o_rd_cmd_valid : out std_logic;
        i_rd_cmd_ready : in std_logic;
        o_rd_cmd_addr : out unsigned(AXI_ADDR_W-1 downto 0);
        o_rd_cmd_len : out unsigned(7 downto 0);
        i_rd_rsp_valid : in std_logic;
        o_rd_rsp_ready : out std_logic;
        i_rd_rsp_data : in std_logic_vector(AXI_DATA_W-1 downto 0);
        i_rd_rsp_last : in std_logic;
        i_rd_rsp_error : in std_logic;
        -- axi_master_wr command, data and response
        o_wr_cmd_valid : out std_logic;
        i_wr_cmd_ready : in std_logic;
        o_wr_cmd_addr : out unsigned(AXI_ADDR_W-1 downto 0);
        o_wr_cmd_len : out unsigned(7 downto 0);
        o_wr_data_valid : out std_logic;
        i_wr_data_ready : in std_logic;
        o_wr_data : out std_logic_vector(AXI_DATA_W-1 downto 0);
        o_wr_strb : out std_logic_vector(AXI_DATA_W/8-1 downto 0);
        o_wr_last : out std_logic;
        i_wr_done : in std_logic;
        i_wr_error : in std_logic
    );
end entity conv_engine_v1;

architecture rtl of conv_engine_v1 is
    function log2c(n : positive) return natural is
        variable r : natural := 0;
        variable v : positive := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function log2c;

    constant C_BEAT_BYTES : natural := AXI_DATA_W / 8;
    constant C_OFF_W      : natural := log2c(C_BEAT_BYTES);   -- address bits inside a beat

    type rstate_t is (R_IDLE, R_X_CMD, R_X_RSP, R_W_CMD, R_W_RSP, R_B_CMD, R_B_RSP, R_GO);
    type wstate_t is (W_IDLE, W_SEND, W_RSP);
    type addr_fifo_t is array (0 to G_FIFO_DEPTH-1) of unsigned(AXI_ADDR_W-1 downto 0);
    type data_fifo_t is array (0 to G_FIFO_DEPTH-1) of acc_t;

    -- address of the beat that holds a byte address
    function align(a : unsigned(AXI_ADDR_W-1 downto 0)) return unsigned is
    begin
        return a and not to_unsigned(C_BEAT_BYTES - 1, AXI_ADDR_W);
    end function align;

    -- int8 at a byte address inside a beat
    function pick_i8(beat : std_logic_vector(AXI_DATA_W-1 downto 0); a : unsigned(AXI_ADDR_W-1 downto 0)) return act_t is
        variable v : unsigned(AXI_DATA_W-1 downto 0);
    begin
        v := shift_right(unsigned(beat), 8 * to_integer(a(C_OFF_W-1 downto 0)));
        return signed(v(ACT_W-1 downto 0));
    end function pick_i8;

    -- int32 at a 4 byte aligned address inside a beat
    function pick_i32(beat : std_logic_vector(AXI_DATA_W-1 downto 0); a : unsigned(AXI_ADDR_W-1 downto 0)) return acc_t is
        variable v : unsigned(AXI_DATA_W-1 downto 0);
    begin
        v := shift_right(unsigned(beat), 8 * to_integer(a(C_OFF_W-1 downto 2) & "00"));
        return signed(v(ACC_W-1 downto 0));
    end function pick_i32;

    -- core
    signal s_ce : std_logic;
    signal s_core_busy, s_core_done, s_term_valid, s_x_rd, s_b_rd, s_out_we, s_core_start : std_logic;
    signal s_x_addr, s_w_addr, s_b_addr, s_out_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_out_data : acc_t;
    signal s_x_data, s_w_data : act_t := (others => '0');
    signal s_b_data : acc_t := (others => '0');

    -- read side: addresses of the term being fetched, then the fetched values
    signal s_rstate : rstate_t := R_IDLE;
    signal s_x_addr_q, s_w_addr_q, s_b_addr_q : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_b_rd_q : std_logic;
    signal s_x_f, s_w_f : act_t := (others => '0');
    signal s_b_f : acc_t := (others => '0');

    -- result fifo and write side
    signal s_f_addr : addr_fifo_t;
    signal s_f_data : data_fifo_t;
    signal s_f_wp, s_f_rp : natural range 0 to G_FIFO_DEPTH-1 := 0;
    signal s_f_cnt : natural range 0 to G_FIFO_DEPTH := 0;
    signal s_fifo_ok : std_logic;
    signal s_wstate : wstate_t := W_IDLE;
    signal s_wr_addr : unsigned(AXI_ADDR_W-1 downto 0) := (others => '0');
    signal s_wr_data : acc_t := (others => '0');
    signal s_aw_sent, s_w_sent : std_logic := '0';

    -- control
    signal s_busy : std_logic := '0';
    signal s_core_done_seen : std_logic := '0';
    signal s_err : std_logic := '0';
    signal s_cycles : unsigned(31 downto 0) := (others => '0');
begin
    assert G_FIFO_DEPTH >= 4 report "G_FIFO_DEPTH must be at least 4" severity failure;
    assert AXI_DATA_W >= 32 and 2 ** log2c(AXI_DATA_W) = AXI_DATA_W report "AXI_DATA_W must be a power of two of at least 32" severity failure;

    u_core : entity work.conv_core_v1
        port map (
            i_clk => i_clk, i_rst => i_rst, i_ce => s_ce, i_cfg => i_cfg, i_start => s_core_start,
            o_busy => s_core_busy, o_done => s_core_done, o_cycles => open,
            o_term_valid => s_term_valid, o_x_addr => s_x_addr, o_w_addr => s_w_addr, o_b_addr => s_b_addr,
            o_x_rd => s_x_rd, o_b_rd => s_b_rd,
            i_x_data => s_x_data, i_w_data => s_w_data, i_b_data => s_b_data,
            o_out_we => s_out_we, o_out_addr => s_out_addr, o_out_data => s_out_data
        );

    s_core_start <= i_start and not s_busy;

    -- Up to 2 results are in flight (one strobe now, one from this ce), so 3 free places are kept in reserve
    s_fifo_ok <= '1' when s_f_cnt <= G_FIFO_DEPTH - 3 else '0';

    -- the core only moves when the data of its term is here (R_GO) or while it has no term (idle, flush)
    s_ce <= s_fifo_ok when (s_rstate = R_IDLE and s_term_valid = '0') or s_rstate = R_GO else '0';

    -- read commands
    o_rd_cmd_valid <= '1' when s_rstate = R_X_CMD or s_rstate = R_W_CMD or s_rstate = R_B_CMD else '0';
    o_rd_cmd_addr <= align(s_x_addr_q) when s_rstate = R_X_CMD else
                     align(s_w_addr_q) when s_rstate = R_W_CMD else
                     align(s_b_addr_q);
    o_rd_cmd_len <= (others => '0');
    o_rd_rsp_ready <= '1' when s_rstate = R_X_RSP or s_rstate = R_W_RSP or s_rstate = R_B_RSP else '0';

    -- write command and data, the int32 goes to its lane of the beat
    o_wr_cmd_valid <= '1' when s_wstate = W_SEND and s_aw_sent = '0' else '0';
    o_wr_cmd_addr <= align(s_wr_addr);
    o_wr_cmd_len <= (others => '0');
    o_wr_data_valid <= '1' when s_wstate = W_SEND and s_w_sent = '0' else '0';
    o_wr_last <= '1';

    process(s_wr_addr, s_wr_data)
        variable v_lane : natural;
        variable v_data : std_logic_vector(AXI_DATA_W-1 downto 0);
        variable v_strb : std_logic_vector(C_BEAT_BYTES-1 downto 0);
    begin
        v_lane := to_integer(s_wr_addr(C_OFF_W-1 downto 2));
        v_data := (others => '0');
        v_strb := (others => '0');
        -- constant slice bounds, a variable bounded slice stops GHDL synthesis
        for i in 0 to C_BEAT_BYTES / 4 - 1 loop
            if i = v_lane then
                v_data(32 * i + 31 downto 32 * i) := std_logic_vector(s_wr_data);
                v_strb(4 * i + 3 downto 4 * i) := "1111";
            end if;
        end loop;
        o_wr_data <= v_data;
        o_wr_strb <= v_strb;
    end process;

    process(i_clk)
        variable v_push, v_pop, v_aw_hs, v_w_hs : boolean;
    begin
        if rising_edge(i_clk) then
            o_done <= '0';
            o_error <= '0';

            -- read side
            case s_rstate is
                when R_IDLE =>
                    if s_term_valid = '1' then
                        s_x_addr_q <= s_x_addr;
                        s_w_addr_q <= s_w_addr;
                        s_b_addr_q <= s_b_addr;
                        s_b_rd_q <= s_b_rd;
                        if s_x_rd = '1' then
                            s_rstate <= R_X_CMD;
                        else
                            s_rstate <= R_W_CMD;
                        end if;
                    end if;
                when R_X_CMD =>
                    if i_rd_cmd_ready = '1' then
                        s_rstate <= R_X_RSP;
                    end if;
                when R_X_RSP =>
                    if i_rd_rsp_valid = '1' then
                        s_x_f <= pick_i8(i_rd_rsp_data, s_x_addr_q);
                        s_err <= s_err or i_rd_rsp_error;
                        s_rstate <= R_W_CMD;
                    end if;
                when R_W_CMD =>
                    if i_rd_cmd_ready = '1' then
                        s_rstate <= R_W_RSP;
                    end if;
                when R_W_RSP =>
                    if i_rd_rsp_valid = '1' then
                        s_w_f <= pick_i8(i_rd_rsp_data, s_w_addr_q);
                        s_err <= s_err or i_rd_rsp_error;
                        if s_b_rd_q = '1' then
                            s_rstate <= R_B_CMD;
                        else
                            s_rstate <= R_GO;
                        end if;
                    end if;
                when R_B_CMD =>
                    if i_rd_cmd_ready = '1' then
                        s_rstate <= R_B_RSP;
                    end if;
                when R_B_RSP =>
                    if i_rd_rsp_valid = '1' then
                        s_b_f <= pick_i32(i_rd_rsp_data, s_b_addr_q);
                        s_err <= s_err or i_rd_rsp_error;
                        s_rstate <= R_GO;
                    end if;
                when R_GO =>
                    -- the core samples its data at this edge
                    if s_ce = '1' then
                        s_x_data <= s_x_f;
                        s_w_data <= s_w_f;
                        s_b_data <= s_b_f;
                        s_rstate <= R_IDLE;
                    end if;
            end case;

            -- write side: results of the core into the fifo, one entry at a time to the master
            v_push := s_out_we = '1';
            v_pop := false;
            v_aw_hs := i_wr_cmd_ready = '1' and s_aw_sent = '0';
            v_w_hs := i_wr_data_ready = '1' and s_w_sent = '0';
            case s_wstate is
                when W_IDLE =>
                    if s_f_cnt > 0 then
                        s_wr_addr <= s_f_addr(s_f_rp);
                        s_wr_data <= s_f_data(s_f_rp);
                        v_pop := true;
                        s_aw_sent <= '0';
                        s_w_sent <= '0';
                        s_wstate <= W_SEND;
                    end if;
                when W_SEND =>
                    if v_aw_hs then
                        s_aw_sent <= '1';
                    end if;
                    if v_w_hs then
                        s_w_sent <= '1';
                    end if;
                    if (s_aw_sent = '1' or v_aw_hs) and (s_w_sent = '1' or v_w_hs) then
                        s_wstate <= W_RSP;
                    end if;
                when W_RSP =>
                    if i_wr_done = '1' then
                        s_err <= s_err or i_wr_error;
                        s_wstate <= W_IDLE;
                    end if;
            end case;

            assert not (v_push and s_f_cnt = G_FIFO_DEPTH and not v_pop) report "result fifo overflow" severity failure;
            if v_push then
                s_f_addr(s_f_wp) <= s_out_addr;
                s_f_data(s_f_wp) <= s_out_data;
                s_f_wp <= (s_f_wp + 1) mod G_FIFO_DEPTH;
            end if;
            if v_pop then
                s_f_rp <= (s_f_rp + 1) mod G_FIFO_DEPTH;
            end if;
            if v_push and not v_pop then
                s_f_cnt <= s_f_cnt + 1;
            elsif v_pop and not v_push then
                s_f_cnt <= s_f_cnt - 1;
            end if;

            -- control: busy from start until the core is done and every result is written
            if s_busy = '0' then
                if i_start = '1' then
                    s_busy <= '1';
                    s_cycles <= (others => '0');
                    s_core_done_seen <= '0';
                    s_err <= '0';
                end if;
            else
                s_cycles <= s_cycles + 1;
                if s_core_done = '1' then
                    s_core_done_seen <= '1';
                end if;
                if s_core_done_seen = '1' and s_f_cnt = 0 and s_wstate = W_IDLE then
                    s_busy <= '0';
                    s_core_done_seen <= '0';
                    o_done <= '1';
                    o_error <= s_err;
                end if;
            end if;

            if i_rst = '1' then
                s_rstate <= R_IDLE;
                s_wstate <= W_IDLE;
                s_f_wp <= 0;
                s_f_rp <= 0;
                s_f_cnt <= 0;
                s_aw_sent <= '0';
                s_w_sent <= '0';
                s_busy <= '0';
                s_core_done_seen <= '0';
                s_err <= '0';
                o_done <= '0';
                o_error <= '0';
            end if;
        end if;
    end process;

    o_busy <= s_busy;
    o_cycles <= s_cycles;
end architecture rtl;
