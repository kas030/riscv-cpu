# CPU 测试报告

> 执行日期：2026-07-15
> RTL 基线：`9e11ca7adec6`
> 测试计划：[cpu_test_plan.md](cpu_test_plan.md)
> 测试入口：[`verification/`](../../verification/README.md)

## 1. 总体结论

本次使用独立于 `vivado/tests/` 的新验证体系，执行本项目定向测试、固定版本
`riscv-tests` 白名单和竞赛 `irom-v2`。结果如下：

| 测试组 | 结果 | 说明 |
| --- | ---: | --- |
| 构建、布局、容量和反汇编审计 | PASS | 六个本地 ELF 及 45 个上游 ELF 均在能力边界内 |
| 本项目定向测试 | 5 PASS / 1 CPU_ERROR | `rv32m` 在新增 REMU 边界点失败 |
| 固定 `riscv-tests` 白名单 | 44 PASS / 1 CPU_ERROR | `rv32um-p-remu` test 7 失败 |
| `irom-v2` 竞赛镜像 | PASS | LED 正确写入 `0x078B7323` |
| 测试脚本与文档检查 | PASS | `git diff --check`、shell 语法和锁文件检查通过 |

唯一失败由本地测试和独立上游测试共同复现，已归类为能力边界内的 CPU 错误，
不是测试或仿真环境错误。

## 2. 环境与输入

- 主机：Linux x86-64
- RISC-V GNU 工具链：`riscv64-unknown-elf-gcc 13.2.0`
- Verilator：`5.020`
- 本地测试 ISA：`rv32im_zicsr/ilp32`，禁用压缩与 linker relaxation
- `riscv-tests` commit：`34e6b6d1e7936b526075432fb730d89148623484`
- 竞赛镜像：`sim/coe/mext/irom-v2.coe`、`sim/coe/mext/dram.coe`
- 本地完成值：PASS=`0xC0DEC0DE`，FAIL=`0xDEADBEEF`
- 竞赛完成值：PASS=`0x078B7323`，FAIL=`0x24181824`

上游 ACT4 和 Embench 只完成版本锁定，尚未通过各自的平台/容量审查，未计入本次
正式执行结果。

## 3. 本项目定向测试结果

| 测试 | 结果 | 周期 | 退休指令 | CPI | 关键覆盖或判定 |
| --- | --- | ---: | ---: | ---: | --- |
| `rv32i` | PASS | 259 | 158 | 1.639 | 37 条 RV32I、分支、跳转、对齐子字访存 |
| `rv32m` | CPU_ERROR | 297 | 88 | 3.375 | 用例 118，SEG=`0x00000076` |
| `zicsr_trap` | PASS | 167 | 106 | 1.575 | 六种 CSR、五个 CSR、`ecall/mret` |
| `pipeline` | PASS | 369 | 211 | 1.749 | 32 个双发射包、5 个 load-use 停顿 |
| `memory` | PASS | 600,155 | 600,105 | 1.000 | BRAM 末字节、L0、MMIO、COUNTER |
| `perf_micro` | PASS | 21,299 | 22,273 | 0.956 | 性能数据仅展示，不作门禁 |

`memory` 最终验证了 `0x8013FFFF` byte lane。为使 CPU-only 行为与
`perip_bridge` 地址窗一致，testbench 的 BRAM 上界由错误的半开判断修正为包含
`BRAM_END`；修正后该测试通过。

## 4. 开源白名单结果

固定白名单包含 37 个 RV32UI 和 8 个 RV32UM 测试。所有测试均通过以下预检查：

- IROM 不超过 16 KiB，BRAM 不超过 256 KiB；
- 代码运行地址为 `0x80000000`，数据位于 `0x80100000`；
- 反汇编不含白名单外指令；
- 上游测试主体和期望值未修改，仅替换平台启动、signature 和 LED 结束协议。

执行结果为 44 项 PASS、1 项 CPU_ERROR。失败项为 `rv32um-p-remu` test 7：

```text
操作数：0x80000000 REMU 0xFFFFFFFF
期望值：0x80000000
实际值：0x00000000
```

同一错误已加入本地 `rv32m` 用例 118，因此即使上游测试未下载，本地回归也会稳定
捕获该问题。

## 5. CPU_ERROR 分析

`rv32m_unit.sv` 的 `div_overflow` 只按操作数位型判断
`0x80000000/0xFFFFFFFF`，启动除法时又对 DIV、DIVU、REM、REMU 统一进入该快速
路径。该特殊情况只适用于有符号 DIV/REM；对无符号 REMU，两个操作数分别是
`2147483648` 和 `4294967295`，余数应保持被除数。

因此当前 RTL 对 REMU 错误返回快速路径的 0。该问题不应标为预期失败、测试错误或
能力边界；修复后必须同时重新运行本地 `rv32m` 和全部 RV32UM 白名单。

## 6. `irom-v2` 正确性与性能结果

竞赛程序在 SW0/SW1/KEY 为零、CPU-only 200 MHz 配置下完成，并由退休的 LED
store 写入 `0x078B7323` 判定 PASS。

| 指标 | 实测值 |
| --- | ---: |
| 周期 | 404,056,765 |
| 退休指令 | 380,344,360 |
| CPI | 1.062 |
| MIPS（按仿真 200 MHz 换算） | 188.263 |
| 双发射包 | 68,939,273 |
| 前端停顿周期 | 92,250,808 |
| load-use EX 停顿 | 58,429,415 |
| load-use MEM 停顿 | 32,924,979 |
| EX busy 周期 | 21,376,428 |
| BRAM load | 110,606,978 |
| L0 命中 | 69,677,186 |
| L0 命中率 | 62.995% |
| COUNTER | 2,020 ms |
| 最终 SEG | `0x37802020` |
| 宿主 wall time | 212.335 s |

上述性能数据只用于展示本次基线，不参与正确性验收，也不能视为开发板实际可达频率。

## 7. 复现命令

```sh
cd verification
make check
make regression
make fetch-open-source
make run-open-source
make competition
```

在当前 RTL 上，`make regression` 和 `make run-open-source` 会因已确认的 REMU
CPU_ERROR 返回非零；删除该用例或修改期望值不能视为修复。
