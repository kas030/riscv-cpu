---
title-meta: RISC-V CPU 技术文档
cover: assets/cover.pdf
---

# 项目概述

## 项目背景

本项目面向 FPGA 上的 32 位小端 RISC-V 处理器系统，软件运行环境为 RT-Thread Nano。系统通过 finsh/msh 提供命令行，并在操作系统中运行官方 EEMBC CoreMark；CPU 也支持裸机程序和既有 SoC 接口。

当前 RTL 实现了 RV32I、RV32M、项目测试所需的 Zicsr 指令和机器模式异常返回；另有一条只服务于特定软件循环的 CRC 融合路径。设计围绕双槽顺序流水、同步存储器时序、数据相关处理、操作系统运行时和固定 FPGA 接口展开。

主办方 COE 镜像和 `irom-v2` 属于兼容性资料，用于说明既有地址映射和裸机接口；本文的运行时和性能描述以 RT-Thread/CoreMark 为主。

## 作品核心内容快速预览

本作品在固定 CPU 顶层接口和 SoC 地址映射下，实现了一款面向 FPGA 的 32 位 RISC-V 处理器。核心采用双槽顺序发射与顺序提交，实际流水边界为 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`；前端使用带 tag 的双发射提示表和 BHT/BTB，后端使用多级前递、load-use 冒险控制、RV32M 多周期执行和 BRAM 专用 L0 load cache。系统软件由 RT-Thread Nano、finsh/msh 和官方 CoreMark 组成，旧竞赛镜像列入兼容性资料。

- **指令与异常支持：**  
  核心内容：37 条 RV32I 基础指令、RV32M 全部 8 条指令，以及项目所需的 Zicsr、`ecall` 和 `mret`。  
  正文索引：RV32I 指令集支持情况（第 \pageref{sec-rv32i-support} 页）、RV32M 多周期运算（第 \pageref{sec-rv32m-design} 页）、Zicsr 与机器模式异常返回（第 \pageref{sec-zicsr-trap} 页）。
- **流水线组织：**  
  核心内容：双槽顺序发射、顺序提交，槽 0 先于槽 1 提交；访存后端分为 MEM1/MEM2。  
  正文索引：CPU 核心微架构（第 \pageref{sec-core-microarchitecture} 页）、双槽顺序发射与流水化访存（第 \pageref{sec-dual-issue-memory} 页）。
- **性能优化：**  
  核心内容：64 项带 tag 的 BHT/BTB、256 项双发射提示表、多级前递、64 项直接映射 L0 load cache 和 4 项完整字 store bypass。  
  正文索引：动态分支预测（第 \pageref{sec-branch-prediction} 页）、L0 load cache（第 \pageref{sec-l0-cache-design} 页）、面向时序收敛的性能优化（第 \pageref{sec-timing-optimization} 页）。
- **存储与接口：**  
  核心内容：共享双口 IROM 总容量 64 KiB，可信测试镜像限制为 16 KiB；数据侧只有一个端口，支持 BRAM、UART/FPU MMIO 和 byte/half/word 小端访问。  
  正文索引：SoC 层次与接口（第 \pageref{sec-soc-interface} 页）、共享访存端口与 L0 cache（第 \pageref{sec-mem-l0-microarchitecture} 页）、perip_bridge（第 \pageref{sec-perip-bridge} 页）。
- **功能验证：**  
  核心内容：`verification/` 的 6 组本地定向测试和 `riscv-tests` 的 45 项白名单结果均按历史快照记录，不能直接作为当前 RTL 的通过结论。  
  正文索引：测试体系（第 \pageref{sec-test-system} 页）、功能验证（第 \pageref{sec-functional-verification} 页）、功能测试汇总（第 \pageref{sec-functional-summary} 页）。
- **运行时与性能基准：**  
  核心内容：RT-Thread Nano 3.1.5、finsh/msh、UART 自动透传和官方 EEMBC CoreMark 1.0；MMIO FPU 只负责 CoreMark 停止计时后的换算，不属于 RV32F。  
  正文索引：RT-Thread 运行时（第 \pageref{sec-rtthread-runtime} 页）、官方 CoreMark（第 \pageref{sec-coremark} 页）、官方 CoreMark 性能记录（第 \pageref{sec-coremark-performance} 页）。
- **验证范围：**  
  核心内容：RT-Thread 启动、UART 控制台、finsh/msh 和 CoreMark 是主要验收对象；CPU 基础回归与旧竞赛镜像作为辅助证据单列。  
  正文索引：测试体系（第 \pageref{sec-test-system} 页）、功能测试汇总（第 \pageref{sec-functional-summary} 页）、旧竞赛镜像兼容性记录（第 \pageref{sec-irom-v2-performance} 页）。

## 设计目标

设计目标如下：

1. 保留比赛要求的 37 条 RV32I 基础整数指令，作为操作系统和裸机程序的整数基础；
2. 支持 RV32M 全部 8 条乘除法指令，并处理除零和有符号除法溢出；
3. 支持最小 Zicsr/M-mode trap 子集，满足 RT-Thread 启动、异常入口和返回需求；
4. 在顺序提交的前提下，每拍最多发射和提交两条指令；
5. 用前递、冒险检测、分支预测和小容量缓存减少操作系统和基准程序的流水线停顿；
6. 保持 CPU 顶层接口和 SoC 地址映射不变，使 CPU-only 仿真和板级工程使用相同的接口时序；
7. 完成 RT-Thread Nano 3.1.5 移植，提供 tick、上下文切换、UART 控制台和 finsh/msh；
8. 在 RT-Thread 环境中运行官方 CoreMark，并明确区分功能结果、性能结果和历史兼容性数据。

## 设计平台

- FPGA 平台：竞业达 FPGA 数字孪生平台；
- 目标器件：Xilinx Kintex-7 XC7K325T-FFG900-2；
- 开发工具：AMD Vivado 2025.2.1；
- 硬件描述语言：SystemVerilog；
- RTL 仿真工具：Verilator 5.020；CPU-only 仿真使用独立的 IROM、BRAM、MMIO、UART 和 FPU 行为/RTL 模型；
- 软件工具链：`verification/` 使用 RISC-V GNU Toolchain GCC 13.2.0，目标为 `rv32im_zicsr/ilp32`；RT-Thread 固件记录使用 Vivado 2025.2.1 附带的 GCC 13.4.0；
- 板级时钟：200 MHz 差分输入，PLL 生成 200 MHz CPU 时钟和 50 MHz 外设时钟；
- 当前状态：本次环境缺少 RISC-V 交叉工具链，未能重跑 `verification/` 或 RT-Thread 镜像；Vivado 综合、实现、时序和板级实验未执行。

# RISC-V CPU 架构设计

## RV32I 指令集支持情况 {#sec-rv32i-support}

设计覆盖比赛基础考核涉及的 37 条 RV32I 指令。`fence` 和 `ebreak` 不在这 37 条指令内，`ecall` 由机器模式 trap 通路处理。

\begin{longtable}{@{}p{2.2cm}p{10.5cm}r@{}}
\caption{RV32I 基础指令支持范围}\\
\toprule
类别 & 指令 & 数量 \\
\midrule
\endfirsthead
\toprule
类别 & 指令 & 数量 \\
\midrule
\endhead
\bottomrule
\endlastfoot
高位立即数 & \mbox{\texttt{lui}、\texttt{auipc}} & 2 \\
跳转 & \mbox{\texttt{jal}、\texttt{jalr}} & 2 \\
条件分支 & \mbox{\texttt{beq}、\texttt{bne}、\texttt{blt}、\texttt{bge}、\texttt{bltu}、\texttt{bgeu}} & 6 \\
Load & \mbox{\texttt{lb}、\texttt{lh}、\texttt{lw}、\texttt{lbu}、\texttt{lhu}} & 5 \\
Store & \mbox{\texttt{sb}、\texttt{sh}、\texttt{sw}} & 3 \\
立即数运算 & \mbox{\texttt{addi}、\texttt{slti}、\texttt{sltiu}、\texttt{xori}、\texttt{ori}、\texttt{andi}、\texttt{slli}、\texttt{srli}、\texttt{srai}} & 9 \\
寄存器运算 & \mbox{\texttt{add}、\texttt{sub}、\texttt{sll}、\texttt{slt}、\texttt{sltu}、\texttt{xor}、\texttt{srl}、\texttt{sra}、\texttt{or}、\texttt{and}} & 10 \\
合计 & & \textbf{37} \\
\end{longtable}

算术结果按 32 位回绕，移位量取低 5 位，且 `x0` 恒为零，`jalr` 目标地址的最低位清零。设计只保证自然对齐访存，暂不处理非法指令、未对齐访问和总线访问故障异常。

## SoC 层次与接口 {#sec-soc-interface}

系统以 `student_top` 为处理器子系统边界，由 CPU 核 `Core_cpu`、共享双口 IROM 和外设桥 `perip_bridge` 组成。CPU 和桥运行在 200 MHz，COUNTER、UART 与 twin controller 运行在 50 MHz。复位信号进入 CPU 核和桥接逻辑，各模块按自身时钟域同步处理；valid、控制使能和 kill 共同屏蔽复位期间的寄存器写、存储器写或 CSR 写。

![CPU SoC 总体结构](assets/cpu-soc-overview.png){ width=100% }

CPU 核对外提供两路独立的 32 位只读取指接口，分别读取当前 PC 和 `PC+4` 对应的指令；两路接口连接同一片双口 IROM。`student_top` 使用 `pc[15:2]` 和 `(pc+4)[15:2]` 访问两个同步端口，地址宽度为 14 位，对应 `16384 × 32 bit = 64 KiB` 物理容量。可信测试工具通过 `--max-words 4096` 将测试镜像限制为 16 KiB，这只是测试输入限制，不是 IROM 硬件容量。

数据侧只有一组 32 位统一接口，包含地址、写数据、读数据、写使能和访问宽度控制。`perip_bridge` 依据地址将请求送往同步 BRAM 或 MMIO 外设，其中 BRAM 读数据按流水时序返回，MMIO 读取使用独立路径。当前地址映射如下。

\begin{longtable}{@{}p{2.4cm}p{5.0cm}p{6.8cm}@{}}
\caption{CPU 子系统地址映射}\\
\toprule
访问目标 & 地址范围或地址 & 接口属性 \\
\midrule
\endfirsthead
\toprule
访问目标 & 地址范围或地址 & 接口属性 \\
\midrule
\endhead
\bottomrule
\endlastfoot
BRAM & \mbox{\texttt{0x8010\_0000}--\texttt{0x8013\_FFFF}} & 256 KiB 数据存储器，支持 byte、half 和 word 访问 \\
SW0 & \texttt{0x8020\_0000} & 低 32 位虚拟开关，只读 \\
SW1 & \texttt{0x8020\_0004} & 高 32 位虚拟开关，只读 \\
KEY & \texttt{0x8020\_0010} & 8 位虚拟按键，只读 \\
SEG & \texttt{0x8020\_0020} & 40 位数码管输出寄存器，可回读写数据 \\
LED & \texttt{0x8020\_0040} & 32 位 LED 输出寄存器，只写 \\
COUNTER & \texttt{0x8020\_0050} & 50 MHz 跨时钟域性能计数器；写起停命令 \\
\texttt{UART\_DATA} & \texttt{0x8020\_0060} & 写入发送字节，读取接收字节并请求清除 RX valid \\
\texttt{UART\_STATUS} & \texttt{0x8020\_0064} & bit0/1/2 为 TX\_BUSY/RX\_VALID/PASSTHROUGH；写入请求透传 \\
FPU MMIO & \texttt{0x8020\_0070}--\texttt{0x8020\_0080} & CoreMark 换算用有限 binary32 协处理器，不代表 RV32F \\
\end{longtable}

`perip_bridge` 的 COUNTER 写入 `0x8000_0000` 开始计数，写入 `0xFFFF_FFFF` 停止计数。UART 通过 `uart_bridge` 在 CPU 200 MHz 域和 UART 50 MHz 域之间完成握手；FPU 通过 MMIO 接收 A、B、CMD，并提供 STATUS/RESULT，不进入 CPU 的整数执行通路。CPU 对外接口没有 ready/valid、重试或错误响应，必须保持现有 BRAM/MMIO 返回时序。

FPU 的五个寄存器为 `0x8020_0070`（A）、`0x8020_0074`（B）、`0x8020_0078`（CMD）、`0x8020_007C`（STATUS）和 `0x8020_0080`（RESULT）。CMD=1 完成 `u32 -> binary32`，CMD=2 完成有限正规数的 binary32 除法。两种运算只服务 CoreMark 停止计时后的秒数和迭代率换算，不把浮点运算加入 CoreMark 主循环。

## CPU 核心微架构 {#sec-core-microarchitecture}

CPU 采用双槽顺序发射、顺序提交结构。源码仍按 IF、ID、EX、MEM 和 WB 五类功能模块组织；为适配同步 BRAM，访存后端拆为 MEM1 和 MEM2，实际流水边界为 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`。图中的上、下两条主数据通路分别对应槽 0 和槽 1：槽 0 保存包内较老的指令，槽 1 保存较新的指令。

\clearpage

\begin{figure}[htbp]
\centering
\includegraphics[width=\linewidth]{assets/cpu-core-microarchitecture.png}
\caption{CPU 双槽流水微架构}
\end{figure}

蓝色主通路表示取指、级间数据传递和寄存器写回，橙色通路表示共享 LSU、数据总线与 L0 cache 的访存路径，紫色通路表示 MEM1、MEM2 到 EX 的前递网络，红色通路表示 stall、flush、busy 和重定向等控制反馈。`ID/EX` 使用 `EX_pipe_valid` 和 `EX_S1_pipe_valid` 标记两槽有效性；其他流水边界主要通过有效控制信号与 kill 屏蔽副作用。复位、冲刷或气泡不会产生寄存器写、存储器写或 CSR 写。

### 双路取指与分支预测（IF）

PC 是复位值为 `0x8000_0000` 的 32 位寄存器。IF 并行形成 `PC+4`、`PC+8` 和预测目标，并在 EX 重定向、预测目标与顺序地址之间选择下一 PC。双发射时顺序前进 8 字节，单发射时前进 4 字节；Stall 时重新请求当前 PC 和相邻字地址，保持同步 IROM 返回与流水线对齐。

为避免把完整的配对判断放入 PC 反馈关键路径，前端维护 256 项直接映射双发射提示表。表索引为 `IF_pc[9:2]`，tag 为 `IF_pc[15:8]`；同步 IROM 返回的候选包先完成保守判断，训练请求延迟一拍写入提示表。tag 未命中、预测跳转或资源冲突时先按单发射处理。

分支预测器由 64 项 BHT 和 64 项 BTB 组成，索引为 `pc[7:2]`，tag 为 `pc[15:8]`。BTB 保存 valid、tag、目标地址和 `is_jal`；只有 tag 命中时才产生预测，BTB 未命中直接预测不跳。条件分支首次训练按实际方向写入 `00` 或 `10`，后续使用 2 位饱和计数器更新；`jal` 也依赖 BTB 命中，`jalr`、`ecall` 和 `mret` 在 EX 解析。

### 译码、寄存器读取与发射控制（ID）

两个 ID 槽分别完成主控制译码、ALU/CSR 控制译码、立即数生成和寄存器索引提取。共享寄存器组包含 32 个 32 位通用寄存器，提供 4 个读端口和 2 个写端口，可同时为两个槽读取各自的 `rs1`、`rs2`，并在同一拍接受两路写回。对 `x0` 的写入被屏蔽，读取 `x0` 始终得到 0；WB 到 ID 的同周期旁路消除寄存器组读写同拍造成的数据陈旧。

槽 1 只有在包内不存在 RAW 相关且资源允许时才有效。候选配对必须同时满足可配对指令类别、无双访存、无双 RV32M 以及槽 0 的 `rd` 不被槽 1 使用。WAW 不阻止双发射；同一拍同一非零 `rd` 时，写口按槽 0 后槽 1 的顺序更新，槽 1 的较新值最终可见。控制流、CSR/SYSTEM 和资源冲突组合退化为单发射。

### 整数执行、多周期运算与重定向（EX）

两个 EX 槽均包含 RV32I ALU 和 RV32M 运算通路。ALU 使用 24 位独热控制码：低 14 位选择 RV32I 算术、逻辑、移位和比较，`[21:14]` 选择 RV32M，bit 22 当前未用，bit 23 保留给项目专用 CRC 融合运算。Load/store 地址由独立的 `rs1+imm` 加法通路形成，分支比较也单独产生结果。

RV32M 单元启动时锁存操作数和类型。普通 `mul` 等待一个周期，高位乘法等待两个周期，普通除法和余数运算进行 32 次迭代。任一槽 busy 时，前端和 ID/EX 保持不动，避免覆盖尚未完成的多周期指令。除零和仅 `DIV/REM` 的 `INT_MIN/-1` 有符号溢出走快速路径；`DIVU/REMU` 的相同位型不走该路径。完成结果进入统一后递与前递网络。

槽 0 还包含 CSR 文件和重定向逻辑。CSR 文件实现 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`。`ecall` 保存异常 PC，写入 `mcause=11`，再跳转到 `mtvec`；`mret` 恢复相关状态并跳转到 `mepc`。EX 先产生 raw redirect，顶层再写入 `redirect_valid_q` 和目标寄存器，随后重定向 IF、冲刷 IF/ID 与 ID/EX，并清除错误路径的后端控制。

### 共享访存端口与 L0 cache（MEM1/MEM2） {#sec-mem-l0-microarchitecture}

CPU 数据侧只有一个端口，因此同一发射包最多包含一条 load/store。MEM1 在槽 0 有访存时优先选择槽 0；槽 0 无访存而槽 1 有访存时选择槽 1。BRAM load 请求强制读取完整 32 位原始字，MEM2 与流水元数据对齐返回，WB 再按地址低位和 `funct3` 选择 byte/half/word 并完成符号或零扩展。store 的小端写数据和 byte mask 由 LSU/BRAM driver 形成。

64 项直接映射 L0 load cache 只保存 BRAM 的完整 32 位数据字，不缓存 MMIO。索引使用地址 `addr[7:2]`，tag 使用 `addr[17:8]`；fill 地址和数据先经顶层寄存后写入缓存。Load 在 EX 提前探测，命中时可在下一拍由 MEM1 前递；未命中时沿同步 BRAM 路径返回。Store 写穿 BRAM 并失效同一字地址的缓存行，fill 与同拍 store 冲突时失效优先。顶层另有 4 项完整字 store bypass，向后续 load 提供最新的完整字；byte/half store 会失效对应 bypass 项。

### 冒险控制与前递网络

冒险单元同时检查两个消费者槽对 ID/EX 和 EX/MEM1 中两槽 load 的依赖，并结合 LoadReady 判断 L0 命中数据能否及时前递。普通 ALU 相关不必停顿。ID 阶段预先计算前递选择码并与消费者一起寄存，`forwarding_unit` 在 EX 只完成数据多路选择；候选包括 EX/MEM1、MEM2、消费者本地 late 操作数和 late `lw` 原始字，WB 同周期数据由寄存器堆读旁路处理。MEM2 的 late subword miss 还会由 `Stall_LateSubword` 追加停顿。

控制流误预测的重定向优先于普通前端推进，并使错误路径失效；RV32M busy、load-use、late subword 和前端 Stall 分别保持流水线或插入气泡。它们一起保证停顿时不丢失在途指令，冲刷时不留下错误副作用。

### 写回选择与顺序提交（WB）

两个 WB 槽分别通过写回多路器选择 `PC+4`、ALU/RV32M 结果、load 扩展结果、U 型立即数或 CSR 旧值，再写入寄存器组的两个写端口。若两槽同拍有效，槽 0 先于槽 1 按程序顺序提交。图中的 In-order Commit 表示写回顺序约束，并不额外增加流水级。

## 主要数据通路选择

| 指令类型 | ALU 输入 A | ALU 输入 B | 运算或地址路径       |
| -------- | ---------- | ---------- | -------------------- |
| R 型     | `rs1`      | `rs2`      | ALU                  |
| I 型算术 | `rs1`      | I 型立即数 | ALU                  |
| Load     | `rs1`      | I 型立即数 | LSU 地址加法器       |
| Store    | `rs1`      | S 型立即数 | LSU 地址加法器       |
| Branch   | `rs1`      | `rs2`      | 分支比较器           |
| `jal`    | PC         | J 型立即数 | 跳转目标加法         |
| `jalr`   | `rs1`      | I 型立即数 | ALU 加法并清除 bit 0 |
| `lui`    | 0          | U 型立即数 | 立即数直通           |
| `auipc`  | PC         | U 型立即数 | ALU 加法             |

Table: RV32I 各类指令的执行数据通路选择

| 指令类型 | 下一 PC              | 写回数据      |
| -------- | -------------------- | ------------- |
| R 型     | `pc+4/pc+8`          | ALU 结果      |
| I 型算术 | `pc+4/pc+8`          | ALU 结果      |
| Load     | `pc+4/pc+8`          | Load 扩展结果 |
| Store    | `pc+4/pc+8`          | 无            |
| Branch   | 预测地址或 EX 重定向 | 无            |
| `jal`    | 预测目标             | `pc+4`        |
| `jalr`   | EX 重定向            | `pc+4`        |
| `lui`    | `pc+4/pc+8`          | U 型立即数    |
| `auipc`  | `pc+4/pc+8`          | ALU 结果      |

Table: RV32I 各类指令的下一 PC 与写回数据选择

写回多路器根据 `MemToReg` 选择数据：`000` 对应 `pc+4`，`001` 对应 ALU/RV32M 结果，`010` 对应 load 数据，`011` 对应 U 型立即数，`100` 对应 CSR 旧值。两个槽共用这套编码。

## 控制器与流水控制

### 控制信号表

| 指令类型     | `NpcOp` | `RegWrite` | `MemToReg` |
| ------------ | ------- | ---------: | ---------- |
| R 型/RV32M   | `00`    |          1 | `001`      |
| I 型算术     | `00`    |          1 | `001`      |
| Load         | `00`    |          1 | `010`      |
| Store        | `00`    |          0 | `000`      |
| Branch       | `01`    |          0 | `000`      |
| `jal`        | `11`    |          1 | `000`      |
| `jalr`       | `10`    |          1 | `000`      |
| `lui`        | `00`    |          1 | `011`      |
| `auipc`      | `00`    |          1 | `001`      |
| Zicsr        | `00`    |          1 | `100`      |
| `ecall/mret` | `10`    |          0 | `000`      |

Table: 控制流与写回控制信号

| 指令类型     | `MemRead` | `MemWrite` | `ALUSrcA` | `ALUSrcB` |
| ------------ | --------: | ---------: | --------: | --------: |
| R 型/RV32M   |         0 |          0 |         0 |         0 |
| I 型算术     |         0 |          0 |         0 |         1 |
| Load         |         1 |          0 |         0 |         1 |
| Store        |         0 |          1 |         0 |         1 |
| Branch       |         0 |          0 |         0 |         0 |
| `jal`        |         0 |          0 |         0 |         1 |
| `jalr`       |         0 |          0 |         0 |         1 |
| `lui`        |         0 |          0 |         0 |         1 |
| `auipc`      |         0 |          0 |         1 |         1 |
| Zicsr        |         0 |          0 |         0 |         1 |
| `ecall/mret` |         0 |          0 |         0 |         1 |

Table: 访存与 ALU 输入控制信号

`NpcOp=00/01/10/11` 依次表示顺序执行、条件分支、绝对目标类重定向和 `jal`。`OffsetOrigin` 区分普通立即数、`jalr` 的 ALU 结果与 CSR trap 目标。控制信号和 valid 随级间寄存器向后传递，不跨级直接驱动后端副作用。

### 分层译码与控制传递

控制器采用分层译码。`main_ctrl` 生成寄存器写、访存、写回和下一 PC 控制；`imm_gen` 生成 I/S/B/U/J 五类立即数；`alu_ctrl` 根据 `opcode`、`funct3` 和 `funct7` 产生 24 位独热运算码，其中 bit `[13:0]` 用于 RV32I/分支运算，`[21:14]` 用于 RV32M，bit 22 未用，bit 23 保留给项目专用 CRC 融合；`csr_ctrl_decode` 识别六种 Zicsr 指令以及 `ecall`、`mret`。`mycpu_decoder` 把这些子模块封装成单槽译码器，两个 ID 槽各实例化一套。

双发射判定检查 slot0 到 slot1 的 RAW 依赖，以及双访存和双 RV32M 冲突。WAW 不会阻止双发射；同一拍写入同一非零 `rd` 时，第二槽按顺序写回并覆盖第一槽结果。控制流、CSR、双访存及双 RV32M 组合均按单发射执行。EX 级比较实际分支结果与预测元数据；方向或目标不一致时产生 raw redirect，顶层打一拍保存后重定向 PC，并冲刷 IF/ID 和 ID/EX。预测正确时，流水线继续执行。

执行 `ecall` 时，处理器保存异常 PC，写入 `mcause=11`，随后跳转到 `mtvec`；执行 `mret` 时，处理器恢复 `mstatus.MIE/MPIE` 并跳转到 `mepc`。

译码结果与 PC、寄存器索引、预测元数据和 valid 一起逐级寄存，不直接跨级驱动后端副作用。ID 发射控制先关闭不满足配对条件的槽 1，冒险控制再根据在途指令决定保持或插入气泡，EX 重定向则使错误路径失效。当前异常体系只覆盖项目测试所需的机器模式最小子集，尚未实现非法指令、未对齐访问、总线故障、中断、U/S 模式和完整 CSR 权限检查。


# RTL 关键模块设计

## 模块选取原则
本章只展开能直接说明处理器组织、双槽流水控制、数据相关处理、存储优化和 SoC 边界的模块。级间寄存器、小型译码子模块和显示扫描逻辑不单独展开；UART、FPU 与板级连接放在 SoC 数据访问边界及附录中说明。

## CPU 核心与流水级

### mycpu
功能：CPU 核心顶层，连接双路取指、双槽流水数据通路、寄存器堆、冒险与前递网络、RV32M、CSR、分支重定向、共享 LSU、L0 load cache 和 store bypass。模块维持槽 0 先于槽 1 提交，并用有效控制、stall、flush 和 kill 屏蔽气泡与错误路径的副作用。

接口：

| 端口名                    | 类型   | 描述                     |
| ------------------------- | ------ | ------------------------ |
| `cpu_clk`, `cpu_rst`      | input  | CPU 主时钟与高有效复位   |
| `irom_addr`, `irom_addr1` | output | 两路 32 位取指地址       |
| `irom_data`, `irom_data1` | input  | 两路 32 位 IROM 指令数据 |
| `perip_addr`              | output | 32 位 BRAM/MMIO 统一地址 |
| `perip_wen`, `perip_mask` | output | 写使能与 2 位访问宽度    |
| `perip_wdata`             | output | 32 位写数据              |
| `perip_rdata`             | input  | 32 位读返回              |

Table: mycpu 接口描述

### `mycpu_if_stage`
功能：IF 级维护 PC，输出当前 PC 和相邻字地址，并在顺序地址、BTB 预测目标和 EX 重定向目标之间选择下一 PC。内部 256 项双发射提示表把候选包判断移出 PC 反馈关键路径；Stall 时重新请求当前包，提示表训练请求延迟一拍写入。

接口：

| 端口名                              | 类型   | 描述                     |
| ----------------------------------- | ------ | ------------------------ |
| `irom_data`, `irom_data1`           | input  | 两路同步 IROM 返回指令   |
| `IF_npc_redirect`                   | input  | 32 位 EX 重定向目标      |
| `clk`, `rst`                        | input  | 时钟与高有效复位         |
| `Stall`, `BranchRedirect`            | input  | 前端冻结与重定向有效     |
| `BP_update_en`, `BP_update_taken`   | input  | 预测更新使能与实际方向   |
| `BP_update_pc`                      | input  | 已解析分支 PC            |
| `BP_update_target`, `BP_update_is_jal` | input | BTB 目标与 JAL 标志   |
| `irom_addr`, `irom_addr1`           | output | 两路 32 位取指地址       |
| `IF_pc`                             | output | 32 位当前 PC             |
| `IF_instr`, `IF_instr1`             | output | 取指包中的两条指令       |
| `IF_issue_dual`                     | output | 双发射提示               |
| `IF_pred_taken`, `IF_pred_target`   | output | 预测方向与 32 位目标     |

Table: mycpu_if_stage 接口描述

### mycpu_id_stage
功能：ID 级单槽译码外壳，内部通过统一译码器完成寄存器字段提取、主控制译码、立即数生成、24 位 ALU 独热译码以及 CSR/SYSTEM 指令译码。核心对两个指令槽各实例化一份，并在顶层完成包内相关和资源冲突检查。

接口描述：

| 端口名                    | 类型   | 描述                |
| ------------------------- | ------ | ------------------- |
| ID_instr                  | input  | 32 位 ID 指令       |
| ID_imm                    | output | 32 位扩展立即数     |
| ID_RegWrite               | output | 寄存器写使能        |
| ID_MemWrite, ID_MemRead   | output | store/load 控制     |
| ID_ALUSrcA, ID_ALUSrcB    | output | ALU 输入来源        |
| ID_MemToReg               | output | 3 位写回来源        |
| ID_NpcOp, ID_OffsetOrigin | output | 两组 2 位控制流控制  |
| ID_ALUControl             | output | 24 位运算独热码     |
| ID_csr_idx, ID_csr_zimm   | output | CSR 地址与立即数    |
| ID_CSRControll            | output | 6 位 CSR/SYSTEM 控制 |
| ID_rs1, ID_rs2, ID_rd     | output | 三组 5 位寄存器索引  |

Table: mycpu_id_stage 接口描述

### mycpu_ex_stage
功能：EX 级使用已选前递数据完成 RV32I 运算、load/store 地址生成、RV32M 多周期执行、CSR 读改写和控制流解析。RV32M 执行期间通过 `EX_busy` 保持前端与 ID/EX，`EX_kill` 用于禁止错误路径启动多周期运算、写 CSR或产生重定向。

接口：

| 端口名                        | 类型   | 描述                  |
| ----------------------------- | ------ | --------------------- |
| EX_pc, EX_imm                 | input  | 32 位 PC 与立即数     |
| EX_rR1_data, EX_rR2_data      | input  | 两个 32 位原始操作数  |
| EX_ALUControl                 | input  | 24 位运算控制         |
| EX_NpcOp, EX_OffsetOrigin     | input  | 控制流与目标来源控制  |
| EX_csr_idx, EX_csr_zimm       | input  | CSR 地址与 5 位立即数 |
| EX_CSRControll                | input  | 6 位 CSR/SYSTEM 控制  |
| ForwardAData, ForwardBData    | input  | 两个 32 位已选前递值  |
| EX_ALUSrcA, EX_ALUSrcB        | input  | ALU 输入来源选择      |
| EX_pred_taken, EX_pred_target | input  | 预测方向与目标        |
| EX_stall, EX_kill             | input  | 多周期保持与失效屏蔽  |
| IF_npc_redirect_raw           | output | 32 位组合重定向目标   |
| EX_alu_result                 | output | 32 位 ALU/RV32M 结果  |
| EX_mem_addr                   | output | 32 位访存地址         |
| EX_forward_B_out              | output | 32 位前递后 rs2       |
| EX_csr_wb                     | output | 32 位 CSR 旧值        |
| BranchTaken, BranchMispredict | output | 实际转移与误预测标志  |
| EX_busy                       | output | RV32M 未完成标志      |

Table: mycpu_ex_stage 接口描述

## 执行与多周期运算

### alu
功能：EX 级 32 位算术逻辑单元。`ALUControl[13:0]` 选择加减、逻辑、移位和比较；`ALUControl[23]` 选择项目专用 CRC 融合结果。加法、减法及比较共享加减法器，分支判断通过 `isTrue` 独立输出，避免控制流路径再次汇总完整结果。

接口：

| 端口名     | 类型   | 描述                            |
| ---------- | ------ | ------------------------------- |
| A, B       | input  | 两个 32 位操作数                |
| ALUControl | input  | 24 位独热码                     |
| Result     | output | 32 位运算结果                   |
| isTrue     | output | 分支条件布尔结果                |

Table: alu 接口描述

### rv32m_unit
功能：实现 `mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem` 和 `remu`。普通乘法等待 1 个周期，高位乘法等待 2 个周期，正常除法和余数运算执行 32 次迭代；除零及有符号除法溢出使用快速特殊结果路径。

接口：

| 端口名               | 类型   | 描述                     |
| -------------------- | ------ | ------------------------ |
| clk, rst             | input  | 时钟与高有效同步复位     |
| start                | input  | 运算启动脉冲             |
| alu_control          | input  | 24 位独热码，使用 `[21:14]` |
| operand_a, operand_b | input  | 两个 32 位操作数         |
| busy                 | output | 正在执行标志             |
| done                 | output | 结果完成脉冲             |
| result               | output | 32 位结果                |

Table: rv32m_unit 接口描述

### 项目专用 CRC 融合

`mycpu_if_stage` 根据连续机器码签名识别竞赛/定向测试中的 CRC 软件循环，把其中的字节更新序列替换为保留 R 型编码的内部运算。`alu_ctrl` 用 bit 23 产生 `OP_CRC8` 控制，`alu` 对 `A[15:0] ^ B[15:0]` 执行 8 次右移与 `16'ha001` 异或，结果零扩展为 32 位。该路径不改变对外的 RV32I/RV32M 能力声明，也不是标准 `CRC8` 或 Zb 指令。

## 冒险、前递与存储优化

### forwarding_unit
功能：EX 级前递数据选择器，核心对两个消费者槽各实例化一份。ID 阶段先根据源寄存器和在途生产者计算选择码，并与消费者一起寄存；本模块在 EX 只完成数据多路选择。候选包括 EX/MEM1、MEM2、消费者本地 late 操作数和 late `lw` 原始字，WB 同周期数据由寄存器堆读旁路处理。

接口：

| 端口名                         | 类型   | 描述                         |
| ------------------------------ | ------ | ---------------------------- |
| ID_EX_data1, ID_EX_data2      | input  | 两个 32 位寄存器原始值       |
| EX_MEM_data0, EX_MEM_data1    | input  | MEM1 两槽候选数据            |
| MEM2_data0, MEM2_data1        | input  | MEM2 两槽候选数据            |
| LATE_data1, LATE_data2        | input  | 消费者本地 late 操作数       |
| LATE_load_word                | input  | late `lw` 原始 32 位字       |
| ForwardA_sel, ForwardB_sel    | input  | 两组 3 位选择码               |
| ForwardAData, ForwardBData    | output | 两个 32 位最终操作数          |

Table: forwarding_unit 接口描述

### hazard_unit
功能：同时检查 IF/ID 两个消费者槽对 ID/EX 和 EX/MEM1 两个 load 生产者槽的依赖，并结合 `LoadReady` 判断 L0 命中数据能否及时前递。数据未就绪时冻结前端并向 ID/EX 注入气泡；误预测时冲刷 IF/ID 与 ID/EX。MEM2 的 late subword miss 由顶层 `Stall_LateSubword` 追加处理。

接口：

| 端口名                               | 类型   | 描述                       |
| ------------------------------------ | ------ | -------------------------- |
| IF_ID_rs1/rs2, IF_ID_rs1_1/rs2_1     | input  | 两槽源寄存器索引           |
| IF_ID_uses_rs1/rs2(_1)               | input  | 两槽源字段有效性           |
| IF_ID_valid_1                        | input  | 槽 1 有效                  |
| ID_EX_rd/rd_1, EX_MEM_rd/rd_1        | input  | 两级两槽 load 目的寄存器   |
| ID_EX_MemRead/MemRead_1              | input  | ID/EX load 标志            |
| ID_EX_LoadReady/LoadReady_1          | input  | ID/EX 数据可前递            |
| EX_MEM_MemRead/MemRead_1             | input  | MEM1 load 标志              |
| EX_MEM_LoadReady/LoadReady_1         | input  | MEM1 数据已就绪             |
| BranchMispredict                     | input  | 误预测状态                 |
| Stall, Flush_IF_ID, Flush_ID_EX      | output | 停顿与两级冲刷             |
| LoadUseEX, LoadUseMEM                | output | 两类 load-use 统计         |

Table: hazard_unit 接口描述

### load_l0_cache {#sec-load-l0-cache-module}
功能：64 项直接映射的 BRAM load 结果缓存，保存完整 32 位字。`lookup` 服务 MEM1，`probe0/probe1` 为两个 EX 提前探测端口，BRAM 返回数据通过 fill 端口写入。Store 仍写穿到 BRAM，并使同一字地址的缓存行失效；MMIO 不进入缓存。

接口：

| 端口名                  | 类型   | 描述                    |
| ----------------------- | ------ | ----------------------- |
| clk, rst                | input  | 时钟与高有效复位        |
| lookup_addr             | input  | 32 位 MEM1 查询地址     |
| lookup_hit, lookup_data | output | 命中及 32 位查询数据    |
| probe_addr0/addr1       | input  | 两个 32 位 EX 探测地址  |
| probe_hit0/hit1         | output | 两个命中标志             |
| probe_data0/data1       | output | 两个 32 位探测数据      |
| fill_en                 | input  | 填充使能                |
| fill_addr, fill_data    | input  | 32 位填充地址与数据     |
| store_en, store_addr    | input  | store 失效使能与地址    |

Table: load_l0_cache 接口描述

## SoC 数据访问边界

### perip_bridge {#sec-perip-bridge}
功能：CPU 单一数据端口的地址译码与返回时序模块。它把 `0x8010_0000--0x8013_FFFF` 映射到 BRAM，并映射 SW0、SW1、KEY、SEG、LED、COUNTER、UART 和 FPU MMIO。BRAM 按同步读时序返回，MMIO 使用独立的数据选择路径。

接口：

| 端口名                         | 类型   | 描述                              |
| ------------------------------ | ------ | --------------------------------- |
| clk, cnt_clk                   | input  | CPU 总线时钟与 50 MHz 外设时钟    |
| rst                            | input  | 高有效复位                        |
| perip_addr, perip_wdata        | input  | 32 位 CPU 地址与写数据            |
| perip_wen, perip_mask           | input  | 写使能与 2 位访问宽度             |
| perip_rdata                    | output | 32 位 BRAM/MMIO 返回              |
| virtual_sw_input               | input  | 64 位虚拟开关                     |
| virtual_key_input              | input  | 8 位虚拟按键                      |
| virtual_seg_output              | output | 40 位数码管状态                   |
| virtual_led_output              | output | 32 位 LED 状态                    |
| UART 数据/状态端口              | mixed  | 连接 `uart_bridge` 的收发与透传信号 |


Table: perip_bridge 接口描述

`UART_DATA` 和 `UART_STATUS` 的具体位语义见 SoC 地址表。`fpu_mmio` 只提供 CoreMark 换算所需的有限 binary32 操作，不代表处理器实现了 RV32F 指令集。

# CPU 特色功能设计

## 双槽顺序发射与流水化访存 {#sec-dual-issue-memory}

IF 级使用 256 项直接映射双发射提示表，索引为 `IF_pc[9:2]`，tag 为 `IF_pc[15:8]`。IROM 扩展到 64 KiB 后，tag 覆盖 `pc[15:8]`，避免相差 16 KiB 的代码区域共享同一提示表项。同步 IROM 返回后，硬件完成可配对类别、槽内 RAW、双访存和双 RV32M 判断；训练请求延迟一拍写入提示表。tag 未命中或预测跳转时先按单发射处理，命中后直接在 `PC+4` 与 `PC+8` 之间选择，避免把完整候选译码串入 PC 反馈路径。

槽 0 始终对应程序顺序中较老的指令，槽 1 对应较新的指令。配对成功时 PC 前进 8 字节，两条指令并行经过 ID、EX、MEM1、MEM2 和 WB；配对失败时只发射槽 0。控制流、CSR/SYSTEM、双访存和双 RV32M 组合均按单发射处理，避免两个槽竞争不可复制的资源。同拍写入同一非零目的寄存器时，槽 0 写口先更新，槽 1 的较新值最终可见。


![双发射提示表结构](diagrams/xml/export/diht-5x.png){ width=88% }

上图给出了双发射提示表的地址划分和表项内容。valid 位表示记录可用，tag 区分 64 KiB IROM 中不同的代码区域，val 位保存该取指包是否允许双发射。提示表只影响吞吐率，不改变指令语义。

同步 BRAM 的请求和返回分为 MEM1、MEM2 两级。MEM1 在两个槽之间仲裁唯一的数据端口，MEM2 接收与流水元数据对齐的返回值，WB 再完成 lane 选择和符号扩展。前递选择码在 ID 阶段预先形成，候选数据由 EX/MEM1、MEM2 和消费者本地 late 通路提供；load 数据尚未返回时，load-use 与 late subword 控制插入停顿。槽 0/槽 1 的有效控制、stall、flush 和 busy 共同阻止错误路径产生寄存器写入或存储副作用。

## 动态分支预测 {#sec-branch-prediction}

条件分支使用 64 项 BHT，配套 64 项 BTB 保存目标地址。BHT/BTB 索引为 `pc[7:2]`，tag 为 `pc[15:8]`；BTB 每项保存 valid、tag、target 和 `is_jal`。只有 tag 命中时才产生预测，BTB 未命中直接预测不跳。`jal` 也依赖 BTB 命中，`jalr`、异常入口和 `mret` 在 EX 级解析。

条件分支第一次由 EX 更新时，taken 写入 `2'b10`，not-taken 写入 `2'b00`；已训练项使用 2 位饱和计数器，状态 `00/01` 预测不跳转，`10/11` 预测跳转。预测方向、目标和更新元数据随指令进入流水线。EX 发现实际方向或目标与预测不一致时产生 raw redirect，顶层将其打一拍保存到 `redirect_valid_q`/目标寄存器，再重定向 IF 并冲刷年轻指令。当前实现没有 BTFNT 冷启动回退。

![BHT 表项与索引结构](diagrams/xml/export/bht-5x.png){ width=88% }

图中 64 项索引结构应与 BTB 的 tag/target 一起理解：BHT 提供条件方向，BTB 提供命中资格和目标地址；预测错误只影响流水性能，不改变架构结果。

## L0 load cache {#sec-l0-cache-design}

L0 cache 用于缩短连续 load 相关的等待时间。缓存包含 64 个直接映射表项，每项保存 BRAM 的完整 32 位字、tag 和 valid 位；地址 `addr[7:2]` 选择表项，`addr[17:8]` 用于 tag 比较。byte/half 的 lane 选择与符号扩展在缓存外完成，因此不同宽度访问可以共享同一缓存字。缓存范围仅限 `0x8010_0000--0x8013_FFFF`，MMIO 访问始终绕过缓存。

![L0 load cache 表项与索引结构](diagrams/xml/export/l0_cache-5x.png){ width=88% }

模块提供 MEM1 lookup 和两个 EX probe 组合查询端口。EX 使用已寄存基址和立即数提前探测，命中数据可在下一拍由 MEM1 前递；未命中时沿 MEM1 发请求、MEM2 接收数据、WB 扩展的普通 BRAM 通路执行。BRAM 返回的 fill 地址和数据先经顶层寄存后写入缓存。若基址需要前递、发生 tag 冲突、同拍存在更老的同地址 store，或访问落在 MMIO 区域，则回退到普通时序。

Store 采用写穿策略，数据始终写入 BRAM，同时失效同一字地址的缓存行；若 fill 与 store 同拍命中同一字，失效具有最终优先级。顶层另有 4 项完整字 store bypass，向后续 load 提供最新的完整字；byte/half store 会失效相应 bypass 项。该策略无需维护脏位，也不改变软件可见地址空间。

## RV32M 多周期运算 {#sec-rv32m-design}

RV32M 单元支持 `mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem` 和 `remu`。普通 `mul` 等待一个周期，三种高位乘法等待两个周期，普通除法与余数运算迭代 32 次。除数为零时，除法返回全 1、余数返回被除数；只有有符号 `div/rem` 对 `INT_MIN/-1` 启用溢出快速路径。

四条乘法指令共用 32×32 位乘法通路。`mul` 取乘积低 32 位，`mulh`、`mulhsu` 和 `mulhu` 分别按有符号×有符号、有符号×无符号和无符号×无符号方式计算并取高 32 位。高位乘法结果增加一级寄存，以切断乘法器和符号修正形成的长组合路径，同时保持普通 `mul` 的等待周期不变。

除法采用逐位移位、比较和减法的迭代结构。有符号运算先记录商和余数的符号并对操作数取绝对值，完成 32 次迭代后再恢复符号；余数符号始终与被除数一致。除零和 `INT_MIN/-1` 在启动阶段直接识别并走快速返回路径，避免进入无意义的 32 周期迭代。

操作数和运算类型在启动时锁存，busy 期间前端与 ID/EX 保持，防止多周期运算被后续指令覆盖。单元完成后产生 done，结果沿 MEM1、MEM2、WB 和统一前递网络继续传递，紧随其后的相关指令可以取得最新结果。双发射判定不允许两条 RV32M 指令同拍占用该资源，因此不需要在单元内部增加多请求仲裁。

## Zicsr 与机器模式异常返回 {#sec-zicsr-trap}

CSR 控制器支持 `csrrw/csrrwi`、`csrrs/csrrsi` 与 `csrrc/csrrci`，并实现 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`。软件可设置 `mtvec`，通过 `ecall` 进入处理程序，再读取异常原因、调整返回地址并执行 `mret` 返回。

六条 CSR 指令都先读取 CSR 旧值并将其送入写回通路。`csrrw/csrrwi` 使用寄存器值或 5 位立即数直接覆盖 CSR；`csrrs/csrrsi` 对指定位置位；`csrrc/csrrci` 对指定位清零。当置位或清零指令的源操作数为 0 时，只读取旧值而不修改 CSR。未实现的 CSR 读取得到 0，写入被忽略，满足本项目裸机测试的使用范围。

执行 `ecall` 时，硬件把当前 PC 保存到 `mepc`，将 `mcause` 写为 11，并跳转到按字对齐的 `mtvec`。进入处理程序时，`mstatus.MPIE` 保存原 `MIE`，随后关闭 `MIE`；执行 `mret` 时再由 `MPIE` 恢复 `MIE`，并跳转到 `mepc`。软件可以在处理程序中把 `mepc` 加 4，以跳过触发异常的 `ecall` 后返回原程序。

CSR 指令、`ecall` 和 `mret` 均按单发射处理，CSR 写、异常重定向和返回操作还受流水 valid 与 kill 信号约束，错误路径不会产生架构副作用。这部分只覆盖项目测试需要的最小机器模式子集，不含中断、PMP、虚拟内存、U/S 模式、非法指令异常和完整 CSR 权限检查，因此不等同于完整的 RISC-V 特权架构实现。



## 面向时序收敛的性能优化 {#sec-timing-optimization}

当前工程围绕 200 MHz 目标配置缩短 PC 反馈、前递选择、访存地址和 flush 控制路径。优化重点是在保持流水行为不变的前提下减少组合深度和控制扇出：

- 在 EX/MEM1 边界提前形成 `MEM_forward_data`，统一保存 L0 命中值、CSR 旧值、立即数、PC+4 和 ALU/RV32M 结果；
- ID 阶段预先生成前递选择码，EX 中的 `forwarding_unit` 只执行数据 mux；
- ID/EX 使用 `EX_pipe_valid`，flush 主要清除有效性，后端由有效控制统一屏蔽副作用；
- 对槽 1 的控制流和 CSR 控制固定为不可达常量，允许综合器裁剪相关逻辑；
- IF 并行预计算 `PC+4`/`PC+8`，用 dual-hint 表保存保守的包内配对判断。

这些结构性优化不等于已达到某个实现频率。当前环境未执行 Vivado 综合、布局布线和时序分析，不能据此给出 WNS、Fmax 或资源结论。

# 实验环境与方法

## 仿真环境

RTL 仿真采用 Verilator 5.020，可信测试程序由 RISC-V GNU 工具链构建。编译目标为 `rv32im_zicsr/ilp32`，禁用压缩指令和链接松弛，并由 `validate_elf.py` 审计镜像容量、地址和反汇编指令。该工具会忽略 GNU `objdump` 将链接填充的零半字显示为 `c.unimp` 的情况；CPU-only testbench 提供两路同步 IROM 行为模型、同步 BRAM、byte-enable、固定 MMIO、UART/FPU 模型和独立 50 MHz 计时器模型。

| 项目              | 实验配置                                      |
| ----------------- | --------------------------------------------- |
| 仿真器            | Verilator 5.020                               |
| RISC-V GNU 工具链 | `verification/` 使用 GCC 13.2.0；RT-Thread 固件记录使用 GCC 13.4.0；本次环境未安装交叉编译器 |
| ISA/ABI           | rv32im_zicsr/ilp32                            |
| CPU-only 时钟     | 默认 200 MHz，周期 5 ns                       |
| 外设与计时器时钟  | 50 MHz                                        |
| 物理 IROM 容量    | 64 KiB；可信测试镜像上限 16 KiB               |
| 数据存储容量      | 256 KiB BRAM                                  |
| 处理器复位地址    | 0x80000000                                    |

Table: RTL 仿真实验配置

CPU-only 的 `CPU_FREQ_MHZ` 是 testbench 用于产生时钟和换算 MIPS 的参数，不等于 Vivado 实现后的 Fmax。严格 CPI 使用 `tb_cpu_only.sv` 的两槽退休有效信号；不使用板级 testbench 的近似指令计数。

## 测试体系 {#sec-test-system}

测试体系包括两类内容：`verification/` 的定向测试检查 CPU 基础功能，`rt-thread/` 的 CPU-only 入口检查操作系统启动、UART 控制台和 CoreMark。`irom-v2` 作为旧 SoC 接口和裸机兼容性资料单列。

- CPU 基础测试包括 `rv32i`、`rv32m`、`zicsr_trap`、`pipeline`、`memory` 和 `perf_micro`；其中前五项主要验证功能，`perf_micro` 观察双发射、停顿和 L0 统计。
- 现有 CPU 基础测试证据来自 `verification/build/local-results.json`（2026-07-31）和 `verification/build/riscv-tests/results.json`（2026-07-24），早于 RTL 基线 `b519bfb4d21de13a7286ab305b552fd786666c65`，因此按历史快照记录。
- RT-Thread/CoreMark 的源码、构建入口和运行日志位于 `rt-thread/` 与 `sim_cpu_only/`，运行结果单独记录。

开源白名单只覆盖 RV32I/RV32M，不等同于完整 RISC-V 架构认证。ACT4 和 Embench-IoT 虽锁定上游版本，但尚未完成适配、容量审计和启用，不产生本文通过率或性能数据。

所有功能用例采用自检方式，程序把失败编号、实际值和期望值写入签名区，并通过 LED 给出明确结束状态。性能指标只有在功能自检通过后才用于性能表。

## RT-Thread 运行时与 finsh/msh {#sec-rtthread-runtime}

`rt-thread/` 集成 RT-Thread Nano 3.1.5 和 `bsp/mycpu` 板级移植，并启用 finsh/msh 命令行。内核源码来自上游 `v3.1.5`。由于当前平台没有中断，idle hook 轮询 `0x8020_0050` 的 50 MHz COUNTER，按毫秒调用 `rt_tick_increase`，单次最多追赶 64 ms；上下文切换使用 `csrw mepc` 与 `mret`。

链接脚本把 `.text` 放入 `0x8000_0000`--`0x8000_FFFF` 的 64 KiB IROM，把 `.rodata`、`.data` 和 `.bss` 放入 `0x8010_0000`--`0x8013_FFFF` 的 256 KiB BRAM，堆从 `__bss_end` 延伸到 BRAM 顶部。演示线程默认延时 3000 ms，然后向 LED 写入 `0xC0DEC0DE` 并永久休眠。

RT-Thread 控制台通过 `UART_DATA`/`UART_STATUS` 访问 9600 8N1 UART，同时把最近字符写入 SEG。启动时 BSP 写 `UART_STATUS` 请求透传并轮询 bit2，串口终端连接后进入 `msh >`；`0xC9`/`0xCA` 保留给上位机进入或退出透传。finsh 读不到输入时返回 `0xFF` 并延时 1 ms，让 idle hook 继续运行。

## 官方 EEMBC CoreMark 1.0 {#sec-coremark}

CoreMark 算法源和 MD5 清单来自 EEMBC 官方仓库，平台适配只负责计时、参数和输出。`msh >coremark` 默认使用种子 `0,0,0x66`、2000 字节数据和 5000 次迭代；在 200 MHz 配置下目标运行时间约 11--12 s。命令也支持显式传入三项种子和迭代数，少于 10 s 的结果只用于调试。

默认种子的三项校验值为 `e714`、`1fd7` 和 `8e3a`；显式种子 `0x3415 0x3415 0x66` 的校验值为 `e3c1`、`0747` 和 `8d84`。CPU-only 的 `COREMARK_VERIFY` 还检查取指 PC 是否始终位于 `0x8000_0000`--`0x8000_FFFF`，越界立即判定失败。

CoreMark 主循环不执行浮点指令。`stop_time()` 之后，软件通过 `fpu_mmio` 完成 `u32 -> binary32` 和 binary32 除法，再由整数代码格式化时间和迭代率；该协处理器只提供 MMIO 服务，不代表 CPU 支持 RV32F。

现有运行记录只能作为历史诊断：`sim_cpu_only/build/verilator-sim.log` 的文件时间为 2026-08-05，早于当前基线中的 IROM/CoreMark/RT-Thread 改动和 MMIO 单精度 FPU 改动。日志确认 RT-Thread 启动、UART 透传和 `help` 回显，随后注入 `coremark 0 0 0x66 24`，在 CoreMark 输出检查处报 `[UART-VERIFY] FAIL: coremark output mismatch`，没有写入 PASS LED，结束原因为 `uart_assert_fail`。当前环境没有 RISC-V 交叉编译器，因此本报告不把这份记录写成当前 PASS，也不提供当前 CoreMark 分数。

## 评价指标

主要性能指标包括总周期数、退休指令数、CPI、MIPS、双发射包数、前端停顿、load-use 停顿、多周期执行等待以及 L0 命中率。CPI 与 MIPS 分别按式 \eqref{eq:cpi} 和式 \eqref{eq:mips} 计算。

\begin{equation}
  \mathrm{CPI}=\frac{N_{\mathrm{cycle}}}{N_{\mathrm{inst}}}
  \label{eq:cpi}
\end{equation}

\begin{equation}
  \mathrm{MIPS}=\frac{f_{\mathrm{clk}}}{\mathrm{CPI}},\quad
  f_{\mathrm{clk}}=200\ \mathrm{{MHz}}
  \label{eq:mips}
\end{equation}

L0 命中率定义为 L0 命中次数与 BRAM load 请求次数之比；不存在 BRAM load 请求时不计算命中率。

CoreMark 记录运行时间、迭代次数、迭代率、三项校验值和输出检查状态；只有校验值和输出协议均正确时，运行时间和迭代率才可作为成绩。CPU 周期、CPI、MIPS 和 L0 命中率用于分析 RT-Thread/CoreMark 的运行行为。

# 功能验证 {#sec-functional-verification}

## RV32I 基础整数指令

依据 RV32I 基础整数指令集定义，测试覆盖除 `fence`、`ebreak` 和 `ecall` 外的 37 条指令。每个测试构造确定的源操作数，执行目标指令后比较寄存器或存储器结果，同时覆盖零值、全一值、最高位为 1、符号扩展、无符号比较和算术右移等边界情形。

| 指令类别                 | 测试指令                                                               |
| ------------------------ | ---------------------------------------------------------------------- |
| 高位立即数与 PC 相对寻址 | `lui`、`auipc`                                                         |
| 无条件跳转               | `jal`、`jalr`                                                          |
| 条件分支                 | `beq`、`bne`、`blt`、`bge`、`bltu`、`bgeu`                             |
| 数据读取                 | `lb`、`lh`、`lw`、`lbu`、`lhu`                                         |
| 数据写入                 | `sb`、`sh`、`sw`                                                       |
| 立即数运算               | `addi`、`slti`、`sltiu`、`xori`、`ori`、`andi`、`slli`、`srli`、`srai` |
| 寄存器运算               | `add`、`sub`、`sll`、`slt`、`sltu`、`xor`、`srl`、`sra`、`or`、`and`   |

Table: RV32I 指令覆盖范围

`rv32i` 定向程序还检查 `x0`、跳转返回地址、六类条件分支和自然对齐 byte/half/word 访存；已保存的 2026-07-31 回归快照记录该项为 PASS，但该快照早于当前 RTL，不能作为当前 PASS 结论。

## RV32M、CSR 与异常返回

`rv32m` 覆盖 `mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem` 和 `remu` 八条指令，重点检查高位乘法、除零、`INT_MIN/-1` 有符号溢出以及 `DIVU/REMU` 相同位型边界。已保存的 2026-07-31 回归快照记录该项为 PASS；开源 `rv32um-p` 的 8/8 结果来自更早历史快照，均不能绑定当前 RTL。

`zicsr_trap` 依次执行寄存器和立即数形式的 CSR 读、写、置位与清零，检查 `mtvec`、`mepc`、`mcause`、`mstatus` 和 `mscratch`，再主动触发 `ecall`，由异常处理程序更新返回地址并执行 `mret`。已保存的 2026-07-31 回归快照记录该项为 PASS，但该快照早于当前 RTL。

`rv32i`、`rv32m`、`zicsr_trap` 和 `memory` 的状态仅来自历史快照，不能作为当前 RTL 的 PASS 结论。`pipeline` 的历史快照为 FAIL，周期 436、退休指令 250、CPI 1.744；由于测试工具链缺失，未能取得当前 RTL 的失败编号和完整 stdout。`perf_micro` 是性能展示负载，不作为额外功能通过条件。

## 功能测试汇总 {#sec-functional-summary}

\begin{longtable}{@{}p{2.8cm}p{2.5cm}p{1.2cm}l@{}}
\caption{CPU 基础功能与历史兼容性验证结果汇总}\\
来源 & 测试程序 & 结果 & 主要覆盖内容 \\
\midrule
\endfirsthead
\toprule
来源 & 测试程序 & 结果 & 主要覆盖内容 \\
\midrule
\endhead
\bottomrule
\endlastfoot
项目定向测试 & \texttt{rv32i} & 历史 PASS & 37 条 RV32I 基础整数指令及边界值 \\
项目定向测试 & \texttt{rv32m} & 历史 PASS & RV32M 的 8 条乘除法指令及特殊语义 \\
项目定向测试 & \texttt{zicsr\_trap} & 历史 PASS & Zicsr、\texttt{ecall}、\texttt{mret} \\
项目定向测试 & \texttt{pipeline} & 历史 FAIL & 双槽约束、前递、停顿、冲刷和 CRC 场景；失败原因待取得日志 \\
项目定向测试 & \texttt{memory} & 历史 PASS & BRAM、子字访问、L0、MMIO 与 COUNTER \\
性能微基准 & \texttt{perf\_micro} & 历史 PASS & ALU、访存、分支和 RV32M 混合负载 \\
历史兼容性 & \texttt{irom-v2} 竞赛综合测试 & 未复现 & 仅保留旧 SoC 接口和裸机镜像兼容性记录 \\
\end{longtable}

\begin{longtable}{@{}p{2.4cm}p{2.0cm}lll@{}}
\caption{开源指令测试交叉验证结果}\\
\toprule
来源 & 测试集 & 用例数量 & 结果 & 主要覆盖内容 \\
\midrule
\endfirsthead
\toprule
来源 & 测试集 & 用例数量 & 结果 & 主要覆盖内容 \\
\midrule
\endhead
\bottomrule
\endlastfoot
\texttt{riscv-tests} & \texttt{rv32ui-p} & 历史快照 & 37/37 通过 & 早于当前 RTL，不能绑定当前基线 \\
\texttt{riscv-tests} & \texttt{rv32um-p} & 历史快照 & 8/8 通过 & 早于当前 RTL，不能绑定当前基线 \\
\end{longtable}

# 性能评估 {#sec-performance-evaluation}

## 本项目定向测试与混合微基准

下表只列出功能自检通过的历史快照负载；快照时间早于当前 RTL，不能作为当前性能结论。`pipeline` 的失败诊断统计移至正文，不列入性能表。

| 测试程序     | 证据状态   | 周期    | 退休指令 | CPI   | 双发射包 | 前端停顿 | load-use EX/MEM | EX busy | L0/BRAM load |
| ------------ | ---------- | ------: | -------: | ----: | -------: | -------: | --------------: | ------: | -----------: |
| `rv32i`      | 历史 PASS   | 287     | 158      | 1.816 | 2        | 0        | 0/0             | 0       | 6/8          |
| `rv32m`      | 历史 PASS   | 410     | 91       | 4.505 | 2        | 256      | 0/0             | 256     | 0/0          |
| `zicsr_trap` | 历史 PASS   | 185     | 106      | 1.745 | 1        | 0        | 0/0             | 0       | 0/0          |
| `memory`     | 历史 PASS   | 600,177 | 600,105  | 1.000 | 2        | 9        | 2/7             | 0       | 4/11         |
| `perf_micro` | 历史 PASS   | 17,305  | 22,273   | 0.777 | 6,504    | 502      | 1/1             | 500     | 0/2,001      |

Table: 早于当前 RTL 的历史通过负载统计

`perf_micro` 的退休指令数高于周期数，说明该负载使用了双槽提交能力；其性能数字只用于说明历史快照的统计口径，不替代当前 RTL 的性能结果。开源白名单没有周期/CPI 字段，不用于性能表。

## 旧竞赛镜像兼容性记录 {#sec-irom-v2-performance}

`irom-v2` 对应 COE 裸机验收，本文只引用其镜像格式、SoC 地址映射和 PASS/FAIL LED 协议。矩阵运算周期、CPI、L0 命中率和 240 MHz 计时数据属于该兼容性记录，不纳入 RT-Thread/CoreMark 性能结果。

## 官方 CoreMark 性能记录 {#sec-coremark-performance}

官方配置使用默认种子 `0,0,0x66`、5000 次迭代和至少 10 s 运行时间。报告不把 24 次 `coremark-smoke` 或 2026-08-05 的历史日志当作正式成绩；现有日志在 UART 透传和 `help` 检查后，于 CoreMark 输出检查处失败，没有产生分数或 PASS LED。当前没有绑定当前 RTL 的 CoreMark 周期、秒数、迭代率或分数。

# FPGA 板级验证状态 {#sec-fpga-validation}

## 硬件平台

板级工程目标为竞业达 FPGA 数字孪生平台，核心器件为 Xilinx Kintex-7 XC7K325T-FFG900-2。200 MHz 差分输入经 PLL 生成 200 MHz CPU 时钟和 50 MHz 外设时钟；CPU 通过内存映射接口连接 LED、数码管、COUNTER、UART 和其他固定 MMIO。UART 使用 9600 baud、8N1 配置。

## 板级测试程序与流程

板级测试使用包含 RT-Thread Nano 和 CoreMark 的 IROM/BRAM 镜像，检查系统启动、COUNTER tick、UART 透传、finsh/msh 命令和 CoreMark 自检输出。`irom-v2` 作为旧 SoC 接口的兼容性样例。正式结论需要 Vivado/XSim 日志、实现时序报告或开发板原始观测；本次环境没有 Vivado，未执行 elaboration、XSim、综合、布局布线、bitstream 或真实板级实验。

## 历史资料与当前状态

旧板级记录中的 `1,683 ms` 来自 `irom-v2` 矩阵程序，不是 RT-Thread/CoreMark 运行结果。当前没有可发布的 LUT/FF/DSP/BRAM、WNS、TNS、Fmax、bitstream 或操作系统板级耗时数据，不能据此声称当前设计已完成 FPGA 验证。

# 结论

当前 RTL 实现了 37 条 RV32I 基础指令、RV32M 8 条指令和项目测试需要的最小 Zicsr/M-mode trap 子集。核心采用双槽顺序发射与顺序提交，访存后端使用 MEM1/MEM2，BRAM load 经过 L0 cache，取指使用总容量 64 KiB 的共享双口 IROM；UART、FPU MMIO、RT-Thread Nano 3.1.5 和 finsh/msh 已接入同一套 SoC 地址空间。

RT-Thread 移植使用 COUNTER 驱动 tick，能够通过 UART 进入 finsh/msh；CoreMark 使用官方算法，MMIO FPU 只在停止计时后完成时间换算，不改变 CPU 的 RV32I/RV32M 指令范围。现有 CPU-only 日志证明系统启动和 UART 透传路径走通，但 CoreMark 输出校验失败，不能形成成绩。

验证结果按证据时间区分：本地 CPU 定向测试和 `riscv-tests` 是历史快照，RT-Thread/CoreMark 日志也有明确的基线和日期；当前环境缺少 RISC-V 交叉编译器，无法重建操作系统镜像。`irom-v2` 作为兼容性资料，不代表 RT-Thread/CoreMark 的验收结果。

# 附录

## 代码清单

\begin{longtable}{@{}p{5.0cm}p{9.2cm}@{}}
\caption{关键源码与验证文件}\\
\toprule
文件或目录 & 主要用途 \\
\midrule
\endfirsthead
\toprule
文件或目录 & 主要用途 \\
\midrule
\endhead
\bottomrule
\endlastfoot
\texttt{rtl/core/mycpu.sv} & CPU 顶层，连接双槽流水线、前递、冒险、CSR、L0、store bypass 和访存接口 \\
\texttt{rtl/pipeline/stage/} & IF、ID、EX、MEM1 和 WB 组合逻辑 \\
\texttt{rtl/pipeline/register/} & 五组流水级间寄存器 \\
\texttt{rtl/control/} & 主译码、ALU/CSR 控制、立即数和重定向控制 \\
\texttt{rtl/datapath/} & ALU、PC、寄存器组和 RV32M 单元 \\
\texttt{rtl/hazard/} & 双槽 load-use 冒险检测和多级前递选择 \\
\texttt{rtl/memory/} & LSU、load mask、BRAM 驱动和 L0 load 缓存 \\
\texttt{rtl/bus/perip\_bridge.sv} & BRAM/MMIO 地址译码、COUNTER、UART/FPU 返回路径 \\
\texttt{rtl/peripheral/fpu\_mmio.sv} & CoreMark 时间换算用的有限 binary32 MMIO 协处理器 \\
\texttt{rt-thread/bsp/mycpu/} & RT-Thread Nano 3.1.5 板级移植、finsh/msh 和演示程序 \\
\texttt{rt-thread/bsp/mycpu/coremark/} & 官方 CoreMark 1.0 算法与平台适配 \\
\texttt{sim\_cpu\_only/tb\_cpu\_only.sv} & CPU-only UART 透传、FPU 和 CoreMark 验收逻辑 \\
\texttt{rtl/peripheral/uart\_bridge.sv} & CPU 200 MHz 与 UART 50 MHz 跨时钟域握手和透传 \\
\texttt{rtl/peripheral/uart.sv} & 9600 baud UART 收发器 \\
\texttt{rtl/peripheral/twin\_controller.sv} & 板级数字孪生 UART、开关、按键和显示控制 \\
\texttt{rtl/soc/student\_top.sv} & CPU、双路 IROM、外设桥和板级信号连接 \\
\texttt{sim\_cpu\_only/} & Verilator/Icarus CPU-only 仿真环境 \\
\texttt{verification/} & 当前可信测试入口、镜像构建和回归工具 \\
\texttt{vivado/tests/} & 历史开发测试与程序生成工具，不作为当前结果来源 \\
\end{longtable}

## 工程目录结构

```text
riscv-cpu-remote/
|-- rtl/
|   |-- core/              CPU 核心顶层
|   |-- pipeline/          流水级与级间寄存器
|   |-- control/           指令译码与控制
|   |-- datapath/          ALU、寄存器组和 RV32M
|   |-- hazard/            冒险检测与前递
|   |-- memory/            LSU、BRAM 与 L0 缓存
|   |-- bus/               外设桥和地址译码
|   |-- peripheral/        UART、FPU 和数字孪生外设
|   |-- soc/               SoC 连接层
|   \-- top/               FPGA 板级顶层
|-- rt-thread/             RT-Thread Nano 3.1.5 移植与 CoreMark 基准
|-- sim_cpu_only/          CPU-only 仿真环境
|-- verification/          CPU 测试和回归工具
|-- tb/                    Vivado testbench
|-- vivado/tests/          历史汇编测试与程序文件生成工具
|-- ip/                    IROM、BRAM 和 PLL 配置
|-- constraints/           板级约束
|-- scripts/               Vivado 自动化脚本
\-- docs/                  技术文档与设计资料
```

## 参考资料

1. RISC-V International. *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*.
2. RISC-V International. *The RISC-V Instruction Set Manual, Volume II: Privileged Architecture*.
3. AMD. *Vivado Design Suite User Guide: Synthesis (UG901)*.
4. IEEE. *IEEE Standard for SystemVerilog, IEEE Std 1800-2017*.
5. `riscv-software-src`. [`riscv-tests`](https://github.com/riscv-software-src/riscv-tests), commit `34e6b6d1e7936b526075432fb730d89148623484`.
6. EEMBC. *CoreMark 1.0*，官方算法与验证规则，`rt-thread/bsp/mycpu/coremark/`。
7. RT-Thread. *RT-Thread Nano v3.1.5*，上游 tag `v3.1.5`，`rt-thread/kernel/`。

## AI 工具声明

本项目使用 GLM-5.2 和 Doubao-Seed-2.1 辅助梳理代码结构、提供模块拆分建议、优化部分代码格式及润色技术文档，少量用于测试代码编写参考。CPU 架构设计、RTL 核心代码、功能调试、仿真验证与时序优化均由我们团队独立完成。

AI 辅助内容约占文档的 15%、代码的 5%，不涉及核心设计内容。
