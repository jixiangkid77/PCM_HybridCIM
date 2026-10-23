#!/usr/bin/env bash
# =============================================================================
# e8_7_gate_energy.sh   (P2R-E8.7: energy of the digital logic over one inference, gate level)
#
# Why    : the energy of the whole digital logic of the final design (the periphery of E3, the
#          address-map unit of E8.5, the conv1 cache of E8.5e) over one whole inference, with the real
#          shift values and data of each model, from a gate-level simulation of the synthesised netlist
#          that is checked against the RTL. Method of E5 (OpenSTA, tt library, 10 ns clock, the activity
#          of every pin from the waveform of the gate-level run).
# What   : per model (A, B; the logic differs only in the parking words of the address-map unit):
#   s0  layer_desc_rom for synthesis with the model's shift values (scripts/e8_7_tools.py synfiles, S0)
#   s1  Yosys stage 1 as E3 variant B (synth, flip-flop transform, clockgate): rtl/synth (E3's files)
#       with the unit of rtl/e8 (pcm_imc_unit_e8c.v, -DE8_AS_PCM_IMC_UNIT), the memories as black boxes
#       (rtl/stub, rtl/e8/e8_rom_r48_stub.v, rtl/e8/sram_pool_25lane_2c_stub.v)
#   s2  Yosys stage 2 (dfflibmap, abc, without the lpflow and probe cells), as E3
#   s3  Yosys stage 3: flatten; every black box turned into ports of the logic (expose -evert), the ports
#       renamed bb<k>_<port>; constants to tie cells, port-to-port connections buffered
#   s4  plain names: the logic netlist core.v (module lenet5_top_core) and the wrapper for simulation
#       (the logic + the memory models) (check E1)
#   s5  the netlist for simulation: the buffers between the clock net and the clock pins of the memory
#       models removed (scripts/e8_7_tools.py ctsfree, check C1)
#   s6  conv1 cache contents; RTL run of the testbench rtl/e8/tb/tb_e87_chip.v (the reference)
#   s7  gate-level compile: the logic netlist + the memory models (cell models of the PDK with -DFUNCTIONAL,
#       as E4, E5 and E8.5b)
#   s8  gate-level runs (A and B together); waveform of the logic from the start to done
#   s9  checks F1 (results) and F2 (every memory driven as in the RTL run)
#   s10 power of the logic netlist with the waveform (scripts/e8_7_power.tcl; check A1)
#   s11 energy per inference by part; summary (scripts/e8_7_tools.py power, judge)
# Checks : written before the run in claude/p2r-e8-7-sandbox.md; this script prints every one.
#
# Usage (WSL, from any folder):
#   bash scripts/e8_7_gate_energy.sh check      tools, files, versions, memory and disk (a few seconds)
#   bash scripts/e8_7_gate_energy.sh run        everything, models A and B, in the background
#   bash scripts/e8_7_gate_energy.sh status     progress and the last lines of the log
#   bash scripts/e8_7_gate_energy.sh stop       stops the run (by its process ids)
#   A run that stopped can be started again with run: finished steps are kept if their inputs are
#   unchanged.
#
# Place  : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status : NEW FILE.
# Work   : /home/kid/p2r_e8/e87/<model>/ (the large files: netlists, waveform);
#          results copied to reports/e8_7/<model>/ and reports/e8_7/e8_7_summary.txt
# =============================================================================
set -uo pipefail

PAPER2="${E87_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
WROOT="${E87_WORK:-/home/kid/p2r_e8/e87}"
YS="${E87_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
OR="${E87_OPENROAD:-/home/kid/p2r_e8/openroad/bin/openroad}"
PLAT="${E87_PLAT:-/home/kid/sky130/orfs/flow/platforms/sky130hd}"
SKY_DIR="${E87_SKY_DIR:-/home/kid/gf/pdk/ciel/sky130/versions/1e931c9417df0478df9ee6b7289202f3e87440ab/sky130A/libs.ref/sky130_fd_sc_hd/verilog}"
CELL_ARGS="${E87_CELL_ARGS:-$SKY_DIR/primitives.v $SKY_DIR/sky130_fd_sc_hd.v}"
MODELS="${E87_MODELS:-A B}"
MEM_GB="${E87_MEM_GB:-16}"            # free memory needed before Yosys stage 1 (E3 variant B: 12.96 GiB)
DISK_GB="${E87_DISK_GB:-10}"          # free space needed in the work folder before the gate-level runs
LIB="$PLAT/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
OUTR="$PAPER2/reports/e8_7"
OUTR_BIG="$PAPER2/reports/e8_7_big"
TIMECMD=()
[ -x /usr/bin/time ] && TIMECMD=(/usr/bin/time -v)
SELF="$(readlink -f "$0")"

RTL_SYNTH=(layer_config_regfile logit_rf sram_mac combiner mac_unit maxpool2x2 pool_wrapper relu argmax10
           argmax_wrapper conv_engine fc_engine top_fsm lenet5_top)
E8_SYN=(amu_entry amu_lanes amu_core amu_buf amu_pflags amu_table amu_top conv1_cache pcm_imc_unit_e8c)
STUBS=(rtl/stub/bias_storage_stub.v rtl/stub/feature_buffer_stub.v rtl/stub/pcm_crossbar_stub.v
       rtl/e8/e8_rom_r48_stub.v rtl/e8/sram_pool_25lane_2c_stub.v)
NEW_FILES=(scripts/e8_7_gate_energy.sh scripts/e8_7_tools.py scripts/e8_7_power.tcl
           rtl/e8/sram_pool_25lane_2c_stub.v rtl/e8/tb/tb_e87_chip.v)
TOP=lenet5_top
SCOPE=tb_e87_chip/DUT/core

say() { echo "[$(date '+%F %T')] $*"; }
die() { say "STOPPED: $*"; exit 1; }
md5of() { md5sum "$@" 2>/dev/null | awk '{print $1}' | md5sum | cut -c1-16; }
free_gb() { awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo; }
disk_gb() { df -Pk "$1" | awk 'NR==2 {printf "%d", $4/1048576}'; }

# step <dir> <name> <key> <command...>: skipped if <dir>/<name>.done holds the same key
step() {
    local d="$1" name="$2" key="$3"; shift 3
    if [ -f "$d/$name.done" ] && [ "$(cat "$d/$name.done")" = "$key" ]; then
        say "  $name: done before with the same inputs, kept"
        return 0
    fi
    rm -f "$d/$name.done"
    say "  $name: start"
    local t0=$(date +%s)
    "$@"
    local rc=$?
    say "  $name: exit $rc after $(( $(date +%s) - t0 )) s"
    [ $rc -eq 0 ] || return $rc
    echo "$key" > "$d/$name.done"
}

# --------------------------------------------------------------------------- check
do_check() {
    local bad=0
    say "P2R-E8.7 check (gate level), models $MODELS"
    for f in "$YS" "$OR"; do
        [ -x "$f" ] && say "  tool  $f" || { say "  MISSING tool $f"; bad=1; }
    done
    command -v iverilog >/dev/null && say "  tool  $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)" \
        || { say "  MISSING iverilog"; bad=1; }
    command -v python3 >/dev/null || { say "  MISSING python3"; bad=1; }
    "$YS" -V 2>&1 | head -1 | sed 's/^/        /'
    "$OR" -version 2>&1 | head -1 | sed 's/^/        /'
    for f in "$LIB" "$PLAT/lef/sky130_fd_sc_hd.tlef" "$PLAT/lef/sky130_fd_sc_hd_merged.lef"; do
        [ -f "$f" ] && say "  file  $(md5sum "$f")" || { say "  MISSING $f"; bad=1; }
    done
    for f in $CELL_ARGS; do
        [ -f "$f" ] && say "  cells $(md5sum "$f")" || { say "  MISSING cell models $f"; bad=1; }
    done
    cd "$PAPER2" || die "no $PAPER2"
    for f in "${NEW_FILES[@]}" "${STUBS[@]}" scripts/e8_5e_cache_hex.py rtl/e8/e8_rom_r48_rec.v \
             rtl/e8/sram_pool_25lane_2c.v rtl/e8/amu_park_A.vh rtl/e8/amu_park_B.vh; do
        [ -f "$f" ] && say "  input $(md5sum "$f")" || { say "  MISSING $PAPER2/$f"; bad=1; }
    done
    for m in "${RTL_SYNTH[@]}"; do [ -f "rtl/synth/$m.v" ] || { say "  MISSING rtl/synth/$m.v"; bad=1; }; done
    for m in "${E8_SYN[@]}"; do [ -f "rtl/e8/$m.v" ] || { say "  MISSING rtl/e8/$m.v"; bad=1; }; done
    for M in $MODELS; do
        for f in "data/rtl_inputs_${M}_v3/layer_config.hex" "data/rtl_inputs_${M}_v3/rshift_per_layer.hex" \
                 "data/rtl_inputs_${M}/images/img_001.hex" "data/golden/golden_conv1_${M}_img1.hex"; do
            [ -f "$f" ] || { say "  MISSING $f"; bad=1; }
        done
    done
    say "  memory available $(free_gb) GiB (Yosys stage 1 needs $MEM_GB); work folder $WROOT, free $(mkdir -p "$WROOT" && disk_gb "$WROOT") GB (gate-level runs need $DISK_GB)"
    [ $bad -eq 0 ] && say "check: everything found" || say "check: something is MISSING (above)"
    return $bad
}

# --------------------------------------------------------------------------- per model, s0..s5
syn_model() {   # $1 = model
    local M="$1" W="$WROOT/$1" MB=""
    [ "$M" = B ] && MB="-DMODEL_B"
    mkdir -p "$W/syn" "$W/sim"
    cd "$PAPER2" || return 1
    local K0
    K0="$(md5of scripts/e8_7_tools.py rtl/synth/layer_desc_rom.v rtl/src/layer_desc_rom.v data/rtl_inputs_${M}_v3/rshift_per_layer.hex)"
    step "$W" s0_synfiles "$K0" python3 scripts/e8_7_tools.py synfiles --paper2 "$PAPER2" --model "$M" \
        --out "$W/syn/layer_desc_rom.v" || return 1

    # ---- stage 1 (the script text is kept as written by the first version of E8.7, so that a stage 1
    #      already done with the same inputs is kept)
    local ys1="$W/syn/stage1.ys"
    {
        echo "# P2R-E8.7 stage 1, model $M, design chip (written by scripts/e8_7_digital_pnr.sh)"
        echo "read_liberty -lib $LIB"
        for m in "${RTL_SYNTH[@]}"; do
            [ "$m" = lenet5_top ] && continue
            echo "read_verilog -sv -DLOAD_REAL_DATA $PAPER2/rtl/synth/$m.v"
        done
        echo "read_verilog -sv -DLOAD_REAL_DATA $W/syn/layer_desc_rom.v"
        echo "read_verilog -sv -DLOAD_REAL_DATA $PAPER2/rtl/synth/lenet5_top.v"
        echo "read_verilog -sv -DE8_AS_PCM_IMC_UNIT $MB -I $PAPER2/rtl/e8 $(for m in "${E8_SYN[@]}"; do printf '%s ' "$PAPER2/rtl/e8/$m.v"; done)"
        for s in "${STUBS[@]}"; do echo "read_verilog -sv $PAPER2/$s"; done
        echo "synth -top $TOP"
        echo "tee -o $W/syn/stat_after_synth.txt stat"
        echo 'dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01'
        echo "opt_expr"
        echo "opt_merge"
        echo "opt_clean"
        echo "tee -o $W/syn/stat_after_transform.txt stat"
        echo "clockgate -liberty $LIB -dont_use sky130_fd_sc_hd__sdlclkp*"
        echo "tee -o $W/syn/stat_after_clockgate.txt stat"
        echo "write_rtlil $W/syn/s1.rtlil"
    } > "$ys1.new"
    if ! cmp -s "$ys1.new" "$ys1"; then mv -f "$ys1.new" "$ys1"; else rm -f "$ys1.new"; fi
    local SRCS=()
    for m in "${RTL_SYNTH[@]}"; do SRCS+=("rtl/synth/$m.v"); done
    for m in "${E8_SYN[@]}"; do SRCS+=("rtl/e8/$m.v"); done
    local K1
    K1="$(md5of "$ys1" "$W/syn/layer_desc_rom.v" "${SRCS[@]}" "${STUBS[@]}" rtl/e8/amu_park_A.vh rtl/e8/amu_park_B.vh "$YS")"
    if ! [ -f "$W/s1_yosys.done" ] || [ "$(cat "$W/s1_yosys.done")" != "$K1" ]; then
        local fg; fg=$(free_gb)
        [ "$fg" -ge "$MEM_GB" ] || { say "  memory available $fg GiB < $MEM_GB GiB for Yosys stage 1: stop the other runs first"; return 1; }
    fi
    step "$W" s1_yosys "$K1" "${TIMECMD[@]}" "$YS" -q -l "$W/syn/stage1.log" -s "$ys1" || return 1

    # ---- stage 2
    local ys2="$W/syn/stage2.ys"
    {
        echo "# P2R-E8.7 stage 2, model $M"
        echo "read_liberty -lib $LIB"
        echo "read_rtlil $W/syn/s1.rtlil"
        echo "dfflibmap -liberty $LIB -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*"
        echo "abc -liberty $LIB -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*"
        echo "clean"
        echo "tee -o $W/syn/stat_final.txt stat -liberty $LIB"
        echo "write_verilog -noattr $W/syn/n0.v"
    } > "$ys2"
    step "$W" s2_yosys "$(md5of "$ys2" "$W/syn/s1.rtlil")" "${TIMECMD[@]}" "$YS" -q -l "$W/syn/stage2.log" -s "$ys2" || return 1

    # ---- stage 3 and the logic netlist
    local STUBS_ABS=(); for s in "${STUBS[@]}"; do STUBS_ABS+=("$PAPER2/$s"); done
    step "$W" s3_script "$(md5of "$W/syn/n0.v" scripts/e8_7_tools.py)" python3 scripts/e8_7_tools.py stage3 \
        --n0 "$W/syn/n0.v" --stubs "${STUBS_ABS[@]}" --top "$TOP" --lib "$LIB" --out-dir "$W/syn" || return 1
    step "$W" s3_yosys "$(md5of "$W/syn/stage3.ys" "$W/syn/n0.v")" "${TIMECMD[@]}" "$YS" -q -l "$W/syn/stage3.log" \
        -s "$W/syn/stage3.ys" || return 1
    step "$W" s4_core "$(md5of "$W/syn/core_raw.v" "$W/syn/bb.json" scripts/e8_7_tools.py)" python3 scripts/e8_7_tools.py core \
        --bb "$W/syn/bb.json" --raw "$W/syn/core_raw.v" --stubs "${STUBS_ABS[@]}" --core-out "$W/core.v" \
        --wrapper-out "$W/wrapper.v" --names-out "$W/names.tsv" --check || return 1

    # ---- the netlist for simulation
    step "$W" s5_simnet "$(md5of "$W/core.v" scripts/e8_7_tools.py)" python3 scripts/e8_7_tools.py ctsfree \
        --net "$W/core.v" --out "$W/sim/core_sim.v" || return 1
    return 0
}

# --------------------------------------------------------------------------- s6, s7: RTL run, compiles
compile_rtl() {   # $1 model -> $W/rtl.vvp
    local M="$1" W="$WROOT/$1" MB=""
    [ "$M" = B ] && MB="-DMODEL_B"
    cd "$PAPER2" || return 1
    iverilog -g2012 -DLOAD_REAL_DATA -DE8_AS_PCM_IMC_UNIT $MB -I rtl/e8 -I rtl/src -y rtl/src -y rtl/e8 -Y .v \
        -s tb_e87_chip -s e8_5b_monitor -M "$W/rtl_deps.txt" -o "$W/rtl.vvp" \
        rtl/e8/tb/tb_e87_chip.v rtl/e8/pcm_imc_unit_e8c.v rtl/e8/conv1_cache.v rtl/e8/sram_pool_25lane_2c.v \
        rtl/e8/e8_rom_r48_rec.v > "$W/rtl_compile.log" 2>&1
}
compile_gate() {   # $1 model -> $W/gate.vvp
    local M="$1" W="$WROOT/$1" MB=""
    [ "$M" = B ] && MB="-DMODEL_B"
    cd "$PAPER2" || return 1
    iverilog -g2012 -DLOAD_REAL_DATA -DFUNCTIONAL -DE87_GATE $MB -I rtl/e8 -I rtl/src -y rtl/src -Y .v \
        -s tb_e87_chip -s e8_5b_monitor -M "$W/gate_deps.txt" -o "$W/gate.vvp" \
        rtl/e8/tb/tb_e87_chip.v "$W/wrapper.v" "$W/sim/core_sim.v" rtl/src/feature_buffer.v rtl/src/bias_storage.v \
        rtl/src/pcm_crossbar.v rtl/e8/sram_pool_25lane_2c.v rtl/e8/e8_rom_r48_rec.v $CELL_ARGS > "$W/gate_compile.log" 2>&1
}
run_sim() {   # $1 model, $2 rtl|gate
    local M="$1" kind="$2" W="$WROOT/$1"
    mkdir -p "$W/$kind"
    cd "$PAPER2" || return 1
    local extra=()
    [ "$kind" = gate ] && extra=("+e87_vcd=$W/gate/core.vcd")
    "${TIMECMD[@]}" vvp -n "$W/$kind.vvp" "+e87_cache=$W/cache.hex" "+e87_dir=$W/$kind" "${extra[@]}" \
        > "$W/${kind}_sim.log" 2> "$W/${kind}_time.txt"
    grep -q "RESULT PASS" "$W/${kind}_sim.log"
}
rtl_run() { compile_rtl "$1" && run_sim "$1" rtl; }
sims_model() {   # $1 model: cache contents, the RTL run, the gate-level compile (the gate-level run is started by run_all)
    local M="$1" W="$WROOT/$1"
    cd "$PAPER2" || return 1
    step "$W" s6_cache "$(md5of scripts/e8_5e_cache_hex.py data/rtl_inputs_${M}_v3/layer_config.hex data/rtl_inputs_${M}_v3/sram_pool.hex)" \
        python3 scripts/e8_5e_cache_hex.py --data "data/rtl_inputs_${M}_v3" --out "$W/cache.hex" || return 1
    step "$W" s6_rtl "$(md5of rtl/e8/tb/tb_e87_chip.v rtl/e8/pcm_imc_unit_e8c.v rtl/e8/conv1_cache.v "$W/cache.hex")" \
        rtl_run "$M" || { tail -5 "$W/rtl_compile.log" "$W/rtl_sim.log"; return 1; }
    step "$W" s7_compile "$(md5of rtl/e8/tb/tb_e87_chip.v "$W/wrapper.v" "$W/sim/core_sim.v")" \
        compile_gate "$M" || { tail -5 "$W/gate_compile.log"; return 1; }
}

# --------------------------------------------------------------------------- s9..s11
post_model() {   # $1 model
    local M="$1" W="$WROOT/$1"
    cd "$PAPER2" || return 1
    mkdir -p "$W/power"
    step "$W" s9_streams "$(md5of "$W/rtl/fbuf.txt" "$W/gate/fbuf.txt" "$W/gate/rom.txt")" python3 scripts/e8_7_tools.py streams \
        --rtl "$W/rtl" --gate "$W/gate" --out "$W/streams.json" || say "  F2 failed (see above); power is still computed"
    step "$W" s10_power "$(md5of "$W/core.v" "$W/gate/core.vcd" scripts/e8_7_power.tcl)" power_run "$M" \
        || { tail -20 "$W/power/gate.log"; return 1; }
    python3 scripts/e8_7_tools.py power --model "$M" --names "$W/names.tsv" --vcd "$W/gate/core.vcd" \
        --rep "$W/power/gate_power.rpt" --inst "$W/power/gate_instances.rpt" --ann "$W/power/gate_annotation.rpt" \
        --out "$W/power.json"
}

power_run() {   # $1 model: OpenSTA on the logic netlist with the waveform of the gate-level run
    local W="$WROOT/$1"
    cp -f "$PAPER2/scripts/e8_7_power.tcl" "$W/power/" || return 1
    E87_PLAT="$PLAT" E87_NET="$W/core.v" E87_TOP="${TOP}_core" E87_VCD="$W/gate/core.vcd" E87_SCOPE="$SCOPE" \
        E87_REP="$W/power/gate" "${TIMECMD[@]}" "$OR" -exit -no_init "$W/power/e8_7_power.tcl" \
        > "$W/power/gate.log" 2> "$W/power/gate_time.txt"
    grep -E "Elapsed \(wall|Maximum resident" "$W/power/gate_time.txt" 2>/dev/null | sed 's/^/     /'
    grep -q "E87P: done" "$W/power/gate.log"
}

collect() {   # results to reports/e8_7/<model>/ (small files only)
    local M="$1" W="$WROOT/$1" D="$OUTR/$1"
    mkdir -p "$D" "$D/power"
    cp -f "$W"/syn/*.txt "$W"/syn/*.ys "$W"/syn/stage*.log "$W/syn/bb.json" "$W/core.v.json" "$W/sim/core_sim.v.json" \
          "$W"/*_sim.log "$W"/*_compile.log "$W"/*_time.txt "$W/streams.json" "$W/power.json" "$D/" 2>/dev/null
    cp -f "$W"/power/gate_power.rpt "$W"/power/gate_annotation.rpt "$W"/power/gate.log "$D/power/" 2>/dev/null
    [ -f "$W/power/gate_instances.rpt" ] && gzip -c "$W/power/gate_instances.rpt" > "$D/power/gate_instances.rpt.gz"
    # the netlists, compressed, kept apart from the small files (not for upload)
    local B="$OUTR_BIG/$M"
    mkdir -p "$B"
    for f in core.v wrapper.v names.tsv sim/core_sim.v; do
        [ -f "$W/$f" ] && gzip -c "$W/$f" > "$B/$(basename "$f").gz"
    done
}

run_all() {
    say "P2R-E8.7 run (gate level), models $MODELS"
    do_check || die "check failed"
    for M in $MODELS; do
        say "==== model $M: synthesis to the netlist for simulation"
        syn_model "$M" || die "model $M, synthesis"
        say "==== model $M: RTL run and compiles"
        sims_model "$M" || die "model $M, RTL run or compile"
    done
    local fg; fg=$(disk_gb "$WROOT")
    [ "$fg" -ge "$DISK_GB" ] || die "free space in $WROOT is $fg GB < $DISK_GB GB for the waveforms"
    say "==== gate-level runs (in parallel): $MODELS"
    local pids=() M
    for M in $MODELS; do
        local W="$WROOT/$M" key
        key="$(md5of "$W/gate.vvp" "$W/cache.hex")"
        if [ -f "$W/s8_gate.done" ] && [ "$(cat "$W/s8_gate.done")" = "$key" ]; then
            say "  model $M gate-level run: done before, kept"
            continue
        fi
        rm -f "$W/s8_gate.done"
        ( run_sim "$M" gate; rc=$?; [ $rc -eq 0 ] && echo "$key" > "$W/s8_gate.done"; exit $rc ) &
        pids+=($!)
        say "  model $M gate-level run started (process $!)"
    done
    for p in "${pids[@]}"; do wait "$p" || say "  a gate-level run did not pass (process $p)"; done
    for M in $MODELS; do
        [ -f "$WROOT/$M/s8_gate.done" ] || die "model $M: the gate-level run did not pass (see $WROOT/$M/gate_sim.log)"
        say "  model $M gate-level run: $(grep -m1 'done seen' "$WROOT/$M/gate_sim.log")"
        say "==== model $M: checks and power"
        post_model "$M" || die "model $M, power"
        collect "$M"
    done
    python3 "$PAPER2/scripts/e8_7_tools.py" judge --work "$WROOT" --models $MODELS --out "$OUTR/e8_7_summary.json" \
        | tee "$OUTR/e8_7_summary.txt"
    say "P2R-E8.7 finished"
    say "results for Claude (small files only): cd $PAPER2 && tar czf reports/e8_7_results.tar.gz -C reports e8_7 && md5sum reports/e8_7_results.tar.gz"
}

# --------------------------------------------------------------------------- commands
case "${1:-}" in
    check)
        do_check ;;
    run)
        mkdir -p "$WROOT" "$OUTR"
        if [ -f "$WROOT/run.pid" ] && kill -0 "$(cat "$WROOT/run.pid")" 2>/dev/null; then
            echo "already running: process $(cat "$WROOT/run.pid"); bash scripts/e8_7_gate_energy.sh status"
            exit 1
        fi
        # bash reads its script while running it: the background run is a copy of this file
        cp -f "$SELF" "$WROOT/e8_7_gate_energy_running.sh"
        nohup bash "$WROOT/e8_7_gate_energy_running.sh" _run >> "$WROOT/run.log" 2>&1 &
        echo $! > "$WROOT/run.pid"
        echo "started: process $(cat "$WROOT/run.pid"); log $WROOT/run.log"
        echo "progress: bash scripts/e8_7_gate_energy.sh status" ;;
    _run)
        run_all ;;
    status)
        if [ -f "$WROOT/run.pid" ] && kill -0 "$(cat "$WROOT/run.pid")" 2>/dev/null; then
            echo "running: process $(cat "$WROOT/run.pid")"
        else
            echo "not running"
        fi
        for M in $MODELS; do
            echo "model $M, steps done: $(cd "$WROOT/$M" 2>/dev/null && ls *.done 2>/dev/null | sed 's/\.done//' | tr '\n' ' ')"
        done
        tail -15 "$WROOT/run.log" 2>/dev/null ;;
    stop)
        if [ -f "$WROOT/run.pid" ] && kill -0 "$(cat "$WROOT/run.pid")" 2>/dev/null; then
            P=$(cat "$WROOT/run.pid")
            # the run and every process started under it (Yosys, OpenROAD, the simulations), by process id
            desc() { local c; for c in $(pgrep -P "$1"); do echo "$c"; desc "$c"; done; }
            ALL="$P $(desc "$P" | tr '\n' ' ')"
            echo "stopping processes: $ALL"
            kill $ALL 2>/dev/null
        else
            echo "not running"
        fi ;;
    *)
        sed -n '2,42p' "$SELF" | sed 's/^# \{0,1\}//' ;;
esac
