-- Author: Roman Riazanov
-- conv_accel_top: v1 accelerator IP, axi_lite_regs + conv_engine_v1 + axi_ddr_master (task 2.3)
-- s_axi_*: AXI4-Lite slave from the PS (layer registers, start, status), m_axi_*: AXI4 master to a PS HP port
-- aclk/aresetn are the AXI names, the active-low reset is inverted once here for the internal modules
-- the soft reset pulse of axi_lite_regs is not wired: the masters have no drain logic yet (technical debt TD-3 in
-- docs/plans/axi-ddr-master.md), so a soft reset would leave bursts in flight; it only clears done and error in the registers
-- the master port widths come from camus_pkg (BOARD), the AXI ID width must match the PS HP port or be narrower
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;

entity conv_accel_top is
    generic (
        G_LITE_ADDR_W : natural := 8;      -- byte address bits of the register space, at least 7
        G_ID_W        : positive := 2;     -- AXI ID bits of the master port
        G_FIFO_DEPTH  : natural := 8       -- result fifo of the engine
    );
    port (
        aclk    : in std_logic;
        aresetn : in std_logic;
        -- AXI4-Lite slave, control from the ARM
        s_axi_awaddr  : in  std_logic_vector(G_LITE_ADDR_W-1 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(G_LITE_ADDR_W-1 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;
        -- AXI4 master, read address
        m_axi_arid    : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_araddr  : out std_logic_vector(AXI_ADDR_W-1 downto 0);
        m_axi_arlen   : out std_logic_vector(7 downto 0);
        m_axi_arsize  : out std_logic_vector(2 downto 0);
        m_axi_arburst : out std_logic_vector(1 downto 0);
        m_axi_arlock  : out std_logic;
        m_axi_arcache : out std_logic_vector(3 downto 0);
        m_axi_arprot  : out std_logic_vector(2 downto 0);
        m_axi_arqos   : out std_logic_vector(3 downto 0);
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        -- read data
        m_axi_rid     : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_rdata   : in  std_logic_vector(AXI_DATA_W-1 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rlast   : in  std_logic;
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic;
        -- write address
        m_axi_awid    : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_awaddr  : out std_logic_vector(AXI_ADDR_W-1 downto 0);
        m_axi_awlen   : out std_logic_vector(7 downto 0);
        m_axi_awsize  : out std_logic_vector(2 downto 0);
        m_axi_awburst : out std_logic_vector(1 downto 0);
        m_axi_awlock  : out std_logic;
        m_axi_awcache : out std_logic_vector(3 downto 0);
        m_axi_awprot  : out std_logic_vector(2 downto 0);
        m_axi_awqos   : out std_logic_vector(3 downto 0);
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        -- write data
        m_axi_wdata   : out std_logic_vector(AXI_DATA_W-1 downto 0);
        m_axi_wstrb   : out std_logic_vector(AXI_DATA_W/8-1 downto 0);
        m_axi_wlast   : out std_logic;
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        -- write response
        m_axi_bid     : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic
    );
end entity conv_accel_top;

architecture rtl of conv_accel_top is
    signal s_rst : std_logic;

    -- axi_lite_regs <-> engine
    signal s_cfg : layer_cfg_t;
    signal s_start, s_busy, s_done, s_error : std_logic;
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
    signal s_wr_strb : std_logic_vector(AXI_DATA_W/8-1 downto 0);
    signal s_wr_done, s_wr_error : std_logic;
begin
    s_rst <= not aresetn;

    u_regs : entity work.axi_lite_regs
        generic map (G_ADDR_W => G_LITE_ADDR_W)
        port map (
            i_clk => aclk, i_rst => s_rst,
            s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
            s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb, s_axi_wvalid => s_axi_wvalid,
            s_axi_wready => s_axi_wready,
            s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
            s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
            s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
            s_axi_rready => s_axi_rready,
            o_cfg => s_cfg, o_start => s_start, o_soft_rst => open,
            i_busy => s_busy, i_done => s_done, i_error => s_error, i_cycles => s_cycles
        );

    u_engine : entity work.conv_engine_v1
        generic map (G_FIFO_DEPTH => G_FIFO_DEPTH)
        port map (
            i_clk => aclk, i_rst => s_rst, i_cfg => s_cfg, i_start => s_start,
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

    -- the engine has one read stream, element 0 of the per-stream vectors
    u_link : entity work.axi_ddr_master
        generic map (
            G_N_RD   => 1,
            G_ID_W   => G_ID_W,
            G_DATA_W => AXI_DATA_W
        )
        port map (
            i_clk => aclk, i_rst => s_rst,
            i_rd_cmd_valid(0) => s_rd_cmd_valid, o_rd_cmd_ready(0) => s_rd_cmd_ready,
            i_rd_cmd_addr => s_rd_cmd_addr, i_rd_cmd_len => s_rd_cmd_len,
            o_rd_rsp_valid(0) => s_rd_rsp_valid, i_rd_rsp_ready(0) => s_rd_rsp_ready, o_rd_rsp_data => s_rd_rsp_data,
            o_rd_rsp_last(0) => s_rd_rsp_last, o_rd_rsp_error(0) => s_rd_rsp_error,
            i_wr_cmd_valid => s_wr_cmd_valid, o_wr_cmd_ready => s_wr_cmd_ready,
            i_wr_cmd_addr => s_wr_cmd_addr, i_wr_cmd_len => s_wr_cmd_len,
            i_wr_data_valid => s_wr_data_valid, o_wr_data_ready => s_wr_data_ready,
            i_wr_data => s_wr_data, i_wr_strb => s_wr_strb, i_wr_last => s_wr_last,
            o_wr_done => s_wr_done, o_wr_error => s_wr_error,
            m_axi_arid => m_axi_arid, m_axi_araddr => m_axi_araddr, m_axi_arlen => m_axi_arlen,
            m_axi_arsize => m_axi_arsize, m_axi_arburst => m_axi_arburst, m_axi_arlock => m_axi_arlock,
            m_axi_arcache => m_axi_arcache, m_axi_arprot => m_axi_arprot, m_axi_arqos => m_axi_arqos,
            m_axi_arvalid => m_axi_arvalid, m_axi_arready => m_axi_arready,
            m_axi_rid => m_axi_rid, m_axi_rdata => m_axi_rdata, m_axi_rresp => m_axi_rresp, m_axi_rlast => m_axi_rlast,
            m_axi_rvalid => m_axi_rvalid, m_axi_rready => m_axi_rready,
            m_axi_awid => m_axi_awid, m_axi_awaddr => m_axi_awaddr, m_axi_awlen => m_axi_awlen,
            m_axi_awsize => m_axi_awsize, m_axi_awburst => m_axi_awburst, m_axi_awlock => m_axi_awlock,
            m_axi_awcache => m_axi_awcache, m_axi_awprot => m_axi_awprot, m_axi_awqos => m_axi_awqos,
            m_axi_awvalid => m_axi_awvalid, m_axi_awready => m_axi_awready,
            m_axi_wdata => m_axi_wdata, m_axi_wstrb => m_axi_wstrb, m_axi_wlast => m_axi_wlast,
            m_axi_wvalid => m_axi_wvalid, m_axi_wready => m_axi_wready,
            m_axi_bid => m_axi_bid, m_axi_bresp => m_axi_bresp, m_axi_bvalid => m_axi_bvalid,
            m_axi_bready => m_axi_bready
        );
end architecture rtl;
