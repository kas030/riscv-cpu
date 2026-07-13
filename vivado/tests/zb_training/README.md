# Zb 单指令训练示例

本目录的示例用于赛前练习，不会被上级 `Makefile` 自动编译。推荐按下面的
顺序使用材料：

1. 阅读 `docs/zb_extension_competition_guide.md`，跟着 `sh1add` 做完整流程。
2. 用 `docs/zb_all_candidate_instructions.md` 核对完整候选范围。
3. 从 `docs/zb_training_exercises.md` 选择一道题练习。
4. 独立完成后，用 `docs/zb_competition_cheatsheet.md` 做限时模拟。
5. 用 `tools/zb_tool.py` 计算编码和参考结果，避免测试与 RTL 写出同一个错误。

实际练习时，把一个 `.S` 文件复制到 `vivado/tests/tier1_basic/`，再执行：

```sh
cd vivado/tests
make clean
make t20_zb_sh1add
```

示例使用固定寄存器 `x5`、`x6`、`x7`，并以 `.word` 写入目标指令，因而不
依赖汇编器是否认识 Zba/Zbb/Zbc/Zbs/Zbkb/Zbkx 助记符。生成镜像后必须查看
`build/<测试名>.dump`，确认目标位置仍是注释标出的 32 位机器码。

每个程序最终把以下值写到 LED 地址 `0x8020_0040`：

- `0xC0DEC0DE`：通过
- `0xDEADBEEF`：失败

这些文件分别要求 CPU 已实现对应的一条指令，不应一次把全部示例合并运行。
主办方若给出不同版本的编码，以题面机器码为准。
