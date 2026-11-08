-- integration test: conv_engine_v1 (loop_nest + addr_gen + mac_int8 + conv_core_v1) with a command level DDR model
-- the model stands in for axi_master_rd and axi_master_wr, with random ready delays and response latencies
-- G_LAYER is a golden layer (stem, b1c1, b1c2, b2c1, b2c2, b2sc, b3c1, b3c2, b3sc) compared with <layer>_acc.mem,
-- or a small layer with random data and a reference convolution in this file (tiny_a to tiny_e)
-- tiny_e with a large G_MAX_WLAT and a small G_FIFO checks that i_ce is held back before the result fifo overflows
-- checks: every result word written once with the right bytes, nothing else written, read counts (x only at
-- non-padding positions, bias once per output element), protocol rules, o_done after the last write, o_error, second run
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/{loop_nest,addr_gen,mac_int8,conv_core_v1,conv_engine_v1}.vhd tests/integration/tb_conv_engine_v1.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_conv_engine_v1 -gG_LAYER=tiny_b
--   ghdl -r --std=08 --workdir=<dir> tb_conv_engine_v1 -gG_LAYER=b3sc -gG_FRAME=f000 -gG_RUNS=1
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.camus_pkg.all;

entity tb_conv_engine_v1 is
    generic (
        G_LAYER   : string := "tiny_a";
        G_FRAME   : string := "f000";
        G_EXPORT  : string := "../build/export";
        G_RUNS    : positive := 2;       -- runs on the same instance, error injection only in the first
        G_MAX_LAT : natural := 3;        -- read response latency, 0 to this many clocks
        G_MAX_WLAT : natural := 3;       -- write response latency, a slow one fills the result fifo
        G_READY   : natural := 70;       -- chance in percent that a ready is high in a clock
        G_ERR_RD  : natural := 0;        -- this read response has an error in run 1 (0 = none)
        G_ERR_WR  : natural := 0;        -- this write response has an error in run 1 (0 = none)
        G_FIFO    : positive := 8
    );
end entity tb_conv_engine_v1;

architecture sim of tb_conv_engine_v1 is
    constant C_PERIOD   : time := 5 ns;   -- 200 MHz
    constant C_IN_BASE  : natural := 16#10000000#;
    constant C_W_BASE   : natural := 16#20000000#;
    constant C_B_BASE   : natural := 16#30000000#;
    constant C_OUT_BASE : natural := 16#40000000#;
    constant C_MEM_SIZE : natural := 65536;
    constant C_BEAT     : natural := AXI_DATA_W / 8;

    type t_shape is record
        k, c, h, w, fy, fx, stride, pad, inl, outl : natural;
        golden : boolean;
    end record;

    function get_shape(name : string) return t_shape is
    begin
        if    name = "stem" then return (16, 1, 112, 112, 3, 3, 2, 1, 1, 16, true);
        elsif name = "b1c1" then return (16, 16, 56, 56, 3, 3, 1, 1, 16, 16, true);
        elsif name = "b1c2" then return (16, 16, 56, 56, 3, 3, 1, 1, 16, 16, true);
        elsif name = "b2c1" then return (32, 16, 56, 56, 3, 3, 2, 1, 16, 16, true);
        elsif name = "b2c2" then return (32, 32, 28, 28, 3, 3, 1, 1, 16, 16, true);
        elsif name = "b2sc" then return (32, 16, 56, 56, 1, 1, 2, 0, 16, 16, true);
        elsif name = "b3c1" then return (64, 32, 28, 28, 3, 3, 2, 1, 16, 16, true);
        elsif name = "b3c2" then return (64, 64, 14, 14, 3, 3, 1, 1, 16, 16, true);
        elsif name = "b3sc" then return (64, 32, 28, 28, 1, 1, 2, 0, 16, 16, true);
        elsif name = "tiny_a" then return (5, 3, 7, 6, 3, 3, 1, 1, 1, 16, false);     -- raw layout in, 5 of 16 lanes out
        elsif name = "tiny_b" then return (18, 20, 6, 5, 3, 3, 2, 1, 16, 16, false);  -- two channel blocks in and out, stride 2
        elsif name = "tiny_c" then return (3, 17, 5, 7, 1, 1, 2, 0, 16, 1, false);    -- 1x1, raw layout out
        elsif name = "tiny_d" then return (2, 1, 4, 4, 3, 3, 1, 1, 1, 1, false);
        elsif name = "tiny_e" then return (4, 1, 5, 5, 1, 1, 1, 0, 1, 1, false);      -- one result per MAC, stresses the result fifo
        end if;
        report "unknown layer " & name severity failure;
        return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false);
    end function get_shape;

    constant C_SHAPE : t_shape := get_shape(G_LAYER);
    constant C_OH    : natural := out_dim(C_SHAPE.h, C_SHAPE.fy, C_SHAPE.stride, C_SHAPE.pad);
    constant C_OW    : natural := out_dim(C_SHAPE.w, C_SHAPE.fx, C_SHAPE.stride, C_SHAPE.pad);
    constant C_TERMS : natural := C_SHAPE.k * C_OH * C_OW * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx;
    constant C_OUTS  : natural := C_SHAPE.k * C_OH * C_OW;

    -- window positions that fall inside the input, the input is read once per channel, output channel and position
    function count_inside return natural is
        variable n : natural := 0;
        variable iy, ix : integer;
    begin
        for oy in 0 to C_OH - 1 loop
            for ox in 0 to C_OW - 1 loop
                for fy in 0 to C_SHAPE.fy - 1 loop
                    for fx in 0 to C_SHAPE.fx - 1 loop
                        iy := oy * C_SHAPE.stride - C_SHAPE.pad + fy;
                        ix := ox * C_SHAPE.stride - C_SHAPE.pad + fx;
                        if iy >= 0 and iy < C_SHAPE.h and ix >= 0 and ix < C_SHAPE.w then
                            n := n + 1;
                        end if;
                    end loop;
                end loop;
            end loop;
        end loop;
        return n;
    end function count_inside;
    constant C_X_READS : natural := C_SHAPE.k * C_SHAPE.c * count_inside;

    signal s_clk, s_rst, s_start : std_logic := '0';
    signal s_cfg : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => to_unsigned(C_IN_BASE, AXI_ADDR_W), w_base => to_unsigned(C_W_BASE, AXI_ADDR_W),
        b_base => to_unsigned(C_B_BASE, AXI_ADDR_W), out_base => to_unsigned(C_OUT_BASE, AXI_ADDR_W));
    signal s_busy, s_done, s_error : std_logic;
    signal s_cycles : unsigned(31 downto 0);

    signal s_rd_cmd_valid, s_rd_cmd_ready : std_logic;
    signal s_rd_cmd_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_rd_cmd_len : unsigned(7 downto 0);
    signal s_rd_rsp_valid, s_rd_rsp_ready, s_rd_rsp_last, s_rd_rsp_error : std_logic := '0';
    signal s_rd_rsp_data : std_logic_vector(AXI_DATA_W-1 downto 0) := (others => '0');

    signal s_wr_cmd_valid, s_wr_data_valid, s_wr_last : std_logic;
    signal s_wr_cmd_ready, s_wr_data_ready : std_logic := '0';
    signal s_wr_cmd_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_wr_cmd_len : unsigned(7 downto 0);
    signal s_wr_data : std_logic_vector(AXI_DATA_W-1 downto 0);
    signal s_wr_strb : std_logic_vector(C_BEAT-1 downto 0);
    signal s_wr_done, s_wr_error : std_logic := '0';

    signal s_finished : boolean := false;
begin

    clk_gen : process
    begin
        while not s_finished loop
            s_clk <= '0';
            wait for C_PERIOD / 2;
            s_clk <= '1';
            wait for C_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    dut : entity work.conv_engine_v1
        generic map (G_FIFO_DEPTH => G_FIFO)
        port map (
            i_clk => s_clk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start,
            o_busy => s_busy, o_done => s_done, o_error => s_error, o_cycles => s_cycles,
            o_rd_cmd_valid => s_rd_cmd_valid, i_rd_cmd_ready => s_rd_cmd_ready, o_rd_cmd_addr => s_rd_cmd_addr,
            o_rd_cmd_len => s_rd_cmd_len,
            i_rd_rsp_valid => s_rd_rsp_valid, o_rd_rsp_ready => s_rd_rsp_ready, i_rd_rsp_data => s_rd_rsp_data,
            i_rd_rsp_last => s_rd_rsp_last, i_rd_rsp_error => s_rd_rsp_error,
            o_wr_cmd_valid => s_wr_cmd_valid, i_wr_cmd_ready => s_wr_cmd_ready, o_wr_cmd_addr => s_wr_cmd_addr,
            o_wr_cmd_len => s_wr_cmd_len,
            o_wr_data_valid => s_wr_data_valid, i_wr_data_ready => s_wr_data_ready, o_wr_data => s_wr_data,
            o_wr_strb => s_wr_strb, o_wr_last => s_wr_last,
            i_wr_done => s_wr_done, i_wr_error => s_wr_error
        );

    -- DDR model, test control and checks in one process, so the model state needs no sharing
    ddr : process
        type t_i8_mem is array (0 to C_MEM_SIZE - 1) of act_t;
        type t_i32_mem is array (0 to C_MEM_SIZE - 1) of acc_t;
        type t_bool_mem is array (0 to C_MEM_SIZE - 1) of boolean;
        type t_mask_mem is array (0 to C_MEM_SIZE - 1) of std_logic_vector(3 downto 0);
        variable v_x_mem, v_w_mem : t_i8_mem := (others => (others => '0'));
        variable v_b_mem, v_exp_mem, v_out_mem : t_i32_mem := (others => (others => '0'));
        variable v_exp_valid : t_bool_mem := (others => false);
        variable v_wmask : t_mask_mem := (others => "0000");
        variable v_n_x, v_n_w, v_n_b, v_n_exp : natural := 0;

        variable v_seed1, v_seed2 : positive := 5;
        variable v_errors : natural := 0;
        variable v_cyc : natural;

        -- read model
        variable v_rphase, v_rwait : natural := 0;
        variable v_rd_addr : natural := 0;
        variable v_rd_count, v_rd_x, v_rd_w, v_rd_b : natural := 0;
        variable v_rd_inject : boolean := false;
        variable v_beat : std_logic_vector(AXI_DATA_W-1 downto 0);
        -- write model
        variable v_wphase, v_wwait : natural := 0;
        variable v_have_cmd, v_have_data : boolean := false;
        variable v_wr_addr : natural := 0;
        variable v_wr_data : std_logic_vector(AXI_DATA_W-1 downto 0);
        variable v_wr_strb : std_logic_vector(C_BEAT-1 downto 0);
        variable v_wr_count : natural := 0;
        variable v_wr_inject : boolean := false;
        -- previous clock, for the rule that valid and the payload stay until the handshake
        variable v_p_rd_v, v_p_rd_r, v_p_wc_v, v_p_wc_r, v_p_wd_v, v_p_wd_r, v_p_rsp_v, v_p_rsp_r : std_logic := '0';
        variable v_p_rd_a, v_p_wc_a : unsigned(AXI_ADDR_W-1 downto 0) := (others => '0');
        variable v_p_wd : std_logic_vector(AXI_DATA_W-1 downto 0) := (others => '0');
        variable v_p_wstrb : std_logic_vector(C_BEAT-1 downto 0) := (others => '0');
        variable v_run : natural := 0;
        variable v_exp_err : boolean;

        procedure fail(msg : string) is
        begin
            report msg severity failure;
        end procedure fail;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                if v_errors <= 10 then
                    report msg severity error;
                end if;
            end if;
        end procedure check;

        impure function rnd(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(v_seed1, v_seed2, r);
            return integer(floor(real(lo) + r * (real(hi) - real(lo) + 1.0)));
        end function rnd;

        impure function chance return std_logic is
        begin
            if rnd(0, 99) < G_READY then
                return '1';
            end if;
            return '0';
        end function chance;

        -- one byte of the DDR image, anything outside the three input regions reads as A5
        impure function rd_byte(a : natural) return std_logic_vector is
            variable v_lane : natural;
            variable v_w : acc_t;
        begin
            if a >= C_IN_BASE and a - C_IN_BASE < v_n_x then
                return std_logic_vector(v_x_mem(a - C_IN_BASE));
            elsif a >= C_W_BASE and a - C_W_BASE < v_n_w then
                return std_logic_vector(v_w_mem(a - C_W_BASE));
            elsif a >= C_B_BASE and a - C_B_BASE < 4 * v_n_b then
                v_w := v_b_mem((a - C_B_BASE) / 4);
                v_lane := (a - C_B_BASE) mod 4;
                return std_logic_vector(v_w(8 * v_lane + 7 downto 8 * v_lane));
            end if;
            return x"A5";
        end function rd_byte;

        procedure tick is
            variable v_lane, v_idx : natural;
        begin
            wait until rising_edge(s_clk);

            -- protocol rules: a request that was not accepted stays unchanged
            if v_p_rd_v = '1' and v_p_rd_r = '0' then
                assert s_rd_cmd_valid = '1' and s_rd_cmd_addr = v_p_rd_a report "read command changed before it was accepted" severity failure;
            end if;
            if v_p_wc_v = '1' and v_p_wc_r = '0' then
                assert s_wr_cmd_valid = '1' and s_wr_cmd_addr = v_p_wc_a report "write command changed before it was accepted" severity failure;
            end if;
            if v_p_wd_v = '1' and v_p_wd_r = '0' then
                assert s_wr_data_valid = '1' and s_wr_data = v_p_wd and s_wr_strb = v_p_wstrb
                    report "write data changed before it was accepted" severity failure;
            end if;
            v_p_rd_v := s_rd_cmd_valid; v_p_rd_r := s_rd_cmd_ready; v_p_rd_a := s_rd_cmd_addr;
            v_p_wc_v := s_wr_cmd_valid; v_p_wc_r := s_wr_cmd_ready; v_p_wc_a := s_wr_cmd_addr;
            v_p_wd_v := s_wr_data_valid; v_p_wd_r := s_wr_data_ready; v_p_wd := s_wr_data; v_p_wstrb := s_wr_strb;
            assert s_rd_cmd_len = 0 and s_wr_cmd_len = 0 report "v1 only issues single beat commands" severity failure;
            assert s_wr_last = '1' or s_wr_data_valid = '0' report "wlast is not set on a single beat" severity failure;

            -- read channel: one command at a time, the response waits until it is accepted
            case v_rphase is
                when 0 =>
                    if s_rd_cmd_valid = '1' and s_rd_cmd_ready = '1' then
                        v_rd_addr := to_integer(s_rd_cmd_addr);
                        assert v_rd_addr mod C_BEAT = 0 report "read address is not beat aligned" severity failure;
                        v_rd_count := v_rd_count + 1;
                        if v_rd_addr >= C_OUT_BASE then
                            fail("read from the result region");
                        elsif v_rd_addr >= C_B_BASE then
                            v_rd_b := v_rd_b + 1;
                        elsif v_rd_addr >= C_W_BASE then
                            v_rd_w := v_rd_w + 1;
                        elsif v_rd_addr >= C_IN_BASE then
                            v_rd_x := v_rd_x + 1;
                        else
                            fail("read below the input region");
                        end if;
                        v_rd_inject := v_run = 1 and G_ERR_RD > 0 and v_rd_count = G_ERR_RD;
                        for i in 0 to C_BEAT - 1 loop
                            v_beat(8 * i + 7 downto 8 * i) := rd_byte(v_rd_addr + i);
                        end loop;
                        v_rphase := 1;
                        v_rwait := rnd(0, G_MAX_LAT);
                        s_rd_cmd_ready <= '0';
                    else
                        s_rd_cmd_ready <= chance;
                    end if;
                when 1 =>
                    if v_rwait = 0 then
                        s_rd_rsp_valid <= '1';
                        s_rd_rsp_data <= v_beat;
                        s_rd_rsp_last <= '1';
                        if v_rd_inject then
                            s_rd_rsp_error <= '1';
                        end if;
                        v_rphase := 2;
                    else
                        v_rwait := v_rwait - 1;
                    end if;
                when others =>
                    if s_rd_rsp_valid = '1' and s_rd_rsp_ready = '1' then
                        s_rd_rsp_valid <= '0';
                        s_rd_rsp_error <= '0';
                        s_rd_rsp_data <= (others => 'X');
                        v_rphase := 0;
                    end if;
            end case;

            -- write channels: command and data in any order, one write at a time
            case v_wphase is
                when 0 =>
                    if s_wr_cmd_valid = '1' and s_wr_cmd_ready = '1' then
                        v_wr_addr := to_integer(s_wr_cmd_addr);
                        assert v_wr_addr mod C_BEAT = 0 report "write address is not beat aligned" severity failure;
                        v_have_cmd := true;
                    end if;
                    if s_wr_data_valid = '1' and s_wr_data_ready = '1' then
                        v_wr_data := s_wr_data;
                        v_wr_strb := s_wr_strb;
                        v_have_data := true;
                    end if;
                    if v_have_cmd then s_wr_cmd_ready <= '0'; else s_wr_cmd_ready <= chance; end if;
                    if v_have_data then s_wr_data_ready <= '0'; else s_wr_data_ready <= chance; end if;
                    if v_have_cmd and v_have_data then
                        v_wr_count := v_wr_count + 1;
                        assert v_wr_addr >= C_OUT_BASE report "write below the result region" severity failure;
                        for i in 0 to C_BEAT - 1 loop
                            if v_wr_strb(i) = '1' then
                                v_idx := (v_wr_addr - C_OUT_BASE + i) / 4;
                                v_lane := (v_wr_addr - C_OUT_BASE + i) mod 4;
                                assert v_idx < C_MEM_SIZE report "write beyond the model" severity failure;
                                check(v_wmask(v_idx)(v_lane) = '0', "byte " & integer'image(v_wr_addr - C_OUT_BASE + i) & " written twice");
                                v_wmask(v_idx)(v_lane) := '1';
                                v_out_mem(v_idx)(8 * v_lane + 7 downto 8 * v_lane) := signed(v_wr_data(8 * i + 7 downto 8 * i));
                            end if;
                        end loop;
                        v_wr_inject := v_run = 1 and G_ERR_WR > 0 and v_wr_count = G_ERR_WR;
                        v_wphase := 1;
                        v_wwait := rnd(0, G_MAX_WLAT);
                    end if;
                when 1 =>
                    if v_wwait = 0 then
                        s_wr_done <= '1';
                        if v_wr_inject then
                            s_wr_error <= '1';
                        end if;
                        v_wphase := 2;
                    else
                        v_wwait := v_wwait - 1;
                    end if;
                when others =>
                    s_wr_done <= '0';
                    s_wr_error <= '0';
                    v_have_cmd := false;
                    v_have_data := false;
                    v_wphase := 0;
            end case;
        end procedure tick;

        procedure load_i8(path : string; mem : inout t_i8_mem; n : out natural) is
            file f : text;
            variable st : file_open_status;
            variable l : line;
            variable v : std_logic_vector(7 downto 0);
            variable i : natural := 0;
        begin
            file_open(st, f, path, read_mode);
            assert st = open_ok report "cannot open " & path severity failure;
            while not endfile(f) loop
                readline(f, l);
                hread(l, v);
                mem(i) := signed(v);
                i := i + 1;
            end loop;
            file_close(f);
            n := i;
        end procedure load_i8;

        procedure load_i32(path : string; mem : inout t_i32_mem; n : out natural) is
            file f : text;
            variable st : file_open_status;
            variable l : line;
            variable v : std_logic_vector(31 downto 0);
            variable i : natural := 0;
        begin
            file_open(st, f, path, read_mode);
            assert st = open_ok report "cannot open " & path severity failure;
            while not endfile(f) loop
                readline(f, l);
                hread(l, v);
                mem(i) := signed(v);
                i := i + 1;
            end loop;
            file_close(f);
            n := i;
        end procedure load_i32;

        -- random data and a reference convolution for the small layers
        procedure make_data is
            variable v_acc : integer;
            variable v_iy, v_ix, v_nblk_in, v_nblk_out : natural;
        begin
            v_nblk_in := (C_SHAPE.c + C_SHAPE.inl - 1) / C_SHAPE.inl;
            v_nblk_out := (C_SHAPE.k + C_SHAPE.outl - 1) / C_SHAPE.outl;
            v_n_x := v_nblk_in * C_SHAPE.h * C_SHAPE.w * C_SHAPE.inl;
            v_n_w := C_SHAPE.k * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx;
            v_n_b := C_SHAPE.k;
            v_n_exp := C_OUTS;
            for c in 0 to C_SHAPE.c - 1 loop
                for y in 0 to C_SHAPE.h - 1 loop
                    for x in 0 to C_SHAPE.w - 1 loop
                        v_x_mem(elem_addr(c, y, x, C_SHAPE.h, C_SHAPE.w, C_SHAPE.inl)) := to_signed(rnd(-128, 127), ACT_W);
                    end loop;
                end loop;
            end loop;
            for i in 0 to v_n_w - 1 loop
                v_w_mem(i) := to_signed(rnd(-128, 127), ACT_W);
            end loop;
            for i in 0 to v_n_b - 1 loop
                v_b_mem(i) := to_signed(rnd(-100000, 100000), ACC_W);
            end loop;
            for k in 0 to C_SHAPE.k - 1 loop
                for oy in 0 to C_OH - 1 loop
                    for ox in 0 to C_OW - 1 loop
                        v_acc := to_integer(v_b_mem(k));
                        for c in 0 to C_SHAPE.c - 1 loop
                            for fy in 0 to C_SHAPE.fy - 1 loop
                                for fx in 0 to C_SHAPE.fx - 1 loop
                                    v_iy := oy * C_SHAPE.stride + fy;   -- offset by pad, checked below
                                    v_ix := ox * C_SHAPE.stride + fx;
                                    if v_iy >= C_SHAPE.pad and v_iy - C_SHAPE.pad < C_SHAPE.h
                                       and v_ix >= C_SHAPE.pad and v_ix - C_SHAPE.pad < C_SHAPE.w then
                                        v_acc := v_acc
                                            + to_integer(v_x_mem(elem_addr(c, v_iy - C_SHAPE.pad, v_ix - C_SHAPE.pad,
                                                                           C_SHAPE.h, C_SHAPE.w, C_SHAPE.inl)))
                                            * to_integer(v_w_mem(((k * C_SHAPE.c + c) * C_SHAPE.fy + fy) * C_SHAPE.fx + fx));
                                    end if;
                                end loop;
                            end loop;
                        end loop;
                        v_exp_mem(elem_addr(k, oy, ox, C_OH, C_OW, C_SHAPE.outl)) := to_signed(v_acc, ACC_W);
                        v_exp_valid(elem_addr(k, oy, ox, C_OH, C_OW, C_SHAPE.outl)) := true;
                    end loop;
                end loop;
            end loop;
            assert v_nblk_out * C_OH * C_OW * C_SHAPE.outl < C_MEM_SIZE report "result array too small" severity failure;
        end procedure make_data;

        procedure compare is
            variable v_bad : natural := 0;
        begin
            for i in 0 to C_MEM_SIZE - 1 loop
                if v_exp_valid(i) then
                    if v_wmask(i) /= "1111" then
                        check(false, "result " & integer'image(i) & " was not fully written, mask " & to_string(v_wmask(i)));
                    elsif v_out_mem(i) /= v_exp_mem(i) then
                        check(false, "result " & integer'image(i) & ": got " & integer'image(to_integer(v_out_mem(i)))
                              & ", expected " & integer'image(to_integer(v_exp_mem(i))));
                    end if;
                else
                    check(v_wmask(i) = "0000", "word " & integer'image(i) & " was written but is not a result");
                end if;
            end loop;
        end procedure compare;
    begin
        -- data
        if C_SHAPE.golden then
            load_i8(G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_in.mem", v_x_mem, v_n_x);
            load_i8(G_EXPORT & "/" & G_LAYER & "_w.mem", v_w_mem, v_n_w);
            load_i32(G_EXPORT & "/" & G_LAYER & "_b.mem", v_b_mem, v_n_b);
            load_i32(G_EXPORT & "/golden/" & G_FRAME & "/" & G_LAYER & "_acc.mem", v_exp_mem, v_n_exp);
            assert v_n_x = C_SHAPE.c * C_SHAPE.h * C_SHAPE.w report "input size " & integer'image(v_n_x) severity failure;
            assert v_n_w = C_SHAPE.k * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx report "weight count " & integer'image(v_n_w) severity failure;
            assert v_n_b = C_SHAPE.k report "bias count " & integer'image(v_n_b) severity failure;
            assert v_n_exp = C_OUTS report "expected count " & integer'image(v_n_exp) severity failure;
            for i in 0 to v_n_exp - 1 loop
                v_exp_valid(i) := true;
            end loop;
        else
            make_data;
        end if;

        s_rst <= '1';
        for i in 1 to 3 loop
            tick;
        end loop;
        s_rst <= '0';
        tick;

        for run in 1 to G_RUNS loop
            v_run := run;
            v_rd_count := 0; v_rd_x := 0; v_rd_w := 0; v_rd_b := 0; v_wr_count := 0;
            v_wmask := (others => "0000");
            v_out_mem := (others => to_signed(-1, ACC_W));
            s_cfg.k <= C_SHAPE.k;
            s_cfg.c <= C_SHAPE.c;
            s_cfg.h <= C_SHAPE.h;
            s_cfg.w <= C_SHAPE.w;
            s_cfg.fy <= C_SHAPE.fy;
            s_cfg.fx <= C_SHAPE.fx;
            s_cfg.stride <= C_SHAPE.stride;
            s_cfg.pad <= C_SHAPE.pad;
            s_cfg.in_lanes <= C_SHAPE.inl;
            s_cfg.out_lanes <= C_SHAPE.outl;
            tick;
            s_start <= '1';
            tick;
            s_start <= '0';
            tick;
            check(s_busy = '1', "busy is not high one clock after start");

            v_cyc := 0;
            while s_done /= '1' loop
                tick;
                v_cyc := v_cyc + 1;
                if v_cyc > C_TERMS * 60 + 100000 then
                    fail("timeout, the engine did not finish");
                end if;
            end loop;
            -- the values read now are those of the clock in which o_done was high
            check(s_busy = '0', "busy is still high with done");
            check(v_rphase = 0 and v_wphase = 0 and not v_have_cmd and not v_have_data, "done while a transfer is pending");
            v_exp_err := run = 1 and (G_ERR_RD > 0 or G_ERR_WR > 0);
            check((s_error = '1') = v_exp_err, "o_error is " & std_logic'image(s_error) & " in run " & integer'image(run));
            compare;
            check(v_rd_w = C_TERMS, "weight reads " & integer'image(v_rd_w) & ", expected " & integer'image(C_TERMS));
            check(v_rd_b = C_OUTS, "bias reads " & integer'image(v_rd_b) & ", expected " & integer'image(C_OUTS));
            check(v_rd_x = C_X_READS, "input reads " & integer'image(v_rd_x) & ", expected " & integer'image(C_X_READS));
            check(v_wr_count = C_OUTS, "write commands " & integer'image(v_wr_count) & ", expected " & integer'image(C_OUTS));
            check(to_integer(s_cycles) > C_TERMS, "o_cycles " & integer'image(to_integer(s_cycles)) & " is not above the MAC count");
            report G_LAYER & " run " & integer'image(run) & ": " & integer'image(v_wr_count) & " results, " & integer'image(v_rd_x) & " x, "
                   & integer'image(v_rd_w) & " w and " & integer'image(v_rd_b) & " bias reads, " & integer'image(to_integer(s_cycles))
                   & " cycles for " & integer'image(C_TERMS) & " MACs, error flag " & std_logic'image(s_error);
            tick;
            check(s_done = '0' and s_error = '0', "o_done or o_error is longer than one clock");
            for i in 1 to 5 loop
                tick;
                check(s_busy = '0' and s_done = '0', "engine is not idle after done");
            end loop;
        end loop;

        report "errors: " & integer'image(v_errors);
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process ddr;

end architecture sim;
