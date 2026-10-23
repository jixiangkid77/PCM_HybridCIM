# Third-party notices

The MIT license in `LICENSE` covers my own code and data. The files below come from, or were generated with, third-party software and data, and keep their own terms.

## NeuroSim

- `reports/12e_neurosim/configs/Param_*.cpp` are copies of `Param.cpp` of the DNN+NeuroSim framework (`Inference_pytorch/NeuroSIM`) with my parameter settings; `reports/12e_neurosim/neurosim_before_step12e3.diff` is a diff against that framework (local clone at commit 6acf552, see `reports/12e_neurosim/neurosim_baseline_commit.txt`).
- Copyright (c) 2015-2017 School of Electrical, Computer and Energy Engineering, Arizona State University (PI: Prof. Shimeng Yu). The copyright notice and the license conditions are kept at the top of each copied file. The model is distributed under the Creative Commons Attribution-NonCommercial 4.0 International Public License.

## OpenRAM

- The memory macros in `reports/12e_openram/macros/` and `reports/e8_rom/` (LEF, Liberty, Verilog models, configuration files and logs) were generated with OpenRAM.
- `scripts/e8_4c_openram_fix.py` and `scripts/e8_4f_openram_spc.py` contain code adapted from OpenRAM (commit e16d9eb), and the `sky130_sram_common.py` files in `reports/e8_rom/e8_4c/configs/`, `reports/e8_rom/e8_4c5k/configs/` and `reports/e8_rom/e8_4f/configs/` are OpenRAM example configurations.
- OpenRAM license:

```
BSD 3-Clause License

Copyright (c) 2019, Regents of the University of California and The Board of Regents for the Oklahoma Agricultural and Mechanical College (acting for and on behalf of Oklahoma State University)
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## SkyWater SKY130 PDK

- The synthesis results, gate-level netlists, memory macros and simulation records refer to standard cells and devices of the SkyWater SKY130 process design kit, which is distributed under the Apache License 2.0. No PDK files are included.

## MNIST

- `data/rtl_inputs_A/images/` and `data/rtl_inputs_B/images/` hold 100 test images of the MNIST database (Y. LeCun, C. Cortes, C. J. C. Burges), and the `image_labels.*` files next to them hold their labels, converted to input files for the testbenches. MNIST is distributed under the Creative Commons Attribution-Share Alike 3.0 license.
