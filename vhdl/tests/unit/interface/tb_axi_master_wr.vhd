-- Author: Olimjon Mirzayusupov
-- self-checking testbench for axi_master_wr against axi_mem_model (.gateflow/plans/axi-ddr-master.md, write master
-- test matrix w1..w5, selected with G_CFG)
--   w1 (G_CFG=1, 64 bit): v1 shape, single-beat commands with a 4-byte strobe in a random lane, command and data
--      presented together, the next command only after o_done (like conv_engine_v1)
--   w2 (G_CFG=2, 64 bit): random lengths 1..256 at addresses near 4 KB edges, random strobes, up to 6 commands in
--      flight, random WREADY and B delay, DUT G_MAX_OUTST = 4 so the limit is reached
--   w3 (G_CFG=3, 64 bit): ordering per command: together, command first, data first; the data of command k+1 is sent
--      before command k is done
--   w4 (G_CFG=4, 64 bit): SLVERR in the first, a middle and the final burst of split commands, mixed with clean
--      commands; o_error must come with exactly the erroring command's o_done
--   w5 (G_CFG=5, 128 bit): w2 at the Ultra96 width
-- every command's parameters, data and strobes are a hash of (command index, beat, G_SEED), so the drivers and the
-- checkers recompute them independently; command and data have independent handshakes and random delays
-- checks: every AW burst equals a beat-by-beat reference split (4 KB pages, 16 beats), AWID 0, full size, INCR;
-- no AW before its burst's data was accepted from the requester (the plan's "AW only once the data is there");
-- one o_done per command in order with the right o_error (A10); after each o_done the command's bytes in the model
-- memory equal a reference image (strobed bytes written, others unchanged, erroring beats not written);
-- m_axi_bready = '1' on every clock after reset + 1 (A6); bus outstanding never above G_MAX_OUTST; total W beats;
-- the model stops on any protocol violation (A1..A5) and the DUT on A11/A12
-- coverage that fails when 0: AW/W ready stalls (all), splits at 4 KB / at 16 beats / both (w2, w3, w5),
-- back-to-back W bursts (w2, w5), G_MAX_OUTST reached (w2, w5), each ordering mode and data ahead of an unfinished
-- command (w3), errors in the first / a middle / the final burst (w4)
-- run from vhdl/ (GHDL, VHDL-2008, the LLVM/GCC backend needs -e):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/axi_pkg.vhd src/interface/sync_fifo.vhd \
--        src/interface/axi_skid.vhd src/interface/axi_master_wr.vhd tests/models/axi_mem_model_pkg.vhd tests/models/axi_mem_model_shared.vhd tests/models/axi_mem_model.vhd \
--        tests/unit/interface/tb_axi_master_wr.vhd
--   ghdl -e --std=08 --workdir=<dir> tb_axi_master_wr
--   ghdl -r --std=08 --workdir=<dir> tb_axi_master_wr -gG_CFG=1 -gG_SEED=1     (w1)
--   ghdl -r --std=08 --workdir=<dir> tb_axi_master_wr -gG_CFG=2 -gG_SEED=1     (w2)
--   ghdl -r --std=08 --workdir=<dir> tb_axi_master_wr -gG_CFG=3 -gG_SEED=1     (w3)
--   ghdl -r --std=08 --workdir=<dir> tb_axi_master_wr -gG_CFG=4 -gG_SEED=1     (w4)
--   ghdl -r --std=08 --workdir=<dir> tb_axi_master_wr -gG_CFG=5 -gG_SEED=1     (w5)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.camus_pkg.all;
use work.axi_pkg.all;
use work.axi_mem_model_pkg.all;
use work.axi_mem_model_shared.all;

entity tb_axi_master_wr is
    generic (
        G_CFG  : positive := 2;      -- 1..5 = w1..w5
        G_SEED : positive := 1
    );
end entity tb_axi_master_wr;

architecture sim of tb_axi_master_wr is
    type nat5_t is array (1 to 5) of natural;
    constant C_WIDTH_OF    : nat5_t := (64, 64, 64, 64, 128);
    constant C_N_OF        : nat5_t := (300, 150, 300, 80, 150);
    constant C_INFLIGHT_OF : nat5_t := (1, 6, 6, 1, 6);
    constant C_READY_OF    : nat5_t := (70, 70, 60, 80, 70);
    constant C_WRLAT_OF    : nat5_t := (3, 24, 5, 5, 24);
    constant C_OUTST_OF    : nat5_t := (8, 4, 8, 8, 4);

    constant C_DATA_W    : positive := C_WIDTH_OF(G_CFG);
    constant C_BYTES     : positive := C_DATA_W / 8;
    constant C_N         : positive := C_N_OF(G_CFG);
    constant C_INFLIGHT  : positive := C_INFLIGHT_OF(G_CFG);
    constant C_MAX_OUTST : positive := C_OUTST_OF(G_CFG);
    constant C_ID_W      : positive := 2;
    constant C_MAX_BURST : positive := 16;
    constant C_PERIOD    : time := 5 ns;
    constant C_BASE      : natural := 16#10000000#;
    constant C_SLOT      : natural := 8192;                     -- 32 slots of 8 KB = the 256 KB region 0
    constant C_PAGE_BEATS : positive := 4096 / C_BYTES;
    constant C_ERR_LO    : natural := C_BASE + 31 * C_SLOT + 16#100#;   -- one beat, off the 4 KB boundaries
    constant C_ERR_HI    : natural := C_ERR_LO + C_BYTES;

    -- ordering of command and data: together (synchronised), command first, data first, free running
    constant M_TOGETHER  : natural := 0;
    constant M_CMD_FIRST : natural := 1;
    constant M_DATA_FIRST : natural := 2;
    constant M_FREE      : natural := 3;

    type cmd_t is record
        addr : unsigned(31 downto 0);
        len  : natural;               -- beats - 1
        mode : natural;
        err  : boolean;               -- expected o_error
        kind : natural;               -- w4: 0 clean, 1 error in the first burst, 2 in a middle burst, 3 in the final burst
    end record;

    function mix(x : unsigned(31 downto 0)) return unsigned is
        variable v : unsigned(63 downto 0);
        variable r : unsigned(31 downto 0);
    begin
        v := x * unsigned'(x"9E3779B1");
        r := v(47 downto 16) xor v(31 downto 0);
        r := r xor shift_right(r, 15);
        return r;
    end function mix;

    function hash(a, b, c : natural) return natural is
        variable v : unsigned(31 downto 0);
    begin
        v := mix(to_unsigned(a, 32) xor x"5BD1E995");
        v := mix(v xor to_unsigned(b, 32));
        v := mix(v xor to_unsigned(c, 32));
        v := mix(v xor to_unsigned(G_SEED, 32));
        return to_integer(v(30 downto 0));
    end function hash;

    function slot_addr(slot, beat : natural) return unsigned is
    begin
        return to_unsigned(C_BASE + slot * C_SLOT + beat * C_BYTES, 32);
    end function slot_addr;

    -- start beat inside a slot: anywhere in the first page, or a few beats before its end
    function near_edge(k : natural) return natural is
    begin
        if hash(k, 2, 0) mod 4 = 0 then
            return hash(k, 3, 0) mod C_PAGE_BEATS;
        end if;
        return C_PAGE_BEATS - 1 - hash(k, 4, 0) mod 40;
    end function near_edge;

    function get_cmd(k : natural) return cmd_t is
        variable c : cmd_t;
        variable r : natural;
    begin
        c.mode := M_FREE;
        c.err := false;
        c.kind := 0;
        case G_CFG is
            when 1 =>
                c.len := 0;
                c.addr := slot_addr(k mod 32, hash(k, 1, 0) mod C_PAGE_BEATS);
                c.mode := M_TOGETHER;
            when 3 =>
                c.len := hash(k, 1, 0) mod 40;
                c.addr := slot_addr(k mod 32, near_edge(k));
                c.mode := k mod 3;
            when 4 =>
                c.kind := k mod 4;
                if c.kind = 0 then
                    c.len := hash(k, 1, 0) mod 48;
                    c.addr := slot_addr(k mod 31, hash(k, 3, 0) mod C_PAGE_BEATS);
                else
                    -- 48 beats, the erroring beat is beat 0, 20 or 40: in the first, a middle or the final burst
                    c.len := 47;
                    c.err := true;
                    if c.kind = 1 then
                        c.addr := to_unsigned(C_ERR_LO, 32);
                    elsif c.kind = 2 then
                        c.addr := to_unsigned(C_ERR_LO - 20 * C_BYTES, 32);
                    else
                        c.addr := to_unsigned(C_ERR_LO - 40 * C_BYTES, 32);
                    end if;
                end if;
            when others =>
                r := hash(k, 1, 0) mod 10;
                if r < 3 then
                    c.len := hash(k, 5, 0) mod 16;
                elsif r < 6 then
                    c.len := 16 + hash(k, 5, 0) mod 48;
                else
                    c.len := 64 + hash(k, 5, 0) mod 192;
                end if;
                c.addr := slot_addr(k mod 32, near_edge(k));
        end case;
        return c;
    end function get_cmd;

    function beat_data(k, b : natural) return std_logic_vector is
        variable v : std_logic_vector(C_DATA_W-1 downto 0);
    begin
        for i in 0 to C_BYTES / 4 - 1 loop
            v(32 * i + 31 downto 32 * i) := std_logic_vector(to_unsigned(hash(k, b, 100 + i), 31)) & std_logic_vector(to_unsigned(k mod 2, 1));
        end loop;
        return v;
    end function beat_data;

    function beat_strb(k, b : natural) return std_logic_vector is
        variable s : std_logic_vector(C_BYTES-1 downto 0) := (others => '0');
        variable h, lane : natural;
    begin
        h := hash(k, b, 7);
        case G_CFG is
            when 1 =>
                lane := hash(k, 0, 8) mod (C_BYTES / 4);
                s(4 * lane + 3 downto 4 * lane) := "1111";
            when 4 =>
                s := (others => '1');
            when others =>
                if h mod 4 = 0 then
                    s := (others => '1');
                else
                    s := std_logic_vector(to_unsigned((h / 4) mod 2 ** C_BYTES, C_BYTES));
                end if;
        end case;
        return s;
    end function beat_strb;

    function in_err(a : unsigned(31 downto 0)) return boolean is
    begin
        return G_CFG = 4 and a >= to_unsigned(C_ERR_LO, 32) and a < to_unsigned(C_ERR_HI, 32);
    end function in_err;

    -- reference split, beat by beat (independent of axi_pkg.burst_beats): a burst ends after 16 beats, at the end
    -- of the command, or where the next beat starts a new 4 KB page
    function ref_burst(addr : unsigned(31 downto 0); left : natural) return natural is
        variable n : natural := 0;
        variable a : natural := to_integer(addr(11 downto 0));
    begin
        loop
            n := n + 1;
            a := a + C_BYTES;
            exit when n = left or n = C_MAX_BURST or a mod 4096 = 0;
        end loop;
        return n;
    end function ref_burst;

    signal s_clk      : std_logic := '0';
    signal s_rst      : std_logic := '1';
    signal s_finished : boolean := false;
    signal s_err_en   : boolean := G_CFG = 4;

    -- requester side
    signal s_cmd_valid : std_logic := '0';
    signal s_cmd_ready : std_logic;
    signal s_cmd_addr  : unsigned(31 downto 0) := (others => '0');
    signal s_cmd_len   : unsigned(7 downto 0) := (others => '0');
    signal s_wd_valid  : std_logic := '0';
    signal s_wd_ready  : std_logic;
    signal s_wd_data   : std_logic_vector(C_DATA_W-1 downto 0) := (others => '0');
    signal s_wd_strb   : std_logic_vector(C_BYTES-1 downto 0) := (others => '0');
    signal s_wd_last   : std_logic := '0';
    signal s_done      : std_logic;
    signal s_error     : std_logic;

    -- AXI
    signal s_awid    : std_logic_vector(C_ID_W-1 downto 0);
    signal s_awaddr  : std_logic_vector(31 downto 0);
    signal s_awlen   : std_logic_vector(7 downto 0);
    signal s_awsize  : std_logic_vector(2 downto 0);
    signal s_awburst : std_logic_vector(1 downto 0);
    signal s_awlock  : std_logic;
    signal s_awcache : std_logic_vector(3 downto 0);
    signal s_awprot  : std_logic_vector(2 downto 0);
    signal s_awqos   : std_logic_vector(3 downto 0);
    signal s_awvalid : std_logic;
    signal s_awready : std_logic;
    signal s_wdata   : std_logic_vector(C_DATA_W-1 downto 0);
    signal s_wstrb   : std_logic_vector(C_BYTES-1 downto 0);
    signal s_wlast   : std_logic;
    signal s_wvalid  : std_logic;
    signal s_wready  : std_logic;
    signal s_bid     : std_logic_vector(C_ID_W-1 downto 0);
    signal s_bresp   : std_logic_vector(1 downto 0);
    signal s_bvalid  : std_logic;
    signal s_bready  : std_logic;

    -- progress shared between the processes
    signal s_cmd_cnt   : natural := 0;      -- commands accepted
    signal s_first_cnt : natural := 0;      -- commands whose first data beat was accepted
    signal s_done_cnt  : natural := 0;      -- commands checked after o_done
    signal s_cwait     : integer := -1;     -- together mode: command k is ready to go
    signal s_dwait     : integer := -1;     -- together mode: data of command k is ready to go
    signal s_ahead     : natural := 0;      -- first beats of command k accepted while command k-1 was not done
    signal s_mode_cnt0, s_mode_cnt1, s_mode_cnt2 : natural := 0;
    -- bus monitor results
    signal s_aw_cmds   : natural := 0;      -- commands whose bursts were all seen and checked
    signal s_aw_total  : natural := 0;
    signal s_w_total   : natural := 0;
    signal s_cov_4k, s_cov_max, s_cov_both, s_cov_b2b : natural := 0;
    signal s_outst_max : natural := 0;
begin
    s_clk <= not s_clk after C_PERIOD / 2 when not s_finished;

    u_dut : entity work.axi_master_wr
        generic map (
            G_ID_W       => C_ID_W,
            G_DATA_W     => C_DATA_W,
            G_ADDR_W     => 32,
            G_MAX_BURST  => C_MAX_BURST,
            G_MAX_OUTST  => C_MAX_OUTST,
            G_FIFO_BEATS => 32,
            G_AXCACHE    => "0011"
        )
        port map (
            i_clk         => s_clk,
            i_rst         => s_rst,
            i_cmd_valid   => s_cmd_valid,
            o_cmd_ready   => s_cmd_ready,
            i_cmd_addr    => s_cmd_addr,
            i_cmd_len     => s_cmd_len,
            i_wdata_valid => s_wd_valid,
            o_wdata_ready => s_wd_ready,
            i_wdata       => s_wd_data,
            i_wstrb       => s_wd_strb,
            i_wlast       => s_wd_last,
            o_done        => s_done,
            o_error       => s_error,
            m_axi_awid    => s_awid,
            m_axi_awaddr  => s_awaddr,
            m_axi_awlen   => s_awlen,
            m_axi_awsize  => s_awsize,
            m_axi_awburst => s_awburst,
            m_axi_awlock  => s_awlock,
            m_axi_awcache => s_awcache,
            m_axi_awprot  => s_awprot,
            m_axi_awqos   => s_awqos,
            m_axi_awvalid => s_awvalid,
            m_axi_awready => s_awready,
            m_axi_wdata   => s_wdata,
            m_axi_wstrb   => s_wstrb,
            m_axi_wlast   => s_wlast,
            m_axi_wvalid  => s_wvalid,
            m_axi_wready  => s_wready,
            m_axi_bid     => s_bid,
            m_axi_bresp   => s_bresp,
            m_axi_bvalid  => s_bvalid,
            m_axi_bready  => s_bready
        );

    u_mem : entity work.axi_mem_model
        generic map (
            G_DATA_W            => C_DATA_W,
            G_ID_W              => C_ID_W,
            G_ADDR_W            => 32,
            G_MAX_BURST         => C_MAX_BURST,
            G_READY_PCT         => C_READY_OF(G_CFG),
            G_RD_LAT_MAX        => 0,
            G_WR_LAT_MAX        => C_WRLAT_OF(G_CFG),
            G_REORDER           => true,
            G_ACCEPT            => 8,
            G_ERR_ADDR_LO       => C_ERR_LO,
            G_ERR_ADDR_HI       => C_ERR_HI,
            G_FAIL_ON_VIOLATION => true,
            G_SEED              => G_SEED
        )
        port map (
            i_clk         => s_clk,
            i_rst         => s_rst,
            i_err_en      => s_err_en,
            s_axi_arid    => (others => '0'),
            s_axi_araddr  => (others => '0'),
            s_axi_arlen   => (others => '0'),
            s_axi_arsize  => (others => '0'),
            s_axi_arburst => (others => '0'),
            s_axi_arvalid => '0',
            s_axi_arready => open,
            s_axi_rid     => open,
            s_axi_rdata   => open,
            s_axi_rresp   => open,
            s_axi_rlast   => open,
            s_axi_rvalid  => open,
            s_axi_rready  => '0',
            s_axi_awid    => s_awid,
            s_axi_awaddr  => s_awaddr,
            s_axi_awlen   => s_awlen,
            s_axi_awsize  => s_awsize,
            s_axi_awburst => s_awburst,
            s_axi_awlock  => s_awlock,
            s_axi_awcache => s_awcache,
            s_axi_awprot  => s_awprot,
            s_axi_awqos   => s_awqos,
            s_axi_awvalid => s_awvalid,
            s_axi_awready => s_awready,
            s_axi_wdata   => s_wdata,
            s_axi_wstrb   => s_wstrb,
            s_axi_wlast   => s_wlast,
            s_axi_wvalid  => s_wvalid,
            s_axi_wready  => s_wready,
            s_axi_bid     => s_bid,
            s_axi_bresp   => s_bresp,
            s_axi_bvalid  => s_bvalid,
            s_axi_bready  => s_bready
        );

    -- command driver: in-flight limit, ordering mode, random delay, hold until accepted
    p_cmd : process
        variable v_seed1 : positive := G_SEED;
        variable v_seed2 : positive := 101;
        variable v_r     : real;
        variable v_d     : natural;
        variable c       : cmd_t;
    begin
        wait until s_rst = '0';
        for k in 0 to C_N - 1 loop
            c := get_cmd(k);
            while s_done_cnt + C_INFLIGHT <= k loop
                wait until rising_edge(s_clk);
            end loop;
            v_d := 0;
            if c.mode = M_DATA_FIRST then
                while s_first_cnt <= k loop
                    wait until rising_edge(s_clk);
                end loop;
            elsif c.mode = M_TOGETHER then
                s_cwait <= k;
                if s_dwait /= k then
                    wait until s_dwait = k;
                end if;
            else
                uniform(v_seed1, v_seed2, v_r);
                v_d := natural(floor(v_r * 4.0));
            end if;
            for i in 1 to v_d loop
                wait until falling_edge(s_clk);
            end loop;
            wait until falling_edge(s_clk);
            s_cmd_addr <= c.addr;
            s_cmd_len <= to_unsigned(c.len, 8);
            s_cmd_valid <= '1';
            loop
                wait until rising_edge(s_clk);
                exit when s_cmd_ready = '1';
            end loop;
            s_cmd_cnt <= k + 1;
            wait until falling_edge(s_clk);
            s_cmd_valid <= '0';
        end loop;
        wait;
    end process p_cmd;

    -- data driver: never waits for later commands; beats of one command may go back to back
    p_data : process
        variable v_seed1 : positive := G_SEED;
        variable v_seed2 : positive := 202;
        variable v_r     : real;
        variable v_d     : natural;
        variable c       : cmd_t;
    begin
        wait until s_rst = '0';
        for k in 0 to C_N - 1 loop
            c := get_cmd(k);
            if c.mode = M_CMD_FIRST then
                while s_cmd_cnt <= k loop
                    wait until rising_edge(s_clk);
                end loop;
            elsif c.mode = M_TOGETHER then
                s_dwait <= k;
                if s_cwait /= k then
                    wait until s_cwait = k;
                end if;
            end if;
            for b in 0 to c.len loop
                v_d := 0;
                if not (b = 0 and c.mode = M_TOGETHER) then
                    uniform(v_seed1, v_seed2, v_r);
                    if v_r < 0.6 then
                        v_d := 0;
                    else
                        v_d := natural(floor(v_r * 5.0)) - 2;
                    end if;
                end if;
                wait until falling_edge(s_clk);
                if v_d > 0 then
                    s_wd_valid <= '0';
                    for i in 1 to v_d loop
                        wait until falling_edge(s_clk);
                    end loop;
                end if;
                s_wd_data <= beat_data(k, b);
                s_wd_strb <= beat_strb(k, b);
                if b = c.len then
                    s_wd_last <= '1';
                else
                    s_wd_last <= '0';
                end if;
                s_wd_valid <= '1';
                loop
                    wait until rising_edge(s_clk);
                    exit when s_wd_ready = '1';
                end loop;
                if b = 0 then
                    s_first_cnt <= k + 1;
                    if k > 0 and s_done_cnt < k then
                        s_ahead <= s_ahead + 1;
                    end if;
                    case c.mode is
                        when M_TOGETHER => s_mode_cnt0 <= s_mode_cnt0 + 1;
                        when M_CMD_FIRST => s_mode_cnt1 <= s_mode_cnt1 + 1;
                        when M_DATA_FIRST => s_mode_cnt2 <= s_mode_cnt2 + 1;
                        when others => null;
                    end case;
                end if;
            end loop;
            wait until falling_edge(s_clk);
            s_wd_valid <= '0';
        end loop;
        wait;
    end process p_data;

    -- AW monitor: every burst against the reference split; W monitor: beats and back-to-back bursts;
    -- outstanding bursts on the bus; m_axi_bready after reset (A6)
    p_bus : process(s_clk)
        variable v_k, v_off, v_n, v_left : natural := 0;
        variable v_c : cmd_t := get_cmd(0);
        variable v_exp : unsigned(31 downto 0);
        variable v_cross, v_cut : boolean := false;
        variable v_prev_last : boolean := false;
        variable v_out, v_out_max : natural := 0;
        variable v_after_rst : natural := 0;
        variable v_w : natural := 0;
        variable v_aw : natural := 0;
        variable v_4k, v_max, v_both, v_b2b : natural := 0;
        variable v_req_beats, v_aw_beats : natural := 0;   -- requester beats accepted, beats claimed by AW bursts
    begin
        if rising_edge(s_clk) then
            if s_rst = '1' then
                v_after_rst := 0;
            else
                if v_after_rst >= 2 then
                    assert s_bready = '1' report "m_axi_bready low after reset (A6)" severity failure;
                end if;
                v_after_rst := v_after_rst + 1;
            end if;

            if s_awvalid = '1' and s_awready = '1' then
                assert v_k < C_N report "AW burst after the last command" severity failure;
                v_exp := v_c.addr + to_unsigned(v_off * C_BYTES, 32);
                v_left := v_c.len + 1 - v_off;
                v_n := ref_burst(v_exp, v_left);
                assert unsigned(s_awaddr) = v_exp
                    report "AW address " & to_hstring(s_awaddr) & ", expected " & to_hstring(v_exp) & " (command "
                           & integer'image(v_k) & ")" severity failure;
                assert to_integer(unsigned(s_awlen)) + 1 = v_n
                    report "AW length " & integer'image(to_integer(unsigned(s_awlen)) + 1) & ", expected " & integer'image(v_n)
                           & " (command " & integer'image(v_k) & ")" severity failure;
                assert unsigned(s_awid) = 0 and s_awsize = axi_size(C_DATA_W) and s_awburst = AXI_BURST_INCR
                    report "AW id, size or burst type" severity failure;
                -- AW only once the burst's data is in the master: the requester must already have delivered every
                -- beat claimed by the AW bursts so far (beats accepted at this very edge do not count)
                v_aw_beats := v_aw_beats + v_n;
                assert v_req_beats >= v_aw_beats
                    report "AW for a burst whose data was not yet accepted from the requester (command "
                           & integer'image(v_k) & ")" severity failure;
                if v_n < v_left then
                    if (to_integer(v_exp(11 downto 0)) + v_n * C_BYTES) mod 4096 = 0 then
                        v_cross := true;
                    else
                        v_cut := true;
                    end if;
                end if;
                v_off := v_off + v_n;
                v_aw := v_aw + 1;
                v_out := v_out + 1;
                if v_off = v_c.len + 1 then
                    if v_cross and v_cut then
                        v_both := v_both + 1;
                    elsif v_cross then
                        v_4k := v_4k + 1;
                    elsif v_cut then
                        v_max := v_max + 1;
                    end if;
                    v_k := v_k + 1;
                    v_off := 0;
                    v_cross := false;
                    v_cut := false;
                    v_c := get_cmd(v_k);
                end if;
            end if;

            if s_wd_valid = '1' and s_wd_ready = '1' then
                v_req_beats := v_req_beats + 1;
            end if;

            if s_bvalid = '1' and s_bready = '1' then
                v_out := v_out - 1;
            end if;
            assert v_out <= C_MAX_OUTST report "more bursts outstanding than G_MAX_OUTST" severity failure;
            if v_out > v_out_max then
                v_out_max := v_out;
            end if;

            if s_wvalid = '1' and s_wready = '1' then
                v_w := v_w + 1;
                if v_prev_last then
                    v_b2b := v_b2b + 1;
                end if;
                v_prev_last := s_wlast = '1';
            else
                v_prev_last := false;
            end if;

            s_aw_cmds <= v_k;
            s_aw_total <= v_aw;
            s_w_total <= v_w;
            s_cov_4k <= v_4k;
            s_cov_max <= v_max;
            s_cov_both <= v_both;
            s_cov_b2b <= v_b2b;
            s_outst_max <= v_out_max;
        end if;
    end process p_bus;

    -- checker: o_done order and o_error (A10), then the command's bytes against the reference image
    p_check : process
        variable v_ref    : mem_pt;
        variable v_errors : natural := 0;
        variable c        : cmd_t;
        variable v_a      : unsigned(31 downto 0);
        variable v_d      : std_logic_vector(C_DATA_W-1 downto 0);
        variable v_s      : std_logic_vector(C_BYTES-1 downto 0);
        variable v_got    : std_logic_vector(C_DATA_W-1 downto 0);
        variable v_beats  : natural := 0;
        variable v_errs   : natural := 0;
        variable v_kinds  : nat5_t := (others => 0);
        variable v_extra  : natural := 0;
        variable v_cycles : natural := 0;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                v_errors := v_errors + 1;
                report "ERROR: " & msg & " at " & time'image(now) severity error;
            end if;
        end procedure check;
    begin
        s_rst <= '1';
        for i in 1 to 4 loop
            wait until rising_edge(s_clk);
        end loop;
        wait until falling_edge(s_clk);
        s_rst <= '0';

        for k in 0 to C_N - 1 loop
            v_cycles := 0;
            loop
                wait until rising_edge(s_clk);
                exit when s_done = '1';
                v_cycles := v_cycles + 1;
                if v_cycles > 200000 then
                    report "FAIL: no o_done for command " & integer'image(k) & " (timeout)" severity failure;
                end if;
            end loop;
            c := get_cmd(k);
            check((s_error = '1') = c.err, "o_error " & std_logic'image(s_error) & " for command " & integer'image(k));
            if s_error = '1' then
                v_errs := v_errs + 1;
            end if;
            if c.err and s_error = '1' then
                v_kinds(c.kind) := v_kinds(c.kind) + 1;
            end if;
            -- apply the command to the reference (an erroring beat is not written), then compare its range
            for b in 0 to c.len loop
                v_a := c.addr + to_unsigned(b * C_BYTES, 32);
                if not in_err(v_a) then
                    v_d := beat_data(k, b);
                    v_s := beat_strb(k, b);
                    for i in 0 to C_BYTES - 1 loop
                        if v_s(i) = '1' then
                            v_ref.write_byte(v_a + to_unsigned(i, 32), v_d(8 * i + 7 downto 8 * i));
                        end if;
                    end loop;
                end if;
            end loop;
            for b in 0 to c.len loop
                v_a := c.addr + to_unsigned(b * C_BYTES, 32);
                mem_read(v_a, v_got);
                for i in 0 to C_BYTES - 1 loop
                    if v_got(8 * i + 7 downto 8 * i) /= v_ref.read_byte(v_a + to_unsigned(i, 32)) then
                        check(false, "memory byte at " & to_hstring(v_a + to_unsigned(i, 32)) & " is "
                              & to_hstring(v_got(8 * i + 7 downto 8 * i)) & ", expected "
                              & to_hstring(v_ref.read_byte(v_a + to_unsigned(i, 32))) & " (command " & integer'image(k) & ")");
                    end if;
                end loop;
            end loop;
            v_beats := v_beats + c.len + 1;
            s_done_cnt <= k + 1;
        end loop;

        -- no extra o_done afterwards
        for i in 1 to 300 loop
            wait until rising_edge(s_clk);
            if s_done = '1' then
                v_extra := v_extra + 1;
            end if;
        end loop;
        check(v_extra = 0, integer'image(v_extra) & " o_done pulses after the last command");
        check(s_aw_cmds = C_N, "bursts of " & integer'image(C_N - s_aw_cmds) & " commands missing on AW");
        check(s_w_total = v_beats, "W beats " & integer'image(s_w_total) & ", expected " & integer'image(v_beats));
        check(axi_stats.get(ST_B) = s_aw_total, "B responses do not match the AW bursts");
        check(axi_stats.get(ST_VIOLATION) = 0, "model violations");

        -- coverage
        check(axi_stats.get(ST_AW_STALL) > 0, "no AWREADY stall");
        check(axi_stats.get(ST_W_STALL) > 0, "no WREADY stall");
        if G_CFG = 2 or G_CFG = 3 or G_CFG = 5 then
            check(s_cov_4k > 0, "no command split at 4 KB only");
            check(s_cov_max > 0, "no command split at 16 beats only");
            check(s_cov_both > 0, "no command split at both");
        end if;
        if G_CFG = 2 or G_CFG = 5 then
            check(s_cov_b2b > 0, "no back-to-back W bursts");
            check(s_outst_max = C_MAX_OUTST, "G_MAX_OUTST never reached (max " & integer'image(s_outst_max) & ")");
        end if;
        if G_CFG = 3 then
            check(s_mode_cnt0 > 0 and s_mode_cnt1 > 0 and s_mode_cnt2 > 0, "an ordering mode was not exercised");
            check(s_ahead > 0, "no data of command k+1 before command k was done");
        end if;
        if G_CFG = 4 then
            check(v_kinds(1) > 0 and v_kinds(2) > 0 and v_kinds(3) > 0, "error in the first / middle / final burst not all seen");
            check(axi_stats.get(ST_B_ERR) > 0, "no SLVERR on B");
        end if;
        if G_CFG /= 4 then
            check(v_errs = 0, "o_error without an error window");
        end if;

        report "w" & integer'image(G_CFG) & " seed " & integer'image(G_SEED) & ": " & integer'image(C_N) & " commands, "
               & integer'image(s_aw_total) & " bursts, " & integer'image(v_beats) & " beats; splits 4K/16/both "
               & integer'image(s_cov_4k) & "/" & integer'image(s_cov_max) & "/" & integer'image(s_cov_both)
               & "; back-to-back " & integer'image(s_cov_b2b) & "; outstanding max " & integer'image(s_outst_max)
               & "; AW/W stalls " & integer'image(axi_stats.get(ST_AW_STALL)) & "/" & integer'image(axi_stats.get(ST_W_STALL))
               & "; errors " & integer'image(v_errs) & "; modes " & integer'image(s_mode_cnt0) & "/" & integer'image(s_mode_cnt1)
               & "/" & integer'image(s_mode_cnt2) & ", ahead " & integer'image(s_ahead) & "; " & integer'image(v_errors) & " check errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        s_finished <= true;
        wait;
    end process p_check;
end architecture sim;
