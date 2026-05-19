# Vivado Tcl Flow

Use these scripts from the repository root with Vivado in batch mode.

```sh
vivado -mode batch -source scripts/create_project.tcl
vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_myCPU
vivado -mode batch -source scripts/run_build.tcl -tclargs bitstream
```

`create_project.tcl` recreates `vivado/digital_twin.xpr` from tracked sources,
constraints, COE/MIF files, and existing XCI IP files. The generated Vivado
project and run directories remain ignored by `.gitignore`.

`run_sim.tcl` accepts `tb_myCPU`, `tb_top`, or `tb_uart`; the default is
`tb_myCPU`.

`run_build.tcl` accepts `synth`, `impl`, or `bitstream`; the default is
`bitstream`.
