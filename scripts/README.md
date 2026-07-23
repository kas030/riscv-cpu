# Vivado Tcl 脚本说明

本目录存放 Vivado 工程创建、仿真、构建和 IP 维护脚本。建议在仓库根目录
执行这些脚本，避免相对路径解析到错误位置。

## 常用命令

```sh
vivado -mode batch -source scripts/create_project.tcl
vivado -mode batch -source scripts/recreate_irom_ip.tcl
vivado -mode batch -source scripts/recreate_bram_ip.tcl
vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_myCPU
vivado -mode batch -source scripts/run_build.tcl -tclargs bitstream
```

## 脚本列表

- `create_project.tcl`
  - 从仓库源码重新创建 `vivado/digital_twin.xpr`。
  - 导入 RTL、约束和 COE/MIF 文件，并显式创建 `IROM`、`BRAM` 和 `pll`
    三个 IP。
  - IROM 创建为双端口 `blk_mem_gen` ROM，不再使用旧 `dist_mem_gen` 配置。
  - 创建后会对所有 XCI 执行 `generate_target all`。

- `recreate_bram_ip.tcl`
  - 专门用于把 Vivado 工程内的 `BRAM` IP 重建为 `blk_mem_gen`
    True Dual Port BRAM。
  - 关闭 BRAM 的 OOC 综合 DCP，使 `clka/clkb` 在全局综合时直接继承
    CPU 的 4.167 ns 时钟约束，避免默认 20 ns `BRAM_ooc.xdc` 导致
    `[Timing 38-316]` 警告和不一致网表。
  - 适用于综合报旧 `BRAM_stub.v` 端口不匹配，例如 RTL 连接了
    `clka/ena/wea/addra/douta/clkb/enb/web/addrb/dinb`，但 Vivado 仍看到
    旧 `clk/a/d/we/spo` 端口。

- `recreate_irom_ip.tcl`
  - 删除工程中的旧 `dist_mem_gen` IROM，并用同名 `blk_mem_gen 8.4`
    重建为 4096×32 双端口 ROM。
  - A/B 端口均为一拍同步读，分别服务 `PC` 和 `PC+4`。
  - 使用 `sim/coe/mext/irom-v2.coe` 初始化并生成新的 output products。
  - 适用于已经由旧脚本创建的工程，无需再次完整重建工程。

- `run_sim.tcl`
  - 运行 XSim 行为仿真。
  - 支持 `tb_myCPU`、`tb_top`、`tb_uart`，默认是 `tb_myCPU`。

- `run_build.tcl`
  - 运行综合、实现或生成 bitstream。
  - 支持 `synth`、`impl`、`bitstream`，默认是 `bitstream`。
  - 日常迭代默认使用 `Vivado Implementation Defaults` 和自动增量布局。
  - 阶段性候选版可显式使用高强度策略：
    `-tclargs impl Performance_NetDelay_high`。

- `report_high_fanout.tcl`
  - 对打开的工程或设计输出高扇出网络报告，用于时序优化分析。

## BRAM IP 重建脚本

### 命名约定

数据存储器统一命名为 `BRAM`，对应 RTL 中 `BRAM Mem_BRAM (...)` 的 IP
例化、Vivado 工程内的 `BRAM` IP、`ip/BRAM/BRAM.xci` 配置文件，以及
`sim/coe/mext/dram.coe` 初始化文件。脚本会按这一套命名重建 IP output products。

### 何时需要运行

当出现类似下面的综合错误时，应运行该脚本：

```text
[Synth 8-11365] ... module 'BRAM' ... named port connection 'clka' does not exist
[Synth 8-11365] ... named port connection 'ena' does not exist
[Synth 8-11365] ... named port connection 'web' does not exist
```

这通常说明 Vivado 仍在使用旧生成产物：

```text
vivado/digital_twin.gen/sources_1/ip/BRAM/BRAM_stub.v
vivado/digital_twin.runs/synth_1/.Xil/.../BRAM_stub.v
```

旧 stub 的端口是 `clk/a/d/we/spo`，而当前 RTL 需要 BRAM 端口
`clka/ena/wea/addra/dina/douta/clkb/enb/web/addrb/dinb/doutb`。

### 前置条件

- 已存在 `vivado/digital_twin.xpr`。
- 若工程不存在，先运行：

```sh
vivado -mode batch -source scripts/create_project.tcl
```

- Vivado 版本需提供 `xilinx.com:ip:blk_mem_gen:8.4`。
- `sim/coe/mext/dram.coe` 存在，用作 BRAM 初始化文件。

### 执行方式

在仓库根目录运行：

```sh
vivado -mode batch -source scripts/recreate_bram_ip.tcl
```

脚本执行后会输出类似信息：

```text
INFO: recreated BRAM as blk_mem_gen true dual-port BRAM: .../BRAM.xci
```

然后重新综合：

```sh
vivado -mode batch -source scripts/run_build.tcl -tclargs synth
```

或在 Vivado GUI 中重新运行 `synth_1`。

### 脚本具体做了什么

`recreate_bram_ip.tcl` 会：

1. 打开 `vivado/digital_twin.xpr`。
2. 从工程中移除旧 `BRAM` IP。
3. 删除工程源目录下旧的 `BRAM.xci`。
4. 通过 `create_ip -name blk_mem_gen ... -module_name BRAM` 重新创建同名 IP。
5. 配置为 True Dual Port RAM：
   - Port A：同步读，32 位宽，深度 65536 word。
   - Port B：同步写，32 位宽，支持 4-bit byte write enable。
   - 关闭输出寄存器，保持读延迟为 BRAM 原生同步读一拍。
   - 使用 `sim/coe/mext/dram.coe` 初始化。
6. 执行 `generate_target all` 生成新的 output products。
7. 设置 `GENERATE_SYNTH_CHECKPOINT=false`，让 BRAM 随顶层按实际
   240 MHz 时钟全局综合。
8. 更新 `sources_1` 编译顺序并关闭工程。

### 与 `create_project.tcl` 的关系

`create_project.tcl` 是“从已有 XCI 导入工程”。如果 `ip/BRAM/BRAM.xci` 已经是
正确的 BRAM 配置，重新创建工程时通常不需要再单独运行
`recreate_bram_ip.tcl`。

但对已经存在的旧 Vivado 工程，可能仍保留旧 output products 或旧 stub。此时
直接运行 `recreate_bram_ip.tcl` 更明确，它会在当前工程内重建 `BRAM` IP。

### GUI 等价操作

在 Vivado GUI 中可手动完成类似流程：

1. 删除旧 `BRAM` IP。
2. `IP Catalog -> Block Memory Generator`。
3. IP 名称设为 `BRAM`。
4. Memory Type 选择 `True Dual Port RAM`。
5. A/B 口宽度设为 32，深度设为 65536。
6. 开启 byte write enable，byte size 设为 8。
7. Port A/Port B 使用 enable pin。
8. 加载 `sim/coe/mext/dram.coe`。
9. 生成 output products。
10. 重新运行综合。

推荐优先使用 Tcl，避免 GUI 配置项漏选。

### 常见问题

- **仍然报 `clka` 不存在**

  说明综合仍拿到了旧 stub。关闭正在运行的综合任务后，重新运行：

  ```sh
  vivado -mode batch -source scripts/recreate_bram_ip.tcl
  ```

  然后在 Vivado 中 reset/re-run `synth_1`。

- **提示找不到工程**

  先运行：

  ```sh
  vivado -mode batch -source scripts/create_project.tcl
  ```

- **提示找不到 `blk_mem_gen:8.4`**

  当前 Vivado 安装版本可能不同。打开 IP Catalog 检查 Block Memory Generator
  的版本；必要时把脚本里的 `-version 8.4` 改成当前版本。

- **是否要编辑 `vivado/digital_twin.gen/` 或 `.runs/`**

  不要手动编辑生成目录。让 Vivado 通过 `generate_target all` 和重新综合生成。

## 注意事项

- 脚本默认工程名为 `digital_twin`，工程目录为 `vivado/`。
- 所有路径均按仓库根目录推导，不依赖当前 shell 工作目录，但仍建议从仓库根
  运行，方便排查日志。
- 如果 Vivado GUI 已打开该工程，batch 脚本可能因文件占用失败。先关闭 GUI 或
  停止正在运行的综合/实现任务。
