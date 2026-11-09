-- Author: Olimjon Mirzayusupov
-- integration test: conv_engine_v1 -> axi_ddr_master (axi_master_rd + axi_master_wr) -> axi_mem_model over real AXI4
-- built from tb_conv_engine_v1: same layers (golden stem .. b3sc from G_EXPORT, or tiny_a .. tiny_e with random data and
-- a reference convolution here), same expectations, but the command-level memory process is replaced by the masters
-- and the AXI4 slave model (random ready, random latency, protocol checks that stop the simulation on any violation)
-- memory map (one model region each, 256 KB): input 0x1000_0000, weights 0x2000_0000, bias 0x3000_0000,
-- results 0x4000_0000; the data is preloaded through the model's backdoor, the result region is filled with x"5A"
-- before every run and read back through the backdoor after o_done
-- checks: every result word, nothing else written (the x"5A" fill and a margin after the results stay untouched),
-- AR counts per region on the bus (x only at non-padding positions, w per MAC, bias once per output element; every
-- engine command is one burst, single beats are never split), one AW per result, every B taken before o_done,
-- RREADY/BREADY always high after reset, o_error only in run 1 when an error is injected (G_ERR = 1: SLVERR on the
-- first weight beat, G_ERR = 2: SLVERR on the first result beat, which the model then does not write), second run
-- the data width is camus_pkg.AXI_DATA_W, so BOARD selects 64 (ZEDBOARD) or 128 (ULTRA96)
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/axi_pkg.vhd src/compute-engine/{loop_nest,addr_gen,mac_int8,conv_core_v1,conv_engine_v1}.vhd \
--        src/interface/{sync_fifo,axi_skid,axi_master_rd,axi_master_wr,axi_ddr_master}.vhd tests/models/axi_mem_model.vhd \
--        tests/integration/tb_conv_engine_axi.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_conv_engine_axi
--   ghdl -r --std=08 --workdir=<dir> tb_conv_engine_axi -gG_LAYER=tiny_b
--   ghdl -r --std=08 --workdir=<dir> tb_conv_engine_axi -gG_LAYER=b3sc -gG_FRAME=f000 -gG_ERR=1
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.camus_pkg.all;
use work.axi_pkg.all;
use work.axi_mem_model_pkg.all;
use work.axi_mem_model_shared.all;

entity tb_conv_engine_axi is
    generic (
        G_LAYER      : string := "tiny_a";
        G_FRAME      : string := "f000";
        G_EXPORT     : string := "../build/export";
        G_RUNS       : positive := 2;      -- runs on the same instance, error injection only in the first
        G_RD_LAT_MAX : natural := 3;       -- model read latency, 0 to this many extra clocks
        G_WR_LAT_MAX : natural := 3;       -- model write response latency
        G_READY_PCT  : natural := 70;      -- model AR/AW/W ready chance in percent
        G_ERR        : natural := 0;       -- 0 none, 1 SLVERR on the first weight beat, 2 on the first result beat (run 1)
        G_FIFO       : positive := 8;      -- engine result fifo
        G_SEED       : positive := 1
    );
end entity tb_conv_engine_axi;

architecture sim of tb_conv_engine_axi is
    constant C_PERIOD   : time := 5 ns;   -- 200 MHz
    constant C_IN_BASE  : natural := 16#10000000#;
    constant C_W_BASE   : natural := 16#20000000#;
    constant C_B_BASE   : natural := 16#30000000#;
    constant C_OUT_BASE : natural := 16#40000000#;
    constant C_REGION   : natural := 262144;
    constant C_MEM_SIZE : natural := C_REGION / 4;   -- int32 words in the result region
    constant C_BEAT     : natural := AXI_DATA_W / 8;
    constant C_ID_W     : positive := 2;
    constant C_FILL     : std_logic_vector(7 downto 0) := x"5A";
    constant C_MARGIN   : natural := 256;            -- bytes after the results that must stay untouched

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
        elsif name = "tiny_a" then return (5, 3, 7, 6, 3, 3, 1, 1, 1, 16, false);
        elsif name = "tiny_b" then return (18, 20, 6, 5, 3, 3, 2, 1, 16, 16, false);
        elsif name = "tiny_c" then return (3, 17, 5, 7, 1, 1, 2, 0, 16, 1, false);
        elsif name = "tiny_d" then return (2, 1, 4, 4, 3, 3, 1, 1, 1, 1, false);
        elsif name = "tiny_e" then return (4, 1, 5, 5, 1, 1, 1, 0, 1, 1, false);
        end if;
        report "unknown layer " & name severity failure;
        return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false);
    end function get_shape;

    constant C_SHAPE : t_shape := get_shape(G_LAYER);
    constant C_OH    : natural := out_dim(C_SHAPE.h, C_SHAPE.fy, C_SHAPE.stride, C_SHAPE.pad);
    constant C_OW    : natural := out_dim(C_SHAPE.w, C_SHAPE.fx, C_SHAPE.stride, C_SHAPE.pad);
    constant C_TERMS : natural := C_SHAPE.k * C_OH * C_OW * C_SHAPE.c * C_SHAPE.fy * C_SHAPE.fx;
    constant C_OUTS  : natural := C_SHAPE.k * C_OH * C_OW;
    -- int32 words of the result layout, padding lanes included
    constant C_OUT_WORDS : natural := ((C_SHAPE.k + C_SHAPE.outl - 1) / C_SHAPE.outl) * C_OH * C_OW * C_SHAPE.outl;

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

    -- SLVERR window of the model: the first weight beat (G_ERR = 1) or the first result beat (G_ERR = 2)
    function err_lo return natural is
    begin
        if G_ERR = 1 then
            return C_W_BASE;
        elsif G_ERR = 2 then
            return C_OUT_BASE;
        end if;
        return 0;
    end function err_lo;
    constant C_ERR_LO : natural := err_lo;
    constant C_ERR_HI : natural := C_ERR_LO + C_BEAT * boolean'pos(G_ERR > 0);

    signal s_clk, s_rst, s_start : std_logic := '0';
    signal s_err_en : boolean := false;
    signal s_cfg : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => to_unsigned(C_IN_BASE, AXI_ADDR_W), w_base => to_unsigned(C_W_BASE, AXI_ADDR_W),
        b_base => to_unsigned(C_B_BASE, AXI_ADDR_W), out_base => to_unsigned(C_OUT_BASE, AXI_ADDR_W));
    signal s_busy, s_done, s_error : std_logic;
    signal s_cycles : unsigned(31 downto 0);

    -- engine <-> axi_ddr_master
    signal s_rd_cmd_valid, s_rd_cmd_ready : std_logic;
    signal s_rd_cmd_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_rd_cmd_len : unsigned(7 downto 0);
    signal s_rd_rsp_valid, s_rd_rsp_ready, s_rd_rsp_last, s_rd_rsp_error : std_logic;
    signal s_rd_rsp_data : std_logic_vector(AXI_DATA_W-1 downto 0);
    signal s_wr_cmd_valid, s_wr_cmd_ready, s_wr_data_valid, s_wr_data_ready, s_wr_last : std_logic;
    signal s_wr_cmd_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_wr_cmd_len : unsigned(7 downto 0);
    signal s_wr_data : std_logic_vector(AXI_DATA_W-1 downto 0);
    signal s_wr_strb : std_logic_vector(C_BEAT-1 downto 0);
    signal s_wr_done, s_wr_error : std_logic;

    -- axi_ddr_master <-> axi_mem_model
    signal m_arid, m_rid, m_awid, m_bid : std_logic_vector(C_ID_W-1 downto 0);
    signal m_araddr, m_awaddr : std_logic_vector(AXI_ADDR_W-1 downto 0);
    signal m_arlen, m_awlen : std_logic_vector(7 downto 0);
    signal m_arsize, m_awsize, m_arprot, m_awprot : std_logic_vector(2 downto 0);
    signal m_arburst, m_awburst, m_rresp, m_bresp : std_logic_vector(1 downto 0);
    signal m_arcache, m_awcache, m_arqos, m_awqos : std_logic_vector(3 downto 0);
    signal m_arlock, m_awlock : std_logic;
    signal m_arvalid, m_arready, m_rlast, m_rvalid, m_rready : std_logic;
    signal m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready : std_logic;
    signal m_rdata, m_wdata : std_logic_vector(AXI_DATA_W-1 downto 0);
    signal m_wstrb : std_logic_vector(C_BEAT-1 downto 0);

    signal s_finished : boolean := false;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;

    u_engine : entity work.conv_engine_v1
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

    -- the engine's ports map name for name; the single read stream uses element 0 of the per-stream vectors
    u_link : entity work.axi_ddr_master
        generic map (
            G_N_RD   => 1,
            G_ID_W   => C_ID_W,
            G_DATA_W => AXI_DATA_W
        )
        port map (
            i_clk => s_clk, i_rst => s_rst,
            i_rd_cmd_valid(0) => s_rd_cmd_valid, o_rd_cmd_ready(0) => s_rd_cmd_ready,
            i_rd_cmd_addr => s_rd_cmd_addr, i_rd_cmd_len => s_rd_cmd_len,
            o_rd_rsp_valid(0) => s_rd_rsp_valid, i_rd_rsp_ready(0) => s_rd_rsp_ready, o_rd_rsp_data => s_rd_rsp_data,
            o_rd_rsp_last(0) => s_rd_rsp_last, o_rd_rsp_error(0) => s_rd_rsp_error,
            i_wr_cmd_valid => s_wr_cmd_valid, o_wr_cmd_ready => s_wr_cmd_ready,
            i_wr_cmd_addr => s_wr_cmd_addr, i_wr_cmd_len => s_wr_cmd_len,
            i_wr_data_valid => s_wr_data_valid, o_wr_data_ready => s_wr_data_ready,
            i_wr_data => s_wr_data, i_wr_strb => s_wr_strb, i_wr_last => s_wr_last,
            o_wr_done => s_wr_done, o_wr_error => s_wr_error,
            m_axi_arid => m_arid, m_axi_araddr => m_araddr, m_axi_arlen => m_arlen, m_axi_arsize => m_arsize,
            m_axi_arburst => m_arburst, m_axi_arlock => m_arlock, m_axi_arcache => m_arcache, m_axi_arprot => m_arprot,
            m_axi_arqos => m_arqos, m_axi_arvalid => m_arvalid, m_axi_arready => m_arready,
            m_axi_rid => m_rid, m_axi_rdata => m_rdata, m_axi_rresp => m_rresp, m_axi_rlast => m_rlast,
            m_axi_rvalid => m_rvalid, m_axi_rready => m_rready,
            m_axi_awid => m_awid, m_axi_awaddr => m_awaddr, m_axi_awlen => m_awlen, m_axi_awsize => m_awsize,
            m_axi_awburst => m_awburst, m_axi_awlock => m_awlock, m_axi_awcache => m_awcache, m_axi_awprot => m_awprot,
            m_axi_awqos => m_awqos, m_axi_awvalid => m_awvalid, m_axi_awready => m_awready,
            m_axi_wdata => m_wdata, m_axi_wstrb => m_wstrb, m_axi_wlast => m_wlast, m_axi_wvalid => m_wvalid,
            m_axi_wready => m_wready,
            m_axi_bid => m_bid, m_axi_bresp => m_bresp, m_axi_bvalid => m_bvalid, m_axi_bready => m_bready
        );

    u_mem : entity work.axi_mem_model
        generic map (
            G_DATA_W       => AXI_DATA_W,
            G_ID_W         => C_ID_W,
            G_ADDR_W       => AXI_ADDR_W,
            G_MAX_BURST    => AXI_MAX_BURST,
            G_REGION_BYTES => C_REGION,
            G_BASE_0       => C_IN_BASE,
            G_BASE_1       => C_W_BASE,
            G_BASE_2       => C_B_BASE,
            G_BASE_3       => C_OUT_BASE,
            G_READY_PCT    => G_READY_PCT,
            G_RD_LAT_MAX   => G_RD_LAT_MAX,
            G_WR_LAT_MAX   => G_WR_LAT_MAX,
            G_REORDER      => true,
            G_ACCEPT       => 8,
            G_ERR_ADDR_LO  => C_ERR_LO,
            G_ERR_ADDR_HI  => C_ERR_HI,
            G_SEED         => G_SEED
        )
        port map (
            i_clk => s_clk, i_rst => s_rst, i_err_en => s_err_en,
            s_axi_arid => m_arid, s_axi_araddr => m_araddr, s_axi_arlen => m_arlen, s_axi_arsize => m_arsize,
            s_axi_arburst => m_arburst, s_axi_arlock => m_arlock, s_axi_arcache => m_arcache, s_axi_arprot => m_arprot,
            s_axi_arqos => m_arqos, s_axi_arvalid => m_arvalid, s_axi_arready => m_arready,
            s_axi_rid => m_rid, s_axi_rdata => m_rdata, s_axi_rresp => m_rresp, s_axi_rlast => m_rlast,
            s_axi_rvalid => m_rvalid, s_axi_rready => m_rready,
            s_axi_awid => m_awid, s_axi_awaddr => m_awaddr, s_axi_awlen => m_awlen, s_axi_awsize => m_awsize,
            s_axi_awburst => m_awburst, s_axi_awlock => m_awlock, s_axi_awcache => m_awcache, s_axi_awprot => m_awprot,
            s_axi_awqos => m_awqos, s_axi_awvalid => m_awvalid, s_axi_awready => m_awready,
            s_axi_wdata => m_wdata, s_axi_wstrb => m_wstrb, s_axi_wlast => m_wlast, s_axi_wvalid => m_wvalid,
            s_axi_wready => m_wready,
            s_axi_bid => m_bid, s_axi_bresp => m_bresp, s_axi_bvalid => m_bvalid, s_axi_bready => m_bready
        );

    main : process
        type t_i8_mem is array (0 to C_MEM_SIZE - 1) of act_t;
        type t_i32_mem is array (0 to C_MEM_SIZE - 1) of acc_t;
        type t_bool_mem is array (0 to C_MEM_SIZE - 1) of boolean;
        variable v_x_mem, v_w_mem : t_i8_mem := (others => (others => '0'));
        variable v_b_mem, v_exp_mem : t_i32_mem := (others => (others => '0'));
        variable v_exp_valid : t_bool_mem := (others => false);
        variable v_n_x, v_n_w, v_n_b, v_n_exp : natural := 0;

        variable v_seed1, v_seed2 : positive := 5;
        variable v_errors : natural := 0;
        variable v_cyc, v_clocks : natural;
        variable v_rd_x, v_rd_w, v_rd_b, v_wr_count : natural := 0;
        variable v_aw0, v_b0 : natural;
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

        -- one clock: count the AR and AW handshakes on the bus by region, check RREADY/BREADY
        procedure tick is
            variable v_a : natural;
        begin
            wait until rising_edge(s_clk);
            -- clocks since the reset was released; RREADY and BREADY rise at the first edge out of reset,
            -- so they are seen high from the second one on
            if s_rst = '1' then
                v_clocks := 0;
            else
                v_clocks := v_clocks + 1;
            end if;
            if v_clocks >= 2 then
                check(m_rready = '1' and m_bready = '1', "RREADY or BREADY low after reset");
            end if;
            if m_arvalid = '1' and m_arready = '1' then
                check(unsigned(m_arlen) = 0, "an engine read was split or merged");
                v_a := to_integer(unsigned(m_araddr));
                if v_a >= C_OUT_BASE then
                    fail("read from the result region");
                elsif v_a >= C_B_BASE then
                    v_rd_b := v_rd_b + 1;
                elsif v_a >= C_W_BASE then
                    v_rd_w := v_rd_w + 1;
                elsif v_a >= C_IN_BASE then
                    v_rd_x := v_rd_x + 1;
                else
                    fail("read below the input region");
                end if;
            end if;
            if m_awvalid = '1' and m_awready = '1' then
                check(unsigned(m_awlen) = 0, "an engine write was split or merged");
                check(to_integer(unsigned(m_awaddr)) >= C_OUT_BASE, "write below the result region");
                v_wr_count := v_wr_count + 1;
            end if;
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

        -- random data and a reference convolution for the small layers (as in tb_conv_engine_v1)
        procedure make_data is
            variable v_acc : integer;
            variable v_iy, v_ix, v_nblk_in : natural;
        begin
            v_nblk_in := (C_SHAPE.c + C_SHAPE.inl - 1) / C_SHAPE.inl;
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
                                    v_iy := oy * C_SHAPE.stride + fy;
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
        end procedure make_data;

        -- input, weights and bias into the model memory, little endian
        procedure preload is
        begin
            for i in 0 to v_n_x - 1 loop
                mem_write(to_unsigned(C_IN_BASE + i, 32), std_logic_vector(v_x_mem(i)));
            end loop;
            for i in 0 to v_n_w - 1 loop
                mem_write(to_unsigned(C_W_BASE + i, 32), std_logic_vector(v_w_mem(i)));
            end loop;
            for i in 0 to v_n_b - 1 loop
                mem_write(to_unsigned(C_B_BASE + 4 * i, 32), std_logic_vector(v_b_mem(i)));
            end loop;
        end procedure preload;

        -- the result region and a margin after it get the fill byte before a run
        procedure fill_results is
        begin
            for i in 0 to 4 * C_OUT_WORDS + C_MARGIN - 1 loop
                mem_write(to_unsigned(C_OUT_BASE + i, 32), C_FILL);
            end loop;
        end procedure fill_results;

        -- every result word as expected, every other word and the margin still filled
        procedure compare is
            variable v_word : std_logic_vector(31 downto 0);
            variable v_byte : std_logic_vector(7 downto 0);
            variable v_skip : boolean;
        begin
            for i in 0 to C_OUT_WORDS - 1 loop
                mem_read(to_unsigned(C_OUT_BASE + 4 * i, 32), v_word);
                -- in the run with a write error the words of the erroring beat are not written by the model
                v_skip := v_run = 1 and G_ERR = 2 and C_OUT_BASE + 4 * i < C_ERR_HI;
                if v_skip then
                    null;
                elsif v_exp_valid(i) then
                    check(signed(v_word) = v_exp_mem(i), "result " & integer'image(i) & ": got " & integer'image(to_integer(signed(v_word)))
                          & ", expected " & integer'image(to_integer(v_exp_mem(i))));
                else
                    check(v_word = C_FILL & C_FILL & C_FILL & C_FILL, "word " & integer'image(i) & " was written but is not a result");
                end if;
            end loop;
            for i in 0 to C_MARGIN - 1 loop
                mem_read(to_unsigned(C_OUT_BASE + 4 * C_OUT_WORDS + i, 32), v_byte);
                check(v_byte = C_FILL, "byte " & integer'image(i) & " after the results was written");
            end loop;
        end procedure compare;
    begin
        assert 4 * C_OUT_WORDS + C_MARGIN <= C_REGION report "the result layout does not fit the result region" severity failure;
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
        preload;

        v_clocks := 0;
        s_rst <= '1';
        for i in 1 to 3 loop
            tick;
        end loop;
        s_rst <= '0';
        tick;

        for run in 1 to G_RUNS loop
            v_run := run;
            v_rd_x := 0;
            v_rd_w := 0;
            v_rd_b := 0;
            v_wr_count := 0;
            fill_results;
            v_aw0 := axi_stats.get(ST_AW);
            v_b0 := axi_stats.get(ST_B);
            s_err_en <= run = 1 and G_ERR > 0;
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
                if v_cyc > C_TERMS * 3 * (12 + G_RD_LAT_MAX) + 100000 then
                    fail("timeout, the engine did not finish");
                end if;
            end loop;
            check(s_busy = '0', "busy is still high with done");
            check(axi_stats.get(ST_B) - v_b0 = axi_stats.get(ST_AW) - v_aw0, "o_done before every write response was taken");
            v_exp_err := run = 1 and G_ERR > 0;
            check((s_error = '1') = v_exp_err, "o_error is " & std_logic'image(s_error) & " in run " & integer'image(run));
            compare;
            check(v_rd_w = C_TERMS, "weight reads " & integer'image(v_rd_w) & ", expected " & integer'image(C_TERMS));
            check(v_rd_b = C_OUTS, "bias reads " & integer'image(v_rd_b) & ", expected " & integer'image(C_OUTS));
            check(v_rd_x = C_X_READS, "input reads " & integer'image(v_rd_x) & ", expected " & integer'image(C_X_READS));
            check(v_wr_count = C_OUTS, "write bursts " & integer'image(v_wr_count) & ", expected " & integer'image(C_OUTS));
            report G_LAYER & " run " & integer'image(run) & " (" & integer'image(AXI_DATA_W) & " bit): "
                   & integer'image(v_wr_count) & " results, " & integer'image(v_rd_x) & " x, " & integer'image(v_rd_w)
                   & " w and " & integer'image(v_rd_b) & " bias reads, " & integer'image(to_integer(s_cycles))
                   & " cycles for " & integer'image(C_TERMS) & " MACs, error flag " & std_logic'image(s_error);
            s_err_en <= false;
            tick;
            check(s_done = '0' and s_error = '0', "o_done or o_error is longer than one clock");
            for i in 1 to 5 loop
                tick;
                check(s_busy = '0' and s_done = '0', "engine is not idle after done");
            end loop;
        end loop;

        check(axi_stats.get(ST_VIOLATION) = 0, "AXI protocol violations: " & integer'image(axi_stats.get(ST_VIOLATION)));
        report "errors: " & integer'image(v_errors) & ", model: AR " & integer'image(axi_stats.get(ST_AR))
               & ", AW " & integer'image(axi_stats.get(ST_AW)) & ", AR stalls " & integer'image(axi_stats.get(ST_AR_STALL))
               & ", R errors " & integer'image(axi_stats.get(ST_R_ERR)) & ", B errors " & integer'image(axi_stats.get(ST_B_ERR));
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process main;

end architecture sim;
