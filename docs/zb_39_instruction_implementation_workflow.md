# Agent 执行任务：独立实现 39 条 RV32 Zb 指令

你正在已配置完成的 Linux 环境中直接操作当前共享仓库。实际执行本文流程，不要只
输出实现计划。按给定顺序逐条实现、验证、提交并推送 39 条 RV32 Zb 候选指令；
除非遇到本文定义的停止条件，否则持续执行到 `39/39`。

每个分支只实现一条指令，全部直接派生自冻结的公共基线 `zb/base`。不要创建包含
全部实现的汇总分支，不要把单指令分支合并回 `zb/base`。

## 1. 完成标准

对 `zb_tool.py list` 列出的 39 条规范指令逐一完成以下闭环：

1. 从 `zb/base` 创建或打开规范单指令分支。
2. 只实现当前目标指令，不引入其他 Zb 指令。
3. 构建该指令的自动生成测试镜像并核对机器码。
4. CPU-only 目标仿真写出 LED `0xC0DEC0DE`。
5. 仓库基础回归全部通过。
6. 记录实现与验证状态，提交并推送单指令分支。

单条指令只有同时满足以下条件才算完成：

- 本地或远端存在规范分支；
- 实现状态为 `implemented`；
- 验证状态为 `pass`；
- 分支提交已经推送到 `origin`。

## 2. 硬性约束

- 开始前完整阅读仓库根目录的 `AGENTS.md`，当前 RTL 和其中的微架构约定优先于
  旧文档。
- 不修改 `rtl/core/mycpu.sv` 的固定端口，不改变双路 IROM、数据总线和 BRAM 的
  时序语义。
- 不通过修改 SoC、外设桥、testbench、生成测试或期望值来掩盖 CPU 错误。
- 不编辑 Vivado 生成目录、`.runs`、`.cache`、`.sim`、日志或历史构建产物。
- 不覆盖、不回退、不顺带整理用户已有修改；发现脏工作区时停止并报告。
- 每个单指令分支必须直接来自 `zb/base`，禁止从另一条单指令分支派生。
- 一个分支只实现一条规范指令；别名不是额外指令，也不创建额外分支。
- 不预先创建 39 个空分支。完成一条后再按队列打开下一条。
- `zb/base` 在批量实施期间保持冻结。若发现必须进入所有分支的公共缺陷，先停止
  批量工作并报告，由用户决定是否更新基线及如何同步已有分支。
- 验证失败时不得记录 `pass`，不得用仅编译成功代替功能仿真和基础回归。
- 对本文明确列出的分支创建、RTL 修改、测试、状态记录、提交和推送直接执行，不要
  在每条指令开始前重复请求确认。

只有以下情况暂停并请求用户处理：

- 启动或切换分支时发现不属于本任务的未提交修改；
- 题面/仓库编码资料相互冲突，无法确定应实现的固定编码位；
- 正确实现必须修改冻结的公共基线、固定顶层接口或既定微架构；
- 工具、权限或远端服务持续失败，且安全重试后仍无法完成必要验证或推送。

目标测试或基础回归失败本身不是停止条件。保留失败证据，在当前指令分支继续定位、
修正并完整重跑验证。

## 3. 权威资料和工具

- 指令语义与标准编码：`docs/zb_instruction_quick_manual.md`
- 完整实现配方与边界条件：`docs/zb_all_candidate_instructions.md`
- 单指令 RTL 接入教程：`docs/zb_extension_competition_guide.md`
- 测试生成器：`vivado/tests/zb_training/tools/zb_tool.py`
- 分支管理脚本：`vivado/tests/zb_training/tools/zb_branch.py`
- 分支脚本说明：`vivado/tests/zb_training/tools/zb_branch.md`

编码和参考结果以 `zb_tool.py` 的元数据、自测以及上述 39 条精简手册交叉核对。
题面若给出非标准编码，必须同时调整 RTL 严格译码，并用 `ZB_ENCODING` 重新生成
测试；不能只改测试机器码。

## 4. 开始执行

环境和当前共享仓库已经就绪，不要安装依赖、重新 clone、初始化仓库或迁移状态。

开始批量实施前，在仓库根目录确认当前分支为 `zb/base`，且工作区为空：

```sh
git branch --show-current
git status --short --branch
```

若不是 `zb/base` 或存在未提交修改，列出实际状态并停止，等待用户处理；不要自动
执行 `stash`、`reset`、`checkout --`、清理文件或切换分支。

随后验证公共工具和基础镜像：

```sh
python3 vivado/tests/zb_training/tools/zb_tool.py selftest
python3 vivado/tests/zb_training/tools/zb_branch.py selftest
python3 vivado/tests/zb_training/tools/zb_tool.py list
make -C vivado/tests
```

任一命令失败都应停止并报告，不要开始创建指令分支。

## 5. 39 条实施队列

严格按以下顺序执行，先稳定译码和普通 ALU 写回路径，再处理较大组合网络：

```text
Zba : sh1add sh2add sh3add
Zbb : andn orn xnor min max minu maxu sext.b sext.h zext.h
      rol ror rori clz ctz cpop orc.b rev8
Zbs : bclr bclri bext bexti binv binvi bset bseti
Zbkb: pack packh brev8 zip unzip
Zbc : clmul clmulh clmulr
Zbkx: xperm4 xperm8
```

这 39 个名字均为规范名。`rev.b` 等价于 `brev8`，`xperm.n` 等价于 `xperm4`，
`xperm.b` 等价于 `xperm8`，不得重复实现。

开始前查看总体状态：

```sh
python3 vivado/tests/zb_training/tools/zb_branch.py status
python3 vivado/tests/zb_training/tools/zb_branch.py status --filter incomplete
```

## 6. 每条指令的固定闭环

以下流程对队列中的每个 `INSN` 重复一次。不要一次打开多个未完成分支。

### 6.1 打开规范分支

```sh
INSN=sh1add
python3 vivado/tests/zb_training/tools/zb_branch.py status "$INSN"
python3 vivado/tests/zb_training/tools/zb_branch.py open "$INSN"
git branch --show-current
git status --short
```

`open` 会切换已有本地分支、跟踪已有远端分支，或从 `zb/base` 新建分支。若它因
工作区不干净、基线缺失或分支历史冲突而停止，先解决提示的问题，不能绕过检查
手工从当前指令分支继续派生。

### 6.2 明确语义、字段和边界

修改 RTL 前完成以下核对：

1. 从精简手册记录规范语义、mask/match、操作数字段和指令形式。
2. 从完整手册查找该类别的 SystemVerilog 运算模板和易错边界。
3. 确认是 `rs1/rs2`、`rs1/shamt`，还是只使用 `rs1` 的固定单目形式。
4. 确认移位量、位索引只取低 5 位；`xperm` 越界索引返回零。
5. 确认 `clmul/clmulh/clmulr` 的 64 位无进位乘积切片位置。
6. 用参考工具抽查至少一个普通值和一个边界值：

```sh
python3 vivado/tests/zb_training/tools/zb_tool.py eval "$INSN" 0x80000001 1
```

单目指令只提供 `rs1`；具体参数数量按工具报错或手册调整。

### 6.3 先生成测试并核对编码

```sh
make -C vivado/tests zb-test ZB_INSN="$INSN"
python3 vivado/tests/zb_training/tools/zb_branch.py verify "$INSN"
```

指令名中的点在构建文件名中转换为下划线，例如 `sext.b` 对应
`vivado/tests/build/zb_sext_b.dump`。打开 `.dump`，确认目标位置确实以 `.word`
发射，固定编码位与手册一致，且测试没有依赖其他未实现 Zb 指令。

### 6.4 实现当前指令

普通 Zb 指令通常只应触及以下路径：

- `rtl/common/defines.sv`：ALU 独热控制宽度；
- `rtl/control/alu_ctrl.sv`：完整指令严格译码和独热控制位；
- `rtl/datapath/alu.sv`：组合运算结果及最终结果汇总。

实际修改前必须以当前 `zb/base` 为准。若基线已经预留控制位或公共逻辑，复用既有
定义，不重复扩宽或重新编号。若没有预留，只为当前分支增加目标指令所需的最小
控制位，并同步所有依赖 `ALU_OP_WIDTH` 的声明和常量宽度。

实现时逐项检查：

- 译码使用完整 `instr` 的固定字段，不能只匹配 opcode 或 funct3；
- 目标指令和相近的 RV32I/RV32M 编码互斥，`ALUControl` 保持一热；
- R 型使用 `A=rs1`、`B=rs2`，立即数型沿用现有立即数/ALU 输入路径；
- 单目指令不能误把固定编码字段当成第二操作数；
- 普通结果沿用现有 ALU 写回和前递路径，不另建只在 WB 可见的旁路；
- 不扩大 RV32M busy 或多周期单元的判定范围；
- 两个执行槽共用的组合 ALU 行为保持一致；
- 写 `x0`、`rd==rs1`、`rd==rs2`、前递和 load-use 由生成测试实际覆盖；
- 组合循环必须有静态边界并可综合，避免锁存器、除零索引或越界 part-select；
- `clmul*`、`zip/unzip`、`xperm*` 等较大网络优先采用清晰、固定次数的组合实现，
  不自行引入新的停顿状态机，除非用户明确批准微架构变化。

通常不需要修改 `main_ctrl.sv`、`imm_gen.sv`、流水寄存器、冒险单元和写回 mux。
如果确实需要，必须说明为什么普通 ALU 路径无法覆盖，并按 `AGENTS.md` 扩大一致性
检查范围。

### 6.5 先做差异审计

```sh
git diff --check
git status --short
git diff zb/base...HEAD -- rtl
```

此时尚未提交时，再执行：

```sh
git diff -- rtl
```

确认没有测试、testbench、SoC、外设或无关格式化修改。若发现来源不明的修改，
停止并报告，不要回退它们。

### 6.6 运行目标验证

先重新运行生成器自测并重建目标镜像：

```sh
python3 vivado/tests/zb_training/tools/zb_tool.py selftest
make -C vivado/tests zb-test ZB_INSN="$INSN"
```

然后执行 `verify` 输出的目标仿真命令。等价流程如下，其中 `SLUG` 把点转换为
下划线：

```sh
SLUG=${INSN//./_}
make -C sim_cpu_only sim-verilator \
  IROM_COE="../vivado/tests/build/zb_${SLUG}.coe" \
  PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE
```

通过标准是仿真明确打印 PASS，虚拟 LED 为 `C0DEC0DE`，且不是因超时或 `$finish`
误判结束。失败时按以下顺序定位：

1. `.dump` 中机器码是否正确；
2. ID 级严格译码和 ALU 独热位是否命中；
3. EX 两槽输入和结果是否正确；
4. MEM1/MEM2/WB 的前递与有效位；
5. 生成测试中的覆盖标签和失败跳转位置。

修正后必须从生成、自测、构建开始重跑，不能只重跑最后一次仿真。

### 6.7 运行基础回归

```sh
make -C vivado/tests
./sim_cpu_only/run_regression.sh
```

基础回归中的每个非跳过项目都必须 PASS。若报告出现缺失镜像导致 SKIP，先补建
镜像后重跑；SKIP 不能算通过。额外检查目标指令相近的 RV32I/RV32M 基线运算，
避免译码过宽造成旧指令误译。

### 6.8 记录、提交和推送

功能实现完成后记录实现状态；目标仿真和基础回归全部通过后再记录验证通过：

```sh
python3 vivado/tests/zb_training/tools/zb_branch.py mark implemented "$INSN" \
  --note "严格译码、ALU、前递场景已实现"
python3 vivado/tests/zb_training/tools/zb_branch.py verify-set pass "$INSN" \
  --note "目标 CPU-only 仿真和基础回归通过"
python3 vivado/tests/zb_training/tools/zb_branch.py status "$INSN"
```

状态文件位于 Git 公共目录，因此上述命令不会产生待提交文件。只暂存本指令实际
修改的 RTL 文件，不使用宽泛的 `git add -A`：

```sh
git status --short
git add rtl/common/defines.sv rtl/control/alu_ctrl.sv rtl/datapath/alu.sv
git diff --cached --check
git diff --cached --stat
git commit -m "feat(cpu): 实现 ${INSN} 指令"
git push -u origin "$(git branch --show-current)"
```

上面的 `git add` 是普通 ALU 接入示例；若实际合理修改了其他 RTL 文件，应逐个把
明确路径加入命令。不要暂存没有出现在本指令差异审计中的文件。

推送后核对远端提交，再返回基线处理下一条：

```sh
git status --short --branch
git rev-parse HEAD
git ls-remote --heads origin "$(git branch --show-current)"
git switch zb/base
git status --short
```

切回基线后工作区必须干净。不要把当前指令分支合并进 `zb/base`。

### 6.9 验证失败或暂时阻塞

若实现已经存在但验证失败，记录真实结果：

```sh
python3 vivado/tests/zb_training/tools/zb_branch.py mark implemented "$INSN"
python3 vivado/tests/zb_training/tools/zb_branch.py verify-set fail "$INSN" \
  --note "简述失败测试、现象和最后确认的原因"
```

继续在同一分支诊断，不要另建修复分支。若需要用户决定编码、微架构或公共基线
变更，停止当前队列，保留证据并报告：指令、分支、提交/工作区状态、失败命令、
首个错误、已排除原因和建议选项。

## 7. 每类指令的重点复核

| 类别 | 指令 | 重点 |
| --- | --- | --- |
| 移位加法 | `sh1add/sh2add/sh3add` | 先移位再加，32 位截断 |
| 取反逻辑 | `andn/orn/xnor` | 只对第二操作数取反 |
| 计数 | `clz/ctz/cpop` | 输入为零时分别得到 32、32、0 |
| 最值 | `min/max/minu/maxu` | 有符号和无符号比较不能混用 |
| 扩展 | `sext.b/sext.h/zext.h` | 符号位、固定 `rs2` 编码 |
| 旋转 | `rol/ror/rori` | 移位量为 0 时避免移位 32 |
| 字节操作 | `orc.b/rev8/brev8` | `rev8` 与逐字节位反转不是同一语义 |
| 单比特 | `bclr*/bext*/binv*/bset*` | 索引只取低 5 位，立即数严格译码 |
| 打包置换 | `pack/packh/zip/unzip` | RV32 位位置和奇偶位次序 |
| 无进位乘法 | `clmul/clmulh/clmulr` | XOR 累加及 `[31:0]`、`[63:32]`、`[62:31]` |
| 交叉置换 | `xperm4/xperm8` | 每个输出元素独立索引，越界清零 |

## 8. 全部完成后的审计

查看总体状态：

```sh
python3 vivado/tests/zb_training/tools/zb_branch.py status --filter incomplete
python3 vivado/tests/zb_training/tools/zb_branch.py status --filter complete
```

最终必须显示已完成 `39/39`。随后执行：

```sh
git fetch origin
git for-each-ref --format='%(refname:short)' refs/remotes/origin/zb/
git status --short --branch
```

执行只读核对，确认以下内容：

- 39 个规范分支全部存在于 `origin`，另有公共基线 `origin/zb/base`；
- 每个分支都以 `zb/base` 为祖先；
- 每个分支只包含对应指令的 RTL 实现和必要注释；
- 每个分支均有明确的目标仿真 PASS 和基础回归 PASS 记录；
- 别名没有产生重复分支；
- `zb/base` 没有被任何单指令实现污染；
- 当前工作区干净。

完成后向用户提交汇总，至少包含：

- 完成数量，正常情况必须是 `39/39`；
- 公共基线提交号；
- 每条指令的规范分支和远端提交号；
- 每条指令的目标仿真与基础回归结果；
- 任何需要比赛现场注意的编码或实现备注；
- 最终工作区状态。

若不是 `39/39`，必须明确列出剩余指令、当前分支、失败命令、首个错误和阻塞原因，
不能宣称任务完成。
