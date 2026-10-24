# PCM_HybridCIM

RTL design, scripts, simulation records and results of my study of a hybrid SRAM / phase change memory (PCM) compute-in-memory accelerator for LeNet-5.

The drift-sensitive weights chosen by a layer-aware allocation are served as exact INT8 products from an SRAM partition, and all other weights stay on a fixed PCM crossbar that is read through a 5-bit ADC. An address-map unit (AMU) reads mask-programmed ROM tables that give the slot of every weight, in the SRAM partition or in the PCM crossbar. Everything here is simulation.

## What the study covers

1. Accuracy under conductance drift and programming noise, with a 5-bit ADC and an ideal converter, for LeNet-5 on MNIST and ResNet-50 on ImageNet: no protection, a uniform per-layer allocation and the layer-aware allocation at the same budget.
2. The RTL implementation of the full LeNet-5 accelerator, synthesis to the SkyWater SKY130 standard cells with Yosys, and gate-level simulation of complete inferences.
3. Post-layout simulation with ngspice of the ROM and SRAM macros generated with OpenRAM: read correctness, read margins, energy and leakage, across process corners and temperatures.
4. Area and energy of the PCM crossbar with NeuroSim (22 nm, and 130 nm for comparison).

## Layout

| Folder | Content |
|---|---|
| `rtl/src` | Verilog of the accelerator |
| `rtl/synth` | versions of the modules prepared for synthesis |
| `rtl/tb` | testbenches of the accelerator |
| `rtl/e8` | address-map unit, ROM macro models, PCM compute unit with the address-map unit, two-cycle SRAM pool, conv1 register cache; testbenches in `rtl/e8/tb` |
| `rtl/stub` | black-box declarations used in synthesis (memories, address decoders, crossbar, configuration registers) |
| `scripts` | flows and analysis scripts (shell, Yosys, Tcl, Python) |
| `scripts/colab` | notebooks and scripts of the accuracy study, run on Google Colab |
| `scripts/colab/lenet_pre_package` | the scripts that `scripts/colab/lenet_pre_package.ipynb` runs for the LeNet-5 results with the 5-bit ADC; their `imc_torch.py` and `imc_vec.py` scale the ADC reference with the drift compensation (`comp_pre`), which the versions in `scripts/` do not |
| `data` | inputs of the RTL simulations for the two trained models A and B: quantized weights, protected-weight indices, drift exponents, address-map tables, lookup tables, 100 MNIST test images, golden outputs |
| `data/source_models` | the trained floating-point models A and B (PyTorch state dicts) and their per-layer protection ratios, from which `data/rtl_inputs_A` and `data/rtl_inputs_B` were exported |
| `reports` | logs and results of every step (below) |
| `figures` | figures 1 to 14 of the study (PNG and PDF, figure 1 also as SVG) |

The Python analysis scripts use paths relative to the repository root, or take the root as `--paper2` (use `.`). The shell flows find the project folder, the tools and the process design kit through variables set at their top. The Yosys scripts read the RTL relative to the root, but they and the OpenSTA Tcl files also contain absolute paths of my machine, such as the SKY130 Liberty file, which have to be edited before a rerun. The testbenches stay in `rtl/tb` and `rtl/e8/tb`, where the flows look for them.

## Steps and results

| Step | What | Scripts | Results |
|---|---|---|---|
| Accuracy | drift sweeps of LeNet-5 and ResNet-50 | `scripts/colab/`, `scripts/colab/lenet_pre_package/`, `scripts/run_lenet_gpu.py`, `scripts/run_lenet_full.py`, `scripts/imc_*.py`, `scripts/accuracy_tables.py` | `reports/accuracy/` |
| Data | quantization, protection split, address-map tables, golden outputs | `scripts/02_*.py` to `scripts/06_*.py`, `scripts/gen_*.py`, `scripts/verify_*.py`, `scripts/check_source_models.py` | `data/`, `reports/source_models_check.txt` |
| 12c, 12e | synthesis of the full design; NeuroSim and OpenRAM baseline | `scripts/preprocess_synth_rtl.py`, `scripts/yosys_12c_sky130.ys`, `scripts/sram_lib_energy.py` | `reports/yosys_12c_*`, `reports/lenet5_top_sky130_stat.txt`, `reports/step12*`, `reports/12e_neurosim/`, `reports/12e_openram/` |
| E1e, E3 | flip-flop census; synthesis with and without clock gating | `scripts/yosys_e1e_ffcensus.ys`, `scripts/yosys_e3s*.ys`, `scripts/gen_e3*_scripts.sh`, `scripts/run_e3*.sh` | `reports/p2r_e1e_*`, `reports/e3_*` |
| E4, E5 | gate-level simulation of the synthesized design; power from its switching activity with OpenSTA | `scripts/e4_*.sh`, `scripts/e4e5_fulldump_all.sh`, `scripts/e5_power*` | `reports/e4*`, `reports/e5_*` |
| E7 | NeuroSim crossbar at 130 nm | `scripts/e7_neurosim_130nm_v2.sh` | `reports/e7_neurosim/`, `reports/e7_130nm.log` |
| E8.1 to E8.3 | tool checks, macro footprints, lookup traces of one inference, ROM contents | `scripts/e8_1*`, `scripts/e8_2*`, `scripts/e8_3*` | `reports/e8_1*`, `reports/e8_2*`, `reports/e8_3*`, `reports/e8_rom/trace/` |
| E8.4a | organization, generation and read margins of the ROM macros; margin model | `scripts/e8_4_rom_bench.py`, `scripts/e8_4a*` | `reports/e8_rom/e8_4a*/`, `reports/e8_4a*` |
| E8.4b | ROM energy from post-layout simulation of the lookup sequences | `scripts/e8_4b_*`, `scripts/e8_4b_rc_compare.py`, `scripts/e8_4b_rel5_judge.py` | `reports/e8_rom/e8_4b*/`, `reports/e8_rom/e8_4b*.txt`, `reports/e8_4b*` |
| E8.4c, E8.4f | SRAM macro characterization | `scripts/e8_4c_*`, `scripts/e8_4c0*`, `scripts/e8_4c5k*`, `scripts/e8_4f_*` | `reports/e8_rom/e8_4c*/`, `reports/e8_rom/e8_4f/`, `reports/e8_4c*`, `reports/e8_4f*` |
| E8.4d | Monte Carlo of the ROM read margins | `scripts/e8_4d_*` | `reports/e8_rom/e8_4d/`, `reports/e8_4d*` |
| E8.4e | ROM and SRAM at other corners and temperatures | `scripts/e8_4e_*` | `reports/e8_rom/e8_4b_c_*/`, `reports/e8_rom/e8_4e_*`, `reports/e8_rom/e8_4e_sram/`, `reports/e8_4e_*` |
| E8.5 | AMU against the reference lookups (RTL and gate level), AMU power, two-cycle SRAM read, parked ROM macros, conv1 cache, macros at rest on an all-ones word | `scripts/e8_5*` | `reports/e8_rom/e8_5*/`, `reports/e8_5*` |
| E8.5g | ROM energy with the measured parked floor | `scripts/e8_5g_drom.py`, `scripts/e8_5d_range.py` | `reports/e8_rom/e8_5g/`, `reports/e8_rom/e8_5d_range.*` |
| E8.6 | ROM energy per inference; final energy and area | `scripts/e8_6a*`, `scripts/e8_6_summary.py`, `scripts/e8_6_constants.py` | `reports/e8_rom/e8_6a*/`, `reports/e8_6a*`, `reports/e8_6/` |
| E8.7 | gate-level energy of the digital logic over one inference | `scripts/e8_7_*` | `reports/e8_7/`, `reports/e8_7_check.log` |
| Figures | figures 1 to 14 | `scripts/make_figures.sh`, which runs `scripts/fig01_concept.py`, `scripts/fig_diagrams.py` (figures 2 to 5), `scripts/fig06_accuracy.py` to `scripts/fig12_sram.py` and `scripts/e8_6_figures.py` (figures 13 and 14) | `figures/` |

Other helpers: `scripts/smoke_test_real_data.py` (a real-data check of one MAC slice), `scripts/report_addr_rom_capacity.py` (writes `reports/addr_rom_capacity_report.txt`), `scripts/make_sta_readable.sh` (netlists in the form OpenSTA reads) and `scripts/watch_e4.sh` (progress of E4). The logs `reports/step9_*`, `reports/step10b_*`, `reports/p2r_e0_flop_power.log` and `reports/rtl_files.txt` are records of earlier checks.

## Recomputing the main numbers

From the repository root, with Python 3 and the packages in `requirements.txt`:

```bash
# accuracy tables from the saved results
python3 scripts/accuracy_tables.py

# ROM energy per inference from the ROM runs at relative tolerance 1e-5, and the judgment of these runs against those at 1e-4
python3 scripts/e8_6a3_rom_energy.py --paper2 . --model-json reports/e8_rom/e8_4b_rel5/model.json --out reports/e8_rom/e8_6a3_rel5/d_rom.json
python3 scripts/e8_4b_rel5_judge.py reports/e8_4b_rom_energy_rel5.log reports/e8_6a3_rom_energy_rel5.log reports/e8_rom/e8_4b_rel5/model.json reports/e8_rom/e8_6a3_rel5/d_rom.json reports/e8_rom/e8_4b_rel4/model.json reports/e8_rom/e8_6a3_rel4/d_rom.json > reports/e8_rom/e8_4b_rel5_judge.txt

# ROM energy at other corners, the parked-floor correction, and the final energy and area
python3 scripts/e8_4e_compare.py --ref reports/e8_rom/e8_4b_rel5/model.json --split reports/e8_rom/e8_4e_split.json --out reports/e8_rom/e8_4e_compare.json ttm40=reports/e8_rom/e8_4b_c_ttm40/model.json tt85=reports/e8_rom/e8_4b_c_tt85/model.json ff25=reports/e8_rom/e8_4b_c_ff25/model.json ss25=reports/e8_rom/e8_4b_c_ss25/model.json ff85=reports/e8_rom/e8_4b_c_ff85/model.json
python3 scripts/e8_4e_rule_c.py reports/e8_rom/e8_4e_compare.json reports/e8_rom/e8_4e_split.json reports/e8_rom/e8_5d_park/d_rom_e85d.json reports/e8_rom/e8_4e_rule_c.json
python3 scripts/e8_5d_range.py reports/e8_rom/e8_6a3_rel5/d_rom.json reports/e8_rom/e8_5d_park/d_rom_e85d.json reports/e8_rom/e8_4e_split.json reports/e8_rom/e8_5d_range.json
python3 scripts/e8_5g_drom.py --paper2 . --e84e-compare reports/e8_rom/e8_4e_compare.json --e84e-split reports/e8_rom/e8_4e_split.json --rule-c reports/e8_rom/e8_4e_rule_c.json --out reports/e8_rom/e8_5g/e8_5g_drom.json
python3 scripts/e8_6_summary.py

# figures 1 to 14
bash scripts/make_figures.sh > figures/figure_scripts_output.txt
```

These commands overwrite the stored files in `reports/` and `figures/` with the same numbers, and the text outputs stored next to them (`*.txt`, `*.log`) are the printed output of the same commands. The E8.6a-3 command prints its log to the screen; the stored `reports/e8_6a3_rom_energy_rel5.log` is that of the run on my machine, with its date, run time and absolute paths. With `reports/e8_rom/e8_4b_rel4/model.json` and `--out reports/e8_rom/e8_6a3_rel4/d_rom.json` the same command gives the stored file of the runs at 1e-4 up to the last digit of a few numbers. The figures were made with matplotlib 3.10.9, cairosvg 2.9.1 (cairo 1.18.0) and the Liberation Sans font; with these a rerun gives the same PNG files, and PDF files that differ only in their creation date. Another font gives slightly different images.

## Checks of single numbers

Each command writes the file that is stored in the repository:

```bash
# the trained models and protection ratios of data/source_models against data/rtl_inputs_A and data/rtl_inputs_B (reads the .pth files without PyTorch; the activation scales are taken from the scales.txt files)
python3 scripts/check_source_models.py > reports/source_models_check.txt

# numerical settings: the ROM runs at relative tolerances 1e-3, 1e-4 and 1e-5; the SRAM time step on a smaller macro
python3 scripts/e8_4b_reltol_check.py > reports/e8_rom/e8_4b_reltol_check.txt
python3 scripts/e8_4c_tstep_compare.py > reports/e8_rom/e8_4c_tstep/tstep_compare.txt

# SRAM: analytical figures of the OpenRAM timing libraries of the macro, per read and per inference; what a gate-level power analysis (OpenSTA) charges from the library;
# the read failure before the precharge of the sense-amplifier inputs
python3 scripts/sram_lib_energy.py > reports/12e_openram/lib_20260608/sram_lib_energy.txt
sta -no_init -no_splash -exit scripts/sram_lib_opensta.tcl > reports/12e_openram/lib_20260608/sram_lib_opensta.log
python3 scripts/e8_4c_diag_summary.py > reports/e8_rom/e8_4c_resume2_diag/diag_summary.txt

# ROM read margins: the synthetic table; Shapiro-Wilk p of the Monte Carlo samples (needs scipy)
python3 scripts/e8_4a9_synthetic_report.py --paper2 . > reports/e8_rom/e8_4a9/synthetic_report.txt
python3 scripts/e8_4d_shapiro.py > reports/e8_rom/e8_4d/e8_4d_shapiro.txt

# AMU energy by block and the clock-gating cells (model A); four constants of scripts/e8_6_summary.py
python3 scripts/e8_7_amu_blocks.py > reports/e8_7/A/power/amu_blocks.txt
python3 scripts/e8_6_constants.py > reports/e8_6/e8_6_constants.txt
```

The LeNet-5 accuracy with the 5-bit ADC (`reports/accuracy/lenet_imc_full_pre.json`) comes from a GPU run on Colab. It needs PyTorch and torchvision, downloads MNIST into `./_mnist` and keeps its progress in `./lenet_pre_ckpt.json`; from the repository root:

```bash
python3 scripts/colab/lenet_pre_package/run_lenet_gpu_pre.py --src-dir data/rtl_inputs_A --v3-dir data/rtl_inputs_A_v3 --mnist --out reports/accuracy/lenet_imc_full_pre.json
```

The simulation flows use Icarus Verilog, Yosys, OpenSTA, OpenROAD (power analysis of E8.7), ngspice, OpenRAM, Magic, Netgen and NeuroSim, with the SkyWater SKY130 PDK.

## Notes on some numbers

- Protected weights. `data/rtl_inputs_A/protection_summary.txt` (3,071) and `data/rtl_inputs_B/protection_summary.txt` (3,072) are from an earlier export that rounded the count of each layer down, and `rtl/src/weight_memory.v`, which holds every weight in per-layer arrays with a protection bitmap read from `protected_*.hex` files, is an earlier module that the accelerator no longer instantiates. Everything else uses the split of `scripts/03_split_protected.py`, which rounds to the nearest count and protects 3,074 weights in both models (`data/rtl_inputs_A/split_summary.json`, `data/rtl_inputs_A_v3/split_summary_v3.json`, and the same for B).
- SRAM analytical figures. The timing library in `reports/12e_openram/lib_20260608/` comes from a run of OpenRAM 1.2.49 that writes only the netlist (`netlist_only = True`) with the configuration of the simulated macro, which sets a single output load of 6.89 fF (`use_specified_load_slew = [(6.89, 0.005)]`; the compiler warns that this option makes the load and slew data of the library inaccurate); `netlist_only_regeneration/` next to it holds a rerun that gives the same library byte for byte, with the compiler's log. Every `internal_power` entry of its clock pin is 11.81819, for reads, writes and a deselected port alike, and its leakage is 34.375 µW. In the units of the library an entry is an energy per clock transition, so a gate-level power analysis charges 23.64 pJ for a read, one rising and one falling transition, and the same for a write or a deselected cycle (`scripts/sram_lib_opensta.tcl`). OpenRAM's analytical model computes the number as the dynamic power of the macro in mW: every gate switches with a fixed transition probability at the 100-MHz default event frequency of the technology and drives the last output load of the library, and each column of the bit-cell array is charged the drain capacitance of its 257 access transistors switching through half the supply; read as a power at 100 MHz, the number is 118.2 pJ per cycle. Of the 11.818 mW, 6.53 mW come from the 258 word-line drivers (those of the 257 rows and of the replica bit line), 3.76 mW from the bit lines and 1.53 mW from the other gates (`netlist_only_regeneration/power_breakdown.txt`, from `scripts/openram_power_breakdown.py` run in the OpenRAM installation). With the compiler's default loads (1.7225, 6.89 and 27.56 fF) the model takes 27.56 fF and gives 14.7287 mW, 29.46 pJ per read (`reports/12e_openram/lib_default_loads/`, the same generation without `use_specified_load_slew`). The leakage is a placeholder of 1 nW per bit cell and per gate. The libraries written with the layout of the simulated macro (`reports/e8_rom/e8_4c/`, `reports/e8_rom/e8_4f/`, the same configuration with `netlist_only = False`) and the one written with the macro on 2026-05-13 with the default loads (`reports/12e_openram/macros/paper2_sram_pool_8x4096/`) have the same leakage and about 1.6e11 in the same entries, because the compiler scales the bit-line wire capacitance by 1e12 (`reports/12e_openram/wire_scale_check/`). These libraries give a minimum clock period of 1.339 to 1.769 ns and the data at most 0.478 ns after the falling clock edge. The ROM compiler of the same version writes no timing library (`rom_compiler.py` writes the netlist and the Verilog model, and with the layout LEF and GDS). `scripts/sram_lib_energy.py` prints these libraries, the energy per read in both readings and with both load settings, the wire term, and the energy per inference priced with the library. The earlier SRAM characterization script `scripts/e8_4c_sram_char.sh` and its logs (`reports/e8_4c_sram_char_resume2.log`, `reports/e8_4c_sram_char_resume3.log`, `reports/e8_4f_sram_char.log`) call the entry "11.81819 pJ per access"; it is the energy of one clock transition, and a read takes two.
- ROM coverage level. The 0.045 V for the columns farther away (`FAR` in `scripts/e8_4a11_select.py`) is measured on the synthetic table of E8.4a-9: the same designed cell (Z 0, T 11, L 36, row 47) with the same two adjacent columns (joined_all) reads 1.017 V in macro k0 and 0.972 V in macro k2 (`reports/e8_rom/e8_4a9/synthetic_report.txt`); its column and the two adjacent columns hold the same bits in both macros, which differ in the columns farther away (the design in `scripts/e8_4a9_make_synthetic.py`).
- Constants of `scripts/e8_6_summary.py`. The crossbar energy of 0.263 µJ, the crossbar areas of 2.27 and 0.68 mm² and the activation buffer of 0.669 mm² are recomputed from the NeuroSim and OpenRAM outputs in this repository by `scripts/e8_6_constants.py`.

## What is not here

- SPICE netlists, extracted layouts and GDS files of the memory macros, and the waveform dumps and simulator logs of the post-layout, RTL and gate-level runs (tens of GB). The scripts regenerate them; the per-run `result.json` and `tb_meta.json` files and the summaries are included.
- Gate-level netlists of the full accelerator (about 20 MB each); the Yosys scripts regenerate them. For model A, `reports/e8_7/A/names.tsv.gz` keeps the original name of every cell of the netlist analyzed in E8.7.
- The MNIST and ImageNet datasets (`data/` holds only the 100 MNIST test images used by the testbenches), and the tools and the process design kit.

## License

MIT for my code and data (see `LICENSE`). Files that come from, or were generated with, third-party software or data keep their own terms (see `THIRD_PARTY_NOTICES.md`).
