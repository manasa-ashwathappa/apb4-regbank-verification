#!/usr/bin/env python3
# Regenerates the two-file EDA Playground build from rtl/ and tb/.
# Run from the repository root:  python3 edaplayground/make_edap.py
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TB = os.path.join(ROOT, "tb")

def read(*p):
    return open(os.path.join(ROOT, *p)).read()

def inline_includes(text):
    return re.sub(r'^\s*`include "(.+)"\s*$',
                  lambda m: open(os.path.join(TB, m.group(1))).read(),
                  text, flags=re.M)

design_hdr = """// =============================================================================
// design.sv  (EDA Playground build)
//
// SVA switch. The free Aldec Riviera-PRO licence on EDA Playground refuses to
// elaborate any module that contains concurrent assertions, so they are
// switched OFF by default here. On Synopsys VCS, Cadence Xcelium or Siemens
// Questa, delete or comment out the next line to enable all SVA checks.
// =============================================================================
`define NO_SVA

"""

tb_hdr = """// =============================================================================
// testbench.sv  (EDA Playground single-file build)
//
// All testbench sources concatenated in compile order:
//   apb_if.sv -> apb_protocol_checker.sv -> regbank_tb_pkg (classes) -> tb_top.sv
// The multi-file version lives in tb/ of the project repository.
//
// Run Options: +TEST=rand_test   (or reset_test, strb_test, irq_w1c_test,
//                                 err_test)
// Use edaplayground/riviera/ for Aldec Riviera-PRO, edaplayground/vcs/ otherwise.
// =============================================================================
"""

def strip_sva(text):
    # Physically remove every `ifndef NO_SVA ... `endif block, so the output
    # contains no concurrent assertions at all, whatever the tool's defines.
    out = re.sub(r"^`ifndef NO_SVA.*?^`endif[^\n]*\n", "", text, flags=re.M | re.S)
    out = out.replace("// NO_SVA: some free simulator licences (e.g. Riviera on EDA Playground)\n"
                      "// refuse to elaborate modules containing concurrent assertions.\n",
                      "//   (removed in this Riviera build - see file header)\n")
    assert "assert property" not in out
    return out

rtl = read("rtl", "apb_regbank.sv")
tb = read("tb", "apb_if.sv") + "\n" + read("tb", "apb_protocol_checker.sv") + "\n" \
     + inline_includes(read("tb", "regbank_tb_pkg.sv")) + "\n" + read("tb", "tb_top.sv")

base = os.path.join(ROOT, "edaplayground")
for sub in ("riviera", "vcs"):
    os.makedirs(os.path.join(base, sub), exist_ok=True)

# Riviera (free tier): assertion code removed from the source.
riv_note = design_hdr.replace(
    "switched OFF by default here. On Synopsys VCS, Cadence Xcelium or Siemens\n"
    "// Questa, delete or comment out the next line to enable all SVA checks.\n"
    "// =============================================================================\n"
    "`define NO_SVA\n",
    "physically removed from this copy. Use the files in edaplayground/vcs/ on\n"
    "// Synopsys VCS, Cadence Xcelium or Siemens Questa to get all SVA checks.\n"
    "// =============================================================================\n")
assert riv_note != design_hdr
open(os.path.join(base, "riviera", "design.sv"), "w").write(riv_note + strip_sva(rtl))
open(os.path.join(base, "riviera", "testbench.sv"), "w").write(tb_hdr + strip_sva(tb))

# VCS / Xcelium / Questa: full SVA.
vcs_hdr = "// design.sv (EDA Playground build, full SVA) - for VCS / Xcelium / Questa\n\n"
open(os.path.join(base, "vcs", "design.sv"), "w").write(vcs_hdr + rtl)
open(os.path.join(base, "vcs", "testbench.sv"), "w").write(tb_hdr + tb)
print("wrote edaplayground/riviera/* and edaplayground/vcs/*")
