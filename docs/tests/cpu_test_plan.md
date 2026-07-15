# CPU 正确性与性能测试计划

> 基线日期：2026-07-15
> 能力依据：[cpu_capability_boundaries.md](../cpu_capability_boundaries.md)
> 执行入口：[`verification/`](../../verification/README.md)

## 1. 判定原则

本计划只验证当前文档承诺的 RV32IM、最小 Zicsr/M-mode trap、自然对齐 BRAM、
固定 MMIO 和顺序双槽实现。`vivado/tests/` 已知存在构建、地址、数据初始化和期望
错误，不得作为源码、工具、镜像或结果来源。

正确性是门禁；性能数字只展示。性能程序必须先得到正确结果才能发布指标，但周期、
CPI、得分或相对历史变化不决定 PASS/FAIL。未实现的 `fence/fence.i`、`ebreak`、
非法指令异常、非对齐异常、中断、U/S 模式和其他扩展只作非门禁边界观察。

结果统一分类为 `PASS`、`CPU_ERROR`、`TEST_ERROR`、`ENV_ERROR`、
`CAPABILITY_BOUNDARY` 或 `TIMEOUT`。

## 2. 测试组成

### 本项目定向测试

| 测试 | 正确性覆盖 | 重点可观测项 |
| --- | --- | --- |
| `rv32i` | 37 条 RV32I、边界值、x0、六种分支、jal/jalr、五种 load/三种 store | 退休结果、BRAM signature |
| `rv32m` | 八条 M 指令、乘法高位、除零、signed overflow、unsigned 相似位型 | RV32M busy、结果 |
| `zicsr_trap` | 六种 CSR 形式、五个 CSR、未实现 CSR、ecall/mret | mepc/mcause、MIE/MPIE、flush |
| `pipeline` | 两槽 RAW/WAW、各级前递、load-use、预测恢复、多周期相关 | slot1、停顿、错误路径副作用 |
| `memory` | BRAM 首末地址、所有 byte lane、L0 hit/tag/失效、MMIO、COUNTER | load 停顿、L0、同步返回 |
| `perf_micro` | 固定 ALU/load/store/branch/M 混合负载 | IPC/CPI、双发射、停顿，仅展示 |

每项以 LED `0xC0DEC0DE`/`0xDEADBEEF` 结束，并把失败编号、实际值和期望值写入
BRAM signature；失败编号也写入 SEG，保证日志可直接定位。

### 可信开源测试

版本由 `verification/upstream.lock.json` 的完整 SHA 固定，不允许回归时浮动升级。

- RISC-V International `riscv-arch-test`：已锁定 ACT4 上游，但在 UDB、Sail 和
  `rvmodel_macros.h` 完成逐项审查前禁用。不能把部分子集通过描述为完整认证。
- `riscv-software-src/riscv-tests`：实际启用 37 个 RV32UI 和 8 个 RV32UM 用例。
  平台层只替换启动地址、内存布局、signature 和 LED 结束动作；测试主体不修改。
- Embench-IoT：已锁定为性能候选。只有同时满足裸机、RV32IM、IROM≤16 KiB、
  BRAM≤256 KiB、无系统调用/浮点/动态分配且通过上游自校验的 workload 才能启用。

开源白名单明确排除 `fence_i`、非对齐异常、机器异常全套、S/U 模式、RV64、
浮点、原子和压缩扩展。每个 ELF 构建后再次按反汇编审计，防止编译器引入越界指令。

### 竞赛端到端测试

必须原样使用 `sim/coe/mext/irom-v2.coe` 和 `dram.coe`，SW0/SW1/KEY 为零，
CPU-only 时钟配置为 240 MHz，超时为 4,000,000,000 ns。退休的 LED store 写入
`0x078B7323` 为正确完成，`0x24181824`、超时或未知态为失败。

SEG、COUNTER 和性能值只记录，不参与正确性门禁。实测值统一写入独立的
[CPU 测试报告](cpu_test_report.md)，不得回填到本计划。

## 3. 构建与环境可信性

- 新测试固定使用 `rv32im_zicsr/ilp32`、`.option norvc` 和禁用 linker relaxation。
- `.text/.rodata` 链接到 `0x80000000`，`.data/.signature` 链接到
  `0x80100000`，分别生成 IROM 与 BRAM 镜像。
- 构建检查 IROM 16 KiB、BRAM 256 KiB、段地址、未解析重定位和实际反汇编指令。
- CPU-only 模型必须与 `student_top/perip_bridge` 的 BRAM 地址窗、byte-enable、
  同步读取和 COUNTER 协议一致；模型错误归类 `ENV_ERROR`，不得修改期望掩盖。
- 所有结果记录 RTL commit、测试源 commit、镜像哈希、工具版本、随机种子和命令。

## 4. 性能报告

统一记录周期、退休指令、IPC/CPI、双发射包、slot1 写回、前端停顿、load-use
EX/MEM 停顿、RV32M busy、条件分支及预测错误、BRAM load、L0 命中率、宿主
wall time 和仿真速度。Vivado 报告另外记录 LUT/FF/DSP/BRAM、WNS 和可达频率。

CPU-only 配置的 240 MHz 用于匹配当前板级 CPU 时钟，并进行仿真时间与 MIPS 换算；
它本身不能证明板上时序收敛。性能表可给出历史差值，但不因改善或退化使正确性
测试通过或失败。

## 5. 执行分层

```sh
cd verification
make check             # 编译、布局、ISA 和上游锁文件检查
make regression        # 六组本地测试
make fetch-open-source # 首次或显式升级时下载固定上游
make run-open-source   # 45 项固定 RV32UI/RV32UM 白名单
make competition       # 完整 irom-v2，运行时间较长
```

- 每次 RTL 修改：`make check`、本地回归和 45 项开源白名单。
- 修改冒险、前递、分支、CSR、RV32M 或访存：追加对应定向压力组。
- 发布候选：以上全部、完整 `irom-v2`、Vivado elaboration/xsim 接口检查及综合时序。
- 上游升级必须独立审核白名单差异、许可证、能力要求和期望，不与 RTL 修改混合。
