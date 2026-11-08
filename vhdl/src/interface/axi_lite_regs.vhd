-- Author: Roman Riazanov
-- axi_lite_regs: AXI4-Lite slave holding the layer registers, register map in docs/plans/axi-interfaces.md
-- byte offsets: 00 CTRL, 04 STATUS, 08 C, 0C K, 10 H, 14 W, 18 FY, 1C FX, 20 STRIDE, 24 PAD,
--               28 IN_LANES, 2C OUT_LANES, 30 IN_BASE, 34 W_BASE, 38 B_BASE, 3C OUT_BASE, 40 CYCLES (read only)
-- offsets 44 to 7F are reserved, 80 and up is for the fused requant registers of step 4.6
-- CTRL (write only, reads 0): bit 0 start, bit 1 soft reset (wins over start), takes effect when wstrb(0) is set
-- STATUS (read only): bit 0 busy, bit 1 done, bit 2 error
-- layer registers are locked while i_busy = 1, the write is still answered with OKAY
-- start while busy is not forwarded and sets error
-- i_done is expected as a pulse, i_busy as a level that rises at most one clock after o_start
-- unmapped reads return 0 and unmapped writes are ignored, both answer OKAY
-- one transaction per channel at a time, a write needs AW and W valid together before it is accepted
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;

entity axi_lite_regs is
    generic (
        G_ADDR_W : natural := 8    -- byte address bits of the register space, at least 7
    );
    port (
        i_clk, i_rst : in std_logic;
        -- AXI4-Lite slave
        s_axi_awaddr  : in  std_logic_vector(G_ADDR_W-1 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(G_ADDR_W-1 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;
        -- to the accelerator
        o_cfg      : out layer_cfg_t;
        o_start    : out std_logic;                -- one clock pulse when CTRL.start is written
        o_soft_rst : out std_logic;                -- one clock pulse when CTRL.soft_rst is written
        i_busy, i_done, i_error : in std_logic;    -- shown in STATUS, done and error are sticky here
        i_cycles   : in unsigned(31 downto 0)      -- shown in CYCLES
    );
end entity axi_lite_regs;

architecture rtl of axi_lite_regs is
    -- word index of a register, byte offset divided by 4
    constant R_CTRL      : natural := 0;
    constant R_STATUS    : natural := 1;
    constant R_C         : natural := 2;
    constant R_K         : natural := 3;
    constant R_H         : natural := 4;
    constant R_W         : natural := 5;
    constant R_FY        : natural := 6;
    constant R_FX        : natural := 7;
    constant R_STRIDE    : natural := 8;
    constant R_PAD       : natural := 9;
    constant R_IN_LANES  : natural := 10;
    constant R_OUT_LANES : natural := 11;
    constant R_IN_BASE   : natural := 12;
    constant R_W_BASE    : natural := 13;
    constant R_B_BASE    : natural := 14;
    constant R_OUT_BASE  : natural := 15;
    constant R_CYCLES    : natural := 16;

    subtype word_t is std_logic_vector(31 downto 0);
    type regs_t is array (R_C to R_OUT_BASE) of word_t;

    -- bits that exist in each layer register, the others read 0
    constant C_MASK : regs_t := (
        R_C => x"0000FFFF", R_K => x"0000FFFF", R_H => x"0000FFFF", R_W => x"0000FFFF",
        R_FY => x"00000007", R_FX => x"00000007", R_STRIDE => x"00000007", R_PAD => x"00000007",
        R_IN_LANES => x"0000001F", R_OUT_LANES => x"0000001F",
        R_IN_BASE => x"FFFFFFFF", R_W_BASE => x"FFFFFFFF", R_B_BASE => x"FFFFFFFF", R_OUT_BASE => x"FFFFFFFF"
    );

    signal s_regs : regs_t := (others => (others => '0'));

    signal s_wr_ready : std_logic := '0';
    signal s_bvalid   : std_logic := '0';
    signal s_rd_ready : std_logic := '0';
    signal s_rvalid   : std_logic := '0';
    signal s_rdata    : word_t := (others => '0');
    signal s_start    : std_logic := '0';
    signal s_soft_rst : std_logic := '0';
    signal s_done     : std_logic := '0';
    signal s_error    : std_logic := '0';

    -- old value with the strobed bytes replaced, only the existing bits of the register are kept
    function merge(old, new_v, mask : word_t; strb : std_logic_vector(3 downto 0)) return word_t is
        variable v : word_t := old;
    begin
        for b in 0 to 3 loop
            if strb(b) = '1' then
                v(8 * b + 7 downto 8 * b) := new_v(8 * b + 7 downto 8 * b);
            end if;
        end loop;
        return v and mask;
    end function merge;

    -- value of a register of up to 16 bits, limited to lo to hi so an illegal value never reaches the datapath
    function clamp(v : word_t; lo, hi : natural) return natural is
        variable n : natural := to_integer(unsigned(v(15 downto 0)));
    begin
        if n < lo then
            return lo;
        elsif n > hi then
            return hi;
        end if;
        return n;
    end function clamp;

    function to_cfg(r : regs_t) return layer_cfg_t is
        variable c : layer_cfg_t;
    begin
        c.c := to_integer(unsigned(r(R_C)(15 downto 0)));
        c.k := to_integer(unsigned(r(R_K)(15 downto 0)));
        c.h := to_integer(unsigned(r(R_H)(15 downto 0)));
        c.w := to_integer(unsigned(r(R_W)(15 downto 0)));
        c.fy := clamp(r(R_FY), 1, 7);
        c.fx := clamp(r(R_FX), 1, 7);
        c.stride := clamp(r(R_STRIDE), 1, 7);
        c.pad := clamp(r(R_PAD), 0, 7);
        c.in_lanes := clamp(r(R_IN_LANES), 1, LANES);
        c.out_lanes := clamp(r(R_OUT_LANES), 1, LANES);
        c.in_base := resize(unsigned(r(R_IN_BASE)), AXI_ADDR_W);
        c.w_base := resize(unsigned(r(R_W_BASE)), AXI_ADDR_W);
        c.b_base := resize(unsigned(r(R_B_BASE)), AXI_ADDR_W);
        c.out_base := resize(unsigned(r(R_OUT_BASE)), AXI_ADDR_W);
        return c;
    end function to_cfg;
begin
    assert G_ADDR_W >= 7 report "G_ADDR_W must be at least 7 to reach CYCLES at offset 40" severity failure;

    o_cfg <= to_cfg(s_regs);
    o_start <= s_start;
    o_soft_rst <= s_soft_rst;

    s_axi_awready <= s_wr_ready;
    s_axi_wready <= s_wr_ready;
    s_axi_bresp <= "00";
    s_axi_bvalid <= s_bvalid;
    s_axi_arready <= s_rd_ready;
    s_axi_rdata <= s_rdata;
    s_axi_rresp <= "00";
    s_axi_rvalid <= s_rvalid;

    process(i_clk)
        variable v_idx : natural;
        variable v_err_set : boolean;
        variable v_status : word_t;
    begin
        if rising_edge(i_clk) then
            s_start <= '0';
            s_soft_rst <= '0';
            v_err_set := false;

            -- write: the ready pulse is the handshake cycle, address and data are still valid in it
            s_wr_ready <= '0';
            if s_wr_ready = '0' and s_bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
                s_wr_ready <= '1';
            end if;

            if s_wr_ready = '1' then
                s_bvalid <= '1';
                v_idx := to_integer(unsigned(s_axi_awaddr(G_ADDR_W-1 downto 2)));
                if v_idx = R_CTRL then
                    if s_axi_wstrb(0) = '1' then
                        if s_axi_wdata(1) = '1' then
                            s_soft_rst <= '1';
                            s_done <= '0';
                            s_error <= '0';
                        elsif s_axi_wdata(0) = '1' then
                            if i_busy = '1' then
                                v_err_set := true;
                            else
                                s_start <= '1';
                                s_done <= '0';
                                s_error <= '0';
                            end if;
                        end if;
                    end if;
                elsif v_idx >= R_C and v_idx <= R_OUT_BASE and i_busy = '0' then
                    s_regs(v_idx) <= merge(s_regs(v_idx), s_axi_wdata, C_MASK(v_idx), s_axi_wstrb);
                end if;
            end if;
            if s_bvalid = '1' and s_axi_bready = '1' then
                s_bvalid <= '0';
            end if;

            -- sticky flags, a set wins over a clear in the same clock
            if i_done = '1' then
                s_done <= '1';
            end if;
            if i_error = '1' or v_err_set then
                s_error <= '1';
            end if;

            -- read
            s_rd_ready <= '0';
            if s_rd_ready = '0' and s_rvalid = '0' and s_axi_arvalid = '1' then
                s_rd_ready <= '1';
            end if;

            if s_rd_ready = '1' then
                s_rvalid <= '1';
                v_idx := to_integer(unsigned(s_axi_araddr(G_ADDR_W-1 downto 2)));
                v_status := (0 => i_busy, 1 => s_done, 2 => s_error, others => '0');
                if v_idx = R_STATUS then
                    s_rdata <= v_status;
                elsif v_idx = R_CYCLES then
                    s_rdata <= std_logic_vector(i_cycles);
                elsif v_idx >= R_C and v_idx <= R_OUT_BASE then
                    s_rdata <= s_regs(v_idx);
                else
                    s_rdata <= (others => '0');
                end if;
            end if;
            if s_rvalid = '1' and s_axi_rready = '1' then
                s_rvalid <= '0';
            end if;

            if i_rst = '1' then
                s_regs <= (others => (others => '0'));
                s_wr_ready <= '0';
                s_bvalid <= '0';
                s_rd_ready <= '0';
                s_rvalid <= '0';
                s_start <= '0';
                s_soft_rst <= '0';
                s_done <= '0';
                s_error <= '0';
            end if;
        end if;
    end process;
end architecture rtl;
