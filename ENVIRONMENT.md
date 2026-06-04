# 环境配置说明

本文记录本仓库当前可用的 CPU-only 仿真环境配置步骤，目的是让其他协作者在没有 Vivado 的情况下，也能在本地跑 `sim_cpu_only/` 下的 Verilator 仿真。

## 1. 前置条件

建议环境：

- Linux x86_64
- `bash`
- `curl` 或 `wget`
- `tar`
- `python3`

可以先检查：

```sh
command -v curl
command -v tar
python3 --version
```

## 2. 安装 micromamba

本仓库当前使用用户目录下的 `micromamba` 管理仿真工具链，不依赖 sudo。

```sh
mkdir -p ~/.local
curl -L https://micro.mamba.pm/api/micromamba/linux-64/latest -o /tmp/micromamba.tar.bz2
tar -xjf /tmp/micromamba.tar.bz2 -C ~/.local bin/micromamba
~/.local/bin/micromamba --version
```

安装完成后，可执行文件路径为：

```text
~/.local/bin/micromamba
```

## 3. 创建 HDL 工具环境

创建专用环境 `hdl`，安装仿真与构建工具：

```sh
~/.local/bin/micromamba create -y -r ~/.local/micromamba -n hdl -c conda-forge iverilog make verilator gxx_linux-64 zlib
```

本仓库当前依赖这些工具：

- `iverilog`
- `verilator`
- `make`
- `x86_64-conda-linux-gnu-g++`
- `zlib`（用于 FST trace）

## 4. 验证安装

验证关键工具：

```sh
~/.local/micromamba/envs/hdl/bin/verilator --version
~/.local/micromamba/envs/hdl/bin/iverilog -V
~/.local/micromamba/envs/hdl/bin/make --version
~/.local/micromamba/envs/hdl/bin/x86_64-conda-linux-gnu-g++ --version
```

如果这些命令都能正常输出版本号，说明环境已就绪。

## 5. 与仓库的集成方式

当前 `sim_cpu_only/` 流程默认直接使用以下路径：

```text
/home/mph/.local/bin/micromamba
/home/mph/.local/micromamba/envs/hdl/bin/...
```

如果其他协作者安装到了不同目录，需要同步调整：

- `sim_cpu_only/Makefile`
- `sim_cpu_only/run_verilator.sh`

更稳妥的做法是大家统一使用：

```text
~/.local/bin/micromamba
~/.local/micromamba/envs/hdl
```

## 6. 跑通一次仿真

环境装好后，在仓库根目录运行：

```sh
./sim_cpu_only/run_verilator.sh
```

如果要看后续如何切换 COE、开启 trace、理解输出结果，请看：

[SIMULATION.md]
