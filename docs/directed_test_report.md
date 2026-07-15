# CPU 定向测试报告

> 执行日期：2026-07-15
> 能力判定依据：[`cpu_capability_boundaries.md`](cpu_capability_boundaries.md)
> RTL 基线：`7aadc28`（分支 `codex/tests`）

## 1. 结论

本次检查覆盖 `vivado/tests` 四个 tier 中默认收集的 t01—t19，共 19 项。`zb_training/t20`—`t27` 是能力边界文档明确排除的 Zb 扩展训练项，不属于本次正式回归范围。

| 结论 | 数量 | 说明 |
| --- | ---: | --- |
| PASS | 12 | 使用仓库默认测试语义构建并通过 CPU-only Verilator 自检 |
| TEST_ERROR / SKIP | 6 | 测试构建参数、地址生成、数据装载或期望行为错误 |
| CAPABILITY_BOUNDARY / SKIP | 1 | 测试依赖当前 CPU 未提供的取数路径 |
| CPU_ERROR | 0 | 未发现能够归因于当前 RTL 实现的错误 |

因此，本次没有修改 CPU RTL。所有有效测试均已通过；其余测试已按要求报告并跳过。

## 2. 环境与方法

- 主机：Linux 6.17.0-35-generic x86_64
- 工具链：`riscv64-unknown-elf-gcc 13.2.0`
- 仿真器：`Verilator 5.020`
- ISA 编译参数：仓库默认 `-march=rv32im -mabi=ilp32`
- 完成协议：LED 写入 `0xC0DEC0DE` 为通过，写入 `0xDEADBEEF` 为失败
- 仿真时限：`20,000,000 ns`；本次所有可运行程序均在时限内主动写 LED 结束
- IROM 镜像在 `/tmp/riscv_cpu_directed_build` 生成，避免覆盖 `vivado/tests/build` 中已跟踪的历史产物
- 数据存储器使用 CPU-only 环境默认的 `sim/coe/bram.coe`

正式构建按测试逐项执行，等价命令为：

```sh
cd vivado/tests
make BUILD=/tmp/riscv_cpu_directed_build tNN_name

cd ../..
./sim_cpu_only/run_verilator.sh \
  IROM_COE=/tmp/riscv_cpu_directed_build/tNN_name.coe \
  BRAM_COE=../sim/coe/bram.coe \
  PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
  STOP_NS=20000000 PROGRESS_NS=0
```

失败分类遵循以下口径：

- `CPU_ERROR`：测试只依赖能力文档承诺的功能，镜像和期望正确，但 RTL 结果错误。
- `TEST_ERROR`：测试源码、链接/初始化流程、构建参数或期望行为错误。
- `CAPABILITY_BOUNDARY`：程序依赖能力文档明确未提供的 CPU/SoC 能力。

## 3. 逐项结果

| 测试 | 层级 | 正式结果 | 周期 | 退休指令 | CPI | 判定 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `t01_arith` | tier1 | PASS | 46 | 41 | 1.122 | RV32I 算术通过 |
| `t02_logic_shift` | tier1 | PASS | 51 | 46 | 1.109 | 逻辑与移位通过 |
| `t03_branch` | tier1 | PASS | 248 | 222 | 1.117 | 条件分支通过 |
| `t04_jump` | tier1 | PASS | 3,290 | 2,225 | 1.479 | `jal/jalr` 通过 |
| `t05_load_store` | tier1 | PASS | 214 | 226 | 0.947 | BRAM load/store 与子字访问通过 |
| `t06_csr_periph` | tier1 | SKIP | — | — | — | TEST_ERROR，见 4.1 |
| `t07_forwarding` | tier2 | PASS | 1,292 | 1,533 | 0.843 | 前递通过 |
| `t08_load_use` | tier2 | PASS | 62 | 45 | 1.378 | load-use 冒险处理通过 |
| `t09_branch_hazard` | tier2 | PASS | 941 | 673 | 1.398 | 控制冒险与刷新通过 |
| `t10_fibonacci` | tier3 | PASS | 36,589 | 24,782 | 1.476 | 迭代/递归 Fibonacci 通过 |
| `t11_bubble_sort` | tier3 | SKIP | 3,468 | 3,348 | 1.036 | TEST_ERROR，见 4.2 |
| `t12_matmul` | tier3 | SKIP | 12,131 | 13,926 | 0.871 | TEST_ERROR，见 4.2 |
| `t13_gcd` | tier3 | PASS | 11,564 | 9,302 | 1.243 | GCD 软件算法通过 |
| `t14_prime_sieve` | tier3 | PASS | 20,986 | 27,771 | 0.756 | 素数筛通过 |
| `t15_string_ops` | tier3 | SKIP | 30 | 14 | 2.143 | CAPABILITY_BOUNDARY，见 4.3 |
| `t16_quicksort` | tier3 | SKIP | 21,402 | 18,628 | 1.149 | TEST_ERROR；仿真虽报 PASS，但属于假阳性，见 4.2 |
| `t17_coremark_lite` | tier4 | SKIP | 95,244 | 106,456 | 0.895 | TEST_ERROR，见 4.2 |
| `t18_m_ext_basic` | tier1 | PASS | 220 | 60 | 3.667 | RV32M 及特殊除法语义通过 |
| `t19_zicsr_trap` | tier1 | SKIP | — | — | — | TEST_ERROR；临时诊断通过，见 4.1 |

表中 SKIP 项的周期、退休指令和 CPI 仅用于记录其失败或假阳性运行，不表示该测试有效。

## 4. 跳过项分析

### 4.1 t06/t19：默认 ISA 编译参数遗漏 Zicsr

`vivado/tests/Makefile` 使用 `-march=rv32im`。当前 GCC 将 Zicsr 作为独立扩展，因此 t06 和 t19 在汇编阶段均报告 `extension 'zicsr' required`，默认 `make all` 也会在 t06 中止。这是测试构建配置错误，不是 CPU 译码失败。

t06 还有独立的测试逻辑错误：源码把 `0x80200050` COUNTER 当作自由运行的指令周期计数器，未写入 `0x80000000` 启动命令便连续读取并要求增长。能力边界及 `perip_bridge.sv` 的实际语义是显式启动/停止的时间计数器；CPU-only 模型同样只有启动后才计数。临时改用 `-march=rv32im_zicsr` 后，t06 在 42 周期写入失败 LED，与该错误期望一致，因此跳过。

为验证 CPU 的 Zicsr/trap 实现，未修改仓库，仅临时把编译参数改为 `-march=rv32im_zicsr` 运行 t19。诊断结果如下：

| 测试 | 诊断结果 | 周期 | 退休指令 | CPI | LED |
| --- | --- | ---: | ---: | ---: | --- |
| `t19_zicsr_trap` | PASS | 85 | 75 | 1.133 | `0xC0DEC0DE` |

这说明 t19 的默认失败点在测试构建配置，而不是当前 CPU 的 Zicsr、`ecall` 或 `mret` 实现。按任务约定，测试基础设施不在本次修正范围内，正式结果仍记为 SKIP。

### 4.2 t11/t12/t16/t17：静态数据地址和 BRAM 初始化流程错误

这四项把输入放在链接到 `0x80100000` 的 `.data`，并使用 `la` 生成地址。链接脚本却把代码链接到 `0x00000000`，CPU 实际从 `0x80000000` 取指。汇编器据此生成 PC-relative `auipc/addi`：例如 t11 的 `la a0, src_arr` 是：

```text
0x00000004: auipc a0,0x80100
0x00000008: addi  a0,a0,-4
```

在实际运行 PC `0x80000004` 上执行后，32 位回绕得到 `0x00100000`，而不是注释和链接符号显示的 `0x80100000`。波形确认源数据请求落在 `0x0010_xxxx`，超出 BRAM 地址窗，返回 0。

此外，默认镜像规则只把 `.text.init/.text/.rodata` 写入 IROM `.coe`，没有为每个 ELF 生成并选择对应的 BRAM 初始化镜像。因此，即使地址生成正确，默认 CPU-only 调用也不会自动装载这些 `.data` 内容。

影响如下：

- t11/t12/t17 得到零输入并写入失败 LED。
- t16 把全零数组复制到工作区；全零数组天然满足“相邻非递减”这个弱断言，所以错误地写入通过 LED。该结果不能证明 quicksort 正确，按 TEST_ERROR 跳过。
- 临时从 ELF 提取 `.data` 初始化 BRAM 后，源地址仍因上述 AUIPC 回绕落在 `0x0010_xxxx`，进一步排除了 CPU BRAM 初值读取错误。

### 4.3 t15：通过数据端口读取 IROM `.rodata`

t15 把字符串 `hello` 放在 IROM 的 `.rodata`，链接地址为 `0x00000120`。`strlen` 随后执行 `lbu` 从 `0x00000120` 取数。当前 SoC 是 Harvard 接口：IROM 只接取指端口，数据端口只定义 `0x80100000`—`0x8013FFFF` BRAM 和固定 MMIO；能力边界没有提供通过 LSU 读取 IROM 的路径。

仿真在第一次 `strlen` 后即进入失败分支：30 周期、14 条退休指令、0 次 BRAM load。这是程序依赖未提供的数据地址空间，归类为 CAPABILITY_BOUNDARY 并跳过，不修改 CPU 总线语义。

## 5. RTL 修正与回归结论

本次所有失败均已有测试错误或能力边界的直接证据；没有出现“测试有效且在能力边界内，但 RTL 结果错误”的情况。因此：

- 未修改 `rtl/`、SoC、外设桥或 testbench。
- 无需执行 RTL 修复后的二次回归。
- 有效覆盖中的 RV32I、RV32M、前递、load-use、控制冒险以及临时诊断的 Zicsr/trap 均通过。
- Zb t20—t27 未执行，因为能力边界明确说明 RV32B/Zb 尚未实现，且默认 `Makefile all` 有意排除这些训练测试。
