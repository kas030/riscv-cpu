# 报告文档构建说明

`docs/` 中的报告使用 Markdown 编写，通过 Pandoc 和 XeLaTeX 生成 PDF。当前支持 `design-report.md`，并为后续的 `test-report.md` 预留了同一套构建入口。

## 环境要求

- Pandoc 3.7 或兼容版本
- TeX Live 2025 或兼容版本，需包含 XeLaTeX、CTeX、`pdfpages`、`titlesec`、`caption` 和 `setspace`
- 字体：宋体（SimSun）、黑体（SimHei）、Times New Roman
- PowerShell 5.1 或 PowerShell 7

可先检查：

```powershell
pandoc --version
xelatex --version
```

## 构建命令

在仓库根目录运行：

```powershell
.\docs\build.ps1
.\docs\build.ps1 -Target design
.\docs\build.ps1 -Target test
.\docs\build.ps1 -Target clean
```

默认目标为 `all`。如果尚未创建 `test-report.md`，默认构建会提示并跳过；显式构建 `test` 则会报错。PDF 输出到 `docs/build/`。

报告 YAML 元数据可用 `cover` 指定相对于 `docs/` 的封面：

```yaml
---
title-meta: RISC-V CPU 设计报告
cover: design-report-cover.pdf
---
```

封面会插入目录之前且不显示页码。目录使用罗马页码，正文从阿拉伯数字 1 开始；目录标题和页码均可点击并跳转到对应章节。

## 标题与自动编号

不要在标题文本中手写编号。一级、二级、三级标题分别写为：

```markdown
# 项目概述
## 项目背景
### 设计平台
```

Pandoc 会自动生成 `1`、`1.1`、`1.1.1` 编号并加入目录。

## 图片与表格

图片标题写在图片语法中：

```markdown
![CPU 整体架构](assets/cpu-architecture.png)
```

表格标题写在表格下方：

```markdown
| 信号 | 含义 |
|---|---|
| RegWrite | 寄存器写使能 |

Table: 主要控制信号
```

生成的图、表分别独立编号，标题格式为“图1-标题”和“表1-标题”，并置于对象下方居中。

## 公式

行内公式使用 `$...$`。需要右侧自动编号的独立公式使用原生 LaTeX `equation` 环境：

```latex
\begin{equation}
  \mathrm{CPI}=\frac{\text{总周期数}}{\text{退休指令数}}
  \label{eq:cpi}
\end{equation}
```

正文中可用 `\eqref{eq:cpi}` 引用公式编号。

## 脚注与参考文献

脚注使用标准 Markdown 语法：

```markdown
这是一处需要补充说明的内容。[^note]

[^note]: 脚注内容。
```

参考文献使用 BibTeX。创建 `docs/references.bib` 后，在报告 YAML 中声明：

```yaml
bibliography: references.bib
```

正文使用 `[@reference-key]` 引用。构建时会按 GB/T 7714-2015 顺序编码制排版，并将参考文献置于独立页面。
