---
title-meta: RISC-V CPU 设计报告
cover: design-report-cover.pdf
---

# 项目概述

## 项目背景

本项目是全国大学生集成电路创新创业大赛“竞业达”企业命题的参赛设计。赛题要求在 FPGA 数字孪生平台上实现一款 RISC-V 处理器，正确执行 RV32I 指令和指定测试程序，并通过 LED、数码管和计时器显示运行结果。

处理器采用 32 位小端 RISC-V 架构，运行无操作系统的裸机程序。除了比赛要求的 RV32I 基础指令，当前 RTL 还支持 RV32M、项目测试所需的 Zicsr 指令和机器模式异常返回。设计时主要考虑流水线吞吐率、同步存储器时序与 FPGA 工作频率。

## 设计目标

设计目标如下：

1. 正确实现比赛要求的 37 条 RV32I 基础整数指令；
2. 支持 RV32M 全部 8 条乘除法指令，并处理除零和有符号除法溢出；
3. 支持最小 Zicsr/M-mode trap 子集，满足裸机异常入口和返回需求；
4. 在保持顺序提交的前提下，每拍最多发射和提交两条指令；
5. 通过前递、冒险检测、分支预测和小容量缓存降低流水线停顿；
6. 保持 CPU 顶层接口和 SoC 地址映射不变，使仿真模型与板级工程使用相同的接口时序。

## 设计平台

- FPGA 平台：竞业达 FPGA 数字孪生平台；
- 目标器件：Xilinx Kintex-7 XC7K325T-FFG900-2；
- 开发工具：AMD Vivado 2025.2.1；
- 硬件描述语言：SystemVerilog；
- RTL 仿真工具：Verilator 5.020、Vivado XSim 和 Icarus Verilog；
- 软件工具链：RISC-V GNU Toolchain GCC 13.2.0，目标为 `rv32im_zicsr/ilp32`；
- 板级时钟：200 MHz 差分输入，PLL 生成 240 MHz CPU 时钟和 50 MHz 外设时钟。

# RISC-V CPU 架构设计

## RV32I 指令集支持情况

设计已覆盖比赛基础考核涉及的 37 条 RV32I 指令。`fence` 和 `ebreak` 不属于这 37 条指令，`ecall` 则由机器模式 trap 通路处理。

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

Table: RV32I 基础指令支持范围

算术结果按 32 位回绕，移位量取低 5 位；`x0` 恒为零，`jalr` 目标地址的最低位清零。设计只保证自然对齐访存，暂不处理非法指令、未对齐访问和总线访问故障异常。

## SoC 层次与接口

系统以 `student_top` 为处理器子系统边界，由 CPU 核 `Core_cpu`、两路指令 ROM 和外设桥 `perip_bridge` 组成。CPU 时钟驱动处理器核和桥接逻辑，50 MHz 外设时钟单独送入 COUNTER。复位信号进入 CPU 核，并通过各级 valid 和副作用使能保证复位期间不会产生寄存器写、存储器写或 CSR 写。

![CPU SoC 总体结构](assets/cpu-soc-overview.png){ width=100% }

CPU 核对外提供两组独立的 32 位只读取指接口。第一路读取当前 PC 对应的指令，第二路读取 `PC+4` 对应的相邻指令；`student_top` 分别用 `pc[13:2]` 和 `(pc+4)[13:2]` 访问两路同步 IROM。高位 PC 在 IROM 寻址时被有意忽略，两路返回数据共同构成最多包含两条连续指令的取指包。

数据侧只有一组 32 位统一接口，包含地址、写数据、读数据、写使能和访问宽度控制。`perip_bridge` 依据地址将请求送往同步 BRAM 或 MMIO 外设；BRAM 读数据按流水时序返回，MMIO 读取使用独立的数据返回路径。当前地址映射如下。

| 访问目标 | 地址范围或地址 | 接口属性 |
| --- | --- | --- |
| BRAM | `0x8010_0000`--`0x8013_FFFF` | 256 KiB 数据存储器，支持 byte、half 和 word 访问 |
| SW0 | `0x8020_0000` | 低 32 位虚拟开关，只读 |
| SW1 | `0x8020_0004` | 高 32 位虚拟开关，只读 |
| KEY | `0x8020_0010` | 8 位虚拟按键，只读 |
| SEG | `0x8020_0020` | 40 位数码管输出寄存器 |
| LED | `0x8020_0040` | 32 位 LED 输出寄存器 |
| COUNTER | `0x8020_0050` | 50 MHz 跨时钟域性能计数器 |

Table: CPU 子系统地址映射

## CPU 核心微架构

CPU 采用双槽顺序发射、顺序提交结构。源码仍按 IF、ID、EX、MEM 和 WB 五类功能模块组织，但为适配同步 BRAM，访存后端被拆分为 MEM1 和 MEM2，因此实际流水边界为 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`。图中的上、下两条主数据通路分别对应槽 0 和槽 1：槽 0 保存包内较老指令，槽 1 保存较年轻指令。

![CPU 双槽流水微架构](assets/cpu-core-microarchitecture.png){ width=100% }

蓝色主通路表示取指、级间数据传递和寄存器写回，橙色通路表示共享 LSU、数据总线与 L0 cache 的访存路径，紫色通路表示 MEM1、MEM2、WB 到 EX 的前递网络，红色通路表示 stall、flush、busy 和重定向等控制反馈。数据与控制信号都随 valid 一起经过级间寄存器；复位、冲刷或气泡会清除有效性，并屏蔽错误路径上的所有体系结构副作用。

### IF：双路取指与分支预测

PC 是复位值为 `0x8000_0000` 的 32 位寄存器。IF 并行形成 `PC+4`、`PC+8` 和预测目标，并在 EX 重定向、预测跳转与顺序地址之间选择下一 PC。双发射时顺序前进 8 字节，单发射时前进 4 字节。

为避免把完整的配对判断放入 PC 反馈关键路径，前端维护 256 项直接映射双发射提示表。同步 IROM 返回两条指令后，硬件判断该取指位置是否适合形成双槽包并训练表项；冷启动、tag 未命中或预测跳转时先按单发射处理。条件分支使用 64 项 2 位饱和计数 BHT，未训练项采用 BTFNT；`jal` 在 IF 直接预测目标，`jalr`、异常入口和 `mret` 在 EX 解析。

### ID：译码、寄存器读取与发射控制

两个 ID 槽分别完成主控制译码、ALU/CSR 控制译码、立即数生成和寄存器索引提取。共享寄存器组包含 32 个 32 位通用寄存器，提供 4 个读端口和 2 个写端口，可同时为两个槽读取各自的 `rs1`、`rs2`，并在同一拍接收两路写回。对 `x0` 的写入被屏蔽，读取 `x0` 始终得到 0；WB 到 ID 的同周期旁路用于消除寄存器组读写同拍造成的数据陈旧。

槽 1 只有在包内不存在 RAW、WAW 相关且资源允许时才有效。控制流、CSR、双访存和双 RV32M 等不能安全并行的组合退化为单发射，因此控制流重定向和 CSR 状态更新集中在较老的槽 0。该限制使两槽无需乱序调度或重排序缓冲区，仍可按程序顺序向后推进。

### EX：整数执行、多周期运算与重定向

两个 EX 槽均包含 RV32I ALU 和 RV32M 运算通路。ALU 使用 22 位独热控制码，低 14 位选择 RV32I 的算术、逻辑、移位和比较操作，高 8 位选择 RV32M 操作。Load/store 地址由独立的 `rs1+imm` 加法通路形成，以缩短通用 ALU 和访存地址计算的组合路径；分支比较也单独产生结果。

RV32M 单元启动时锁存操作数与类型。普通 `mul` 等待一个周期，高位乘法等待两个周期，普通除法和余数进行 32 次迭代；任一槽 busy 时，前端与 ID/EX 保持，避免尚未完成的多周期指令被覆盖。完成结果与普通 ALU 结果一样进入后端，可被后续指令前递。

槽 0 还包含 CSR 文件与统一重定向逻辑。CSR 文件实现 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`；`ecall` 保存异常 PC 并写入 `mcause=11` 后跳转到 `mtvec`，`mret` 恢复相关状态并跳转到 `mepc`。EX 将分支实际方向和目标与预测元数据比较，只有不一致时才把正确 PC 反馈到 IF，并冲刷 IF/ID 与 ID/EX。

### MEM1/MEM2：共享访存端口与 L0 cache

CPU 数据侧只有一个端口，因此同一发射包最多包含一条 load/store。MEM1 从两个槽中选择有效访存请求，通过共享 LSU 输出地址、写数据和访问宽度；LSU 按小端字节序生成 `sb`、`sh`、`sw` 所需的写数据与 byte mask。MEM2 将同步 BRAM 返回的完整 32 位原始字与相应流水元数据对齐，byte/half lane 选择及符号或零扩展留到写回路径完成。

64 项直接映射 L0 load cache 只保存 BRAM 的完整 32 位数据字，不缓存 MMIO。Load 在 EX 提前探测缓存；命中时，数据可在下一拍由 MEM1 送入前递网络，使紧随其后的相关指令更早取得操作数。未命中时，冒险控制等待 BRAM 数据沿 MEM2 后端返回。Store 对 BRAM 写穿，并使同一字地址对应的 L0 cache 行失效，因而不需要维护脏数据。

### 冒险控制与前递网络

冒险单元同时检查两个消费者槽对 ID/EX 和 EX/MEM1 中两槽 load 的依赖，并结合 L0 命中状态产生 stall、bubble 与 flush。普通 ALU 相关不必停顿，而由两个 EX 槽各自的前递选择器解决。候选值来自 MEM1、MEM2 和 WB，阶段优先级为 MEM1 高于 MEM2、高于 WB；同一阶段若存在多个有效生产者，则较年轻的槽 1 优先，从而选择程序顺序上最新的值。

控制流误预测的重定向优先于普通前端推进，并使错误路径指令失效；RV32M busy 则保持前端和 ID/EX。valid、stall、flush 与 busy 共同构成统一的流水控制，使停顿时不丢失在途指令、冲刷时不保留错误副作用。

### WB：写回选择与顺序提交

两个 WB 槽分别通过写回多路器选择 `PC+4`、ALU/RV32M 结果、load 扩展结果、U 型立即数或 CSR 旧值，再写入寄存器组的两个写端口。若两槽同拍有效，槽 0 先于槽 1 按程序顺序提交。图中的 In-order Commit 表示写回顺序约束，并不额外增加流水级。

## 主要数据通路选择

| 指令类型 | ALU 输入 A | ALU 输入 B | 运算或地址路径 | 下一 PC | 写回数据 |
| --- | --- | --- | --- | --- | --- |
| R 型 | `rs1` | `rs2` | ALU | `pc+4/pc+8` | ALU 结果 |
| I 型算术 | `rs1` | I 型立即数 | ALU | `pc+4/pc+8` | ALU 结果 |
| Load | `rs1` | I 型立即数 | LSU 地址加法器 | `pc+4/pc+8` | Load 扩展结果 |
| Store | `rs1` | S 型立即数 | LSU 地址加法器 | `pc+4/pc+8` | 无 |
| Branch | `rs1` | `rs2` | 分支比较器 | 预测地址或 EX 重定向 | 无 |
| `jal` | PC | J 型立即数 | 跳转目标加法 | 预测目标 | `pc+4` |
| `jalr` | `rs1` | I 型立即数 | ALU 加法并清除 bit 0 | EX 重定向 | `pc+4` |
| `lui` | 0 | U 型立即数 | 立即数直通 | `pc+4/pc+8` | U 型立即数 |
| `auipc` | PC | U 型立即数 | ALU 加法 | `pc+4/pc+8` | ALU 结果 |

Table: RV32I 各类指令的数据通路选择

写回多路器根据 `MemToReg` 选择数据：`000` 对应 `pc+4`，`001` 对应 ALU/RV32M 结果，`010` 对应 load 数据，`011` 对应 U 型立即数，`100` 对应 CSR 旧值。两个槽共用这套编码。

## 控制器与流水控制

### 控制信号表

| 指令类型 | `NpcOp` | `RegWrite` | `MemToReg` | `MemRead` | `MemWrite` | `ALUSrcA` | `ALUSrcB` |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: |
| R 型/RV32M | `00` | 1 | `001` | 0 | 0 | 0 | 0 |
| I 型算术 | `00` | 1 | `001` | 0 | 0 | 0 | 1 |
| Load | `00` | 1 | `010` | 1 | 0 | 0 | 1 |
| Store | `00` | 0 | `000` | 0 | 1 | 0 | 1 |
| Branch | `01` | 0 | `000` | 0 | 0 | 0 | 0 |
| `jal` | `11` | 1 | `000` | 0 | 0 | 0 | 1 |
| `jalr` | `10` | 1 | `000` | 0 | 0 | 0 | 1 |
| `lui` | `00` | 1 | `011` | 0 | 0 | 0 | 1 |
| `auipc` | `00` | 1 | `001` | 0 | 0 | 1 | 1 |
| Zicsr | `00` | 1 | `100` | 0 | 0 | 0 | 1 |
| `ecall/mret` | `10` | 0 | `000` | 0 | 0 | 0 | 1 |

Table: 各类指令的主要控制信号

`NpcOp=00/01/10/11` 依次表示顺序执行、条件分支、绝对目标类重定向和 `jal`。`OffsetOrigin` 区分普通立即数、`jalr` 的 ALU 结果与 CSR trap 目标。控制信号和 valid 随级间寄存器向后传递，不跨级直接驱动后端副作用。

### 分层译码与控制传递

控制器采用分层译码。`main_ctrl` 生成寄存器写、访存、写回和下一 PC 控制；`imm_gen` 生成 I/S/B/U/J 五类立即数；`alu_ctrl` 根据 `opcode`、`funct3` 和 `funct7` 产生 22 位独热运算码；`csr_ctrl_decode` 识别六种 Zicsr 指令以及 `ecall`、`mret`。`mycpu_decoder` 将这些子模块封装为单槽译码器，两个 ID 槽各实例化一套。

双发射判定会检查 slot0 到 slot1 的 RAW 依赖，以及双访存和双 RV32M 冲突；WAW 不会阻止双发射，同一拍写入同一 `rd` 时，第二槽结果覆盖第一槽。控制流、CSR、双访存及双 RV32M 组合均按单发射执行。EX 级把实际分支结果与预测元数据进行比较；方向或目标不一致时重定向 PC，并冲刷 IF/ID 和 ID/EX，预测正确时则让流水线继续执行。

执行 `ecall` 时，处理器保存异常 PC，写入 `mcause=11`，随后跳转到 `mtvec`；执行 `mret` 时，处理器恢复 `mstatus.MIE/MPIE` 并跳转到 `mepc`。目前尚未实现非法指令、未对齐访问、中断、U/S 模式和完整的 CSR 权限检查。
译码结果不会跨级直接驱动后端副作用，而是与 PC、寄存器索引、预测元数据和 valid 一起逐级寄存。ID 发射控制先关闭不满足配对条件的槽 1；冒险控制再根据在途指令决定保持或插入气泡；EX 重定向则使错误路径失效。当前异常体系只覆盖项目测试所需的机器模式最小子集，尚未实现非法指令、未对齐访问、总线故障、中断、U/S 模式和完整 CSR 权限检查。

# CPU 性能优化设计

## 优化项一

第一项优化是双槽顺序发射和访存后端流水化。顺序流水线增加了第二个译码、执行和写回槽。两槽不存在相关或资源冲突时可以同拍推进；无法安全配对时，硬件自动改为单发射。整个过程不需要软件使用专用指令，两槽的提交顺序也没有改变。

同步 BRAM 无法在一个组合 MEM 阶段内完成请求、返回和扩展，因此访存后端分为 MEM1 和 MEM2。MEM1 发出请求，MEM2 接收返回数据，WB 最后处理子字节选择和符号扩展。前递网络覆盖 MEM1、MEM2 与 WB，load-use 检测也会按照数据真正可用的阶段插入停顿。

混合性能微基准共退休 22,273 条指令，运行 21,299 个周期，CPI 为 0.956，平均 IPC 超过 1。在这项负载中，双槽结构利用了程序中的指令级并行性，提高了吞吐率。

## 优化项二

第二项优化集中在控制流、load 相关和关键路径上。条件分支使用 64 项 2 位饱和计数 BHT，尚未训练的分支按 BTFNT 预测。`jal` 在 IF 级预测跳转，只有方向或目标出错时，EX 才会冲刷流水线。64 项 L0 load 缓存在 EX 级提前查询，命中数据可从 MEM1 前递，从而减少紧随 load 的相关停顿。

为适应 240 MHz 的工程配置，IF 同时计算 `pc+4` 和 `pc+8`，并把双发射合法性写入提示表；分支比较结果由 ALU 单独输出，load/store 使用独立的地址加法器，高位乘法增加结果寄存，load 的 lane 选择和扩展则移到 WB。这样可以把 PC 反馈、分支判断、访存返回与乘法结果分散到不同的组合路径中。

综合程序共发出 110,606,978 次 BRAM load，其中 69,677,186 次命中 L0，命中率为 62.995%。Store 采用写穿策略，并在写入时使对应缓存行失效，因此不需要维护脏数据。

## 性能结果汇总

| 测试项目 | 周期数 | 退休指令数 | CPI | 其他结果 |
| --- | ---: | ---: | ---: | --- |
| 混合性能微基准 | 21,299 | 22,273 | 0.956 | IPC 大于 1 |
| 综合矩阵程序 | 404,056,765 | 380,344,360 | 1.062 | L0 命中率 62.995% |

Table: CPU 性能结果摘要

表中的周期、退休指令、CPI、L0 命中率和 COUNTER 均来自 CPU-only 仿真。COUNTER 是 50 MHz 计时器模型的读数，不能直接等同于 FPGA 板级执行时间。

# CPU 特色功能设计

## 特色功能一

第一项特色功能是完整的 RV32M 扩展。RV32M 单元支持 `mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem` 和 `remu`。普通 `mul` 需要一个等待周期，三种高位乘法需要两个等待周期，普通除法与余数运算迭代 32 次。除数为零时，除法返回全 1，余数返回被除数；只有有符号 `div/rem` 会对 `INT_MIN/-1` 启用溢出快速路径。

RV32M 单元与普通 ALU 相互独立。操作数在启动时锁存；busy 期间，前端和 ID/EX 保持不动。运算完成后，结果沿现有的 MEM1、MEM2、WB 及前递通路继续传递。该单元已通过 8 项定向测试和 8 项 RV32UM 开源参考测试。

## 特色功能二

第二项特色功能是 Zicsr 和机器模式异常返回。CSR 控制器支持 `csrrw/csrrwi`、`csrrs/csrrsi` 与 `csrrc/csrrci`，并实现了 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`。软件可先设置 `mtvec`，再通过 `ecall` 进入处理程序；处理程序读取 `mcause` 和 `mepc`、修改返回地址，最后执行 `mret` 返回。

这部分只覆盖项目测试需要的最小机器模式子集，不含中断、PMP、虚拟内存、U/S 模式，也不是完整的特权异常体系。Zicsr 定向测试检查了寄存器源、立即数源、读改写语义和完整的 `ecall/mret` 流程，结果均符合预期。

# 附录

## 代码清单

| 文件或目录 | 主要用途 |
| --- | --- |
| `rtl/core/mycpu.sv` | CPU 顶层，连接双槽流水线、前递、冒险、CSR、L0 和访存接口 |
| `rtl/pipeline/stage/` | IF、ID、EX、MEM1 和 WB 组合逻辑 |
| `rtl/pipeline/register/` | 五组流水级间寄存器 |
| `rtl/control/` | 主译码、ALU/CSR 控制、立即数和重定向控制 |
| `rtl/datapath/` | ALU、PC、寄存器组和 RV32M 单元 |
| `rtl/hazard/` | 双槽 load-use 冒险检测和多级前递 |
| `rtl/memory/` | LSU、load mask、BRAM 驱动和 L0 load 缓存 |
| `rtl/bus/perip_bridge.sv` | BRAM/MMIO 地址译码和板级访存时序 |
| `rtl/soc/student_top.sv` | CPU、双路 IROM 和外设桥连接 |
| `sim_cpu_only/` | Verilator/Icarus CPU-only 仿真环境 |
| `tb/` | Vivado CPU、板级和 UART testbench |
| `verification/` | CPU-only 测试入口、镜像和回归工具 |
| `vivado/tests/` | 分层汇编测试、链接脚本和镜像生成工具 |

Table: 关键源码与验证文件

## 工程目录结构

```text
riscv-cpu-remote/
├── rtl/
│   ├── core/              CPU 核心顶层
│   ├── pipeline/          流水级与级间寄存器
│   ├── control/           指令译码与控制
│   ├── datapath/          ALU、寄存器组和 RV32M
│   ├── hazard/            冒险检测与前递
│   ├── memory/            LSU、BRAM 与 L0 缓存
│   ├── bus/               外设桥和地址译码
│   ├── soc/               SoC 连接层
│   └── top/               FPGA 板级顶层
├── sim_cpu_only/          CPU-only 仿真环境
├── verification/          CPU 测试和回归工具
├── tb/                    Vivado testbench
├── vivado/tests/          汇编测试与镜像工具
├── ip/                    IROM、BRAM 和 PLL 配置
├── constraints/           板级约束
├── scripts/               Vivado 自动化脚本
└── docs/                  设计报告与测评报告
```

## 参考资料

1. RISC-V International. *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*.
2. RISC-V International. *The RISC-V Instruction Set Manual, Volume II: Privileged Architecture*.
3. AMD. *Vivado Design Suite User Guide: Synthesis (UG901)*.
4. IEEE. *IEEE Standard for SystemVerilog, IEEE Std 1800-2017*.

## AI 工具声明

本文使用 AI 工具对文档部分内容进行润色。RTL、测试程序、实验数据及技术结论均由我们核对。
