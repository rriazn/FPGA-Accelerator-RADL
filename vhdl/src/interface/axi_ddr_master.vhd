-- Author: Olimjon Mirzayusupov
-- axi_ddr_master: the accelerator's AXI4 data link to DDR as one block (docs/plans/axi-ddr-master.md, F9)
-- structural only: axi_master_rd drives AR/R, axi_master_wr drives AW/W/B, both with the same ID width, joined into
-- one m_axi bundle for one PS HP port; the top level (task 2.3) instantiates this block
-- the requester port names mirror conv_engine_v1 (o_rd_cmd_valid -> i_rd_cmd_valid, i_wr_done <- o_wr_done, ...)
-- read requesters: G_N_RD streams, flattened buses (stream s is bit s / slice s), stream s uses ARID s
-- every command is a whole transfer of up to 256 beats at a beat-aligned address; the masters split it at 4 KB
-- and at G_MAX_BURST; there is no soft-reset input (technical debt TD-3), only the synchronous active-high i_rst
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;
use work.axi_pkg.all;

entity axi_ddr_master is
    generic (
        G_N_RD          : positive := 1;
        G_ID_W          : positive := 2;
        G_DATA_W        : positive := AXI_DATA_W;
        G_ADDR_W        : positive := AXI_ADDR_W;
        G_MAX_BURST     : positive := AXI_MAX_BURST;
        G_RD_MAX_OUTST  : positive := 8;      -- read bursts in flight (TD-1)
        G_RD_FIFO_BEATS : positive := 64;     -- per read stream, the credit pool (TD-1)
        G_WR_MAX_OUTST  : positive := 8;      -- write bursts waiting for B (TD-1)
        G_WR_FIFO_BEATS : positive := 32;     -- write data FIFO (TD-1)
        G_AXCACHE       : std_logic_vector(3 downto 0) := AXI_AXCACHE
    );
    port (
        i_clk, i_rst    : in  std_logic;
        -- read requesters
        i_rd_cmd_valid  : in  std_logic_vector(G_N_RD-1 downto 0);
        o_rd_cmd_ready  : out std_logic_vector(G_N_RD-1 downto 0);
        i_rd_cmd_addr   : in  unsigned(G_N_RD*G_ADDR_W-1 downto 0);
        i_rd_cmd_len    : in  unsigned(G_N_RD*8-1 downto 0);
        o_rd_rsp_valid  : out std_logic_vector(G_N_RD-1 downto 0);
        i_rd_rsp_ready  : in  std_logic_vector(G_N_RD-1 downto 0);
        o_rd_rsp_data   : out std_logic_vector(G_N_RD*G_DATA_W-1 downto 0);
        o_rd_rsp_last   : out std_logic_vector(G_N_RD-1 downto 0);
        o_rd_rsp_error  : out std_logic_vector(G_N_RD-1 downto 0);
        -- write requester
        i_wr_cmd_valid  : in  std_logic;
        o_wr_cmd_ready  : out std_logic;
        i_wr_cmd_addr   : in  unsigned(G_ADDR_W-1 downto 0);
        i_wr_cmd_len    : in  unsigned(7 downto 0);
        i_wr_data_valid : in  std_logic;
        o_wr_data_ready : out std_logic;
        i_wr_data       : in  std_logic_vector(G_DATA_W-1 downto 0);
        i_wr_strb       : in  std_logic_vector(G_DATA_W/8-1 downto 0);
        i_wr_last       : in  std_logic;
        o_wr_done       : out std_logic;
        o_wr_error      : out std_logic;
        -- AXI4 master, read address
        m_axi_arid      : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_araddr    : out std_logic_vector(G_ADDR_W-1 downto 0);
        m_axi_arlen     : out std_logic_vector(7 downto 0);
        m_axi_arsize    : out std_logic_vector(2 downto 0);
        m_axi_arburst   : out std_logic_vector(1 downto 0);
        m_axi_arlock    : out std_logic;
        m_axi_arcache   : out std_logic_vector(3 downto 0);
        m_axi_arprot    : out std_logic_vector(2 downto 0);
        m_axi_arqos     : out std_logic_vector(3 downto 0);
        m_axi_arvalid   : out std_logic;
        m_axi_arready   : in  std_logic;
        -- read data
        m_axi_rid       : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_rdata     : in  std_logic_vector(G_DATA_W-1 downto 0);
        m_axi_rresp     : in  std_logic_vector(1 downto 0);
        m_axi_rlast     : in  std_logic;
        m_axi_rvalid    : in  std_logic;
        m_axi_rready    : out std_logic;
        -- write address
        m_axi_awid      : out std_logic_vector(G_ID_W-1 downto 0);
        m_axi_awaddr    : out std_logic_vector(G_ADDR_W-1 downto 0);
        m_axi_awlen     : out std_logic_vector(7 downto 0);
        m_axi_awsize    : out std_logic_vector(2 downto 0);
        m_axi_awburst   : out std_logic_vector(1 downto 0);
        m_axi_awlock    : out std_logic;
        m_axi_awcache   : out std_logic_vector(3 downto 0);
        m_axi_awprot    : out std_logic_vector(2 downto 0);
        m_axi_awqos     : out std_logic_vector(3 downto 0);
        m_axi_awvalid   : out std_logic;
        m_axi_awready   : in  std_logic;
        -- write data
        m_axi_wdata     : out std_logic_vector(G_DATA_W-1 downto 0);
        m_axi_wstrb     : out std_logic_vector(G_DATA_W/8-1 downto 0);
        m_axi_wlast     : out std_logic;
        m_axi_wvalid    : out std_logic;
        m_axi_wready    : in  std_logic;
        -- write response
        m_axi_bid       : in  std_logic_vector(G_ID_W-1 downto 0);
        m_axi_bresp     : in  std_logic_vector(1 downto 0);
        m_axi_bvalid    : in  std_logic;
        m_axi_bready    : out std_logic
    );
end entity axi_ddr_master;

architecture rtl of axi_ddr_master is
begin
    u_rd : entity work.axi_master_rd
        generic map (
            G_N_RD       => G_N_RD,
            G_ID_W       => G_ID_W,
            G_DATA_W     => G_DATA_W,
            G_ADDR_W     => G_ADDR_W,
            G_MAX_BURST  => G_MAX_BURST,
            G_MAX_OUTST  => G_RD_MAX_OUTST,
            G_FIFO_BEATS => G_RD_FIFO_BEATS,
            G_AXCACHE    => G_AXCACHE
        )
        port map (
            i_clk         => i_clk,
            i_rst         => i_rst,
            i_cmd_valid   => i_rd_cmd_valid,
            o_cmd_ready   => o_rd_cmd_ready,
            i_cmd_addr    => i_rd_cmd_addr,
            i_cmd_len     => i_rd_cmd_len,
            o_rsp_valid   => o_rd_rsp_valid,
            i_rsp_ready   => i_rd_rsp_ready,
            o_rsp_data    => o_rd_rsp_data,
            o_rsp_last    => o_rd_rsp_last,
            o_rsp_error   => o_rd_rsp_error,
            m_axi_arid    => m_axi_arid,
            m_axi_araddr  => m_axi_araddr,
            m_axi_arlen   => m_axi_arlen,
            m_axi_arsize  => m_axi_arsize,
            m_axi_arburst => m_axi_arburst,
            m_axi_arlock  => m_axi_arlock,
            m_axi_arcache => m_axi_arcache,
            m_axi_arprot  => m_axi_arprot,
            m_axi_arqos   => m_axi_arqos,
            m_axi_arvalid => m_axi_arvalid,
            m_axi_arready => m_axi_arready,
            m_axi_rid     => m_axi_rid,
            m_axi_rdata   => m_axi_rdata,
            m_axi_rresp   => m_axi_rresp,
            m_axi_rlast   => m_axi_rlast,
            m_axi_rvalid  => m_axi_rvalid,
            m_axi_rready  => m_axi_rready
        );

    u_wr : entity work.axi_master_wr
        generic map (
            G_ID_W       => G_ID_W,
            G_DATA_W     => G_DATA_W,
            G_ADDR_W     => G_ADDR_W,
            G_MAX_BURST  => G_MAX_BURST,
            G_MAX_OUTST  => G_WR_MAX_OUTST,
            G_FIFO_BEATS => G_WR_FIFO_BEATS,
            G_AXCACHE    => G_AXCACHE
        )
        port map (
            i_clk         => i_clk,
            i_rst         => i_rst,
            i_cmd_valid   => i_wr_cmd_valid,
            o_cmd_ready   => o_wr_cmd_ready,
            i_cmd_addr    => i_wr_cmd_addr,
            i_cmd_len     => i_wr_cmd_len,
            i_wdata_valid => i_wr_data_valid,
            o_wdata_ready => o_wr_data_ready,
            i_wdata       => i_wr_data,
            i_wstrb       => i_wr_strb,
            i_wlast       => i_wr_last,
            o_done        => o_wr_done,
            o_error       => o_wr_error,
            m_axi_awid    => m_axi_awid,
            m_axi_awaddr  => m_axi_awaddr,
            m_axi_awlen   => m_axi_awlen,
            m_axi_awsize  => m_axi_awsize,
            m_axi_awburst => m_axi_awburst,
            m_axi_awlock  => m_axi_awlock,
            m_axi_awcache => m_axi_awcache,
            m_axi_awprot  => m_axi_awprot,
            m_axi_awqos   => m_axi_awqos,
            m_axi_awvalid => m_axi_awvalid,
            m_axi_awready => m_axi_awready,
            m_axi_wdata   => m_axi_wdata,
            m_axi_wstrb   => m_axi_wstrb,
            m_axi_wlast   => m_axi_wlast,
            m_axi_wvalid  => m_axi_wvalid,
            m_axi_wready  => m_axi_wready,
            m_axi_bid     => m_axi_bid,
            m_axi_bresp   => m_axi_bresp,
            m_axi_bvalid  => m_axi_bvalid,
            m_axi_bready  => m_axi_bready
        );
end architecture rtl;
