# CPU 测试报告

> 执行日期：2026-07-15
> RTL 基线：`df123a486be552f61ff9bc745bbf17c31add751a`
> 测试计划：[cpu_test_plan.md](cpu_test_plan.md)
> 测试入口：[`verification/`](../../verification/README.md)
> CPU-only 配置：240 MHz，周期 4.166667 ns

## 1. 总体结论

RV32M 的有符号除法溢出判断已限定为 `DIV/REM`，无符号 `DIVU/REMU` 不再错误
进入该快速路径。修复后，本项目定向测试、固定开源白名单和竞赛 `irom-v2` 全部
通过：

| 测试组 | 结果 | 说明 |
| --- | ---: | --- |
| 构建、布局、容量和 ISA 审计 | PASS | 6 个本地 ELF 和 45 个上游 ELF 均未越过能力边界 |
| 本项目定向测试 | **6/6 PASS** | RV32I、RV32M、Zicsr/trap、流水线、访存、性能微基准 |
| 固定 `riscv-tests` 白名单 | **45/45 PASS** | 37 个 RV32UI、8 个 RV32UM，原失败 `rv32um-p-remu` 已通过 |
| `irom-v2` 竞赛镜像 | **PASS** | 退休的 LED store 写入 `0x078B7323` |
| Vivado 综合、实现和时序 | NOT RUN | 当前环境没有 Vivado，未生成 240 MHz WNS/Fmax 结论 |

结论仅覆盖当前能力边界内的 CPU-only 功能和性能仿真。它不是完整 RISC-V 架构
认证，也不能替代开发板实测或 Vivado 实现后的时序收敛检查。

## 2. CPU 错误与修复

### 2.1 原错误

`rv32m_unit.sv` 原先只按操作数位型判断：

```text
operand_a = 0x80000000
operand_b = 0xFFFFFFFF
```

该位型只有在有符号 `DIV/REM` 中表示 `INT_MIN / -1` 溢出。旧逻辑却让 `DIVU` 和
`REMU` 也进入溢出快速路径，导致 `REMU` 错误返回 0；正确余数应为
`0x80000000`。`DIVU` 的错误快速路径碰巧也返回正确商 0，但没有执行正确的无符号
除法语义。

### 2.2 修复

`div_overflow` 现在同时要求操作是 `DIV` 或 `REM`：

```systemverilog
assign div_overflow = (op_div || op_rem) &&
                      (operand_a == 32'h8000_0000) &&
                      (operand_b == 32'hFFFF_FFFF);
```

除数为零的快速路径保持不变；有符号 `DIV` 仍返回 `0x80000000`，有符号 `REM`
仍返回 0。无符号同位型输入改走正常 32 次迭代路径。

### 2.3 独立复现与关闭条件

| 测试 | 修复前 | 修复后 | 关闭依据 |
| --- | ---: | ---: | --- |
| 本地 `rv32m` 用例 118 | CPU_ERROR | PASS | `0x80000000 REMU 0xFFFFFFFF` 返回 `0x80000000` |
| 上游 `rv32um-p-remu` test 7 | CPU_ERROR | PASS | 未修改上游测试主体和期望值 |
| 全部 RV32UM | 7 PASS / 1 CPU_ERROR | 8/8 PASS | 乘、除、余数及特殊情况全部通过 |

## 3. 测试环境与输入

| 项目 | 值 |
| --- | --- |
| 主机 | Linux 6.17.0-35-generic x86_64 |
| RISC-V GNU 工具链 | `riscv64-unknown-elf-gcc 13.2.0` |
| Verilator | `5.020` |
| 本地测试 ISA/ABI | `rv32im_zicsr/ilp32`，禁用压缩和 linker relaxation |
| CPU-only 时钟 | 240 MHz，4.166667 ns |
| COUNTER 时钟模型 | 50 MHz |
| 本地完成值 | PASS=`0xC0DEC0DE`，FAIL=`0xDEADBEEF` |
| 竞赛完成值 | PASS=`0x078B7323`，FAIL=`0x24181824` |
| Vivado | 未安装，综合/实现/板级仿真未执行 |

固定上游版本：

- `riscv-tests`：`34e6b6d1e7936b526075432fb730d89148623484`，正式启用；
- `riscv-arch-test`：`18b803cb4eea318db611ca87138ee9d3ad662d24`，只锁定未启用；
- Embench-IoT：`09c2ed8c3b7008c95d08b038de4a3f6dc103ed70`，只锁定未启用。

竞赛镜像未经修改：

| 文件 | SHA-256 |
| --- | --- |
| `sim/coe/mext/irom-v2.coe` | `0cea80f2ca36e2672ac8d1e3d0087f88dc24b5a33a177c74b47330b0637c6a1b` |
| `sim/coe/mext/dram.coe` | `d1c6d8f4adbe80d618ccfccc0336a9a61b56007b0f44a4e79bddf71ccab89c03` |

## 4. 本项目定向测试

### 4.1 正确性结果

| 测试 | 结果 | 关键覆盖 |
| --- | ---: | --- |
| `rv32i` | PASS | 37 条 RV32I、分支/跳转、对齐 byte/half/word load/store |
| `rv32m` | PASS | 8 条 RV32M、除零、有符号溢出、无符号同位型边界 |
| `zicsr_trap` | PASS | 6 条 Zicsr、5 个 CSR、`ecall`/`mret` |
| `pipeline` | PASS | 双发射、包内约束、前递、load-use、控制流冲刷 |
| `memory` | PASS | BRAM 首尾、子字 lane、L0、MMIO、50 MHz COUNTER |
| `perf_micro` | PASS | 双发射、分支、load-use 和 RV32M 混合性能负载 |

### 4.2 基本性能数据

| 测试 | 周期 | 退休指令 | CPI | MIPS | 双发射包 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rv32i` | 259 | 158 | 1.639 | 146.409 | 0 |
| `rv32m` | 403 | 91 | 4.429 | 54.194 | 0 |
| `zicsr_trap` | 167 | 106 | 1.575 | 152.335 | 1 |
| `pipeline` | 369 | 211 | 1.749 | 137.236 | 32 |
| `memory` | 600,155 | 600,105 | 1.000 | 239.980 | 0 |
| `perf_micro` | 21,299 | 22,273 | **0.956** | **250.975** | 6,501 |

MIPS 按 CPU-only 240 MHz 换算，不是板上实测值。`perf_micro` 的 CPI 小于 1，说明
该负载确实利用了双槽提交能力。

### 4.3 停顿和缓存数据

| 测试 | 前端停顿 | load-use EX | load-use MEM | EX busy | L0 命中/BRAM load | 命中率 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rv32i` | 0 | 0 | 0 | 0 | 6/8 | 75.000% |
| `rv32m` | 256 | 0 | 0 | 256 | 0/0 | N/A |
| `zicsr_trap` | 0 | 0 | 0 | 0 | 0/0 | N/A |
| `pipeline` | 40 | 2 | 3 | 35 | 0/3 | 0.000% |
| `memory` | 6 | 1 | 5 | 0 | 4/11 | 36.364% |
| `perf_micro` | 4,502 | 2,001 | 2,001 | 500 | 0/2,001 | 0.000% |

## 5. 固定开源白名单

所有 45 个 ELF 都通过 IROM≤16 KiB、BRAM≤256 KiB、段地址、重定位和反汇编 ISA
审计。平台层只替换启动地址、signature 与 LED 结束动作，未修改上游测试主体或
期望值。

RV32UI 为 **37/37 PASS**：

```text
add addi and andi auipc beq bge bgeu blt bltu bne jal jalr
lb lbu lh lhu lui lw or ori sb sh sll slli slt slti sltiu sltu
sra srai srl srli sub sw xor xori
```

RV32UM 为 **8/8 PASS**：

```text
mul mulh mulhsu mulhu div divu rem remu
```

`fence_i`、非对齐异常、RV32MI/RV32SI、RV64、浮点、原子和压缩测试仍按能力边界
排除。ACT4 与 Embench-IoT 尚未完成平台适配/容量审核，未计入通过数。

## 6. `irom-v2` 正确性结果

竞赛给定的 `irom-v2` 和 `dram.coe` 在 SW0/SW1/KEY 为零的环境下完整运行：

| 判定项 | 结果 |
| --- | --- |
| 结束原因 | 退休的 LED store |
| 期望 LED | `0x078B7323` |
| 实际 LED | `0x078B7323` |
| 失败 LED | 未出现 `0x24181824` |
| 最终 SEG | `0x37801683` |
| 最终 PC | `0x80000810` |
| 正确性结论 | **PASS** |

SEG、COUNTER 和性能指标不参与正确性门禁。

## 7. `irom-v2` 性能数据

| 指标 | 实测值 |
| --- | ---: |
| CPU-only 频率 | 240.000 MHz |
| CPU 周期 | 4.166667 ns |
| 周期 | 404,056,765 |
| 退休指令 | 380,344,360 |
| CPI | 1.062 |
| IPC | 0.941 |
| MIPS | 225.915 |
| 寄存器写回 | 349,087,549 |
| slot1 写回 | 69,193,505 |
| store | 21,450,257 |
| taken branch | 10,826,006 |
| 双发射包 | 68,939,273 |
| 前端停顿周期 | 92,250,808 |
| load-use 总停顿 | 91,354,378 |
| load-use EX 停顿 | 58,429,415 |
| load-use MEM 停顿 | 32,924,979 |
| hazard + EX busy | 20,479,998 |
| EX busy 周期 | 21,376,428 |
| BRAM load | 110,606,978 |
| L0 命中 | 69,677,186 |
| L0 命中率 | 62.995% |
| COUNTER | 1,683 ms |
| 仿真时间 | 1,683,300,499 ns |
| 宿主 wall time | 279.582 s |
| 宿主 CPU time | 278.185 s |
| 仿真速度 | 14.307 ms/s |

### 7.1 与历史 200 MHz 基线对比

| 指标 | 200 MHz 历史值 | 240 MHz 本次值 | 变化 |
| --- | ---: | ---: | ---: |
| 周期 | 404,056,765 | 404,056,765 | 0% |
| 退休指令 | 380,344,360 | 380,344,360 | 0% |
| CPI | 1.062 | 1.062 | 0% |
| MIPS | 188.263 | 225.915 | **+20.000%** |
| COUNTER | 2,020 ms | 1,683 ms | **-16.683%** |
| 宿主 wall time | 212.335 s | 279.582 s | +31.670% |

周期、退休指令和 CPI 完全一致，说明频率配置变化没有改变该程序的周期级执行路径。
MIPS 正好随 200→240 MHz 增加 20%；COUNTER 测得的时间约按 `200/240` 缩短。
宿主 wall time 反映本次 Verilator 运行环境和负载，不代表 FPGA 性能。

## 8. 未执行项与限制

- 当前主机没有 Vivado，未执行 elaboration、xsim、综合、布局布线和 bitstream。
- 因而本报告没有 LUT/FF/DSP/BRAM、WNS、TNS、route status 或实现后 Fmax 数据；
  240 MHz 仍须以 Vivado 实现报告和开发板稳定性测试确认。
- 未执行完整 ACT4 架构认证、形式验证、随机差分测试或能力边界外指令。
- 未启用尚未完成裸机适配与容量审计的 Embench-IoT workload。

## 9. 复现命令与结果文件

```sh
cd verification
make check
make regression
make fetch-open-source
make verify-open-source
make run-open-source
make competition
```

机器可读结果位于构建目录：

- `verification/build/local-results.json`
- `verification/build/riscv-tests/manifest.json`
- `verification/build/riscv-tests/results.json`
- `verification/build/irom-v2-result.json`

`verification/build/` 为可再生测试产物，不作为 RTL 源文件提交；本报告是本次结果的
受版本控制记录。
