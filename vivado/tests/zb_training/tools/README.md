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

`zb_branch.py` 复用生成器中的 39 条指令、扩展归属和别名，按需管理
`zb/<扩展>-<指令>` 分支。公共基线固定为 `zb/base`；首次打开一条尚不存在的
指令分支时，会直接从该基线创建，不会从当前单指令分支派生。

```sh
# 查看全部进度，或只看未完成项
python3 vivado/tests/zb_training/tools/zb_branch.py status
python3 vivado/tests/zb_training/tools/zb_branch.py status --filter incomplete

# 创建/跟踪并切换到规范分支，例如 zb/zbb-andn
python3 vivado/tests/zb_training/tools/zb_branch.py open andn

# 记录实现状态；省略指令名时从当前 zb/... 分支推断
python3 vivado/tests/zb_training/tools/zb_branch.py mark implemented \
  --note "译码、执行和前递已完成"

# 展开当前指令的构建、机器码检查、目标仿真和基础回归命令
python3 vivado/tests/zb_training/tools/zb_branch.py verify

# 手工跑完验证后记录结果
python3 vivado/tests/zb_training/tools/zb_branch.py verify-set pass \
  --note "目标仿真和基础回归通过"

# 测试脚本自身的 Git 分支及状态逻辑
python3 vivado/tests/zb_training/tools/zb_branch.py selftest
```

分支名中的扩展使用小写，指令名中的点转换为连字符，例如 `andn` 对应
`zb/zbb-andn`，`sext.b` 对应 `zb/zbb-sext-b`。`rev.b`、`xperm.n`、
`xperm.b` 等别名会解析到与规范名相同的分支。

状态保存在 `$(git rev-parse --git-common-dir)/zb-branch-status.json`，不会进入
提交，并由同一仓库的所有 worktree 共享。只有目标分支存在、实现标记为
`implemented` 且验证标记为 `pass` 时，状态才是“已完成”。把实现改回
`pending` 会同步清除旧的验证结果。状态文件损坏或版本不兼容时，脚本会停止并
提示处理，不会静默覆盖。

`open` 要求工作区干净且本地存在 `zb/base`。若规范分支仅存在于 `origin`，它会
建立本地 tracking 分支；若本地和远端都不存在，则从 `zb/base` 新建。脚本不会
自动创建 39 个空分支，也不会自动提交或推送实现进度。
