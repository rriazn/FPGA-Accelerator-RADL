-- self-checking unit testbench for addr_gen
-- run from vhdl/ (GHDL, VHDL-2008):
--   ghdl -a --std=08 --workdir=<dir> src/camus_pkg.vhd src/compute-engine/addr_gen.vhd tests/unit/compute-engine/tb_addr_gen.vhd
--   ghdl -r --std=08 --workdir=<dir> tb_addr_gen
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.camus_pkg.all;

entity tb_addr_gen is
end entity tb_addr_gen;

architecture sim of tb_addr_gen is
    constant C_IN_BASE  : natural := 16#10000000#;
    constant C_W_BASE   : natural := 16#20000000#;
    constant C_B_BASE   : natural := 16#30000000#;
    constant C_OUT_BASE : natural := 16#40000000#;

    signal s_cfg : layer_cfg_t := (
        c => 1, k => 1, h => 1, w => 1, fy => 1, fx => 1, stride => 1, pad => 0,
        in_lanes => 16, out_lanes => 16,
        in_base => to_unsigned(C_IN_BASE, AXI_ADDR_W), w_base => to_unsigned(C_W_BASE, AXI_ADDR_W),
        b_base => to_unsigned(C_B_BASE, AXI_ADDR_W), out_base => to_unsigned(C_OUT_BASE, AXI_ADDR_W));
    signal s_k, s_oy, s_ox, s_c, s_fy, s_fx : natural := 0;
    signal s_x_addr, s_w_addr, s_b_addr, s_out_addr : unsigned(AXI_ADDR_W-1 downto 0);
    signal s_x_valid : std_logic;
begin

    dut : entity work.addr_gen
        port map (
            i_cfg => s_cfg, i_k => s_k, i_oy => s_oy, i_ox => s_ox, i_c => s_c, i_fy => s_fy, i_fx => s_fx,
            o_x_addr => s_x_addr, o_x_valid => s_x_valid, o_w_addr => s_w_addr,
            o_b_addr => s_b_addr, o_out_addr => s_out_addr
        );

    stim : process
        type t_bool_vec is array (natural range <>) of boolean;
        variable v_seen   : t_bool_vec(0 to 65535);
        variable v_checks : natural := 0;
        variable v_errors : natural := 0;

        procedure fail(msg : string) is
        begin
            v_errors := v_errors + 1;
            report msg & " at " & time'image(now) severity error;
        end procedure fail;

        procedure set_cfg(k, c, h, w, fy, fx, stride, pad, inl, outl : natural) is
        begin
            s_cfg.k <= k;
            s_cfg.c <= c;
            s_cfg.h <= h;
            s_cfg.w <= w;
            s_cfg.fy <= fy;
            s_cfg.fx <= fx;
            s_cfg.stride <= stride;
            s_cfg.pad <= pad;
            s_cfg.in_lanes <= inl;
            s_cfg.out_lanes <= outl;
            wait for 1 ns;
        end procedure set_cfg;

        procedure apply(k, oy, ox, c, fy, fx : natural) is
        begin
            s_k <= k;
            s_oy <= oy;
            s_ox <= ox;
            s_c <= c;
            s_fy <= fy;
            s_fx <= fx;
            wait for 1 ns;
        end procedure apply;

        impure function x_off return integer is
        begin
            return to_integer(s_x_addr) - C_IN_BASE;
        end function x_off;

        impure function w_off return integer is
        begin
            return to_integer(s_w_addr) - C_W_BASE;
        end function w_off;

        impure function b_off return integer is
        begin
            return to_integer(s_b_addr) - C_B_BASE;
        end function b_off;

        impure function out_off return integer is
        begin
            return to_integer(s_out_addr) - C_OUT_BASE;
        end function out_off;

        procedure check(cond : boolean; msg : string) is
        begin
            v_checks := v_checks + 1;
            if not cond then
                fail(msg);
            end if;
        end procedure check;

        -- all four addresses of the applied term, an offset of -1 is not checked
        procedure expect(valid : boolean; xo, wo, bo, oo : integer; msg : string) is
        begin
            check((s_x_valid = '1') = valid, msg & ": o_x_valid");
            if valid and xo >= 0 then
                check(x_off = xo, msg & ": x offset " & integer'image(x_off) & ", expected " & integer'image(xo));
            end if;
            if wo >= 0 then
                check(w_off = wo, msg & ": w offset " & integer'image(w_off) & ", expected " & integer'image(wo));
            end if;
            if bo >= 0 then
                check(b_off = bo, msg & ": b offset " & integer'image(b_off) & ", expected " & integer'image(bo));
            end if;
            if oo >= 0 then
                check(out_off = oo, msg & ": out offset " & integer'image(out_off) & ", expected " & integer'image(oo));
            end if;
        end procedure expect;

        -- weights, bias and output addresses over a whole layer
        procedure prop_layer(k, c, h, w, fy, fx, stride, pad, inl, outl : natural) is
            constant oh : natural := (h + 2 * pad - fy) / stride + 1;
            constant ow : natural := (w + 2 * pad - fx) / stride + 1;
            variable n   : natural := 0;
            variable idx : natural;
        begin
            set_cfg(k, c, h, w, fy, fx, stride, pad, inl, outl);
            -- weights are the plain [K][C][FY][FX] array, so the offset is the running index
            for kk in 0 to k - 1 loop
                for cc in 0 to c - 1 loop
                    for yy in 0 to fy - 1 loop
                        for xx in 0 to fx - 1 loop
                            apply(kk, 0, 0, cc, yy, xx);
                            check(w_off = n, "weight index " & integer'image(n) & ", got " & integer'image(w_off));
                            n := n + 1;
                        end loop;
                    end loop;
                end loop;
            end loop;
            -- bias, 4 bytes each
            for kk in 0 to k - 1 loop
                apply(kk, 0, 0, 0, 0, 0);
                check(b_off = 4 * kk, "bias of channel " & integer'image(kk));
            end loop;
            -- output: every int32 slot of the layer is hit exactly once
            for i in 0 to k * oh * ow - 1 loop
                v_seen(i) := false;
            end loop;
            for kk in 0 to k - 1 loop
                for yy in 0 to oh - 1 loop
                    for xx in 0 to ow - 1 loop
                        apply(kk, yy, xx, 0, 0, 0);
                        idx := out_off / 4;
                        if out_off mod 4 /= 0 or out_off < 0 or idx >= k * oh * ow then
                            fail("output offset out of range " & integer'image(out_off));
                        elsif v_seen(idx) then
                            fail("output slot used twice " & integer'image(idx));
                        else
                            v_seen(idx) := true;
                        end if;
                    end loop;
                end loop;
            end loop;
            v_checks := v_checks + 1;
        end procedure prop_layer;

        -- input pixel position under each kernel cell, written independently as padded coordinates
        -- plain layout (lanes = 1): the offset is (c*h + iy)*w + ix
        -- blocked layout: the offset must stay inside the c*h*w bytes of the map
        procedure scan_input(c, h, w, fy, fx, stride, pad, inl : natural) is
            constant oh : natural := (h + 2 * pad - fy) / stride + 1;
            constant ow : natural := (w + 2 * pad - fx) / stride + 1;
            variable py, px, iy, ix : integer;
            variable valid : boolean;
        begin
            set_cfg(1, c, h, w, fy, fx, stride, pad, inl, 16);
            for oy in 0 to oh - 1 loop
                for ox in 0 to ow - 1 loop
                    for cc in 0 to c - 1 loop
                        for yy in 0 to fy - 1 loop
                            for xx in 0 to fx - 1 loop
                                py := oy * stride + yy;     -- row in the padded image
                                px := ox * stride + xx;
                                valid := py >= pad and py < pad + h and px >= pad and px < pad + w;
                                iy := py - pad;
                                ix := px - pad;
                                apply(0, oy, ox, cc, yy, xx);
                                check((s_x_valid = '1') = valid, "scan valid at oy/ox/fy/fx "
                                      & integer'image(oy) & "/" & integer'image(ox) & "/"
                                      & integer'image(yy) & "/" & integer'image(xx));
                                if valid then
                                    if inl = 1 then
                                        check(x_off = (cc * h + iy) * w + ix, "scan x offset at oy/ox/fy/fx "
                                              & integer'image(oy) & "/" & integer'image(ox) & "/"
                                              & integer'image(yy) & "/" & integer'image(xx));
                                    else
                                        check(x_off >= 0 and x_off < c * h * w, "scan x offset in the map");
                                    end if;
                                end if;
                            end loop;
                        end loop;
                    end loop;
                end loop;
            end loop;
        end procedure scan_input;

        -- 1x1 stride 1 kernel: every input byte is hit exactly once
        procedure prop_input(c, h, w, lanes : natural) is
        begin
            set_cfg(1, c, h, w, 1, 1, 1, 0, lanes, 16);
            for i in 0 to c * h * w - 1 loop
                v_seen(i) := false;
            end loop;
            for cc in 0 to c - 1 loop
                for yy in 0 to h - 1 loop
                    for xx in 0 to w - 1 loop
                        apply(0, yy, xx, cc, 0, 0);
                        if s_x_valid /= '1' then
                            fail("input pixel reported as padding");
                        elsif x_off < 0 or x_off >= c * h * w then
                            fail("input offset out of range " & integer'image(x_off));
                        elsif v_seen(x_off) then
                            fail("input byte used twice " & integer'image(x_off));
                        else
                            v_seen(x_off) := true;
                        end if;
                    end loop;
                end loop;
            end loop;
            v_checks := v_checks + 1;
        end procedure prop_input;
    begin
        -- stem: input 112x112x1 plain, 16 output channels, 3x3, stride 2, pad 1
        set_cfg(16, 1, 112, 112, 3, 3, 2, 1, 1, 16);
        apply(5, 0, 1, 0, 1, 1);
        expect(true, 2, 49, 20, 84, "stem k5 oy0 ox1 fy1 fx1");
        apply(5, 0, 1, 0, 0, 1);
        expect(false, -1, 46, 20, 84, "stem top padding row");
        apply(5, 0, 0, 0, 1, 0);
        expect(false, -1, 48, 20, 20, "stem left padding column");
        apply(15, 55, 55, 0, 2, 2);   -- last term of the last output
        expect(true, 12543, 143, 60, 200700, "stem last term");
        apply(0, 0, 0, 0, 0, 0);
        expect(false, -1, 0, 0, 0, "stem first term");

        -- only i_k changes, the outputs that depend on it must follow
        apply(3, 0, 0, 0, 0, 0);
        expect(false, -1, 27, 12, 12, "k = 3");
        s_k <= 4;
        wait for 1 ns;
        expect(false, -1, 36, 16, 16, "k changed to 4");

        -- blocked input layout, 56x56, c = 3 at (2, 3) and the second channel block
        set_cfg(16, 16, 56, 56, 3, 3, 1, 1, 16, 16);
        apply(0, 1, 2, 3, 2, 2);   -- iy = 2, ix = 3
        expect(true, 1843, -1, 0, -1, "blocked c3 at (2,3)");
        set_cfg(32, 32, 28, 28, 3, 3, 1, 1, 16, 16);
        apply(0, 5, 6, 17, 0, 0);  -- iy = 4, ix = 5, channel 17
        expect(true, 14417, -1, 0, -1, "blocked c17 at (4,5)");

        -- 5x5 input, 3x3 kernel, stride 2, pad 1: rows are padding for (oy, fy) = (0, 0) and (2, 2)
        set_cfg(1, 1, 5, 5, 3, 3, 2, 1, 1, 16);
        for oy in 0 to 2 loop
            for fy in 0 to 2 loop
                apply(0, oy, 1, 0, fy, 1);
                expect(not ((oy = 0 and fy = 0) or (oy = 2 and fy = 2)), (oy * 2 - 1 + fy) * 5 + 2, -1, -1, -1,
                       "5x5 rows oy " & integer'image(oy) & " fy " & integer'image(fy));
            end loop;
        end loop;

        -- properties on the real layer shapes: k, c, h, w, fy, fx, stride, pad, in lanes, out lanes
        prop_layer(16, 1, 112, 112, 3, 3, 2, 1, 1, 16);     -- stem
        prop_layer(16, 16, 56, 56, 3, 3, 1, 1, 16, 16);     -- block 1 conv
        prop_layer(32, 16, 56, 56, 3, 3, 2, 1, 16, 16);     -- b2c1
        prop_layer(32, 16, 56, 56, 1, 1, 2, 0, 16, 16);     -- b2sc
        prop_layer(64, 64, 14, 14, 3, 3, 1, 1, 16, 16);     -- b3c2
        prop_layer(16, 3, 7, 9, 3, 3, 2, 1, 1, 16);         -- odd shape

        -- padding and the plain input offset, padded coordinates model
        scan_input(1, 112, 112, 3, 3, 2, 1, 1);             -- stem
        scan_input(3, 7, 9, 3, 3, 2, 1, 1);
        scan_input(2, 6, 5, 3, 3, 1, 1, 1);
        scan_input(2, 4, 4, 1, 1, 2, 0, 1);                 -- 1x1 stride 2
        scan_input(16, 56, 56, 3, 3, 1, 1, 16);             -- blocked, range only
        scan_input(16, 56, 56, 3, 3, 2, 1, 16);
        scan_input(32, 8, 8, 1, 1, 2, 0, 16);

        -- the blocked and plain input layouts map every byte once
        prop_input(16, 56, 56, 16);
        prop_input(32, 28, 28, 16);
        prop_input(64, 14, 14, 16);
        prop_input(1, 112, 112, 1);
        prop_input(3, 7, 9, 1);

        report integer'image(v_checks) & " checks, " & integer'image(v_errors) & " errors";
        if v_errors > 0 then
            report "FAIL" severity failure;
        else
            report "PASS";
        end if;
        wait;
    end process stim;

end architecture sim;
