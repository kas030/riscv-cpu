# RV32 Zb 可能考查指令总表

只需查阅 39 条指令的编码和语义时，使用
[RV32 Zb 39 条指令精简手册](zb_instruction_quick_manual.md)。本文继续保留实现路径、
运算模板和完整测试矩阵。

本文汇总本工程赛前训练范围内可能要求现场加入的 RV32 位操作指令，并给出足以
落到本仓库 RTL 的实现路径、标准编码参考和运算模板。覆盖：

- Zba：地址生成
- Zbb：基础位操作
- Zbc：无进位乘法
- Zbs：单比特操作
- Zbkb：密码学常用位操作
- Zbkc：密码学无进位乘法子集
- Zbkx：寄存器内交叉置换

按不重复指令计，共有 **39 条 RV32 候选指令**。Zbkb、Zbkc 与其他扩展存在
重叠，因此各扩展表中的行数相加会大于 39。

> 这是一份备考全集，不代表这些指令已经在 RTL 中实现。不同版本规范可能使用
> `rev.b/brev8`、`xperm.n/xperm4`、`xperm.b/xperm8` 等不同名称；编码和语义
> 永远以比赛题面为准。

如果比赛允许主办方自定义语义或编码，就不存在能够提前穷举的“所有指令”。本文
的“全量”是指上述标准 RV32 Zb/Zbk 范围，并额外列出常见旧草案名称。

## 1. 数量与优先级概览

| 扩展 | RV32 指令数 | 不重复新增数 | 典型难点 | 建议优先级 |
|---|---:|---:|---|---|
| Zba | 3 | 3 | 固定移位后加法 | 最高 |
| Zbb | 18 | 18 | 旋转、计数、符号比较、单目精确译码 | 最高 |
| Zbc | 3 | 3 | 64 位无进位乘积及结果切片 | 中 |
| Zbs | 8 | 8 | 寄存器/立即数索引、低 5 位规则 | 最高 |
| Zbkb | 12 | 5 | pack、字节内倒位、bit 交错 | 高 |
| Zbkc | 2 | 0 | 是 Zbc 的 `clmul/clmulh` 子集 | 中 |
| Zbkx | 2 | 2 | 多路选择与越界清零 | 中 |

最可能在有限时间内完成的是 Zba、逻辑取反、单比特操作、pack 和简单扩展类。
组合网络较大的 `clmul*`、`xperm*`、`clz/ctz/cpop` 更适合作为进阶题。

## 2. 统一记号

下表语义使用这些记号：

```text
A = rs1
B = rs2
u32(x) = x 的低 32 位
s32(x) = 把 x 解释为 32 位有符号数
n = B[4:0] 或题面规定的立即数 shamt[4:0]
P = A 与 B 的 64 位无进位乘积
```

所有普通结果都写入 `rd`，溢出默认只保留低 32 位。表中的“形式”用于判断第二个
输入来自寄存器还是指令立即数字段：

- R：读取 `rs1`、`rs2`。
- I：读取 `rs1`，第二个输入来自立即数字段。
- 单目：只读取 `rs1`，`instr[24:20]` 可能是功能编码而不是真实 `rs2`。

## 3. Zba：地址生成，共 3 条

| 指令 | 形式 | RV32 语义 | 实现提示 |
|---|---|---|---|
| `sh1add` | R | `u32((A << 1) + B)` | 固定移位 1 后加法 |
| `sh2add` | R | `u32((A << 2) + B)` | 固定移位 2 后加法 |
| `sh3add` | R | `u32((A << 3) + B)` | 固定移位 3 后加法 |

这三条最适合练习新增独热控制位。它们都能复用现有普通 ALU 写回、前递和冒险
处理，不需要多周期执行。

## 4. Zbb：基础位操作，共 18 条

### 4.1 带取反的逻辑运算

| 指令 | 形式 | RV32 语义 | 易错点 |
|---|---|---|---|
| `andn` | R | `A & ~B` | 只取反 `B` |
| `orn` | R | `A \| ~B` | 不是 `~(A \| B)` |
| `xnor` | R | `~(A ^ B)` | 结果保持 32 位 |

### 4.2 位计数

| 指令 | 形式 | RV32 语义 | 关键边界 |
|---|---|---|---|
| `clz` | 单目 | 从最高位起连续 0 的数量 | `A=0` 时结果为 32 |
| `ctz` | 单目 | 从最低位起连续 0 的数量 | `A=0` 时结果为 32 |
| `cpop` | 单目 | `A` 中 1 的总数 | 结果范围 0～32 |

这三条常共享 `opcode/funct7/funct3`，再由 `instr[24:20]` 区分。当前
`alu_ctrl` 若只看到 `{funct7, funct3}`，就必须先扩展接口以接收完整指令。

### 4.3 有符号与无符号最值

| 指令 | 形式 | RV32 语义 | 比较方式 |
|---|---|---|---|
| `min` | R | `s32(A) < s32(B) ? A : B` | 有符号 |
| `max` | R | `s32(A) > s32(B) ? A : B` | 有符号 |
| `minu` | R | `A < B ? A : B` | 无符号 |
| `maxu` | R | `A > B ? A : B` | 无符号 |

必须用 `0xFFFF_FFFF` 与 `1` 区分有符号、无符号实现是否正确。相等时选择哪个
操作数不影响最终数值。

### 4.4 符号与零扩展

| 指令 | 形式 | RV32 语义 | 结果 |
|---|---|---|---|
| `sext.b` | 单目 | 符号扩展 `A[7:0]` | `{{24{A[7]}}, A[7:0]}` |
| `sext.h` | 单目 | 符号扩展 `A[15:0]` | `{{16{A[15]}}, A[15:0]}` |
| `zext.h` | 单目或题面指定形式 | 零扩展 `A[15:0]` | `{16'b0, A[15:0]}` |

`zext.h` 在不同规范/工具链组合中可能使用不同编码形式，现场不要只根据助记符
推断 `rs2` 是否有效。

### 4.5 循环移位

| 指令 | 形式 | RV32 语义 | 关键边界 |
|---|---|---|---|
| `rol` | R | `u32((A << n) \| (A >> (32-n)))` | `n=B[4:0]` |
| `ror` | R | `u32((A >> n) \| (A << (32-n)))` | `n=B[4:0]` |
| `rori` | I | `u32((A >> n) \| (A << (32-n)))` | `n=shamt[4:0]` |

`n=0` 必须单独处理，或使用 `{A,A}` 拼接后移位，避免生成移位 32 的表达式。

### 4.6 按字节归约与字节反转

| 指令 | 形式 | RV32 语义 | 示例 |
|---|---|---|---|
| `orc.b` | 单目 | 每个非零输入字节变成 `8'hFF`，零字节仍为 0 | `00120080 -> 00FF00FF` |
| `rev8` | 单目 | 反转 4 个字节的顺序 | `01234567 -> 67452301` |

`rev8` 只交换字节位置，不反转每个字节内部的 bit；它与 Zbkb 的
`rev.b/brev8` 是两种不同操作。

## 5. Zbc：无进位乘法，共 3 条

无进位乘法把输入看作 GF(2) 多项式，部分积通过异或累加：

```text
P = XOR over i where B[i]==1 of (uint64(A) << i)
```

| 指令 | 形式 | RV32 结果 | 最易混淆处 |
|---|---|---|---|
| `clmul` | R | `P[31:0]` | 低 32 位 |
| `clmulh` | R | `P[63:32]` | 高 32 位 |
| `clmulr` | R | `P[62:31]` | 相对 `clmulh` 右移一位的窗口 |

三条可以共享一张 64 位无进位乘积网络，但需要不同的独热控制位。不要使用普通
乘法器的进位加法结果代替。

## 6. Zbs：单比特操作，共 8 条

寄存器版本使用 `B[4:0]` 作为索引；立即数版本使用题面指定的立即数低 5 位：

```text
index = B[4:0] 或 imm[4:0]
mask  = 32'b1 << index
```

| 指令 | 形式 | RV32 语义 |
|---|---|---|
| `bclr` | R | `A & ~mask` |
| `bclri` | I | `A & ~mask` |
| `bext` | R | `(A >> index) & 1` |
| `bexti` | I | `(A >> index) & 1` |
| `binv` | R | `A ^ mask` |
| `binvi` | I | `A ^ mask` |
| `bset` | R | `A | mask` |
| `bseti` | I | `A | mask` |

寄存器版本必须测试索引 32 或 63，确认实现只使用低 5 位。立即数版本不能把编码
字段当成真实 `rs2`，否则可能产生不存在的 RAW 冒险。

## 7. Zbkb：密码学常用位操作，共 12 条

Zbkb 中有 7 条也属于 Zbb，因此真正额外增加的是 5 条。

| 指令 | 与其他扩展关系 | RV32 语义摘要 |
|---|---|---|
| `rol` | 与 Zbb 重叠 | 循环左移 |
| `ror` | 与 Zbb 重叠 | 循环右移 |
| `rori` | 与 Zbb 重叠 | 立即数循环右移 |
| `andn` | 与 Zbb 重叠 | `A & ~B` |
| `orn` | 与 Zbb 重叠 | `A \| ~B` |
| `xnor` | 与 Zbb 重叠 | `~(A ^ B)` |
| `rev8` | 与 Zbb 重叠 | 反转字节顺序 |
| `pack` | Zbkb 新增 | `{B[15:0], A[15:0]}` |
| `packh` | Zbkb 新增 | `{16'b0, B[7:0], A[7:0]}` |
| `rev.b` / `brev8` | Zbkb 新增、名称有版本差异 | 每个字节内部独立倒位 |
| `zip` | Zbkb 新增、仅 RV32 | 低/高手字 bit 交错到偶/奇位置 |
| `unzip` | Zbkb 新增、仅 RV32 | `zip` 的逆操作 |

### `zip` 与 `unzip` 的精确定义

```text
zip:
  rd[2*i]   = A[i]
  rd[2*i+1] = A[i+16]

unzip:
  rd[i]    = A[2*i]
  rd[i+16] = A[2*i+1]

i = 0..15
```

必须分别测试 `unzip(zip(x)) == x` 和 `zip(unzip(x)) == x`。

### `rev8` 与 `rev.b/brev8` 的区别

```text
A = 0x01234567
rev8(A)      = 0x67452301  // 调换字节顺序
rev.b(A)     = 0x80C4A2E6  // 每个字节内部倒位
```

部分题目把 `rev.b` 写作 `brev8`。看到名称后仍要根据题面伪代码确认是哪一种。

## 8. Zbkc：密码学无进位乘法，共 2 条

Zbkc 不引入新的运算，只选取 Zbc 中密码学最常用的两条：

| 指令 | 等价来源 |
|---|---|
| `clmul` | Zbc `clmul` |
| `clmulh` | Zbc `clmulh` |

若题面写的是 Zbkc，就不应自动假设还要求实现 `clmulr`。

## 9. Zbkx：交叉置换，共 2 条

| 常见名称 | 另一版本名称 | 元素宽度 | 元素数量 | 有效索引 |
|---|---|---:|---:|---:|
| `xperm.n` | `xperm4` | 4 bit | 8 | 0～7 |
| `xperm.b` | `xperm8` | 8 bit | 4 | 0～3 |

每个输出元素从 `B` 的对应元素取得索引，再选择 `A` 中的元素；索引越界时输出
零。以 `xperm8` 为例：

```text
for i = 0..3:
    index = B[8*i +: 8]
    rd[8*i +: 8] = index < 4 ? A[8*index +: 8] : 8'b0
```

这类指令的核心测试是混合有效和越界索引，不能只测恒等排列或完整逆序。

## 10. 按实现难度重新分类

### A 类：通常只改宽度、译码和 ALU

```text
sh1add sh2add sh3add
andn orn xnor
min max minu maxu
sext.b sext.h zext.h
bclr bset binv bext
pack packh
```

这些运算大多是一条组合表达式，现有普通 ALU 写回、前递和双发射通路可以复用。

### B 类：重点处理立即数或完整指令译码

```text
clz ctz cpop
rori
bclri bexti binvi bseti
orc.b rev8 rev.b/brev8 zip unzip
```

实现前先确认 `alu_ctrl` 是否能看到区分指令所需的 `instr[24:20]` 或完整立即数。

### C 类：边界容易写错

```text
rol ror rori
bclr/bext/binv/bset 及立即数版本
rev8 rev.b/brev8
```

重点测试移位量 0、位索引 0/31/32，以及“字节顺序反转”和“字节内部倒位”。

### D 类：组合网络较大

```text
clz ctz cpop
clmul clmulh clmulr
zip unzip
xperm.n/xperm4 xperm.b/xperm8
```

现场先保证功能正确，再考虑树形计数、共享中间结果或缩短关键路径。

## 11. 不属于本 RV32 主清单的指令

下列名称可能出现在 RV64 文档中，但不能直接作为本 RV32 CPU 的候选实现：

```text
add.uw
sh1add.uw sh2add.uw sh3add.uw
slli.uw zext.w
clzw ctzw cpopw
rolw rorw roriw
packw
```

原因是它们依赖 64 位 XLEN 或 32 位 word 运算后的 64 位扩展语义。本工程寄存器和
ALU 均为 32 位，除非题面明确重新定义，否则不要加入。

## 12. 旧草案或自定义题面中可能出现的名称

早期 Bitmanip 草案还出现过一些后来被改名、拆分或未进入当前主扩展的指令。若
历年题目基于旧材料，可能看到：

```text
grev grevi                 // 广义 bit 反转
gorc gorci                 // 广义 OR-combine
shfl shfli                 // bit shuffle
unshfl unshfli             // bit unshuffle
bcompress bdecompress      // bit 压缩/展开，旧资料也可能写 bext/bdep
bfp                        // bit-field place
cmix cmov                  // 三操作数条件混合/移动
fsl fsr fsri               // funnel shift
crc32.b crc32.h crc32.w
crc32c.b crc32c.h crc32c.w
```

这些指令**不计入前面的 39 条标准训练主清单**。尤其是三操作数指令，本工程现有
R 型数据通路只有两个源寄存器，不能再按“只加一个 ALU 控制位”的套路处理。比赛
若给出其中任何一条，应完全依照题面语义、编码和允许修改范围重新评估数据通路。

## 13. 每条指令都要执行的测试矩阵

无论抽到哪一条，至少覆盖：

1. 全零、全 1、最高位和一个普通随机输入。
2. 移位量或索引 0、31；寄存器版本再测 32 或 63。
3. `rd == rs1`、`rd == rs2`，以及写 `x0`。
4. 上一条指令产生 `rs1/rs2`，验证 EX/MEM 前递。
5. load 后立即使用加载结果，验证 load-use 停顿。
6. 结果被下一条指令立即消费，验证写回前递。
7. 目标指令分别进入两个发射槽。
8. 与目标编码相近的 RV32I/RV32M 指令仍然正确。
9. `.dump` 中机器码与题面一致。
10. 最终向 `0x8020_0040` 写入 `0xC0DEC0DE` 或 `0xDEADBEEF`。

## 14. 在本仓库添加任意普通 Zb 指令的固定步骤

本节是所有后续配方的公共前提。题目若是不访存、不跳转、单周期完成的 OP 或
OP-IMM 指令，通常只需修改 CPU 核心内的以下位置。

### 第一步：确认题面字段和数据来源

先写出：

```text
opcode = ?
funct7 = ?
funct3 = ?
instr[24:20] 是 rs2、shamt，还是固定功能码？
A 来自 rs1 吗？B 来自 rs2 还是立即数？
```

不要先写 ALU。错误最多的地方通常是把固定功能码当成 `rs2`，或只匹配
`funct3` 导致误译其他指令。

### 第二步：分配新的独热控制位

在 `rtl/common/defines.sv` 中把 `ALU_OP_WIDTH` 增加 1。宏值必须写成实际数字，
不能把下面的 `N` 当作可直接粘贴的标识符。例如当前最高已用位是 bit 22，下一条
指令使用 bit 23 时应写：

```systemverilog
`define ALU_OP_WIDTH 24
```

在 `rtl/control/alu_ctrl.sv` 中新增：

```systemverilog
// 示例：bit 23 对应 24'h800000
localparam logic [`ALU_OP_WIDTH-1:0] OP_XXX = 24'h800000;
logic do_xxx;

assign do_xxx = /* 完整编码匹配 */;

// 加入 ALUControl 的 OR 汇总：
// | ({`ALU_OP_WIDTH{do_xxx}} & OP_XXX)
```

如果宽度增加后旧 `OP_*` 常量仍写着旧位宽，功能上会零扩展，但 Verilator 会产生
宽度告警。应把常量字面量一起改成新宽度。

### 第三步：必要时让 `alu_ctrl` 接收完整指令

只依赖 `opcode/funct7/funct3` 的 R 型指令可以沿用当前接口。以下类型通常还需要
`instr[24:20]` 或完整 `imm12`：

```text
clz ctz cpop sext.b sext.h zext.h
rori orc.b rev8 brev8 zip unzip
bclri bexti binvi bseti
```

稳妥做法是把 `alu_ctrl` 改为接收完整 `instr`：

```systemverilog
module alu_ctrl(
    input  logic [31:0] instr,
    output logic [`ALU_OP_WIDTH-1:0] ALUControl
);
    logic [6:0] opcode;
    logic [6:0] funct7;
    logic [2:0] funct3;
    logic [4:0] field_24_20;
    logic [11:0] imm12;

    assign opcode      = instr[6:0];
    assign funct7      = instr[31:25];
    assign funct3      = instr[14:12];
    assign field_24_20 = instr[24:20];
    assign imm12       = instr[31:20];
```

然后在 `rtl/control/mycpu_decoder.sv` 中改为：

```systemverilog
alu_ctrl u_alu_ctrl (
    .instr      (ID_instr),
    .ALUControl (ID_ALUControl)
);
```

两条发射槽都会经过 `mycpu_decoder`，因此不需要在 `mycpu.sv` 中复制一份新译码。

### 第四步：在 ALU 中接入结果

在 `rtl/datapath/alu.sv` 中增加选择和局部结果：

```systemverilog
logic m_xxx;
logic [DATAWIDTH-1:0] r_xxx;

assign m_xxx = ALUControl[N];
assign r_xxx = /* 本文后续对应指令的表达式 */;

// 加入 Result 的 OR 汇总：
// | ({DATAWIDTH{m_xxx}} & r_xxx)
```

分支比较使用独立的 `isTrue`，普通 Zb 运算不要修改它。

### 第五步：确认普通写回路径可复用

本清单中的 OP/OP-IMM 指令都写回 ALU 结果。现有 `main_ctrl.sv` 已经为这两类
opcode 产生：

```text
RegWrite = 1
MemToReg = ALU
MemRead/MemWrite = 0
NpcOp = 顺序执行
```

因此通常不需要修改流水寄存器、MEM、WB、寄存器堆、前递和冒险单元。立即数或
单目指令的 `uses_rs2` 必须为 0；本工程目前只把 R 型、store、branch 视为使用
`rs2`，OP-IMM 不会制造假冒险。

### 第六步：不得扩大 RV32M 判定范围

`mycpu_ex_stage.sv` 中必须保持：

```systemverilog
assign is_m_op = |EX_ALUControl[21:14];
```

新增 Zb 位位于这个范围之外。不要改成 `[ALU_OP_WIDTH-1:14]`，否则新指令会错误
启动多周期乘除法单元。若你主动把 `clmul*` 做成多周期，则必须单独增加启动、忙、
完成和双槽冻结机制，不能借用一个尚未分配的 RV32M 控制位蒙混过去。

## 15. 39 条指令的标准编码参考

以下编码以当前 `riscv-opcodes` 中的 RV32 定义为参考。比赛题面若给出不同编码，
必须使用题面编码。

记号：

```text
OP      : opcode = 0x33
OP-IMM  : opcode = 0x13
f7      : instr[31:25]
f3      : instr[14:12]
rs2/f5  : instr[24:20]
imm12   : instr[31:20]
```

### 15.1 Zba 编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `sh1add` | OP | `f7=0x10, f3=2` |
| `sh2add` | OP | `f7=0x10, f3=4` |
| `sh3add` | OP | `f7=0x10, f3=6` |

### 15.2 Zbb 编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `andn` | OP | `f7=0x20, f3=7` |
| `orn` | OP | `f7=0x20, f3=6` |
| `xnor` | OP | `f7=0x20, f3=4` |
| `clz` | OP-IMM 单目 | `imm12=0x600, f3=1` |
| `ctz` | OP-IMM 单目 | `imm12=0x601, f3=1` |
| `cpop` | OP-IMM 单目 | `imm12=0x602, f3=1` |
| `max` | OP | `f7=0x05, f3=6` |
| `maxu` | OP | `f7=0x05, f3=7` |
| `min` | OP | `f7=0x05, f3=4` |
| `minu` | OP | `f7=0x05, f3=5` |
| `sext.b` | OP-IMM 单目 | `imm12=0x604, f3=1` |
| `sext.h` | OP-IMM 单目 | `imm12=0x605, f3=1` |
| `zext.h` | OP 特殊单目 | `f7=0x04, rs2/f5=0, f3=4` |
| `rol` | OP | `f7=0x30, f3=1` |
| `ror` | OP | `f7=0x30, f3=5` |
| `rori` | OP-IMM | `f7=0x30, f3=5`，`rs2/f5=shamt` |
| `orc.b` | OP-IMM 单目 | `imm12=0x287, f3=5` |
| `rev8` | OP-IMM 单目 | RV32 常用 `imm12=0x698, f3=5` |

### 15.3 Zbc/Zbkc 编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `clmul` | OP | `f7=0x05, f3=1` |
| `clmulr` | OP | `f7=0x05, f3=2` |
| `clmulh` | OP | `f7=0x05, f3=3` |

### 15.4 Zbs 编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `bclr` | OP | `f7=0x24, f3=1` |
| `bclri` | OP-IMM | `f7=0x24, f3=1`，`rs2/f5=index` |
| `bext` | OP | `f7=0x24, f3=5` |
| `bexti` | OP-IMM | `f7=0x24, f3=5`，`rs2/f5=index` |
| `binv` | OP | `f7=0x34, f3=1` |
| `binvi` | OP-IMM | `f7=0x34, f3=1`，`rs2/f5=index` |
| `bset` | OP | `f7=0x14, f3=1` |
| `bseti` | OP-IMM | `f7=0x14, f3=1`，`rs2/f5=index` |

### 15.5 Zbkb 新增编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `pack` | OP | `f7=0x04, f3=4` |
| `packh` | OP | `f7=0x04, f3=7` |
| `brev8` / `rev.b` | OP-IMM 单目 | 常用 `imm12=0x687, f3=5` |
| `zip` | OP-IMM 单目 | 当前常用 `f7=0x04, rs2/f5=0x0F, f3=1` |
| `unzip` | OP-IMM 单目 | 当前常用 `f7=0x04, rs2/f5=0x0F, f3=5` |

旧冻结草案对 `zip/unzip` 的 `instr[24:20]` 曾使用其他固定值。遇到这两条尤其要
逐位照抄题面，不要凭记忆写编码。

### 15.6 Zbkx 编码

| 指令 | 格式 | 标准匹配条件 |
|---|---|---|
| `xperm4` / `xperm.n` | OP | `f7=0x14, f3=2` |
| `xperm8` / `xperm.b` | OP | `f7=0x14, f3=4` |

## 16. 可直接放进 `alu.sv` 的运算配方

以下 `A/B` 分别表示 ALU 的两个 32 位输入。立即数版本应让 `B` 来自立即数，或
直接从流水线携带的指令字段生成 `index/shamt`；不要读取一个不存在的 `rs2`。

### 16.1 一行表达式即可完成

```systemverilog
// Zba
r_sh1add = (A << 1) + B;
r_sh2add = (A << 2) + B;
r_sh3add = (A << 3) + B;

// Zbb 逻辑
r_andn = A & ~B;
r_orn  = A | ~B;
r_xnor = ~(A ^ B);

// Zbb 最值
r_min  = ($signed(A) < $signed(B)) ? A : B;
r_max  = ($signed(A) > $signed(B)) ? A : B;
r_minu = (A < B) ? A : B;
r_maxu = (A > B) ? A : B;

// Zbb 扩展
r_sext_b = {{24{A[7]}}, A[7:0]};
r_sext_h = {{16{A[15]}}, A[15:0]};
r_zext_h = {16'b0, A[15:0]};

// Zbs；index 对寄存器版取 B[4:0]，立即数版取 shamt[4:0]
mask   = 32'b1 << index;
r_bclr = A & ~mask;
r_bext = (A >> index) & 32'b1;
r_binv = A ^ mask;
r_bset = A | mask;

// Zbkb
r_pack  = {B[15:0], A[15:0]};
r_packh = {16'b0, B[7:0], A[7:0]};

// Zbb 字节操作
r_rev8 = {A[7:0], A[15:8], A[23:16], A[31:24]};
```

同一个 `mask` 可以由 8 条 Zbs 指令共享；寄存器版和立即数版仍需各自独立、互斥
的译码信号。

### 16.2 旋转模板

```systemverilog
logic [4:0] shamt;

assign shamt = /* ror/rol 取 B[4:0]，rori 取立即数字段 */;
assign r_rol = (shamt == 0) ? A : ((A << shamt) | (A >> (32-shamt)));
assign r_ror = (shamt == 0) ? A : ((A >> shamt) | (A << (32-shamt)));
```

也可以用 64 位拼接避免 `32-shamt`：

```systemverilog
assign r_ror = ({A, A} >> shamt);
```

赋给 32 位结果时自然保留低 32 位。`rol` 可以用相反方向的拼接或显式零移位分支。

### 16.3 `clz/ctz/cpop` 模板

```systemverilog
integer i;
always_comb begin
    r_clz  = 32'd32;
    r_ctz  = 32'd32;
    r_cpop = 32'd0;

    for (i = 0; i < 32; i = i + 1) begin
        r_cpop = r_cpop + {{31{1'b0}}, A[i]};
        if ((r_ctz == 32'd32) && A[i])
            r_ctz = i;
        if ((r_clz == 32'd32) && A[31-i])
            r_clz = i;
    end
end
```

所有组合输出必须先赋默认值，否则容易推导锁存器。若综合时序不足，再改成分组
优先编码器或树形计数；现场功能优先。

### 16.4 `orc.b` 模板

```systemverilog
integer i;
always_comb begin
    r_orc_b = 32'b0;
    for (i = 0; i < 4; i = i + 1)
        r_orc_b[8*i +: 8] = (A[8*i +: 8] == 8'b0) ? 8'h00 : 8'hFF;
end
```

### 16.5 `brev8/rev.b` 模板

```systemverilog
integer byte_i, bit_i;
always_comb begin
    r_brev8 = 32'b0;
    for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1)
        for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1)
            r_brev8[8*byte_i + bit_i] = A[8*byte_i + (7-bit_i)];
end
```

这里字节位置不变，只反转每个字节内部的 8 位。

### 16.6 `clmul*` 模板

```systemverilog
logic [63:0] cl_product;
integer i;

always_comb begin
    cl_product = 64'b0;
    for (i = 0; i < 32; i = i + 1)
        if (B[i])
            cl_product = cl_product ^ ({32'b0, A} << i);
end

assign r_clmul  = cl_product[31:0];
assign r_clmulh = cl_product[63:32];
assign r_clmulr = cl_product[62:31];
```

不要用 `A * B`，那是带进位整数乘法。三个结果可以共享 `cl_product`。

### 16.7 `zip/unzip` 模板

```systemverilog
integer i;
always_comb begin
    r_zip   = 32'b0;
    r_unzip = 32'b0;
    for (i = 0; i < 16; i = i + 1) begin
        r_zip[2*i]       = A[i];
        r_zip[2*i+1]     = A[i+16];
        r_unzip[i]       = A[2*i];
        r_unzip[i+16]    = A[2*i+1];
    end
end
```

### 16.8 `xperm4/xperm8` 模板

```systemverilog
integer i4, i8;
logic [3:0] index4;
logic [7:0] index8;

always_comb begin
    r_xperm4 = 32'b0;
    index4 = 4'b0;
    for (i4 = 0; i4 < 8; i4 = i4 + 1) begin
        index4 = B[4*i4 +: 4];
        if (index4 < 8)
            r_xperm4[4*i4 +: 4] = A[4*index4 +: 4];
    end
end

always_comb begin
    r_xperm8 = 32'b0;
    index8 = 8'b0;
    for (i8 = 0; i8 < 4; i8 = i8 + 1) begin
        index8 = B[8*i8 +: 8];
        if (index8 < 4)
            r_xperm8[8*i8 +: 8] = A[8*index8 +: 8];
    end
end
```

部分综合工具不喜欢循环中复用一个动态索引变量。若报错，可把每个输出元素展开成
独立组合表达式或 `case`。默认结果必须为 0，保证越界索引清零。

## 17. 逐条译码写法示例

假设 `alu_ctrl` 已经能看到完整 `instr`，可以先定义：

```systemverilog
logic is_op, is_op_imm;
logic [6:0] funct7;
logic [2:0] funct3;
logic [4:0] field_24_20;
logic [11:0] imm12;

assign is_op       = instr[6:0] == 7'h33;
assign is_op_imm   = instr[6:0] == 7'h13;
assign funct7      = instr[31:25];
assign funct3      = instr[14:12];
assign field_24_20 = instr[24:20];
assign imm12       = instr[31:20];
```

然后按下面的固定模式写。这里展示了所有不同译码形态，其余指令只替换常量：

```systemverilog
// 普通双源 R 型：sh1add
assign do_sh1add = is_op && (funct7 == 7'h10) && (funct3 == 3'h2);

// 单目 OP-IMM，必须匹配完整 imm12：cpop
assign do_cpop = is_op_imm && (imm12 == 12'h602) && (funct3 == 3'h1);

// OP 中 rs2 字段固定为 0：zext.h
assign do_zext_h = is_op && (funct7 == 7'h04) &&
                   (field_24_20 == 5'd0) && (funct3 == 3'h4);

// 带 5 位立即数的 OP-IMM：bseti
assign do_bseti = is_op_imm && (funct7 == 7'h14) && (funct3 == 3'h1);
// field_24_20 是 index，不应再与某个固定值比较。

// 固定功能码 OP-IMM：brev8
assign do_brev8 = is_op_imm && (imm12 == 12'h687) && (funct3 == 3'h5);
```

特别注意 `rori/bclri/bexti/binvi/bseti`：`instr[24:20]` 是有效立即数，译码只能
匹配 `funct7/funct3/opcode`，不能要求这五位等于某个常量。

## 18. 每类指令的最低定向向量

| 类别 | 输入 | 期望或性质 |
|---|---|---|
| `sh1/2/3add` | 最高位附近、会溢出的输入 | 只保留低 32 位 |
| `andn/orn/xnor` | `A=0xAA55AA55, B=0x0F0FF0F0` | 与独立软件表达式一致 |
| `clz` | `0, 1, 0x80000000` | `32, 31, 0` |
| `ctz` | `0, 1, 0x80000000` | `32, 0, 31` |
| `cpop` | `0, 0xFFFFFFFF, 0xAAAAAAAA` | `0, 32, 16` |
| `min/max` | `A=0xFFFFFFFF, B=1` | signed 与 unsigned 结果不同 |
| `sext/zext` | `A=0x00008080` | 检查 bit 7、bit 15 符号 |
| `rol/ror/rori` | `n=0,1,31,32/寄存器版` | 零移位和低 5 位规则 |
| `orc.b` | `A=0x00120080` | `0x00FF00FF` |
| `rev8` | `A=0x01234567` | `0x67452301` |
| `brev8/rev.b` | `A=0x01234567` | `0x80C4A2E6` |
| `clmul*` | `A=0xB, B=0x6` | 完整无进位乘积为 `0x3A` |
| Zbs 寄存器版 | index `0,31,32,63` | 32/63 分别等价于 0/31 |
| Zbs 立即数版 | index `0,31` | 不读取真实 `rs2` |
| `pack` | `AAAABBBB, CCCCDDDD` | `DDDDBBBB` |
| `packh` | `AAAABBCC, DDDDEEFF` | `0000FFCC` |
| `zip/unzip` | 多组随机值 | 两者互逆 |
| `xperm4/8` | 恒等、逆序、全越界、混合越界 | 越界元素必须为 0 |

完成组合级测试后，还必须执行第 13 节的前递、load-use、双发射槽和 x0 测试。

配套材料：

- [从零添加一条 RV32 Zb 指令](zb_extension_competition_guide.md)
- [RV32 Zb 指令比赛现场速查表](zb_competition_cheatsheet.md)
- [RV32 Zb 扩展现场加指令训练题库](zb_training_exercises.md)
- `vivado/tests/zb_training/tools/zb_tool.py`：参考运算与机器码编码工具
