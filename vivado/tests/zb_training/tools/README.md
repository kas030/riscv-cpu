# Zb 训练辅助工具

`zb_tool.py` 仅依赖 Python 3 标准库，用来在现场核对机器码和 RV32 Zb
运算结果。它覆盖 Zba、Zbb、Zbc、Zbs、Zbkb、Zbkx 中常见的 RV32 运算；
编码仍应以比赛题面给出的版本为准。

```sh
# 先运行内置定向测试
python3 vivado/tests/zb_training/tools/zb_tool.py selftest

# R 型：funct7=0、rs2=x3、rs1=x2、funct3=0、rd=x1
python3 vivado/tests/zb_training/tools/zb_tool.py encode-r \
  --funct7 0 --rs2 x3 --rs1 x2 --funct3 0 --rd x1

# OP-IMM；imm12 可输入有符号立即数或完整的 12 位原始位型
python3 vivado/tests/zb_training/tools/zb_tool.py encode-op-imm \
  --imm12 0xfff --rs1 x2 --funct3 0 --rd x1

# 计算参考值。单目运算只给 rs1，双目/立即数运算再给 rs2
python3 vivado/tests/zb_training/tools/zb_tool.py eval ror 0x80000001 1
python3 vivado/tests/zb_training/tools/zb_tool.py eval cpop 0xf0f0000f
python3 vivado/tests/zb_training/tools/zb_tool.py eval xperm8 0x44332211 0x00010203
python3 vivado/tests/zb_training/tools/zb_tool.py list

# 生成一条完整 CPU 自检程序；目标指令始终以 .word 写入
python3 vivado/tests/zb_training/tools/zb_tool.py generate ror \
  --output vivado/tests/build/zb_ror.S

# 题面编码不同时，可传入任意寄存器实例的 32 位机器码
python3 vivado/tests/zb_training/tools/zb_tool.py generate ror \
  --output vivado/tests/build/zb_ror.S --encoding 0x6062d3b3
```

输出编码同时给出十六进制数和可直接粘贴到汇编中的 `.word`。所有参考运算
均截断为 32 位；寄存器形式的移位量和位索引只取低 5 位。`xperm4/xperm8`
的越界索引返回零，`clmulh/clmulr` 分别取 64 位无进位乘积的 `[63:32]` 和
`[62:31]`。

`generate` 覆盖 39 条不重复候选，并接受 `rev.b`、`xperm.n`、`xperm.b` 别名。
`--encoding` 只覆盖指令形式中的固定编码位，要求题面仍使用相同的
`rd/rs1/rs2/shamt` 字段布局。完整构建入口见上级 `README.md` 和
`make zb-test ZB_INSN=<name>`。

## 单指令分支管理

`zb_branch.py` 用于按需创建单指令分支、记录实现状态并展开验证流程。完整命令、
分支命名、别名和状态文件说明见 [zb_branch.md](zb_branch.md)。
