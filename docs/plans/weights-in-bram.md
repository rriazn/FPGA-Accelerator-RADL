# Weights in BRAM (task 4.1, weight part) implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status 2026-11-28: plan only, nothing implemented. Owner: Roman (weights). The input line buffers of 4.1 are Olim's part and not in this plan.

**Goal:** v2 of the accelerator: all conv weights and biases sit in on-chip ROMs initialized at synthesis from `.mem` files, so the engine reads only the input `x` from DDR (v1 reads `x`, `w` and the bias per MAC).

**Architecture:** `export.py` concatenates the per-layer `.mem` files into one weight image and one bias image plus a map of offsets. A new `weight_rom` (byte-wide weight ROM, int32 bias ROM, BRAM, one clock read latency with enable) connects directly to the BRAM-like `w`/`b` ports that `conv_core_v1` already has. A new `conv_engine_v2` is `conv_engine_v1` without the weight and bias AXI reads. W_BASE and B_BASE keep their offsets but now hold byte offsets into the ROMs; a read-only VERSION register (0x44) tells the driver which meaning applies, so one driver runs v1 and v2 bitstreams.

**Tech stack:** VHDL-2008 (GHDL 6 mcode for simulation, Vivado for synthesis), Python 3.6 + numpy in `radl-tf1`, C11 in `radl-tf1`.

**Spec:** [architecture-spec.md](architecture-spec.md) (sections 4, 6.2, open point 2), [vhdl-accelerator-tasks.md](vhdl-accelerator-tasks.md) task 4.1, [addr-gen-rewrite.md](addr-gen-rewrite.md) (pointer table, the `w` and `b` rows are unchanged here).

## Decisions (2026-11-28)

| # | Question | Decision |
|---|---|---|
| W1 | How are the weights loaded? | BRAM init from `.mem` files at synthesis; no weight load path from DDR. This settles open point 2 of the spec for v2. |
| W2 | How does the driver select a layer's weights? | W_BASE and B_BASE are **byte offsets into the ROMs** (v2). No register map change; `addr_gen` pointers are unchanged. |
| W3 | Generality (random layers, task 5.3, `tiny_*` testbenches) | **ROM only.** A random layer points W_BASE/B_BASE at any offset inside the network image and uses those bytes as its weights; the reference model reads the same image. Limit: a layer's weights must fit in the image (76,432 B, 336 biases). |
| W4 | ROM shape | **Byte-wide**, plain `[K][C][FY][FX]` order, same as the `.mem` files. Re-banked in 4.2/4.3 when the PE array exists. |
| W5 | v1 next to v2 | New `conv_engine_v2.vhd`, generic `G_ENGINE` in `conv_accel_top`, read-only VERSION register at 0x44 (v1 reads 0 there already, it is reserved). v1 stays buildable. |

Proposals inside this plan (not decided, strike if unwanted): ROM sizes as constants in the generated `quant_pkg.vhd` (Task 1); out-of-range ROM offsets set STATUS.error (Task 3); the `--sim-rom` option of the stand-in (Task 6).

## Global constraints

- VHDL naming: ports `i_`/`o_`, signals `s_`, AXI ports keep `s_axi_*`/`m_axi_*`; reset `i_rst` synchronous active-high, control state reset, datapath (ROM, data registers) not.
- Comments short, one line where possible, no trailing `.`, no special characters.
- `python/` stays Python 3.6 (no walrus, no dataclasses); run in `radl-tf1`.
- C and Python only run in Docker: `docker run --rm -v "${PWD}:/work" -w /work/<dir> radl-tf1 ...`.
- GHDL is the mcode build: run testbenches with `ghdl -r --std=08 --workdir=<dir> <tb>`, never edit sources while a run is going.
- `layers.txt` and the per-layer `.mem` files do not change format (`camus_naive.c` reads them).
- v1 behaviour and all existing testbench runs stay as they are (`G_ENGINE = 1` is the default everywhere).
- Do not commit or push; each task ends with a review stop instead of a commit.
- Every task keeps bit-exactness: the final check is `camus_accel` bit-exact against `test_logits.bin`.

## Review focus

1. **Stale ROM.** A bitstream built from an older export than the files on the board gives wrong logits. Expected: detected, not silent. Covered by the bit-exact check in Task 7; a ROM checksum register is open point 1 below.
2. **W_BASE or B_BASE near 2^32.** `to_integer` on a 32-bit unsigned above 2^31 aborts GHDL. Expected: the ROM returns 0 and the engine flags an error. Test in Task 2 (`0xFFFFFFFF` reads 0) and Task 3 (`G_ROM_ERR`).
3. **Long stalls between terms.** With slow DDR `i_ce` is 0 for many clocks; the ROM output must hold. Test in Task 2 (hold check) and the random ready delays of the existing engine testbenches.
4. **Padding term that is also the bias term.** With pad 1 the first term of every output element at `(oy, ox) = (0, 0)` is a padding position and has `o_b_rd = 1`; the new padding fast path must still enable the bias ROM there. Test: `tiny_a` and `tiny_d` (pad 1) in Task 3, checked against the reference.
5. **Init file not found or wrong length.** Vivado or GHDL could build a ROM of zeros. Expected: elaboration fails. Test: the init function asserts the line count (Task 2); Task 7 checks the synthesis log and `accel_golden`.

---

### Task 1: ROM image files from `export.py`

**Files:**
- Modify: `python/export.py` (new `write_rom()`, called next to the per-layer `.mem` writes, about line 80)
- Modify: `docs/software.md` (exported files list)

**Interfaces:**
- Produces, in `build/export/`:
  - `w_rom.mem`: int8, one per line (2 hex digits), the `<name>_w.mem` contents of the conv layers in `CONVS` order (stem, b1c1, b1c2, b2c1, b2c2, b2sc, b3c1, b3c2, b3sc), no FC. 76,432 lines.
  - `b_rom.mem`: int32, one per line (8 hex digits), the `<name>_b.mem` contents in the same order. 336 lines.
  - `rom_map.txt`: header `# name w_off w_bytes b_off b_bytes  (byte offsets: W_BASE and B_BASE of v2)`, then one row per conv layer, decimal. `b_off` is a multiple of 4.
  - `quant_pkg.vhd`: two more constants, `W_ROM_BYTES : natural := 76432;` and `B_ROM_WORDS : natural := 336;` (proposal: the sizes live here so RTL and testbenches get them from one place).

- [ ] **Step 1: Implement `write_rom(q)` in `python/export.py`**

Use `write_mem()` for both images. Assert inside `write_rom` that the concatenated lengths equal the sums of the per-layer sizes, the same style as the existing asserts.

- [ ] **Step 2: Run the export**

Run: `docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python export.py`
Expected: no assertion, the three new files exist.

- [ ] **Step 3: Check the images against the per-layer files**

Run (host Python, numpy only):
```
python -c "import pathlib as p; d=p.Path('build/export'); W=d.joinpath('w_rom.mem').read_text().split(); B=d.joinpath('b_rom.mem').read_text().split(); rows=[r.split() for r in d.joinpath('rom_map.txt').read_text().splitlines() if not r.startswith('#')]; [print(n, W[int(wo):int(wo)+int(wn)]==d.joinpath(n+'_w.mem').read_text().split(), B[int(bo)//4:(int(bo)+int(bn))//4]==d.joinpath(n+'_b.mem').read_text().split()) for n,wo,wn,bo,bn in rows]; print(len(W), len(B))"
```
Expected: nine lines `<name> True True`, then `76432 336`.

- [ ] **Step 4: Check that `camus_naive` is unaffected**

Run: `docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run`
Expected: `bit-exact ... yes` for `-O0` and `-O2`.

- [ ] **Step 5: Add the three files to the exported files list in `docs/software.md`. Review stop.**

### Task 2: `weight_rom` and the testbench ROM helpers

**Files:**
- Create: `vhdl/src/compute-engine/weight_rom.vhd`
- Create: `vhdl/tests/models/rom_image_pkg.vhd` (simulation only)
- Create: `vhdl/tests/unit/compute-engine/tb_weight_rom.vhd`
- Modify: `docs/plans/vhdl-modules.md` (new section `weight_rom` (4.1); mark the `weight_store`/`weight_loader` sketches as the 4.3 target, not v2)

**Interfaces:**
- Consumes: `w_rom.mem`, `b_rom.mem`, `rom_map.txt`, `W_ROM_BYTES`, `B_ROM_WORDS` from Task 1.
- Produces:

```vhdl
entity weight_rom is
    generic (
        G_W_INIT  : string;     -- path of w_rom.mem
        G_B_INIT  : string;     -- path of b_rom.mem
        G_W_BYTES : positive;   -- W_ROM_BYTES
        G_B_WORDS : positive    -- B_ROM_WORDS
    );
    port (
        i_clk    : in  std_logic;
        i_en     : in  std_logic;                        -- 1 samples both addresses, 0 holds both outputs
        i_w_addr : in  unsigned(AXI_ADDR_W-1 downto 0);  -- byte offset
        i_b_addr : in  unsigned(AXI_ADDR_W-1 downto 0);  -- byte offset, bits 1:0 ignored
        o_w_data : out act_t;                            -- clock after i_en, 0 if i_w_addr >= G_W_BYTES
        o_b_data : out acc_t                             -- clock after i_en, 0 if i_b_addr/4 >= G_B_WORDS
    );
end entity;
```

  `rom_image_pkg`: `type i8_vec is array (natural range <>) of act_t;`, `type i32_vec is array (natural range <>) of acc_t;`, `impure function read_i8_mem(path : string; n : positive) return i8_vec;`, `impure function read_i32_mem(path : string; n : positive) return i32_vec;`, `procedure rom_map_lookup(path, name : string; variable w_off, b_off : out natural);` (fails with a report if the name is missing). Later testbenches use these instead of their own loaders for the ROM image.

- [ ] **Step 1: Write `tb_weight_rom` (generic `G_EXPORT : string := "../build/export"`)**

The reference image comes from `rom_image_pkg`, not from the RTL init function. Checks, each a `report ... severity failure` on mismatch:
- every `i_w_addr` from 0 to `W_ROM_BYTES-1` returns the image byte one clock after `i_en = 1`
- every bias word `i` at `i_b_addr = 4*i` and at `4*i + 2` returns word `i`
- after a read, `i_en = 0` for a random 0 to 20 clocks with a changing address: both outputs keep their value
- `i_w_addr = W_ROM_BYTES`, `i_w_addr = 16#FFFFFFFF#` and `i_b_addr = 4*B_ROM_WORDS` return 0, and the simulation does not stop
- `rom_map_lookup` for `stem` gives (0, 0) and for `b3sc` gives `w_off = W_ROM_BYTES - 2048`, `b_off = 4*(B_ROM_WORDS - 64)` (the last layer ends on the last byte and word)
- ends with `report "PASS"` (the regression script greps for it)

- [ ] **Step 2: Run it, it fails because `weight_rom` does not exist**

Run (from `vhdl/`): `ghdl -a --std=08 --workdir=$W ../build/export/quant_pkg.vhd src/camus_pkg.vhd tests/models/rom_image_pkg.vhd tests/unit/compute-engine/tb_weight_rom.vhd`
Expected: analysis error, unit `weight_rom` not found.

- [ ] **Step 3: Implement `weight_rom`**

Two constant arrays, each filled by an impure init function that reads exactly `G_W_BYTES` (`G_B_WORDS`) lines with `hread` and asserts with severity failure if the file has fewer or more non-empty lines. One clocked process: `if i_en = '1'` sample. Compare the full 32-bit address against the size **before** `to_integer`, and convert only the low bits (17 for the weights). Attribute `rom_style` = `"block"` on both arrays. No reset.

- [ ] **Step 4: Run it**

Run: `ghdl -a ... src/compute-engine/weight_rom.vhd ...` then `ghdl -r --std=08 --workdir=$W tb_weight_rom`
Expected: `PASS`.

- [ ] **Step 5: Add `weight_rom` to `vhdl-modules.md`. Review stop.**

### Task 3: `conv_engine_v2`

**Files:**
- Create: `vhdl/src/compute-engine/conv_engine_v2.vhd` (starts as a copy of `conv_engine_v1.vhd`)
- Modify: `vhdl/tests/integration/tb_conv_engine_v1.vhd` (generic `G_ENGINE`, it tests both engines)
- Modify: `docs/plans/vhdl-modules.md` (section `conv_engine_v2` (4.1))

**Interfaces:**
- Consumes: `weight_rom` (Task 2), `conv_core_v1` unchanged.
- Produces: `conv_engine_v2`, same ports as `conv_engine_v1` plus generics `G_W_INIT`, `G_B_INIT`, `G_W_BYTES`, `G_B_WORDS` (no defaults, passed to `weight_rom`). `i_cfg.w_base`, `i_cfg.b_base` are ROM byte offsets.

Behaviour (the diff to v1):
- Read FSM states `R_IDLE`, `R_X_CMD`, `R_X_RSP`, `R_GO`; the `R_W_*` and `R_B_*` states and their AXI reads are gone.
- `weight_rom` gets the core's `o_w_addr`, `o_b_addr` and `i_en => s_ce`; its outputs drive the core's `i_w_data`, `i_b_data` directly (the core's port contract is the BRAM contract, so no latch is needed).
- **Padding fast path:** in `R_IDLE` a term with `o_term_valid = 1` and `o_x_rd = 0` gets `i_ce` at once (subject to the fifo rule), no AXI read. Such a term can also be the bias term (review focus 4).
- **Range error (proposal):** at a clock with `s_ce = 1` and `o_term_valid = 1`, set the error flag if `o_w_addr >= G_W_BYTES`, or if `o_b_rd = 1` and (`o_b_addr(1 downto 0) /= "00"` or `o_b_addr >= 4*G_B_WORDS`). As in v1 the layer runs to the end and `o_error` pulses with `o_done`.
- Write side, fifo, done and cycle counting: unchanged.

- [ ] **Step 1: Extend `tb_conv_engine_v1` with `G_ENGINE : natural := 1` and `G_ROM_ERR : natural := 0`**

For `G_ENGINE = 2`:
- the DUT is `conv_engine_v2` with the ROM generics from `G_EXPORT` and `quant_pkg`
- weights and bias for the reference come from the ROM image (`rom_image_pkg`): golden layers at their `rom_map.txt` offsets; tiny layers at `tiny_rom_off(name)`: `tiny_a` (0, 0), `tiny_b` (`W_ROM_BYTES - 18*20*9`, `4*(B_ROM_WORDS - 18)`, ends on the last byte and word), `tiny_c` (12345, 4*77), `tiny_d` (1, 4), `tiny_e` (40000, 4*300)
- the command model fails on any read outside the x region, and asserts `x reads = C_X_READS`, `bias reads = 0`, `weight reads = 0`
- `G_ROM_ERR`: 1 = W_BASE one byte too high for the layer to fit, 2 = B_BASE + 2, 3 = B_BASE one word too high; expected: `o_done` comes, `o_error = 1` with it, every result word is written once (values not compared)
- `G_ENGINE = 1` keeps every existing check as it is

- [ ] **Step 2: Run it, it fails because `conv_engine_v2` does not exist**

Run: `ghdl -a ...` with the file list of the testbench header plus `quant_pkg`, `rom_image_pkg`, `weight_rom`
Expected: analysis error, unit `conv_engine_v2` not found.

- [ ] **Step 3: Implement `conv_engine_v2` as described above**

- [ ] **Step 4: Run both engines**

Run: `ghdl -r --std=08 --workdir=$W tb_conv_engine_v1 -gG_ENGINE=<1|2> -gG_LAYER=<l>` for `l` in `tiny_a` to `tiny_e`, then `-gG_ENGINE=2 -gG_ROM_ERR=<1|2|3> -gG_LAYER=tiny_b`, then `-gG_ENGINE=2 -gG_LAYER=b3sc -gG_FRAME=f000 -gG_RUNS=1`
Expected: `PASS` in every run.

- [ ] **Step 5: Add `conv_engine_v2` to `vhdl-modules.md`. Review stop.**

### Task 4: VERSION register

**Files:**
- Modify: `vhdl/src/interface/axi_lite_regs.vhd`
- Modify: `vhdl/tests/unit/interface/tb_axi_lite_regs.vhd`
- Modify: `docs/plans/axi-interfaces.md` section 6 (row 0x44, meaning of W_BASE/B_BASE per version, reserved range now 0x48 to 0x7F)

**Interfaces:**
- Produces: generic `G_VERSION : natural range 0 to 255 := 0` on `axi_lite_regs`; offset 0x44 reads `G_VERSION`, writes are ignored and answered OKAY. With the default the register map is unchanged (0x44 reads 0).

- [ ] **Step 1: Add `G_VERSION` to `tb_axi_lite_regs`; with `G_VERSION = 2` check that 0x44 reads 2, a write to 0x44 does not change it, 0x48 reads 0**
- [ ] **Step 2: Run with `-gG_VERSION=2`, expect FAIL (0x44 reads 0)**
- [ ] **Step 3: Implement the read-only register**
- [ ] **Step 4: Run with the default and with `-gG_VERSION=2`, expect `PASS` in both**
- [ ] **Step 5: Update `axi-interfaces.md`. Review stop.**

### Task 5: Top level, AXI testbenches, regression

**Files:**
- Modify: `vhdl/src/conv_accel_top.vhd`
- Modify: `vhdl/src/conv_accel_bd_zed.vhd`, `vhdl/src/conv_accel_bd.vhd` (generic map only, ports unchanged)
- Modify: `vhdl/tests/integration/tb_conv_engine_axi.vhd`, `vhdl/tests/integration/tb_conv_accel_top.vhd`
- Modify: `vhdl/tests/run_axi_regression.sh`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces: `conv_accel_top` generics `G_ENGINE : natural range 1 to 2 := 1`, `G_W_INIT`, `G_B_INIT : string := ""`, `G_W_BYTES`, `G_B_WORDS : positive := 1` (ignored when `G_ENGINE = 1`). An if-generate picks the engine; `axi_lite_regs` gets `G_VERSION => 0` for v1 and `2` for v2. The wrappers pass `G_ENGINE => 2`, `W_ROM_BYTES`, `B_ROM_WORDS` from `quant_pkg` and the file names `"w_rom.mem"`, `"b_rom.mem"` (whether Vivado finds a bare file name is checked in Task 7).

- [ ] **Step 1: Give both AXI testbenches `G_ENGINE` and `G_ROM_ERR` with the same meaning as in Task 3**

Differences to Task 3: for v2 the weight region of `axi_mem_model` is not loaded, `G_ERR = 1` (SLVERR) targets the first input beat instead of the first weight beat, and `tb_conv_accel_top` also reads VERSION through AXI-Lite (0 for v1, 2 for v2). W_BASE/B_BASE are written through AXI-Lite as the ROM offsets.

- [ ] **Step 2: Run `tb_conv_accel_top -gG_ENGINE=2 -gG_LAYER=tiny_a`, expect FAIL (generic or entity missing)**

- [ ] **Step 3: Implement the top level generics and the wrapper generic maps**

- [ ] **Step 4: Extend `run_axi_regression.sh`**

Analyse `../build/export/quant_pkg.vhd`, `rom_image_pkg`, `weight_rom`, `conv_engine_v2`; stop with a clear message if `../build/export/w_rom.mem` is missing. Add `tb_weight_rom`, `tb_axi_lite_regs -gG_VERSION=2`, and repeat the `tb_conv_engine_v1`, AXI-P5 and top level blocks with `-gG_ENGINE=2` (including the three `G_ROM_ERR` runs; `--golden` adds `b3sc` for v2 too). Note in the header that GHDL mcode cannot run the script as written (handover section 7); run the same list with `ghdl -r`.

- [ ] **Step 5: Run the full list for the ZedBoard**

Run: every line of the script with `ghdl -r --std=08 --workdir=$W ...`
Expected: all runs `PASS`, the v1 runs unchanged.

- [ ] **Step 6: Review stop.**

### Task 6: C side (driver, stand-in, programs)

**Files:**
- Create: `c/rom_map.h`
- Modify: `c/accel_regs.h`, `c/accel.h`, `c/accel.c`
- Modify: `c/accel_sim.h`, `c/accel_sim.c`, `c/platform_cli.c`, `c/platform_cli.h`
- Modify: `c/camus_accel.c`, `c/accel_golden.c`, `c/accel_probe.c`
- Modify: `c/Makefile` (`ACCEL_HDR`, the package file lists, `run-accel`)

**Interfaces:**
- Consumes: `rom_map.txt`, `w_rom.mem`, `b_rom.mem` (Task 1), VERSION (Task 4).
- Produces:
  - `#define ACCEL_REG_VERSION 0x44` in `accel_regs.h`
  - `int accel_version(const platform_t *p);` (reads VERSION) in `accel.h`/`accel.c`
  - `accel_layer_t` gets `uint32_t w_off, b_off;`. If `wt == NULL` (v2), `accel_run` writes `w_off`/`b_off` to W_BASE/B_BASE and flushes neither buffer; otherwise v1 as today.
  - `rom_map.h`: `static int rom_map_lookup(const char *dir, const char *name, uint32_t *w_off, uint32_t *w_bytes, uint32_t *b_off);` returns 0, or -1 if the name or the file is missing
  - stand-in: `int sim_load_rom(sim_t *s, const char *export_dir);` after it VERSION reads 2, W_BASE/B_BASE are offsets into the loaded images and an out-of-range offset sets STATUS.error; without it the stand-in is v1
  - `platform_cli`: option `--sim-rom <export_dir>` (stand-in only, error with `--regs`) calls `sim_load_rom` (proposal)
- Programs: `camus_accel` and `accel_golden` read VERSION once; at 2 they skip the weight upload, take the offsets from `rom_map.txt`, and die if a layer's `w_bytes` differs from `K*C*FY*FX` of `layers.txt`. `accel_probe` prints VERSION, accepts 0 or 2, and does the "unmapped reads 0" check at 0x48 instead of 0x44.

- [ ] **Step 1: Add v2 runs to `run-accel` in the Makefile**

```make
	./accel_probe --sim-rom $(EXPORT)
	set -e; for l in $(GOLDEN_LAYERS); do ./accel_golden $(EXPORT) $$l --sim-rom $(EXPORT); done
	./camus_accel $(EXPORT) --sim-rom $(EXPORT)
```

- [ ] **Step 2: Run it, expect FAIL (unknown option `--sim-rom`)**

Run: `docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run-accel`

- [ ] **Step 3: Implement the interfaces above**

- [ ] **Step 4: Run it**

Run: `docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run-accel`
Expected: both probe runs pass (VERSION 0, then 2), all 18 `accel_golden` runs match, both `camus_accel` runs report bit-exact on all 200 frames.

- [ ] **Step 5: Check that the board builds still compile**

Run: `docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make package-accel`
Expected: `build/board-accel.tar.gz` contains `c/rom_map.h` and `build/export/rom_map.txt`.

- [ ] **Step 6: Review stop.**

### Task 7: Synthesis and board run (v2 data point)

**Files:**
- Modify: `docs/plans/vivado-block-design.md` (source list: `weight_rom`, `conv_engine_v2`, `quant_pkg.vhd`, the two `.mem` files)
- Modify: `docs/plans/vhdl-accelerator-tasks.md` (4.1 row: result), this file (Result section)

**Interfaces:**
- Consumes: everything above, the existing ZedBoard block design.

- [ ] **Step 1: Add the new sources to the Vivado project as in `vivado-block-design.md`; `quant_pkg.vhd` as VHDL 2008, the wrapper stays plain VHDL**

- [ ] **Step 2: Synthesize and check the ROMs**

Expected in the synthesis log: both `.mem` files are read (no "could not open"), no assertion from the init functions; in the utilization report the weight ROM is block RAM (about 19 to 24 BRAM36 on the XC7Z020, *estimate*), not LUTs. If the bare file name is not found, set the full path in the wrapper and note it in `vivado-block-design.md`. If Vivado rejects `hread`, replace it in the init function by a hex character parse (still `.mem`).

- [ ] **Step 3: Implement with the real clock constraint at the v1 board clock (about 66.7 MHz) and record WNS/TNS**

- [ ] **Step 4: Run on the ZedBoard (procedure as in [run-accelerator-on-board.md](../run-accelerator-on-board.md))**

Expected: `accel_probe` passes and prints VERSION 2; `accel_golden` matches on all nine layers; `camus_accel` bit-exact on 5 frames. Record clocks per frame, clocks per MAC and seconds per frame at the same PL clock as the v1 point of 2026-11-25 (2,245,339,410 clocks, 60.1 per MAC, 33.80 s), and the BRAM count.

- [ ] **Step 5: Write the Result section below and the 4.1 result in the task list. Review stop.**

## Expected effect (*estimate*, not measured)

v1 needs about 45 clocks of logic plus about 230 ns of DDR wait per MAC ([addr-gen-rewrite.md](addr-gen-rewrite.md#result), two-point fit). v2 removes the weight read of every term and the bias read of every output element, and padding terms no longer wait for anything. With one DDR read left per MAC instead of two, a rough guess is half the clocks per MAC (about 30), so about 17 s per frame at 66.7 MHz. The previous prediction of this kind was wrong by a wide margin, so only the board number counts. The input line buffers (Olim) remove the remaining x reads.

## Open points

1. **ROM checksum (proposal).** A read-only register with a checksum of the ROM image (generated into `quant_pkg`), compared by the driver with `w_rom.mem`, would turn a stale bitstream (review focus 1) into a clear error instead of wrong logits. Not part of the tasks above.
2. **Merge with the line buffers.** Olim's input line buffers replace the `R_X_*` path of the same engine. Agree who edits `conv_engine_v2.vhd` first; the weight side touches only the `w`/`b` ports and the error flag.
3. **Re-banking for 4.2/4.3.** The byte-wide ROM gives one weight per clock. The 9-tap and 16-lane steps need a new image layout from `export.py` and the banked `weight_store` of `vhdl-modules.md`; W_BASE/B_BASE stay offsets.
4. **Ultra96.** BRAM count and the ROM path are checked on the ZedBoard only; repeat Task 7 steps 2 and 3 for the Ultra96 wrapper.

## Result

Not run yet.
