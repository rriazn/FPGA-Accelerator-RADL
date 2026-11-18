-- Author: Roman Riazanov
-- conv_accel_bd_zed: conv_accel_top with literal port widths for the ZedBoard, the top of the Vivado block design
-- (module reference), the Ultra96 version is conv_accel_bd, add only one of the two to the project
-- Vivado reads the ports of a module reference without the packages, so the widths from camus_pkg (AXI_DATA_W,
-- AXI_ADDR_W) and the generics of conv_accel_top are not usable there (error IP_Flow 19-627)
-- the widths below are those of BOARD = ZEDBOARD (64 bit data, 32 bit address, 2 bit ID, 8 bit register address)
-- if the widths do not match BOARD in camus_pkg the instance below fails at elaboration, it never mismatches silently
library ieee;
use ieee.std_logic_1164.all;

entity conv_accel_bd_zed is
    port (
        aclk    : in std_logic;
        aresetn : in std_logic;
        -- AXI4-Lite slave, control from the ARM
        s_axi_awaddr  : in  std_logic_vector(7 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(7 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;
        -- AXI4 master, read address
        m_axi_arid    : out std_logic_vector(1 downto 0);
        m_axi_araddr  : out std_logic_vector(31 downto 0);
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
        m_axi_rid     : in  std_logic_vector(1 downto 0);
        m_axi_rdata   : in  std_logic_vector(63 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rlast   : in  std_logic;
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic;
        -- write address
        m_axi_awid    : out std_logic_vector(1 downto 0);
        m_axi_awaddr  : out std_logic_vector(31 downto 0);
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
        m_axi_wdata   : out std_logic_vector(63 downto 0);
        m_axi_wstrb   : out std_logic_vector(7 downto 0);
        m_axi_wlast   : out std_logic;
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        -- write response
        m_axi_bid     : in  std_logic_vector(1 downto 0);
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic
    );
end entity conv_accel_bd_zed;

architecture rtl of conv_accel_bd_zed is
begin
    u_top : entity work.conv_accel_top
        port map (
            aclk => aclk, aresetn => aresetn,
            s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
            s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb, s_axi_wvalid => s_axi_wvalid,
            s_axi_wready => s_axi_wready,
            s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
            s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
            s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
            s_axi_rready => s_axi_rready,
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
