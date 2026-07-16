## Linux 下的技术文档兼容配置

仓库正式配置使用 Times New Roman、宋体和黑体，定义在
`pandoc/report.yaml` 与 `pandoc/report-style.tex` 中。Linux 系统一般没有这些
Windows 字体。本项目在 Debian 13 上构建技术文档时使用下列替代字体：

| 用途 | 正式字体 | Linux 替代字体 |
|---|---|---|
| 英文与数字正文 | Times New Roman | Liberation Serif |
| 中文正文 | SimSun | Noto Serif CJK SC |
| 中文标题 | SimHei | Noto Sans CJK SC |
| 英文代码 | 未单独指定 | Noto Sans Mono |
| 中文代码 | 未单独指定 | Noto Sans Mono CJK SC |

Table: Linux 技术文档字体替代

该配置只用于 Linux 兼容构建，不修改仓库正式样式。已验证的工具版本为 Pandoc
3.10 和 TeX Live 2025。先在 `docs/` 目录生成临时配置：

```sh
cp pandoc/report.yaml /tmp/riscv-report-linux.yaml
cp pandoc/report-style.tex /tmp/riscv-report-style-linux.tex

sed -i \
  's#pandoc/report-style.tex#/tmp/riscv-report-style-linux.tex#;
   s#Times New Roman#Liberation Serif#;
   s#SimSun#Noto Serif CJK SC#;
   s#SimHei#Noto Sans CJK SC#' \
  /tmp/riscv-report-linux.yaml

sed -i \
  '/CJKsansfont: Noto Sans CJK SC/a\  monofont: Noto Sans Mono' \
  /tmp/riscv-report-linux.yaml

sed -i \
  's/{SimHei}/{Noto Sans CJK SC}/;
   /\\newCJKfontfamily\\reportheiti/a\
\\setCJKmonofont{Noto Sans Mono CJK SC}\
\\AtBeginEnvironment{verbatim}{\\footnotesize\\setstretch{1.0}}' \
  /tmp/riscv-report-style-linux.tex
```

英文代码使用独立的 `Noto Sans Mono`，不使用拉丁字形较宽的 CJK 合并版本。
中文代码由 `Noto Sans Mono CJK SC` 补充。块级代码和字符图使用
`\footnotesize` 和单倍行距，避免等宽字体变宽后超出正文宽度，并使字符图的
纵向连线保持紧凑；正文中的行内代码仍使用原字号和正文行距。

随后构建技术文档：

```sh
mkdir -p build
pandoc technical-report.md \
  --defaults=/tmp/riscv-report-linux.yaml \
  --output=build/technical-report.pdf
```

生成文件为 `docs/build/technical-report.pdf`。`/tmp` 可能在重启后被清理，遇到临时
配置不存在时，重新执行上述命令即可。
