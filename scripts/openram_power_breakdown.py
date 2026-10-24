#!/usr/bin/env python3
"""Split OpenRAM's analytical power of an SRAM macro over the modules it comes from.

Run from the root of the OpenRAM installation that generated the macro (version 1.2.49, commit e16d9eb), after
`source setpaths.sh`, with the configuration of the macro:
    python3 -u <path>/openram_power_breakdown.py -v <configuration.py>

The macro is built as sram_compiler.py builds it, but no file is written. Its analytical power is then evaluated as
the compiler evaluates it for the timing library (compiler/characterizer/elmore.py, analytical_power: the
top-level module of the macro, at the characterized corner, with the last characterized load), and the same sum is
split over the modules that define their own analytical_power; every other module only adds up its instances
(compiler/base/design.py). The split must add up to the total, which is checked.
"""
import collections
import os
import sys

sys.path.insert(0, os.getcwd())          # common.py of the OpenRAM installation
from common import *                     # noqa: E402,F401,F403
make_openram_package()                   # noqa: F405
import openram                           # noqa: E402

(OPTS, args) = openram.parse_args()
if len(args) != 1:
    print(openram.USAGE)
    sys.exit(2)
OPTS.top_process = 'openram'
openram.init_openram(config_file=args[0])
openram.setup_bitcell()

from openram import sram                 # noqa: E402
from openram.base.design import design   # noqa: E402
from openram.tech import spice           # noqa: E402

top = sram()
macro = top.s                            # the object passed to lib(...) in sram.save()
corner = (OPTS.process_corners[0], OPTS.supply_voltages[0], OPTS.temperatures[0])
# the loads of the library as compiler/characterizer/lib.py (prepare_tables) chooses them; the analytical model
# takes the last one (compiler/characterizer/elmore.py, analytical_power: "only last load is used")
default_loads = [x * spice["dff_in_cap"] for x in OPTS.load_scales]
if OPTS.use_specified_load_slew is None:
    loads = default_loads
else:
    loads = [ls[0] for ls in OPTS.use_specified_load_slew]
load = loads[-1]
print(f"corner {corner}, loads of the library {loads} fF (the model takes the last, {load} fF), event frequency "
      f"{spice['default_event_frequency']} MHz, min_tx_drain_c {spice['min_tx_drain_c']} fF, rbl_delay_percentage "
      f"{OPTS.rbl_delay_percentage}, netlist_only {OPTS.netlist_only}")

total = macro.analytical_power(corner, load)
dyn = collections.defaultdict(float)
leak = collections.defaultdict(float)
count = collections.Counter()
per_inst = collections.defaultdict(set)
by_parent = collections.Counter()
arrays = []


def walk(mod, parent="(top)"):
    if type(mod).analytical_power is design.analytical_power:
        for inst in mod.insts:
            walk(inst.mod, type(mod).__name__)
        return
    p = mod.analytical_power(corner, load)
    key = type(mod).__name__
    dyn[key] += p.dynamic
    leak[key] += p.leakage
    count[key] += 1
    per_inst[key].add(round(p.dynamic, 6))
    by_parent[(parent, key, round(p.dynamic, 6))] += 1
    if hasattr(mod, "gen_bl_wire") and hasattr(mod, "row_size"):
        bl = mod.gen_bl_wire()
        arrays.append((key, mod.name, mod.row_size, mod.column_size, 2 * bl.return_input_cap(), p.dynamic, p.leakage))


walk(macro)
print(f"total from the model: dynamic {total.dynamic:.6f} nW = {total.dynamic / 1e6:.9f} mW,"
      f" leakage {total.leakage:.3f} nW")
alt = macro.analytical_power(corner, default_loads[-1])
print(f"for comparison, with the compiler's default loads {default_loads} fF (load_scales x dff_in_cap), the model "
      f"takes {default_loads[-1]} fF: dynamic {alt.dynamic:.6f} nW = {alt.dynamic / 1e6:.9f} mW, leakage {alt.leakage:.3f} nW")
print(f"sum of the split:     dynamic {sum(dyn.values()):.6f} nW, leakage {sum(leak.values()):.3f} nW")
assert abs(sum(dyn.values()) - total.dynamic) <= 1e-6 * total.dynamic
assert abs(sum(leak.values()) - total.leakage) <= 1e-6 * max(total.leakage, 1.0)
print("\nmodule class, instances, dynamic mW, share of dynamic, leakage uW, distinct per-instance dynamic values (nW)")
for key in sorted(dyn, key=lambda k: -dyn[k]):
    vals = sorted(per_inst[key])
    shown = ", ".join(f"{v:g}" for v in vals[:6]) + (" ..." if len(vals) > 6 else "")
    print(f"{key:40s} {count[key]:6d} {dyn[key] / 1e6:10.6f} {dyn[key] / total.dynamic:8.2%}"
          f" {leak[key] / 1e3:10.3f}   [{shown}]")
print("\nthe same split by the module that holds each instance: holder class, module class, instances, dynamic per"
      " instance (nW), dynamic mW")
for (parent, key, val), n in sorted(by_parent.items(), key=lambda kv: -kv[0][2] * kv[1]):
    if val > 0:
        print(f"{parent:32s} {key:36s} {n:6d} {val:12g} {n * val / 1e6:10.6f}")
print("\nbit-cell arrays (bit-line term): class, name, rows, columns, bit-line capacitance per column in the model"
      " (fF), dynamic mW, leakage uW")
for key, name, rows, cols, c_bl, d, lk in arrays:
    print(f"{key} {name} {rows} x {cols}: {c_bl:.3f} fF, {d / 1e6:.6f} mW, {lk / 1e3:.3f} uW")
openram.end_openram()
