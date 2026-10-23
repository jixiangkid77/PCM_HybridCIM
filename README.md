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
| `data` | inputs of the RTL simulations for the two trained models A and B: quantized weights, protected-weight indices, drift exponents, address-map tables, lookup tables, 100 MNIST test images, golden outputs |
| `reports` | logs and results of every step (below) |
| `figures` | figures of the study (PNG, with PDF or SVG) |

The Python analysis scripts use paths relative to the repository root, or take the root as `--paper2` (use `.`). The shell flows find the project folder, the tools and the process design kit through variables set at their top. The Yosys scripts read the RTL relative to the root, but they and the OpenSTA Tcl files also contain absolute paths of my machine, such as the SKY130 Liberty file, which have to be edited before a rerun. The testbenches stay in `rtl/tb` and `rtl/e8/tb`, where the flows look for them.

## Steps and results

| Step | What | Scripts | Results |
|---|---|---|---|
| Accuracy | drift sweeps of LeNet-5 and ResNet-50 | `scripts/colab/`, `scripts/run_lenet_gpu*.py`, `scripts/run_lenet_full.py`, `scripts/imc_*.py`, `scripts/accuracy_tables.py` | `reports/accuracy/` |
| Data | quantization, protection split, address-map tables, golden outputs | `scripts/02_*.py` to `scripts/06_*.py`, `scripts/gen_*.py`, `scripts/verify_*.py` | `data/` |
| 12c, 12e | synthesis of the full design; NeuroSim and OpenRAM baseline | `scripts/preprocess_synth_rtl.py`, `scripts/yosys_12c_sky130.ys` | `reports/yosys_12c_*`, `reports/lenet5_top_sky130_stat.txt`, `reports/step12*`, `reports/12e_neurosim/`, `reports/12e_openram/` |
| E1e, E3 | flip-flop census; synthesis with and without clock gating | `scripts/yosys_e1e_ffcensus.ys`, `scripts/yosys_e3s*.ys`, `scripts/gen_e3*_scripts.sh`, `scripts/run_e3*.sh` | `reports/p2r_e1e_*`, `reports/e3_*` |
| E4, E5 | gate-level simulation of the synthesized design; power from its switching activity with OpenSTA | `scripts/e4_*.sh`, `scripts/e4e5_fulldump_all.sh`, `scripts/e5_power*` | `reports/e4*`, `reports/e5_*` |
| E7 | NeuroSim crossbar at 130 nm | `scripts/e7_neurosim_130nm_v2.sh` | `reports/e7_neurosim/`, `reports/e7_130nm.log` |
| E8.1 to E8.3 | tool checks, macro footprints, lookup traces of one inference, ROM contents | `scripts/e8_1*`, `scripts/e8_2*`, `scripts/e8_3*` | `reports/e8_1*`, `reports/e8_2*`, `reports/e8_3*`, `reports/e8_rom/trace/` |
| E8.4a | organization, generation and read margins of the ROM macros; margin model | `scripts/e8_4_rom_bench.py`, `scripts/e8_4a*` | `reports/e8_rom/e8_4a*/`, `reports/e8_4a*` |
| E8.4b | ROM energy from post-layout simulation of the lookup sequences | `scripts/e8_4b_*`, `scripts/e8_4b_rc_compare.py`, `scripts/e8_4b_rel5_judge.py` | `reports/e8_rom/e8_4b*/`, `reports/e8_4b*` |
| E8.4c, E8.4f | SRAM macro characterization | `scripts/e8_4c_*`, `scripts/e8_4c0*`, `scripts/e8_4c5k*`, `scripts/e8_4f_*` | `reports/e8_rom/e8_4c*/`, `reports/e8_rom/e8_4f/`, `reports/e8_4c*`, `reports/e8_4f*` |
| E8.4d | Monte Carlo of the ROM read margins | `scripts/e8_4d_*` | `reports/e8_rom/e8_4d/`, `reports/e8_4d*` |
| E8.4e | ROM and SRAM at other corners and temperatures | `scripts/e8_4e_*` | `reports/e8_rom/e8_4b_c_*/`, `reports/e8_rom/e8_4e_*`, `reports/e8_rom/e8_4e_sram/`, `reports/e8_4e_*` |
| E8.5 | AMU against the reference lookups (RTL and gate level), AMU power, two-cycle SRAM read, parked ROM macros, conv1 cache, macros at rest on an all-ones word | `scripts/e8_5*` | `reports/e8_rom/e8_5*/`, `reports/e8_5*` |
| E8.5g | ROM energy with the measured parked floor | `scripts/e8_5g_drom.py`, `scripts/e8_5d_range.py` | `reports/e8_rom/e8_5g/`, `reports/e8_rom/e8_5d_range.*` |
| E8.6 | ROM energy per inference; final energy and area | `scripts/e8_6a*`, `scripts/e8_6_summary.py`, `scripts/e8_6_figures.py` | `reports/e8_rom/e8_6a*/`, `reports/e8_6a*`, `reports/e8_6/` |
| E8.7 | gate-level energy of the digital logic over one inference | `scripts/e8_7_*` | `reports/e8_7/`, `reports/e8_7_check.log` |
| Figures | figures 2 to 5 (diagrams), 8 and 9; figures 1, 6 and 7 are stored as images | `scripts/fig_diagrams.py`, `scripts/e8_6_figures.py` | `figures/` |

Other helpers: `scripts/smoke_test_real_data.py` (a real-data check of one MAC slice), `scripts/report_addr_rom_capacity.py` (writes `reports/addr_rom_capacity_report.txt`), `scripts/make_sta_readable.sh` (netlists in the form OpenSTA reads) and `scripts/watch_e4.sh` (progress of E4). The logs `reports/step9_*`, `reports/step10b_*`, `reports/p2r_e0_flop_power.log` and `reports/rtl_files.txt` are records of earlier checks.

## Recomputing the main numbers

From the repository root, with Python 3 and the packages in `requirements.txt`:

```bash
# accuracy tables from the saved results
python3 scripts/accuracy_tables.py

# ROM energy at other corners, the parked-floor correction, and the final energy and area
python3 scripts/e8_4e_compare.py --ref reports/e8_rom/e8_4b_rel5/model.json --split reports/e8_rom/e8_4e_split.json --out reports/e8_rom/e8_4e_compare.json ttm40=reports/e8_rom/e8_4b_c_ttm40/model.json tt85=reports/e8_rom/e8_4b_c_tt85/model.json ff25=reports/e8_rom/e8_4b_c_ff25/model.json ss25=reports/e8_rom/e8_4b_c_ss25/model.json ff85=reports/e8_rom/e8_4b_c_ff85/model.json
python3 scripts/e8_4e_rule_c.py reports/e8_rom/e8_4e_compare.json reports/e8_rom/e8_4e_split.json reports/e8_rom/e8_5d_park/d_rom_e85d.json reports/e8_rom/e8_4e_rule_c.json
python3 scripts/e8_5d_range.py reports/e8_rom/e8_6a3_rel5/d_rom.json reports/e8_rom/e8_5d_park/d_rom_e85d.json reports/e8_rom/e8_4e_split.json reports/e8_rom/e8_5d_range.json
python3 scripts/e8_5g_drom.py --paper2 . --e84e-compare reports/e8_rom/e8_4e_compare.json --e84e-split reports/e8_rom/e8_4e_split.json --rule-c reports/e8_rom/e8_4e_rule_c.json --out reports/e8_rom/e8_5g/e8_5g_drom.json
python3 scripts/e8_6_summary.py

# figures 2 to 5, 8 and 9
python3 scripts/e8_6_figures.py
python3 scripts/fig_diagrams.py --out figures
```

These commands overwrite the stored files in `reports/` and `figures/` with the same numbers. The text outputs stored next to them (`*.txt`, `*.log`) are the printed output of the same commands. The figure scripts use the Liberation Sans font; with another font the images come out slightly different.

The simulation flows use Icarus Verilog, Yosys, OpenSTA, OpenROAD (power analysis of E8.7), ngspice, OpenRAM, Magic, Netgen and NeuroSim, with the SkyWater SKY130 PDK.

## What is not here

- SPICE netlists, extracted layouts and GDS files of the memory macros, and the waveform dumps and simulator logs of the post-layout, RTL and gate-level runs (tens of GB). The scripts regenerate them; the per-run `result.json` and `tb_meta.json` files and the summaries are included.
- Gate-level netlists of the full accelerator (about 20 MB each); the Yosys scripts regenerate them.
- The trained floating-point models A and B and their per-layer protection ratios, which `scripts/02_*.py` and `scripts/03_*.py` read; `data/` holds their quantized export.
- The MNIST and ImageNet datasets (`data/` holds only the 100 MNIST test images used by the testbenches), and the tools and the process design kit.

## License

MIT for my code and data (see `LICENSE`). Files that come from, or were generated with, third-party software or data keep their own terms (see `THIRD_PARTY_NOTICES.md`).
