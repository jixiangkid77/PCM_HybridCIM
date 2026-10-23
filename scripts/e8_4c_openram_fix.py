#!/usr/bin/env python3
"""
e8_4c_openram_fix.py   (P2R-E8.4c: OpenRAM's SRAM compiler with one routing correction)

What it corrects (found in the sandbox, 2026-10-16; claude/p2r-e8-4c-sandbox.md):
  OpenRAM e16d9eb, sram_1bank.route_control_logic, connects every control-logic output (p_en_bar, s_en,
  w_en, wl_en) to the bank's vertical M2 bus with connect_vbus: a horizontal M3 wire at the height of the
  control-logic pin, from the pin to the bus. Inside the bank, the column-decoder outputs reach the column
  multiplexer's select lines sel_0 ... sel_(n-1) on horizontal M3 wires that start left of these buses. With
  16 words per row (16 select lines) the band of select lines covers the height of the p_en_bar pin, so the
  M3 wire of p_en_bar lies on top of the wire of sel_7: precharge enable and the 8th column select are one
  net (sandbox: 256-byte and 1 KB macros of the manuscript's configuration; netgen: one net fewer, p_en_bar0
  merged with sel_7; simulation: the 256-byte macro reads wrong and draws about 330 uW with the clock
  stopped).
  The correction: a control signal whose M3 wire would run inside the band of select lines (with two M3
  pitches of clearance on each side) is routed on M3 from its pin four M3 pitches to the side, then
  vertically to a height below the band (above it if another control signal is already near that height),
  then horizontally to its bus, where it drops to M2 as before. Every other wire, the placement and the
  macro size are unchanged.

How it runs: exactly the steps of OpenRAM's sram_compiler.py, with sram_1bank.route_control_logic replaced
  in memory before the SRAM is built. OpenRAM's files are not changed.
  Run from the OpenRAM folder after "source ./setpaths.sh", as sram_compiler.py:
      python3 -u <path>/e8_4c_openram_fix.py -v <config.py>
  Besides OpenRAM's outputs it writes <output_path>/<output_name>.e8fix.json (each control signal: pin
  height, band, moved or not, new height) and prints the same lines starting with "E8FIX".

Place  : scripts/
Status : NEW FILE.
"""
import copy
import datetime
import json
import os
import sys

sys.path.insert(0, os.getcwd())          # OpenRAM's common.py, as for sram_compiler.py (run from the OpenRAM folder)
from common import *                     # noqa: E402,F401,F403  (OpenRAM's own helper, provides make_openram_package)

make_openram_package()                   # noqa: F405
import openram                           # noqa: E402

(OPTS, args) = openram.parse_args()
if len(args) != 1:
    print(openram.USAGE)
    sys.exit(2)
OPTS.top_process = 'openram'
from openram import debug                # noqa: E402

openram.init_openram(config_file=args[0])
openram.setup_bitcell()
openram.print_banner()
start_time = datetime.datetime.now()
openram.print_time("Start", start_time)
openram.report_status()
debug.print_raw("Words per row: {}".format(OPTS.words_per_row))

import importlib                         # noqa: E402
from openram.base import vector          # noqa: E402

# the class sram_1bank (openram.modules re-exports the class under the module's name, so the module is taken
# from importlib and the class from it; sram.py imports the same class object)
_sram_1bank_module = importlib.import_module("openram.modules.sram_1bank")
SRAM_1BANK = getattr(_sram_1bank_module, "sram_1bank", _sram_1bank_module)

FIXLOG = []


def _select_band(self, port):
    """height range (top-level coordinates) of the column-select pins sel_* of the port's column multiplexer"""
    pd_inst = self.bank.port_data_inst[port]
    names = sorted(n for n in pd_inst.mod.pin_map if n.startswith("sel_"))
    lo = hi = None
    for n in names:
        p = copy.deepcopy(pd_inst.get_pin(n))                         # bank coordinates
        p.transform(self.bank_inst.offset, self.bank_inst.mirror, self.bank_inst.rotate)
        lo = p.by() if lo is None else min(lo, p.by())
        hi = p.uy() if hi is None else max(hi, p.uy())
    return names, lo, hi


def route_control_logic_e8fix(self):
    """sram_1bank.route_control_logic of OpenRAM e16d9eb with the correction described in the file header"""
    for port in self.all_ports:
        names, lo, hi = _select_band(self, port)
        clear = 2 * self.m3_pitch
        signals = [s for s in self.control_logic_outputs[port] if "clk" not in s]
        src_y = {s: self.control_logic_insts[port].get_pin(s).cy() for s in signals}
        for signal in signals:
            src_pin = self.control_logic_insts[port].get_pin(signal)
            dest_pin = self.bank_inst.get_pin(signal + "{}".format(port))
            y = src_pin.cy()
            rec = {"port": port, "signal": signal, "pin_y_um": round(y, 4), "select_lines": len(names),
                   "band_um": None if lo is None else [round(lo, 4), round(hi, 4)], "moved": False}
            if lo is not None and lo - clear < y < hi + clear:
                below = lo - clear
                above = hi + clear
                others = [v for s, v in src_y.items() if s != signal]
                y_new = below
                if any(abs(v - y_new) < clear for v in others):
                    y_new = above
                rightward = src_pin.cx() < dest_pin.cx()
                in_pos = src_pin.rc() if rightward else src_pin.lc()
                # the vertical part runs four M3 pitches away from the control logic: right at the pin it would
                # come closer than the M3 spacing to the control logic's own M3 shapes (sandbox, magic DRC met3.2)
                x_jog = in_pos.x + (4 if rightward else -4) * self.m3_pitch
                mid0 = vector(x_jog, in_pos.y)
                mid1 = vector(x_jog, y_new)
                mid2 = vector(dest_pin.cx(), y_new)
                self.add_via_stack_center(from_layer=src_pin.layer, to_layer="m3", offset=in_pos)
                self.add_path("m3", [in_pos, mid0, mid1, mid2])
                self.add_via_stack_center(from_layer="m3", to_layer=dest_pin.layer, offset=mid2)
                rec.update({"moved": True, "new_y_um": round(y_new, 4), "jog_x_um": round(x_jog, 4),
                            "conflict_free_of_other_pins": not any(abs(v - y_new) < clear for v in others)})
            else:
                self.connect_vbus(src_pin, dest_pin)
            FIXLOG.append(rec)
            print("E8FIX " + json.dumps(rec), flush=True)

    if self.has_rbl:                     # unchanged from OpenRAM e16d9eb
        for port in self.all_ports:
            src_pin = self.control_logic_insts[port].get_pin("rbl_bl")
            dest_pin = self.bank_inst.get_pin("rbl_bl_{0}_{0}".format(port))
            self.add_wire(self.m3_stack,
                          [src_pin.center(), vector(src_pin.cx(), dest_pin.cy()), dest_pin.rc()])
            self.add_via_stack_center(from_layer=src_pin.layer,
                                      to_layer="m4",
                                      offset=src_pin.center())
            self.add_via_stack_center(from_layer=dest_pin.layer,
                                      to_layer="m3",
                                      offset=dest_pin.center())


SRAM_1BANK.route_control_logic = route_control_logic_e8fix
print("E8FIX sram_1bank.route_control_logic replaced (OpenRAM {})".format(getattr(openram, "__version__", "?")), flush=True)

output_extensions = ["lvs", "sp", "v", "lib", "py", "html", "log"]
if not OPTS.netlist_only:
    output_extensions.extend(["lef", "gds"])
output_files = ["{0}{1}.{2}".format(OPTS.output_path, OPTS.output_name, x) for x in output_extensions]
debug.print_raw("Output files are: ")
for path in output_files:
    debug.print_raw(path)

from openram import sram                 # noqa: E402

s = sram()
s.save()
with open("{0}{1}.e8fix.json".format(OPTS.output_path, OPTS.output_name), "w") as fh:
    json.dump({"routes": FIXLOG, "openram_commit_expected": "e16d9eb"}, fh, indent=1)

openram.end_openram()
openram.print_time("End", datetime.datetime.now(), start_time)
