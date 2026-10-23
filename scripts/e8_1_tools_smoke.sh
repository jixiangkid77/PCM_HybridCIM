#!/usr/bin/env bash
# =============================================================================
# e8_1_tools_smoke.sh
#
# Experiment : P2R-E8.1. Check that the circuit tools found in the Nix store
#              run outside a Nix shell and work with the sky130 PDK, before
#              any ROM is regenerated or simulated.
#
# Background
#   Probe 2 (e8_rom_probe2.log, 2026-10-07 22:28) found, in /nix/store,
#   ngspice 45, Xyce 7.10.0 (two builds), magic 8.3.629 and netgen 1.5.318.
#   They are not on PATH and no Nix profile exposes them, so they were most
#   likely pulled in by the memory compiler's Nix environment. This step
#   proves they run when called by full path:
#     1. version of every tool;
#     2. ngspice loads the sky130 TT models and simulates one inverter
#        (supply current and delay are printed; the numbers only show that
#        the models load and the measurement syntax works);
#     3. magic loads the sky130A technology and reads the address-map ROM
#        layout, and reports its bounding box, which must match the LEF
#        footprint 347.73 x 229.125 um.
#
# Writes only into a new folder, reports/e8_rom/smoke/. No existing file is
# touched, nothing is installed.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\
#           (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Creates the NEW folder reports\e8_rom\smoke\.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_1_tools_smoke.sh 2>&1 | tee reports/e8_1_tools_smoke.log
# Runtime : under a minute.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
PDK_ROOT_DIR=/home/kid/gf/pdk
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
ROMGDS="$PAPER2/reports/12e_openram/macros/paper2_addr_decoder_8x5120/paper2_addr_decoder_8x5120.gds"
WORK="$PAPER2/reports/e8_rom/smoke"

pick() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE=$(pick "/nix/store/*-ngspice-*/bin/ngspice")
XYCE=$(pick "/nix/store/*-xyce-*/bin/Xyce")
MAGIC=$(pick "/nix/store/*magic-vlsi*/bin/magic")
NETGEN=$(pick "/nix/store/*-netgen-*/bin/netgen")

hr() { echo; echo "########## $* ##########"; }

echo "=============================================================="
echo "P2R-E8.1 tool smoke test, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

hr "1. tools used by this experiment (full paths are the record)"
printf "   %-8s %s\n" ngspice "${NGSPICE:-<missing>}" Xyce "${XYCE:-<missing>}" \
       magic "${MAGIC:-<missing>}" netgen "${NETGEN:-<missing>}"
echo "   all Xyce builds present:"; ls -d /nix/store/*-xyce-*/bin/Xyce 2>/dev/null | sed 's/^/     /'
echo "---- versions ----"
[ -n "$NGSPICE" ] && timeout 20 "$NGSPICE" -v < /dev/null 2>&1 | head -3
[ -n "$XYCE" ]    && timeout 20 "$XYCE" -v < /dev/null 2>&1 | head -2
[ -n "$MAGIC" ]   && timeout 20 "$MAGIC" --version < /dev/null 2>&1 | head -2
echo "---- model and technology files ----"
ls -la "$MODELS" "$MAGICRC" "$ROMGDS" 2>&1

mkdir -p "$WORK" || { echo "cannot create $WORK"; exit 1; }
cd "$WORK" || exit 1

hr "2. ngspice with the sky130 TT models: one inverter"
cat > .spiceinit <<'EOF'
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=8
EOF
cat > inv_tt.sp <<EOF
* P2R-E8.1 smoke test: one sky130 inverter, TT corner, 1.8 V, 25 C
.lib "$MODELS" tt
.temp 25
Vdd vdd 0 1.8
Vin in 0 pulse(0 1.8 1n 50p 50p 4.95n 10n)
Xp out in vdd vdd sky130_fd_pr__pfet_01v8 w=0.84 l=0.15
Xn out in 0 0 sky130_fd_pr__nfet_01v8 w=0.42 l=0.15
Cl out 0 5f
.tran 5p 41n
.meas tran iavg   avg i(Vdd) from=11n to=41n
.meas tran tpd_hl trig v(in) val=0.9 rise=2 targ v(out) val=0.9 fall=2
.meas tran tpd_lh trig v(in) val=0.9 fall=2 targ v(out) val=0.9 rise=2
.end
EOF
if [ -n "$NGSPICE" ]; then
  START=$(date +%s)
  timeout 300 "$NGSPICE" -b -o inv_tt.log inv_tt.sp > /dev/null 2>&1
  echo "exit status: $?   wall time: $(( $(date +%s) - START )) s"
  echo "---- measurements ----"
  grep -i -E "^\s*(iavg|tpd_hl|tpd_lh)\s*=" inv_tt.log || echo "   no measurement printed"
  echo "---- errors or warnings, if any ----"
  grep -i -E "error|fatal|could not|unknown|warning" inv_tt.log | head -15 || true
  echo "   (energy per 10 ns cycle = 1.8 V x |iavg| x 10 ns; only a sanity check)"
else
  echo "   ngspice missing, step skipped"
fi

hr "3. magic: sky130A technology and the ROM layout"
cat > read_rom.tcl <<EOF
puts "TECH [tech name]"
gds read $ROMGDS
load paper2_addr_decoder_8x5120
select top cell
puts "BOX_LAMBDA [box values]"
box
quit -noprompt
EOF
if [ -n "$MAGIC" ]; then
  START=$(date +%s)
  if [ -f "$MAGICRC" ]; then
    MAGIC_SETUP=(-rcfile "$MAGICRC")
  else
    echo "   no sky130A.magicrc; loading the technology file directly"
    MAGIC_SETUP=(-T "$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.tech")
  fi
  PDK_ROOT="$PDK_ROOT_DIR" timeout 600 "$MAGIC" -dnull -noconsole "${MAGIC_SETUP[@]}" \
      < read_rom.tcl > magic_read_rom.log 2>&1
  echo "exit status: $?   wall time: $(( $(date +%s) - START )) s"
  echo "---- technology and bounding box ----"
  grep -E "TECH|BOX_LAMBDA|microns|lambda|width|height" magic_read_rom.log | head -12
  echo "---- errors, if any ----"
  grep -i -E "error|could not|unknown|not found" magic_read_rom.log | head -10 || true
  echo "   expected footprint from the LEF: 347.73 x 229.125 um"
else
  echo "   magic missing, step skipped"
fi

echo
echo "---- files written, all new, all in $WORK ----"
ls -la "$WORK"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S')."
echo "=============================================================="
