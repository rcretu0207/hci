[![Documentation Status](https://readthedocs.org/projects/hwpe-doc/badge/?version=latest)](https://hwpe-doc.readthedocs.io/en/latest/?badge=latest)
See documentation on https://hwpe-doc.readthedocs.io/en/latest/.

# Repository content
The `hci` repository contains the definition of the Heterogeneous Cluster Interconnect (HCI) interfaces used with HWPEs (HW Processing Engines), as well as the IPs necessary to manage the streams and construct streamers, used in all recent (2019-ongoing) PULP platform HWPEs, e.g.:
 - https://github.com/pulp-platform/rbe
 - https://github.com/pulp-platform/ne16
 - https://github.com/pulp-platform/neureka
 - https://github.com/pulp-platform/redmule

# Functional verification additions
This branch extends the existing traffic and performance testbench with passive
correctness checks. The added monitors cover three separate parts of the HCI
behavior:

- A functional scoreboard keeps a shadow copy of the TCDM and checks read data,
  byte-enabled writes, response order, and the final memory contents.
- A response-legality monitor tracks accepted transactions and catches early,
  unexpected, or undrained responses.
- A QoS monitor reconstructs narrow-wide conflict windows and checks that the
  configured arbitration ratio is respected, including the final partial window.

The test set contains 34 configurations across 256- and 512-bit HWPE widths,
fixed and random bank grants, and GEMM, Transformer, and Conv2d traffic. All
applicable checks pass on the clean design with no errors or warnings. Four
separate fault injections were also used to exercise the monitors: corrupted
read data, corrupted stored write data, premature completion, and an incorrect
QoS decision. Each fault was detected by its intended check.

The monitor implementations are in `target/verif/src/`. The additional hardware,
testbench, and workload configurations are under
`target/verif/exploration/config/` and use the verification flow below.

# Verification flow
The typical full flow is:

```
make checkout       # Fetch and check out dependencies via Bender
make config-verif   # Generate Makefiles from JSON verification configs
make stim-verif     # Generate simulation stimulus vectors (requires Python 3)
make compile-verif  # Compile RTL and testbench with QuestaSim
make opt-verif      # Optimize the compiled design with vopt
make run-verif      # Run the simulation (batch mode by default)
```

To open the simulation in the QuestaSim GUI with waveforms, pass `GUI=1`:

```
make run-verif GUI=1
```

Cleanup targets:

| Target               | Effect                                             |
|----------------------|----------------------------------------------------|
| `clean-config-verif` | Remove generated configuration Makefiles           |
| `clean-stim-verif`   | Remove generated stimulus vectors                  |
| `clean-sim-verif`    | Remove QuestaSim build artifacts (work lib, logs)  |
| `clean-verif`        | Run all three clean targets above                  |

**Notes:**
- On IIS machines, defaults to QuestaSim (`questa-2022.3`) (can be overriden with `SIM_QUESTA=<version>`). On non-IIS machines, defaults to QuestaSim available in `PATH`.
- Verification configuration is driven by JSON files under `target/verif/config/`. Edit those before running `config-verif` and `stim-verif`.
- `run-verif` depends on `opt-verif` and `stim-verif`, so after `checkout` and `config-verif` you can jump straight to it.

# Style guide
These IPs use a slightly different style than other PULP IPs. Refer to `STYLE.md` for some indications.

# References
If you are using HCI IPs for an academic publication, we recommend citing one or more of the following papers, which describe several aspects of the HCI system:
```
@article{garofalo2022darkside,
  author={Garofalo, Angelo and Tortorella, Yvan and Perotti, Matteo and Valente, Luca and Nadalini, Alessandro and Benini, Luca and Rossi, Davide and Conti, Francesco},
  journal={IEEE Open Journal of the Solid-State Circuits Society}, 
  title={DARKSIDE: A Heterogeneous RISC-V Compute Cluster for Extreme-Edge On-Chip DNN Inference and Training}, 
  year={2022},
  volume={2},
  number={},
  pages={231-243},
  keywords={Clustering methods;Low power electronics;Engines;System-on-chip;Human computer interaction;Hardware;Tensors;Heterogeneous cluster;tensor product engine (TPE);ultralow-power AI},
  doi={10.1109/OJSSCS.2022.3210082}
}
@article{conti2023marsellus,
  author={Conti, Francesco and Paulin, Gianna and Garofalo, Angelo and Rossi, Davide and Di Mauro, Alfio and Rutishauser, Georg and Ottavi, Gianmarco and Eggiman, Manuel and Okuhara, Hayate and Benini, Luca},
  journal={IEEE Journal of Solid-State Circuits}, 
  title={Marsellus: A Heterogeneous RISC-V AI-IoT End-Node SoC With 2–8 b DNN Acceleration and 30%-Boost Adaptive Body Biasing}, 
  year={2024},
  volume={59},
  number={1},
  pages={128-142},
  keywords={Artificial neural networks;Computer architecture;Task analysis;Engines;System-on-chip;Kernel;Microcontrollers;Artificial intelligence (AI);deep neural networks (DNNs);digital signal processor (DSP);heterogeneous architecture;Internet of Things (IoT);RISC-V;system-on-chip (SoC)},
  doi={10.1109/JSSC.2023.3318301}
}
@inproceedings{prasad2023archimedes,
  author={Prasad, Arpan Suravi and Benini, Luca and Conti, Francesco},
  booktitle={2023 60th ACM/IEEE Design Automation Conference (DAC)}, 
  title={Specialization meets Flexibility: a Heterogeneous Architecture for High-Efficiency, High-flexibility AR/VR Processing}, 
  year={2023},
  volume={},
  number={},
  pages={1-6},
  keywords={Power demand;Design automation;Wearable computers;Pipelines;Gaze tracking;Energy efficiency;Task analysis},
  doi={10.1109/DAC56929.2023.10247945}
}
```
