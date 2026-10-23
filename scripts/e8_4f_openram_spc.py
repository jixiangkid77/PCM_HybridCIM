#!/usr/bin/env python3
"""
e8_4f_openram_spc.py   (P2R-E8.4f: OpenRAM's SRAM compiler with the sense-side precharge drawn in the layout)

What it adds (claude/p2r-e8-4c-results.md, KID 2026-10-17 21:45 chose S; claude/p2r-e8-plan.md, E8.4f):
  E8.4c found that the 4 KB macro (16 words per row) reads wrong because the column multiplexer has only
  NMOS pass gates: the sense-amplifier input on the side discharged by the previous read recovers only to
  about 1.15 V. The fix chosen (S) was a copy of OpenRAM's column precharge cell (2 pull-up PMOS and
  1 equalizer, W 0.55 um, L 0.15 um, gate on p_en_bar) on the two inputs of each data sense amplifier,
  added to the simulation netlist only. This compiler draws them in the layout:
    - port_data gets a second precharge array, "sense precharge", with one precharge cell per data bit on
      bl_out_<bit> / br_out_<bit> (the column multiplexer's outputs = the sense amplifier's inputs); the
      cells sit at the x of the first column of each bit's group, mirrored as that column's bitcell;
    - it is placed between the column multiplexer and the sense amplifiers (the vertical order of
      port_data becomes: precharge, column multiplexer, sense precharge, sense amplifiers, write drivers);
    - bitlines: column multiplexer -> sense precharge -> sense amplifiers (OpenRAM's connect_bitlines);
      the spare column keeps its route from the main precharge array to its sense amplifier;
    - enable: the sense precharge's en_bar rail (M3) is extended to the left into the replica column and
      joined to the main precharge's en_bar rail (port_data pin p_en_bar) by a vertical M2 wire there;
      p_en_bar stays one pin of port_data;
    - supply: its vdd pins are copied up like those of every other instance of port_data.
  The spare column's sense amplifier needs no cell: it is on a precharged column (no multiplexer).
  Everything else is OpenRAM e16d9eb, plus the routing correction of E8.4c (sram_1bank.route_control_logic,
  scripts/e8_4c_openram_fix.py, included here unchanged).
  Only for a port with a column multiplexer, a read port, a replica column on its left (port 0): the
  configuration of the manuscript's macro (1rw, 16 words per row). Anything else stops with an error.

How it runs: exactly the steps of OpenRAM's sram_compiler.py, with the methods replaced in memory before
  the SRAM is built. OpenRAM's files are not changed.
  Run from the OpenRAM folder after "source ./setpaths.sh", as sram_compiler.py:
      python3 -u <path>/e8_4f_openram_spc.py -v <config.py>
  Besides OpenRAM's outputs it writes <output_path>/<output_name>.e8spc.json (the cells, their offsets, the
  enable connection, the E8.4c routes) and prints the same lines starting with "E8SPC" / "E8FIX".

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

FIXLOG = []
SPCLOG = []

# ------------------------------------------------------------------ E8.4c: the routing correction (unchanged)
_sram_1bank_module = importlib.import_module("openram.modules.sram_1bank")
SRAM_1BANK = getattr(_sram_1bank_module, "sram_1bank", _sram_1bank_module)


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
    """sram_1bank.route_control_logic of OpenRAM e16d9eb with the correction of scripts/e8_4c_openram_fix.py"""
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
print("E8FIX sram_1bank.route_control_logic replaced (OpenRAM {})".format(getattr(openram, "__version__", "?")),
      flush=True)

# ------------------------------------------------------------------ E8.4f: the sense precharge in port_data
_pd_module = importlib.import_module("openram.modules.port_data")
PORT_DATA = getattr(_pd_module, "port_data", _pd_module)
_pa_module = importlib.import_module("openram.modules.precharge_array")
PRECHARGE_ARRAY = getattr(_pa_module, "precharge_array", _pa_module)

_orig_add_modules = PORT_DATA.add_modules
_orig_create_instances = PORT_DATA.create_instances
_orig_compute_instance_offsets = PORT_DATA.compute_instance_offsets
_orig_place_instances = PORT_DATA.place_instances
_orig_route_sense = PORT_DATA.route_sense_amp_to_column_mux_or_precharge_array
_orig_route_control_pins = PORT_DATA.route_control_pins


class sense_precharge_array(PRECHARGE_ARRAY):
    """OpenRAM's precharge array with one cell per data bit; cell i mirrored as the bitcell of column col_index[i]
    (OpenRAM's precharge_array mirrors by the cell's own index, which is right only for consecutive columns)"""

    def __init__(self, name, columns, offsets, col_index, bitcell_bl, bitcell_br):
        self.col_index = list(col_index)
        super().__init__(name=name, columns=columns, offsets=offsets, bitcell_bl=bitcell_bl, bitcell_br=bitcell_br,
                         column_offset=0)

    def place_insts(self):
        for i, xoffset in enumerate(self.offsets):
            if self.cell.mirror.y and self.col_index[i] % 2:
                mirror, tempx = "MY", xoffset + self.pc_cell.width
            else:
                mirror, tempx = "", xoffset
            self.local_insts[i].place(offset=vector(tempx, 0), mirror=mirror)


def _spc_used(self):
    return getattr(self, "sense_precharge_array", None) is not None


def add_modules_spc(self):
    _orig_add_modules(self)
    self.sense_precharge_array = None
    if self.col_addr_size > 0 and self.port in self.read_ports:
        if not (self.has_rbl and self.port == 0):
            debug.error("E8SPC: only written for port 0 with the replica column on its left", -1)
        cols = [b * self.words_per_row for b in range(self.word_size)]
        offs = [self.bit_offsets[c] for c in cols]
        self.sense_precharge_array = sense_precharge_array(name="sense_precharge_array_{}".format(self.port),
                                                           columns=self.word_size, offsets=offs, col_index=cols,
                                                           bitcell_bl=self.bl_names[self.port],
                                                           bitcell_br=self.br_names[self.port])
        rec = {"port": self.port, "cells": self.word_size, "columns": cols, "offsets_um": [round(x, 4) for x in offs],
               "words_per_row": self.words_per_row}
        SPCLOG.append(rec)
        print("E8SPC module " + json.dumps(rec), flush=True)


def create_instances_spc(self):
    _orig_create_instances(self)
    self.sense_precharge_array_inst = None
    if _spc_used(self):
        self.sense_precharge_array_inst = self.add_inst(name="sense_precharge_array{}".format(self.port),
                                                        mod=self.sense_precharge_array)
        temp = []
        for bit in range(self.word_size):
            temp.append("bl_out_{0}".format(bit))
            temp.append("br_out_{0}".format(bit))
        temp.extend(["p_en_bar", "vdd"])
        self.connect_inst(temp)


def compute_instance_offsets_spc(self):
    if not _spc_used(self):
        return _orig_compute_instance_offsets(self)
    order = [self.precharge_array_inst, self.column_mux_array_inst, self.sense_precharge_array_inst,
             self.sense_amp_array_inst, self.write_driver_array_inst, self.write_mask_and_array_inst]
    offs = 6 * [None]
    self.width = 0
    self.height = 0
    for i, p in enumerate(order):
        if p is None:
            continue
        self.height += (p.height + self.m2_gap)
        self.width = max(self.width, p.width)
        offs[i] = vector(0, self.height)
    self.write_mask_and_offset = offs[5]
    self.write_driver_offset = offs[4]
    self.sense_amp_offset = offs[3]
    self.sense_precharge_offset = offs[2]
    self.column_mux_offset = offs[1]
    self.precharge_offset = offs[0]


def place_instances_spc(self):
    _orig_place_instances(self)
    if _spc_used(self):
        self.sense_precharge_array_inst.place(offset=self.sense_precharge_offset, mirror="MX")


def route_sense_spc(self, port):
    if not _spc_used(self):
        return _orig_route_sense(self, port)
    # column multiplexer -> sense precharge -> sense amplifiers (data bits)
    self.connect_bitlines(inst1=self.column_mux_array_inst, inst1_bls_template="{inst}_out_{bit}",
                          inst2=self.sense_precharge_array_inst, num_bits=self.word_size)
    self.connect_bitlines(inst1=self.sense_precharge_array_inst, inst2=self.sense_amp_array_inst,
                          num_bits=self.word_size)
    # spare columns: from the main precharge array, as OpenRAM does
    if self.num_spare_cols:
        off = 1 if self.port == 0 else 0
        self.connect_bitlines(inst1=self.precharge_array_inst, inst1_bls_template="{inst}_{bit}",
                              inst2=self.sense_amp_array_inst, num_bits=self.num_spare_cols,
                              inst1_start_bit=self.num_cols + off, inst2_start_bit=self.word_size)


def route_control_pins_spc(self):
    _orig_route_control_pins(self)
    if not _spc_used(self):
        return
    # join the sense precharge's en_bar rail to the main precharge's en_bar rail (the p_en_bar pin): extend the
    # sense precharge rail (M3) to the left into the replica column and run M2 up to the main rail there
    top = self.precharge_array_inst.get_pin("en_bar")
    bot = self.sense_precharge_array_inst.get_pin("en_bar")
    rbl_bl = self.precharge_array_inst.get_pin("bl_0")
    rbl_br = self.precharge_array_inst.get_pin("br_0")
    d0_bl = self.sense_precharge_array_inst.get_pin("bl_0")
    d0_br = self.sense_precharge_array_inst.get_pin("br_0")
    diag = {"pre_inst": [round(v, 4) for v in (self.precharge_array_inst.lx(), self.precharge_array_inst.rx())],
            "spc_inst": [round(v, 4) for v in (self.sense_precharge_array_inst.lx(), self.sense_precharge_array_inst.rx())],
            "pre_en_bar": [top.layer] + [round(v, 4) for v in (top.lx(), top.rx(), top.by(), top.uy())],
            "spc_en_bar": [bot.layer] + [round(v, 4) for v in (bot.lx(), bot.rx(), bot.by(), bot.uy())],
            "rbl_bl": [rbl_bl.layer] + [round(v, 4) for v in (rbl_bl.lx(), rbl_bl.rx(), rbl_bl.by(), rbl_bl.uy())],
            "rbl_br": [rbl_br.layer] + [round(v, 4) for v in (rbl_br.lx(), rbl_br.rx(), rbl_br.by(), rbl_br.uy())],
            "spc_bl_0": [d0_bl.layer] + [round(v, 4) for v in (d0_bl.lx(), d0_bl.rx(), d0_bl.by(), d0_bl.uy())],
            "spc_br_0": [d0_br.layer] + [round(v, 4) for v in (d0_br.lx(), d0_br.rx(), d0_br.by(), d0_br.uy())],
            "colmux": [round(v, 4) for v in (self.column_mux_array_inst.lx(), self.column_mux_array_inst.by(),
                                             self.column_mux_array_inst.uy())],
            "m2_pitch": self.m2_pitch}
    print("E8SPC geometry " + json.dumps(diag), flush=True)
    # the vertical wire: in the empty strip left of the replica column's precharge cell
    x = 0.5 * min(rbl_bl.lx(), rbl_br.lx())
    if not (x > 0 and x + 0.5 * self.m2_pitch < min(rbl_bl.lx(), rbl_br.lx()) - self.m2_pitch):
        debug.error("E8SPC: no room left of the replica column for the enable connection", -1)
    p_bot = vector(x, bot.cy())
    p_top = vector(x, top.cy())
    if bot.lx() > x:
        self.add_path(bot.layer, [p_bot, vector(bot.lx() + 0.5 * bot.height(), bot.cy())], width=bot.height())
    if top.lx() > x:
        self.add_path(top.layer, [p_top, vector(top.lx() + 0.5 * top.height(), top.cy())], width=top.height())
    self.add_via_stack_center(from_layer=bot.layer, to_layer="m2", offset=p_bot)
    self.add_path("m2", [p_bot, p_top])
    self.add_via_stack_center(from_layer="m2", to_layer=top.layer, offset=p_top)
    rec = {"port": self.port, "x_um": round(x, 4), "from_y_um": round(bot.cy(), 4), "to_y_um": round(top.cy(), 4),
           "rail_layers": [bot.layer, top.layer], "vertical_layer": "m2"}
    SPCLOG.append(rec)
    print("E8SPC enable " + json.dumps(rec), flush=True)


PORT_DATA.add_modules = add_modules_spc
PORT_DATA.create_instances = create_instances_spc
PORT_DATA.compute_instance_offsets = compute_instance_offsets_spc
PORT_DATA.place_instances = place_instances_spc
PORT_DATA.route_sense_amp_to_column_mux_or_precharge_array = route_sense_spc
PORT_DATA.route_control_pins = route_control_pins_spc
print("E8SPC port_data: sense precharge added (add_modules, create_instances, compute_instance_offsets, "
      "place_instances, route_sense_amp_to_column_mux_or_precharge_array, route_control_pins)", flush=True)

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
with open("{0}{1}.e8spc.json".format(OPTS.output_path, OPTS.output_name), "w") as fh:
    json.dump({"sense_precharge": SPCLOG, "routes_e8fix": FIXLOG, "openram_commit_expected": "e16d9eb"}, fh, indent=1)

openram.end_openram()
openram.print_time("End", datetime.datetime.now(), start_time)
