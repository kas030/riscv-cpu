# RV32 Zb 指令比赛现场速查表

> 这是一张“照着做”的检查单，不代替入门讲解。第一次练习请先读
> [Zb 扩展指令教程](zb_extension_competition_guide.md)，完整范围见
> [可能考查指令总表](zb_all_candidate_instructions.md)。**编码和语义永远以比赛题面为准。**

## 一、拿到题目后的七步

1. **写语义**：先写成 32 位伪代码，圈出符号、回绕、移位量、索引和越界规则。
2. **拆机器码**：确认 `opcode`、`funct7`、`funct3`、`rs2/imm[4:0]`，判断 B 是寄存器还是立即数。
3. **定数据路**：普通 OP/OP-IMM 指令走现有 ALU 写回，通常不用改流水寄存器、前递或 WB。
4. **加控制位**：扩大 `ALU_OP_WIDTH`，从当前最高已用位之后分配新的独热位；
   原始 22 位基线的第一个空闲位才是 bit 22。
5. **加译码和运算**：严格匹配题面编码，在 ALU 中计算局部结果并接入 `Result`。
6. **先小后大地测**：先测纯运算，再测覆盖写、前递、load-use、x0 和两个发射槽。
7. **查机器码和波形**：先确认 `.dump`，再沿 `ID 控制 -> EX 输入 -> ALU 结果 -> WB` 排查。

## 二、编码公式

```text
R 型（opcode=0x33）
31       25 24    20 19    15 14  12 11     7 6       0
| funct7   |  rs2  |  rs1  |funct3|   rd   |  0x33   |

word = (funct7 << 25) | (rs2 << 20) | (rs1 << 15)
     | (funct3 << 12) | (rd << 7) | 0x33

OP-IMM（opcode=0x13）
31                 20 19    15 14  12 11     7 6       0
|       imm12        |  rs1  |funct3|   rd   |  0x13   |

word = (imm12 << 20) | (rs1 << 15) | (funct3 << 12)
     | (rd << 7) | 0x13
```

工具链不认识助记符时使用 `.word 0xXXXXXXXX`。可用工具生成并复核：

```sh
python3 vivado/tests/zb_training/tools/zb_tool.py encode-r \
  --funct7 0x10 --rs2 6 --rs1 5 --funct3 2 --rd 7 --word
```

## 三、通常只改这三个位置

| 位置 | 要做什么 | 改完立即检查 |
|---|---|---|
| `rtl/common/defines.sv` | `ALU_OP_WIDTH` 加 1 | 所有相关信号都使用该宏，没有手写旧宽度 |
| `rtl/control/alu_ctrl.sv` | 新增 `OP_XXX`、`do_xxx` 和 OR 汇总项 | 只在目标机器码上置位，且保持独热 |
| `rtl/datapath/alu.sv` | 新增 `m_xxx`、`r_xxx` 和 `Result` 汇总项 | `r_xxx` 是完整 32 位结果，未选中时不影响输出 |

独热控制的最小写法（以下用原始基线的 bit 22、`23'h400000` 举例）：

```systemverilog
// alu_ctrl.sv
localparam logic [`ALU_OP_WIDTH-1:0] OP_XXX = 23'h400000;
logic do_xxx;
assign do_xxx = /* 完整编码条件 */;
// 在原 ALUControl OR 表达式末尾加入：
// | ({`ALU_OP_WIDTH{do_xxx}} & OP_XXX)

// alu.sv
logic m_xxx;
logic [DATAWIDTH-1:0] r_xxx;
assign m_xxx = ALUControl[22];
assign r_xxx = /* 32 位运算 */;
// 在原 Result OR 表达式末尾加入：
// | ({DATAWIDTH{m_xxx}} & r_xxx)
```

## 四、两个最容易丢分的陷阱

### 1. 忽略完整 `instr` 中的区分字段

公共基线中的 `alu_ctrl` 已接收完整 `ID_instr`。`clz/ctz/cpop/sext.b/sext.h`
等指令可能拥有相同 `funct7/funct3`，必须继续检查 `instr[24:20]` 或完整
`imm12`，否则会误译。

- 若题目只需 `funct7/funct3`：直接使用模块内已有的字段。
- 若题目还规定了 `instr[24:20]`：从 `instr` 提取该字段，并匹配题面要求的全部固定位。
- 不要把 `instr[24:20]` 一律当作 `rs2`：OP-IMM 或单目指令中它可能是编码常量。

### 2. 新指令被误当成 RV32M

`mycpu_ex_stage.sv` 中必须保持：

```systemverilog
assign is_m_op = |EX_ALUControl[21:14];
```

bit 14～21 专属于现有乘除法。Zb 控制位应分配在这个范围之外，原始基线从
bit 22 起使用；**不要**把范围写成 `[ALU_OP_WIDTH-1:14]`，否则新指令会启动
多周期 RV32M 单元。

## 五、常用 SystemVerilog 运算模板

```systemverilog
// 移位加法：sh1add；sh2add/sh3add 改常量
r = (A << 1) + B;

// 旋转右移：必须单独处理 shamt==0
shamt = B[4:0];
r = (shamt == 0) ? A : ((A >> shamt) | (A << (32-shamt)));

// 单比特操作：寄存器索引只取低 5 位
mask = 32'b1 << B[4:0];
r_bset = A | mask;  r_bclr = A & ~mask;
r_binv = A ^ mask;  r_bext = (A >> B[4:0]) & 32'b1;

// 计数/置换/无进位乘法：组合循环必须先给默认值
always_comb begin
    count = 6'd0;
    for (int i = 0; i < 32; i++) count += A[i];
end

always_comb begin
    cl_product = 64'b0;
    for (int i = 0; i < 32; i++)
        if (B[i]) cl_product ^= ({32'b0, A} << i);
end
// clmul=[31:0]，clmulh=[63:32]，clmulr=[62:31]
```

额外牢记：`xperm4/xperm8` 的索引越界结果为 0；`brev8` 是每个字节内部倒位，
`rev8` 是调换字节顺序；立即数位索引和寄存器位索引都按题面确认取值范围。

## 六、提交前最小测试

- **纯语义**：`0`、全 1、最高位、一个普通随机值。
- **边界**：移位量/位索引 `0`、`31`；寄存器版本再测 `32`（应只取低 5 位）。
- **覆盖写**：`rd == rs1`、`rd == rs2`，以及写 `x0` 无副作用。
- **前递**：上一条刚产生两个源操作数；目标结果被下一条立即使用。
- **冒险**：load 后立即把加载值交给目标指令。
- **流水**：目标指令分别进入两个发射槽；复杂指令至少再测一个特殊规则，如
  `xperm` 越界或 `clmul*` 结果切片。

程序结束协议：向 `0x80200040` 写 `0xC0DEC0DE` 表示通过，写
`0xDEADBEEF` 表示失败。构建后先检查 `.dump` 中目标 `.word` 是否正确；生成
`.coe` 后仍要确认 Vivado IROM 已实际更新。

## 七、失败时按这个顺序查

```text
机器码字段正确吗？
  -> ID_ALUControl 只置了目标位吗？
  -> EX 的 A/B 是正确寄存器、立即数和前递值吗？
  -> r_xxx 局部结果正确吗？
  -> Result 是否选中了 r_xxx？
  -> WB 是否写到正确 rd？
  -> 程序是否真的写出了 LED 完成值？
```

若所有运算波形都正确但仿真不结束，优先检查 IROM 镜像、LED 地址和完成协议，
不要继续盲改 ALU。完整练习见 [Zb 训练题库](zb_training_exercises.md)。
