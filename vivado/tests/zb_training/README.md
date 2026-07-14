# RV32 Zb 单指令测试

本目录用于比赛现场为一条随机抽取的 RV32 Zb 指令生成独立测试。覆盖范围为
Zba、Zbb、Zbc、Zbs、Zbkb、Zbkx，共 39 条不重复候选指令。生成程序只用
`.word` 发射目标指令，因此 RISC-V 汇编器只需支持仓库原有的 `rv32im`。

## 一条命令生成镜像

```sh
cd vivado/tests
make zb-test ZB_INSN=ror
```

产物位于 `build/`：

```text
zb_ror.S    zb_ror.elf    zb_ror.bin    zb_ror.map
zb_ror.coe  zb_ror.mif    zb_ror.dump
```

指令名中的点会在文件名中转换为下划线，例如 `sext.b` 生成
`build/zb_sext_b.coe`。可以用下面的命令查看全部候选及别名：

```sh
python3 zb_training/tools/zb_tool.py list
python3 zb_training/tools/zb_tool.py selftest
```

Makefile 默认使用 `python3`。环境只有 `python` 命令时可执行：

```sh
make zb-test ZB_INSN=ror PYTHON=python
```

## 分支与验证进度

公共基线为 `zb/base`，每条指令在首次开发时按需创建独立分支，命名为
`zb/<扩展>-<指令>`，例如 `zb/zba-sh1add`、`zb/zbb-sext-b`。使用分支管理脚本
可以避免误从另一条已实现指令的分支派生：

```sh
python3 zb_training/tools/zb_branch.py status --filter incomplete
python3 zb_training/tools/zb_branch.py open sh1add
python3 zb_training/tools/zb_branch.py mark implemented
python3 zb_training/tools/zb_branch.py verify
python3 zb_training/tools/zb_branch.py verify-set pass
```

`verify` 只显示针对该指令展开的验证流程，不会替代需要人工运行的编译和仿真。
分支存在、实现标记完成且验证结果为 `pass` 时，该指令才计入已完成。进度保存在
Git 公共目录的 `zb-branch-status.json` 中，供同仓库 worktree 共享但不提交。完整
命令、安全检查和别名规则见 [分支管理脚本说明](tools/zb_branch.md)。
在 Linux 环境批量实现全部候选时，按
[39 条指令实施工作流](../../../docs/zb_39_instruction_implementation_workflow.md)
执行。

## 使用题面编码

默认编码来自 `docs/zb_all_candidate_instructions.md`。若题面编码不同，把题面给出的
任意一个 32 位机器码实例传给 `ZB_ENCODING`：

```sh
make zb-test ZB_INSN=ror ZB_ENCODING=0x6062d3b3
```

样例机器码中的 `rd/rs1/rs2/shamt` 可以任意，生成器只提取该指令形式的固定编码
位，再为各测试场景重新填充操作数字段。该覆盖方式要求题面仍沿用对应指令的
R 型、固定单目型或 5 位立即数型字段布局；如果题面改变了操作数字段位置，应直接
按题面调整生成器，不能只使用 `ZB_ENCODING`。

也可以只生成汇编：

```sh
python3 zb_training/tools/zb_tool.py generate ror \
  --output build/zb_ror.S --encoding 0x6062d3b3
```

生成后必须检查 `build/zb_<指令>.dump`，确认所有目标位置的机器码与题面编码规则
一致。`brev8` 同时接受别名 `rev.b`，`xperm4/xperm8` 同时接受
`xperm.n/xperm.b`。

## 自动覆盖内容

每份程序只要求 CPU 实现当前目标指令，并覆盖：

- 指令类别专属的零值、全一、符号、移位、索引、字节置换或越界边界；
- `rd == rs1`、适用时的 `rd == rs2`，以及写 `x0`；
- 普通 ALU 生产者到目标指令、目标结果到下一条消费者的前递；
- BRAM store 初始化后 `lw` 紧跟目标指令的 load-use；
- 通过循环训练双发射提示表，让目标指令分别获得槽 0、槽 1 的执行机会；
- 与目标 `funct3` 接近的 RV32I 指令和一条 RV32M `mul`，检查译码是否过宽。

程序通过时向 LED 地址 `0x8020_0040` 写入 `0xC0DEC0DE`，失败时写入
`0xDEADBEEF`。槽位测试会自动检查功能结果和循环次数；确认实际槽位时观察波形中的
`IF_issue_dual`、`EX_valid` 和 `EX_S1_valid`。

## CPU-only / Vivado 验证

生成镜像后，可在有 Verilator 的环境运行：

```sh
cd sim_cpu_only
make sim-verilator \
  IROM_COE=../vivado/tests/build/zb_ror.coe \
  PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE
```

Vivado 仿真则把生成的 `.coe` 用作 IROM 初始化文件，运行 `tb/tb_myCPU.sv`，等待
LED 完成值。测试失败时先从 `.dump` 核对机器码，再按功能向量、前递、load-use、
双发射段落的顺序定位波形。

## 保留的训练示例

目录中的 `t20`—`t27` 是 8 类代表指令的手写训练样例，不会被上级 Makefile 默认
编译。它们适合阅读和限时练习；需要覆盖任意候选时应使用统一生成器。相关资料：

1. `docs/zb_extension_competition_guide.md`
2. `docs/zb_all_candidate_instructions.md`
3. `docs/zb_training_exercises.md`
4. `docs/zb_competition_cheatsheet.md`
