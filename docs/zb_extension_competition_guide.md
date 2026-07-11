# 从零添加一条 RV32 Zb 指令

这是一份跟做教程，面向“会写基本 SystemVerilog，但刚接触本 CPU”的同学。
我们先用 `sh1add` 完整走一遍，再说明其他 Zb 指令与它相比多了什么。

配套材料：

- [比赛现场速查表](zb_competition_cheatsheet.md)
- [12 道训练题](zb_training_exercises.md)
- `vivado/tests/zb_training/` 中的汇编示例和参考工具

> 指令名称和编码可能随规范版本变化。比赛时以题面给出的语义和 32 位机器码为准。

## 1. 先理解我们到底要做什么

以 `sh1add x7, x5, x6` 为例，它的意思是：

```text
x7 = (x5 << 1) + x6
```

CPU 要完成三件事：

1. **认出来**：在 ID 级判断当前机器码是不是 `sh1add`。
2. **算出来**：在 EX 级计算 `(A << 1) + B`。
3. **写回去**：沿现有流水线把结果写入 `x7`。

这类指令不访存、不跳转，并且一拍能算完，所以写回、前递和冒险处理大多可以
复用现有普通 ALU 指令。我们的主要工作就是“新增一个选择信号”和“新增一种运算”。

### 本教程会遇到的几个词

| 术语 | 在本仓库中的意思 |
|---|---|
| ID | 译码级，读取指令字段并生成控制信号 |
| EX | 执行级，ALU 真正进行运算 |
| `ALUControl` | 告诉 ALU 本拍要做哪种运算的一组独热控制位 |
| 独热 | 正常情况下只有一位为 1；例如 bit 0 表示 add，bit 1 表示 sub |
| 前递 | 结果还没写回寄存器堆时，直接送给后面的依赖指令 |
| `.word` | 直接把一个 32 位机器码放进汇编程序，避免工具链不认识新助记符 |

## 2. 一条普通 Zb 指令在 CPU 中怎样流动

先不要记所有模块，只记住这条主线：

```text
指令进入 ID
  -> alu_ctrl 认出是哪种运算
  -> ID/EX 寄存器保存控制信号
  -> alu 在 EX 级计算
  -> 现有 MEM/WB 通路把结果写回 rd
```

对 `sh1add` 这样的 OP 类型指令，现有 `main_ctrl.sv` 已经会产生“读取两个寄存器、
写回 ALU 结果”的控制信号。因此通常不用碰访存、分支、流水寄存器或寄存器堆。

## 3. 跟做：完整实现 `sh1add`

### 第一步：把题面改写成硬件表达式

```systemverilog
result = (A << 1) + B;
```

这里的 `A` 对应 `rs1`，`B` 对应 `rs2`。结果只保留低 32 位，SystemVerilog 的
32 位逻辑向量会自然截断溢出部分。

先手算两个例子，避免代码写完才发现自己理解错了：

```text
sh1add(3, 100)          = 106
sh1add(0x40000001, 3)  = 0x80000005
```

### 第二步：拆机器码

`sh1add` 是 R 型指令。训练示例固定使用：

```text
funct7=0x10, rs2=x6, rs1=x5, funct3=2, rd=x7, opcode=0x33
```

拼接后是：

```asm
.word 0x2062A3B3       /* sh1add x7, x5, x6 */
```

不要只相信手算，可以用：

```sh
python3 vivado/tests/zb_training/tools/zb_tool.py encode-r \
  --funct7 0x10 --rs2 6 --rs1 5 --funct3 2 --rd 7 --word
```

### 第三步：给 ALU 分配一个新控制位

当前 `ALUControl` 有 22 位，而且已经全部使用。先在 `defines.sv` 中把宽度从 22
改为 23。已有信号大多使用宏定义，会自动一起变宽。

然后在 `alu_ctrl.sv` 中增加 bit 22：

```systemverilog
localparam logic [`ALU_OP_WIDTH-1:0] OP_SH1ADD = 23'h400000;
logic do_sh1add;

assign do_sh1add = kind_r &&
                   (funct7 == 7'b0010000) &&
                   (funct3 == 3'b010);
```

最后把它加入原有 `ALUControl` OR 汇总：

```systemverilog
| ({`ALU_OP_WIDTH{do_sh1add}} & OP_SH1ADD)
```

为什么不能只看 `funct3`？因为很多指令的 `funct3` 相同。译码条件太宽，会让别的
机器码也错误地执行 `sh1add`。

### 第四步：在 ALU 中计算结果

在 `alu.sv` 中把 bit 22 接成一个选择信号：

```systemverilog
logic m_sh1add;
logic [DATAWIDTH-1:0] r_sh1add;

assign m_sh1add = ALUControl[22];
assign r_sh1add = (A << 1) + B;
```

然后加入 `Result` 汇总：

```systemverilog
| ({DATAWIDTH{m_sh1add}} & r_sh1add)
```

可以把这里理解为：`m_sh1add=1` 时让 `r_sh1add` 通过；否则这一项贡献全 0，
不会影响 add、sub 等已有结果。

### 第五步：避免被当成乘除法

本仓库的 RV32M 使用 `ALUControl[21:14]`。新增 bit 22 后，EX 级判断必须仍是：

```systemverilog
assign is_m_op = |EX_ALUControl[21:14];
```

不要为了“自动覆盖所有高位”改成 `[ALU_OP_WIDTH-1:14]`，否则 `sh1add` 会错误启动
多周期乘除单元，流水线也会无故停住。

### 第六步：运行最小测试

训练程序在 `vivado/tests/zb_training/t20_zb_sh1add.S`。复制到会被 Makefile 收集的
目录后构建：

```sh
cp vivado/tests/zb_training/t20_zb_sh1add.S \
   vivado/tests/tier1_basic/t20_zb_sh1add.S
cd vivado/tests
make clean
make t20_zb_sh1add
```

先打开 `build/t20_zb_sh1add.dump`，确认里面确实有 `0x2062A3B3`。随后更新 Vivado
实际使用的 IROM 镜像。生成 `.coe` 并不等于仿真已经加载了它。

测试程序会向 LED 地址 `0x80200040` 写：

- `0xC0DEC0DE`：全部断言通过
- `0xDEADBEEF`：至少一个断言失败

### 第七步：不会工作时怎样看波形

按数据流逐段检查，不要同时怀疑所有模块：

1. ID 级指令是不是 `0x2062A3B3`？
2. `ID_ALUControl[22]` 是否为 1，并且其他操作位没有误置位？
3. EX 级 A、B 是否分别等于 x5、x6 的值？
4. `r_sh1add` 是否正确？
5. `EX_alu_result` 是否选择了它？
6. WB 是否对 x7 写入正确结果？
7. 运算正确但仿真不结束时，检查 IROM 和 LED 完成写，而不是继续修改 ALU。

到这里，你已经完成了比赛中最常见的一类题。

## 4. 其他指令只是在哪一步不同

### A 类：只替换运算表达式

`sh2add/sh3add`、`andn/orn/xnor`、`pack/packh` 与 `sh1add` 的流程相同，主要区别
只是 ALU 表达式：

```systemverilog
r_sh2add = (A << 2) + B;
r_andn   = A & ~B;
r_pack   = {B[15:0], A[15:0]};
```

这类题最适合先练习。

### B 类：运算不难，但要特别处理边界

旋转和 Zbs 位操作属于这一类：

```systemverilog
shamt = B[4:0];
r_ror = (shamt == 0) ? A : ((A >> shamt) | (A << (32-shamt)));

mask   = 32'b1 << B[4:0];
r_bset = A | mask;
r_bext = (A >> B[4:0]) & 32'b1;
```

`ror` 必须测试移位量 0；寄存器版本的位索引只使用低 5 位，所以索引 32 等价于 0。

### C 类：需要完整指令字段才能正确译码

`clz/ctz/cpop/sext.b/sext.h` 等单目 OP-IMM 指令可能共享 `funct7/funct3`，再使用
`instr[24:20]` 区分。当前 `alu_ctrl` 看不到这五位。

遇到这类题，应让 `alu_ctrl` 接收完整 `instr`，并在 `mycpu_decoder.sv` 中连接
`ID_instr`。不要为了少改一个端口而使用宽松译码，因为它会误收其他编码。

`cpop` 的组合实现可以从 0 开始逐位累加：

```systemverilog
always_comb begin
    r_cpop = 32'b0;
    for (int i = 0; i < 32; i++)
        r_cpop = r_cpop + A[i];
end
```

### D 类：置换时必须处理索引越界

`xperm4/xperm8` 把 A 看成一张小表，把 B 的每个元素当索引。索引超出表范围时，
对应输出必须为 0。例如：

```text
xperm8(0x44332211, 0x00010203) = 0x11223344
```

实现时先把结果清零，再只给合法索引赋值。这样越界规则自然成立。

### E 类：结果切片容易混淆，组合逻辑也较大

`clmul*` 先生成一个 64 位无进位乘积：

```systemverilog
always_comb begin
    product = 64'b0;
    for (int i = 0; i < 32; i++)
        if (B[i]) product ^= ({32'b0, A} << i);
end
```

然后分别取：

```text
clmul  = product[31:0]
clmulh = product[63:32]
clmulr = product[62:31]
```

组合实现最容易在比赛中写对，但面积和时序风险最高，应最后练习。

### 两种很容易混淆的字节操作

- `rev8`：交换四个字节的位置。
- `brev8`：每个字节的位置不变，只把字节内部的 8 个 bit 反过来。

例如 `brev8(0x01234567)=0x80C4A2E6`，不能用普通字节反序代替。

## 5. 哪些模块通常不用改

只要题目是普通、单周期、写回 rd 的 OP/OP-IMM 指令，通常只需要核对而无需修改：

- `main_ctrl.sv`：已经把 OP/OP-IMM 送到普通 ALU 写回。
- ID/EX、EX/MEM、MEM/WB：控制宽度使用宏，后级只传最终结果。
- `forwarding_unit.sv`：只比较 rs/rd 和写使能，不关心具体运算。
- `hazard_unit.sv`：OP 默认使用 rs1/rs2，OP-IMM 默认使用 rs1。
- `reg_file.sv`：现有写回和 x0 保护继续有效。

如果题目要求访存、改变 PC、多周期执行或新的写回来源，就不再属于这个简单模板，
必须重新检查控制和流水接口。

## 6. 做完功能测试后，还要测流水线

纯数学结果正确并不代表比赛测试一定通过。至少再加：

```asm
目标指令 x3, x1, x2
add      x4, x3, x3       /* 立即消费结果，测试前递 */
```

还应覆盖：

- `rd == rs1`，双源指令再测 `rd == rs2`
- load 后立即把加载值作为输入
- 写入 x0 后确认 x0 仍为 0
- 目标指令分别进入两个发射槽
- 与目标编码相近的旧指令仍然正确

接下来建议按题库顺序完成题 1、2、7、9，再进入旋转、计数、置换和无进位乘法。
能够不看本教程完成一题后，再只拿[比赛速查表](zb_competition_cheatsheet.md)限时训练。
