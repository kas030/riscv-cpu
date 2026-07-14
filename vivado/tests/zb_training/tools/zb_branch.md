# Zb 单指令分支管理脚本

`zb_branch.py` 复用 `zb_tool.py` 中的 39 条指令、扩展归属和别名，按需管理
`zb/<扩展>-<指令>` 分支。公共基线固定为 `zb/base`；首次打开一条尚不存在的
指令分支时，会直接从该基线创建，不会从当前单指令分支派生。

## 常用流程

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

## 命令说明

- `status [NAME] [--filter all|complete|incomplete]`：查看分支位置、实现状态、
  验证状态和总体完成度。
- `open NAME`：切换已有本地分支、跟踪已有远端分支，或从 `zb/base` 创建新分支。
- `mark implemented|pending [NAME] [--note TEXT]`：记录实现状态。省略指令名时，
  从当前分支推断。
- `verify [NAME]`：显示当前验证状态和针对目标指令展开后的验证命令。
- `verify-set pending|pass|fail [NAME] [--note TEXT]`：记录验证结果。
- `selftest`：在临时 Git 仓库验证分支和状态逻辑。

## 分支和别名

分支名中的扩展使用小写，指令名中的点转换为连字符，例如 `andn` 对应
`zb/zbb-andn`，`sext.b` 对应 `zb/zbb-sext-b`。`rev.b`、`xperm.n`、
`xperm.b` 等别名会解析到与规范名相同的分支。

`open` 要求工作区干净且本地存在 `zb/base`。若规范分支仅存在于 `origin`，它会
建立本地 tracking 分支；若本地和远端都不存在，则从 `zb/base` 新建。脚本不会
自动创建 39 个空分支，也不会自动提交或推送实现进度。

## 状态文件和完成判定

状态保存在 `$(git rev-parse --git-common-dir)/zb-branch-status.json`，不会进入
提交，并由同一仓库的所有 worktree 共享。只有目标分支存在、实现标记为
`implemented` 且验证标记为 `pass` 时，状态才是“已完成”。把实现改回
`pending` 会同步清除旧的验证结果。

状态文件采用版本化 JSON、UTF-8、原子写入和短时锁。文件损坏或版本不兼容时，
脚本会停止并提示处理，不会静默覆盖。
