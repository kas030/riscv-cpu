# 当前 CPU 能力边界

> 状态日期：2026-07-15  
> 适用对象：本仓库当前 `mycpu` RTL、`student_top` SoC 连接及配套测试环境

## 1. 文档目的与判定口径

本文依据当前 RTL 实现，说明 CPU **能够保证的行为**和**不应假定存在的能力**。

本文以当前 RTL 为功能事实来源。这里的“支持”表示 RTL 中存在明确译码和数据通路；不等同于已通过完整 RISC-V Architecture Test、形式验证或全部非法编码测试。

## 2. 总体结论

| 能力项 | 当前状态 | 边界说明 |
| --- | --- | --- |
| RV32I 基础 37 条 | 支持 | 覆盖整数运算、跳转、分支和基本 load/store |
| `fence` | 未显式实现 | 标准编码通常表现为无有效副作用，但不提供内存屏障语义 |
| `ebreak` | 未实现 | 不进入断点异常；标准编码通常表现为无有效副作用 |
| `ecall` | 支持 | 仅实现 M 模式 Environment Call，`mcause=11` |
| Zicsr 六条指令 | 支持 | 仅对本文列出的最小 M 模式 CSR 提供有效语义 |
| `mret` | 支持 | 恢复 `mstatus.MIE/MPIE` 并跳转到 `mepc` |
| RV32M 八条指令 | 支持 | 包括除零和有符号除法溢出语义 |
| 特权级 | 仅 M 模式 | 无 U/S 模式，无权限切换和 CSR 权限检查 |
| 异常 | 仅 `ecall` | 无非法指令、断点、地址未对齐和访问故障异常 |
| 中断 | 不支持 | 无 `mie`、`mip` 等完整中断通路 |
| 流水线 | 双槽顺序发射 | 最多每拍发射/提交两条，控制流、CSR 和资源冲突时退化为单发射 |
| 板级时钟 | CPU 200 MHz，外设 50 MHz | PLL 输入为 200 MHz 差分时钟；200 MHz 是当前目标约束，仍须以实现后的时序报告判定是否收敛 |
| 数据存储 | 256 KiB BRAM + 固定 MMIO | 对外只有一组数据访问接口；无总线握手和访问故障反馈 |

结论：当前 CPU 覆盖 RV32I、RV32M、Zicsr 和最小 M-mode trap 功能，但不能描述为“完整实现 RV32IM 特权架构”。更准确的表述是：**RV32IM + 最小 Zicsr/M-mode trap 子集**。

## 3. 指令集边界

### 3.1 RV32I 基础 37 条

当前明确支持以下 37 条基础指令，不包含汇编伪指令：

| 类别 | 指令 | 数量 |
| --- | --- | ---: |
| 高位立即数 | `lui`、`auipc` | 2 |
| 跳转 | `jal`、`jalr` | 2 |
| 条件分支 | `beq`、`bne`、`blt`、`bge`、`bltu`、`bgeu` | 6 |
| Load | `lb`、`lh`、`lw`、`lbu`、`lhu` | 5 |
| Store | `sb`、`sh`、`sw` | 3 |
| 立即数运算 | `addi`、`slti`、`sltiu`、`xori`、`ori`、`andi`、`slli`、`srli`、`srai` | 9 |
| 寄存器运算 | `add`、`sub`、`sll`、`slt`、`sltu`、`xor`、`srl`、`sra`、`or`、`and` | 10 |
| 合计 |  | **37** |

基础整数行为边界：

- XLEN 固定为 32 位，通用寄存器为 `x0`—`x31`，`x0` 恒为 0。
- 加减法按 32 位自然回绕，不产生算术溢出异常。
- 移位量使用低 5 位。
- `jalr` 目标地址最低位会被清零。
- 不支持压缩指令，因此指令流应按 4 字节边界组织；配套测试使用 `.option norvc` 或 `-march=rv32im`。
- 对保留、非法 opcode 或非法 `funct` 组合没有统一的 illegal-instruction trap，软件不得依赖其执行结果。

### 3.2 其他基础 SYSTEM/同步指令

| 指令 | 当前行为 | 是否可作为正式能力使用 |
| --- | --- | --- |
| `fence` | 没有专用译码，也没有屏障或缓存同步动作 | 否 |
| `ebreak` | 没有专用译码，不写 `mepc/mcause`，不跳转 `mtvec` | 否 |
| `ecall` | 作为 M 模式同步异常进入 trap | 是 |

标准 `fence`、`ebreak` 编码的 `rd` 为 `x0`，在当前实现中通常近似空操作；但这不代表 CPU 实现了相应的架构语义。

### 3.3 RV32M

当前实现完整的 8 条 RV32M 指令：

- 乘法：`mul`、`mulh`、`mulhsu`、`mulhu`
- 除法/余数：`div`、`divu`、`rem`、`remu`

特殊情况按 RISC-V 语义处理：

- 除数为 0 时，`div/divu` 返回全 1，`rem/remu` 返回被除数。
- `0x80000000 / -1` 时，`div` 返回 `0x80000000`，`rem` 返回 0。

RV32M 单元是多周期资源：

- 普通 `mul` 等待 1 个执行周期。
- 三种高位乘法等待 2 个执行周期。
- 普通除法/余数使用 32 次迭代。
- 除零和有符号溢出走特殊快速路径。
- 同一双发射包最多包含一条 M 扩展指令；M 单元忙时前端和 ID/EX 保持。

延迟描述用于理解当前微架构，不构成固定软件时序接口。

### 3.4 未实现的其他扩展

当前 ALU/译码没有实现 RV32A、F、D、C、V、B 等扩展。仓库中的 Zb 训练文档和练习镜像用于扩展训练，不表示 Zb 指令已进入当前 CPU RTL。也未实现 `fence.i`、`wfi`、`sfence.vma` 等指令。

## 4. Zicsr 与 trap 边界

### 4.1 Zicsr 指令

支持全部 6 种基本 CSR 读改写形式：

| 寄存器源形式 | 立即数源形式 | 语义 |
| --- | --- | --- |
| `csrrw` | `csrrwi` | 写入新值并返回旧值 |
| `csrrs` | `csrrsi` | 按位设置并返回旧值；源为 0 时不写 |
| `csrrc` | `csrrci` | 按位清除并返回旧值；源为 0 时不写 |

汇编器提供的 `csrw`、`csrr` 等伪指令可展开为上述指令。CPU 不检查 CSR 特权级、只读属性或未实现 CSR 的非法访问。

### 4.2 已实现 CSR

| CSR | 地址 | 当前有效语义 |
| --- | ---: | --- |
| `mstatus` | `0x300` | 固定 `MPP=11`；实现 `MIE` bit 3 和 `MPIE` bit 7 的读写及 trap/mret 更新 |
| `mtvec` | `0x305` | 保存 trap 基地址；进入 trap 时强制目标低 2 位为 0，仅支持 Direct 行为 |
| `mscratch` | `0x340` | 32 位普通读写寄存器；属于当前实现额外提供的最小 CSR |
| `mepc` | `0x341` | 保存 `ecall` 自身 PC；CSR 写入时低 2 位清零 |
| `mcause` | `0x342` | `ecall` 进入时写入 11，也允许软件通过 CSR 指令读写 |

复位后 `mstatus=0x00001800`，其他已实现 CSR 为 0。访问未实现 CSR 时读回 0、写入被忽略，不触发异常。

### 4.3 `ecall`/`mret` 流程

CPU 只执行以下最小同步 trap 流程：

1. M 模式执行 `ecall`。
2. `mepc` 保存 `ecall` 指令地址，`mcause` 写为 11。
3. `mstatus.MPIE` 保存原 `MIE`，随后 `MIE` 清零，`MPP` 保持 `11`。
4. PC 跳转到 `{mtvec[31:2], 2'b00}`。
5. trap handler 可通过 CSR 指令读取和修改上述寄存器；若要跳过 `ecall`，软件应把 `mepc` 加 4。
6. 执行 `mret` 后，`MIE` 恢复为 `MPIE`，`MPIE` 置 1，PC 跳转到 `mepc`。

trap 能力明确不包括：

- U/S 模式 `ecall` 及不同来源的 `mcause` 编码；
- vectored `mtvec`；
- 外部、定时器或软件中断；
- `ebreak`、非法指令、取指/读写访问故障和地址未对齐异常；
- `mtval`、`medeleg`、`mie`、`mip` 等其他特权 CSR；
- 嵌套中断、委托、PMP、页表和虚拟内存。

因此，trap handler 应由 M 模式裸机程序提供，并只依赖本文列出的状态。

## 5. 微架构与执行边界

### 5.1 流水线和顺序性

逻辑模块仍按 `IF -> ID -> EX -> MEM -> WB` 组织，实际级间边界为：

```text
IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB
```

CPU 最多每拍顺序发射两条指令，第一槽先于第二槽提交。当前双发射约束为：

- 控制流和 CSR/SYSTEM 指令单发射。
- 同一包最多一条访存指令、最多一条 RV32M 指令。
- 第一槽结果若被第二槽读取，则该包不双发射。
- 两槽写同一非零寄存器时，第二槽是更年轻的指令，最终值覆盖第一槽。
- 取指提示表冷启动或 tag 未命中时保守单发射；双发射不是软件可依赖的确定行为。

流水线使用 valid、stall 和 flush 抑制气泡及错误路径副作用。冒险单元覆盖两槽消费者对 EX/MEM1 两槽 load 的依赖，前递优先级为 MEM1、MEM2、WB，同阶段第二槽优先于第一槽。

### 5.2 控制流预测

- `jal` 在 IF 阶段预测跳转。
- 条件分支使用 64 项、2 位饱和计数 BHT；未训练项使用 BTFNT（后向跳、前向不跳）。
- `jalr`、`ecall` 和 `mret` 在 EX 阶段解析。
- EX 比较实际方向/目标与预测元数据，错误时重定向并冲刷年轻指令。

分支预测只影响性能，不改变架构结果；本文不承诺固定 CPI。

## 6. 取指、数据存储与 MMIO

### 6.1 取指空间

- CPU 复位入口：`0x80000000`。
- SoC 使用 `pc[13:2]` 访问 4096×32 bit IROM，可用镜像容量为 16 KiB。
- 链接脚本把镜像链接到偏移 `0x00000000`，CPU 运行时从 `0x80000000` 取对应内容。
- IROM 高位地址被忽略，超出 16 KiB 会发生地址别名，不会触发取指访问故障。
- 对外有 `pc` 和 `pc+4` 两路只读取指口，用于双槽取指。

### 6.2 数据 BRAM

有效 BRAM 地址范围为 `0x80100000`—`0x8013FFFF`，共 256 KiB。支持：

- 任意字节 lane 的 `lb/lbu/sb`；
- 对齐半字的 `lh/lhu/sh`；
- 4 字节对齐的 `lw/sw`。

只对自然对齐访问保证标准结果。当前实现不会产生地址未对齐异常：半字奇地址不会跨半字拼接，字访问低两位也不会形成跨字访问，软件不得依赖这些非对齐结果。

BRAM 读取为同步时序，load 原始 32 位字经过 MEM1/MEM2 返回，在写回路径完成 byte/half 选择和符号扩展。CPU 内含 64 项直接映射的 L0 load 缓存：

- 只缓存 BRAM 的完整 32 位 load 字；
- 不缓存 MMIO；
- store 写穿到 BRAM，并使同一字地址的缓存行失效；
- 命中可缩短紧随 load 的依赖等待，未命中仍按同步 BRAM 路径返回。

L0 是内部性能结构，不提供软件可见的缓存控制或一致性指令，也不支持其他总线主设备修改 BRAM 后的硬件一致性。

### 6.3 MMIO 地址表

地址译码以 `rtl/bus/perip_bridge.sv` 为准：

| 地址 | 名称 | 读 | 写 | 说明 |
| --- | --- | --- | --- | --- |
| `0x80200000` | SW0 | 是 | 否 | 开关低 32 位 |
| `0x80200004` | SW1 | 是 | 否 | 开关高 32 位 |
| `0x80200010` | KEY | 是 | 否 | 低 8 位有效 |
| `0x80200020` | SEG | 是 | 是 | 数码管写数据回读 |
| `0x80200040` | LED | 否 | 是 | 32 位 LED 输出 |
| `0x80200050` | COUNTER | 是 | 是 | 计数值/控制命令 |
| `0x80200060` | UART_DATA | 是 | 是 | 串口数据：写=发送，读=接收并清除 RX_VALID |
| `0x80200064` | UART_STATUS | 是 | 是 | 串口状态：bit0=TX_BUSY，bit1=RX_VALID，bit2=PASSTHROUGH；写任意值=请求进入透传 |

COUNTER 写入 `0x80000000` 开始计数，写入 `0xFFFFFFFF` 停止计数。

UART 为 9600 8N1，经 `twin_controller` 透传协议接入板级串口：
RT-Thread 启动时主动写 UART_STATUS 请求透传（串口终端即连即用）；
也可发送 0xC9 进入透传、0xCA 退出；透传中 0x80 保留用于状态回读，
其余字节在透传态由 CPU 读写。竞赛裸机镜像不请求则 twin 保持 IDLE。
详见 `rt-thread/README.md` 与 `rtl/peripheral/uart_bridge.sv`。

MMIO 外设不统一处理 byte-enable，且仅在精确地址命中时有定义。软件应使用上述地址上的对齐 `lw/sw`；不要假定 `lb/lh/sb/sh`、LED 回读、未列出地址或地址别名具有标准外设语义。

### 6.4 外部访存接口限制

CPU 对外只有一组数据访问端口：`perip_addr`、`perip_wen`、`perip_mask`、`perip_wdata`、`perip_rdata`。接口没有 ready/valid、重试、错误响应或 burst 机制，依赖当前 SoC 中固定的同步 BRAM 和 MMIO 返回时序。替换存储器或桥接总线时，必须保持现有返回拍数，或在 CPU 外增加适配逻辑。

## 7. 软件可依赖与不可依赖的边界

裸机程序可以依赖：

- 32 位小端 RV32IM 基础执行语义；
- 本文列出的 5 个 CSR、6 条 Zicsr 指令、M 模式 `ecall/mret`；
- 16 KiB IROM 镜像、256 KiB BRAM 和固定 MMIO 地址；
- CPU 自身写 BRAM 后再读取同一地址时的 L0 失效处理；
- 双槽实现维持顺序可见的寄存器和存储副作用。

裸机程序不应依赖：

- 操作系统级特权功能、用户态隔离、虚拟内存、PMP 或中断；
- 非对齐或越界访存异常；
- 非法指令、`ebreak` 或总线错误进入 trap；
- `fence`/`fence.i` 的排序或指令同步效果；
- 未实现 CSR 的异常或保留位语义；
- 固定双发射率、固定 CPI、固定 load-use 气泡数或固定 RV32M 总周期数；
- IROM 超过 16 KiB、MMIO 子字访问、未映射地址返回值；
- Linux、标准 SBI 或需要完整 RISC-V privileged architecture 的运行环境。

## 8. 实现依据

- 指令译码：[`rtl/control/main_ctrl.sv`](../rtl/control/main_ctrl.sv)、[`rtl/control/alu_ctrl.sv`](../rtl/control/alu_ctrl.sv)
- CSR/trap：[`rtl/control/csr_ctrl_decode.sv`](../rtl/control/csr_ctrl_decode.sv)、[`rtl/control/csr_file.sv`](../rtl/control/csr_file.sv)
- RV32M：[`rtl/datapath/rv32m_unit.sv`](../rtl/datapath/rv32m_unit.sv)
- CPU 顶层与流水控制：[`rtl/core/mycpu.sv`](../rtl/core/mycpu.sv)
- 取指与预测：[`rtl/pipeline/stage/mycpu_if_stage.sv`](../rtl/pipeline/stage/mycpu_if_stage.sv)
- Load/store：[`rtl/memory/mycpu_lsu.sv`](../rtl/memory/mycpu_lsu.sv)、[`rtl/memory/bram_driver.sv`](../rtl/memory/bram_driver.sv)
- 地址映射：[`rtl/bus/perip_bridge.sv`](../rtl/bus/perip_bridge.sv)
- SoC 取指映射：[`rtl/soc/student_top.sv`](../rtl/soc/student_top.sv)
- 可信回归与测试计划：[`verification/`](../verification/README.md)、
  [`cpu_test_plan.md`](tests/cpu_test_plan.md)
