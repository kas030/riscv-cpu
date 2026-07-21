# CPU 核交互式原理图与逐拍执行演示实现计划

## 文档状态

- 目标工程：当前仓库中的 `rtl/core/mycpu.sv`、`sim_cpu_only/` 与 `site/`
- 实现基线：当前 RTL 支持的 RV32I、RV32M、Zicsr、`ecall` 和 `mret`
- 首期交付形态：由真实 RTL 仿真预生成执行记录，网站静态加载并回放
- 非目标：修改 CPU 固定外部接口、改变流水线时序或在浏览器中重新实现一套 CPU 功能模型

## 背景与目标

现有网站已经包含流水线架构简介和若干手工编写的逐拍案例，但这些案例属于教学描述，并非由 RTL 自动生成。当 RTL 的冒险、前递、重定向或访存时序发生变化时，手工案例可能与真实实现不一致。

本计划新增一个交互式 CPU 可视化器，使用户能够：

1. 在网页中缩放、拖动和搜索 CPU 原理图。
2. 查看 `mycpu` 下所有已实例化功能模块及关键控制/数据连线。
3. 选择测试程序或某条动态指令，逐拍观察它经过双槽流水线的过程。
4. 查看每拍关键信号的当前值、变化、数据来源和体系结构副作用。
5. 证明页面展示的数据来自当前 RTL，并通过自动化检查阻止过期或不一致的数据进入网站。

## 范围界定

### 首期包含

- `IF/ID/EX/MEM1/MEM2/WB` 流水边界和两个顺序发射槽。
- PC、双路 IROM、发射提示表和分支预测/重定向路径。
- 两路译码、寄存器堆、立即数、ALU、RV32M 和 CSR/trap 路径。
- load-use 冒险、三阶段双槽前递、hold、bubble 和 flush。
- LSU、共享数据端口、同步 BRAM 返回、load mask 和 L0 cache。
- 两路写回、寄存器提交、store、CSR 写和重定向等副作用。
- 覆盖全部已支持指令类型的预置微程序，以及典型冒险组合。
- 桌面端完整交互和移动端只读/简化交互。

### 首期不包含

- Vivado 综合后的门级网表或布局布线视图。
- PLL、UART、twin controller、板级 IP 和完整 SoC 外设内部结构。
- 任意用户输入汇编的在线编译与实时 Verilator 服务。
- 对未实现指令、异常、中断、总线协议或 Linux 软件栈的模拟。
- 将网页动画作为新的 CPU 参考模型或验证判定来源。

### “所有模块和关键信号”的判定

“所有模块”是指当前 `mycpu` 实例树中参与 CPU 功能的所有 RTL 实例；同一模块的多个实例按实例分别展示。未实例化的源码文件、testbench 内存模型和板级模块不计入 CPU 原理图完整性。

“关键信号”由版本化清单定义，至少覆盖：

- 每个模块的功能输入、功能输出和状态更新使能。
- 所有流水级 valid、stall、flush 和 busy 信号。
- 所有体系结构副作用的使能、地址和值。
- 所有前递、冒险、预测、重定向和访存选择信号。
- 用户理解某条指令执行路径所需的数据值。

局部实现中的中间 net 可在模块详情面板中补充，但不要求全部同时画到主画布上。

## 总体技术路线

采用“RTL 产生事实、网站只做回放”的单向数据链路：

```text
汇编源码/预置镜像
        │
        ▼
sim_cpu_only Verilator 仿真
        │ 每拍采样信号、提交和存储副作用
        ▼
原始 trace JSONL
        │ 校验、指令编号、增量编码、分块
        ▼
trace manifest + trace chunks + graph manifest
        │
        ▼
site React 可视化器
        ├── 原理图缩放/拖动/搜索
        ├── 时间轴和单拍播放
        ├── 动态指令路径高亮
        └── 信号、寄存器、CSR、内存状态检查
```

不得在前端重新计算 ALU、前递、冒险或分支结果。前端允许进行格式化、筛选和显示派生，例如将 `32'h0000_002a` 同时显示为十六进制和有符号十进制，但不得用派生结果替换 RTL 采样值。

## 原理图设计

### 技术选型

- 使用 `@xyflow/react` 管理画布、缩放、拖动、节点选择、边选择、缩略图和视口定位。
- 使用自定义 SVG edge 绘制总线、控制线和动态流动效果。
- 使用自定义 React node 绘制功能模块、流水寄存器、MUX、存储单元和端口。
- `elkjs` 仅用于初始分层布局或新模块的辅助排布；最终关键位置保存在版本化布局清单中，避免每次构建产生大幅漂移。
- 页面必须支持 `prefers-reduced-motion`，减少动态效果时仅改变颜色和线宽，不播放流动动画。

### 视图层次

#### 第一级：流水线总览

展示 IF、IF/ID、ID、ID/EX、EX、EX/MEM1、MEM1、MEM1/MEM2、MEM2、MEM2/WB 和 WB，并显示双槽和主要反馈路径。

#### 第二级：功能模块

按流水级展开实际模块实例，例如：

- IF：PC、双路取指、hint 表、BHT 和下一 PC 选择。
- ID：两个 decoder、四读口两写口寄存器堆和配对元数据。
- EX：两个执行槽、ALU、两个 RV32M 单元、CSR 文件、分支比较和重定向控制。
- MEM1/MEM2：LSU、共享总线选择、L0 lookup/fill、同步返回对齐和 load mask。
- WB：两个写回 mux、两路提交和寄存器写端口。
- 反馈网络：hazard unit、两个 forwarding unit、stall/flush/busy 汇合逻辑。

#### 第三级：信号详情

点击模块或连线后，在侧栏展示：

- RTL 层次路径、位宽和信号说明。
- 当前值、上一拍值和是否发生变化。
- 生产者、消费者和所属信号组。
- 对应源码文件及行号或符号锚点。
- 对枚举/独热控制的语义解码，例如 `ForwardA=3` 对应哪个生产者。

### 视觉约定

- 槽 0 使用蓝色，槽 1 使用紫色。
- 控制线使用橙色，数据线使用蓝绿色，地址线使用深蓝色。
- 本拍有效传输使用加粗高亮；数值变化时短暂闪烁。
- hold 使用黄色边框，bubble 使用灰色虚线，flush 使用红色淡出。
- 未知值显示为 `X`，不得自动转换为 0。
- 总线标签同时显示信号名、位宽和选定显示格式。

### 图数据清单

新增一份唯一的图与信号清单，例如：

```text
tools/cpu_visualizer/manifest.json
```

清单至少包含：

```json
{
  "schemaVersion": 1,
  "modules": [],
  "ports": [],
  "edges": [],
  "signals": [],
  "groups": [],
  "layouts": {}
}
```

每条 edge 必须绑定零个或多个真实 signal ID；纯结构说明线允许无信号，但必须标记为 `static`。构建脚本应验证实例路径、信号路径、位宽、端点和引用完整性。

## RTL 逐拍数据采集

### 仿真入口

在 `sim_cpu_only/` 增加独立可视化 trace 目标，不改变现有回归默认行为：

```text
sim_cpu_only/tb_visual_trace.sv
sim_cpu_only/visual_trace_probe.sv
sim_cpu_only/run_visual_trace.sh
sim_cpu_only/visual_trace.mk
```

建议命令：

```sh
./sim_cpu_only/run_visual_trace.sh \
  vivado/tests/build/t07_forwarding.coe \
  site/public/generated/cpu-traces/t07_forwarding
```

trace testbench 复用当前行为 IROM、BRAM 和 MMIO 模型，保持与 `student_top.sv` 相同的 IROM 地址截取，以及当前 CPU-only 环境已经验证的同步 BRAM 返回拍数。

### 采样时刻

每个周期只产生一个规范化 frame。frame 必须在有效时钟上升沿之后、非阻塞赋值和组合逻辑稳定之后采样，并在 trace 元数据中注明采样语义。

禁止同时混用“时钟沿之前的组合值”和“时钟沿之后的寄存状态”。如确实需要展示沿两侧变化，应显式记录 `preEdge` 和 `postEdge` 两组数据，而不能依靠前端猜测。

### 信号分组

首期至少采集以下类别。

#### 取指与发射

- `IF_pc`、`IF_pc1`、`IF_instr`、`IF_instr1`
- `IF_issue_dual`、`ID_issue_dual`
- 预测方向、预测目标、BHT 更新和 hint 命中/训练状态

#### 流水有效性与控制

- `ID_valid/ID_S1_valid`
- `EX_valid/EX_S1_valid`
- `MEM_valid/MEM_S1_valid`
- `MEM2_valid/MEM2_S1_valid`
- `WB_retire_valid0/WB_retire_valid1`
- `Stall_Front`、`Stall_Hazard`、`LoadUseEX`、`LoadUseMEM`
- `Flush_IF_ID`、`Flush_ID_EX_comb`、`Flush_EX_MEM`
- `EX_busy`、`EX_busy_S1`、`EX_any_busy`

#### 译码与执行

- 两槽 PC、rs1、rs2、rd、立即数和寄存器读值
- 两槽 RegWrite、MemRead、MemWrite、MemToReg 和 ALU control
- 两槽 ALU 输入、ALU 结果、访存地址、store 数据和 RV32M 状态
- CSR 索引、旧值、新值、写使能、trap 原因和返回目标

#### 冒险与前递

- `ForwardA/ForwardB/ForwardA_S1/ForwardB_S1`
- 四路最终前递输入值
- MEM1、MEM2、WB 两槽的 producer valid、rd 和 forward data

#### 访存与 L0

- 共享总线来源选择、地址、写使能、mask、写数据和读数据
- BRAM/MMIO 分类和同步返回有效性
- EX probe 地址、hit、raw word 和扩展后值
- L0 lookup、fill、invalidate 的地址、索引和数据
- MEM1/MEM2 中的 load 元数据和返回数据

#### 提交与副作用

- 两槽 WB 来源、rd、wdata 和 RegWrite
- store 地址、mask、数据和所属动态指令
- CSR 写、redirect、LED/SEG/COUNTER 写等可见事件
- 每拍退休数和累计退休数

### 动态指令身份

页面需要区分循环中多次执行同一 PC 的不同动态指令。trace 后处理器为每次被前端接受的指令分配单调递增的 `instructionId`，并跟随 hold、bubble、flush 和双槽迁移。

身份跟踪只用于界面关联，不得参与 CPU 功能计算。实现时必须用以下检查降低旁路跟踪器出错风险：

- 每一级 tag 的有无必须与对应 valid 一致。
- 已退休或被 flush 的 tag 不得再次出现。
- 槽 0 和槽 1 的退休顺序必须与 issue 顺序一致。
- tag 对应 PC 必须与该级现有 PC/PC+4 元数据相符。
- stall 时保持的 tag 不变，bubble 时下一级 tag 为空。

如果旁路跟踪无法通过这些检查，trace 生成必须失败，不能退化为仅凭 PC 猜测。

## Trace 数据格式

### 元数据

每个场景包含：

- schema 版本和 graph manifest 版本。
- RTL Git commit；工作区有修改时增加 `dirty` 标记和相关源码摘要哈希。
- Verilator 版本、仿真配置和采样语义。
- IROM/BRAM 镜像哈希、入口地址和结束原因。
- 指令集范围、预期结果和实际结果。
- 总周期数、退休数、最终寄存器/CSR 摘要和关键内存摘要。

### 周期 frame

内部原始格式使用 JSONL，便于流式写出和定位失败。网站发布格式按固定周期数分块，并只保存相对上一拍发生变化的信号：

```json
{
  "cycle": 17,
  "changed": {
    "core.EX_valid": "1",
    "core.EX_pc": "80000020",
    "core.EX_alu_result": "0000002a",
    "core.ForwardA": "2"
  },
  "stages": {},
  "events": []
}
```

所有 32 位值以固定 8 位十六进制字符串保存，避免 JavaScript 有符号数和精度转换问题。未知位保留 `x/z`。小位宽控制信号可以使用二进制字符串或经 schema 约束的整数。

### 分块与加载

- trace index 单独加载，包含场景、指令和周期索引。
- 周期数据建议每 128 或 256 拍一个 chunk。
- 首次只加载当前场景的元数据和第一个 chunk。
- DIV、长程序和循环按需加载后续 chunk。
- 服务器压缩使用构建平台支持的 Brotli/gzip，不在浏览器中引入自定义解压格式作为首期依赖。

## 前端交互设计

### 页面布局

```text
┌──────────────── 顶部工具栏 ────────────────┐
│ 场景  播放/暂停  上一拍/下一拍  周期  搜索 │
├──────────────┬──────────────────┬──────────┤
│ 程序/指令列表 │ 可缩放 CPU 原理图 │ 信号检查器│
│ 动态指令状态  │ 数据流与状态高亮  │ 状态/源码  │
├──────────────┴──────────────────┴──────────┤
│ 流水线时间轴、事件标记、寄存器/CSR/内存差异 │
└────────────────────────────────────────────┘
```

### 时间控制

- 上一拍、下一拍、播放、暂停、重置和跳转到指定周期。
- 播放速度至少提供 0.25×、0.5×、1×、2× 和 4×。
- 键盘左右方向键逐拍，空格播放/暂停。
- 时间轴标记 stall、flush、redirect、L0 hit/miss、store、CSR 写和 retire。

### 指令交互

- 程序列表显示地址、机器码、反汇编和执行次数。
- 动态指令列表显示 `instructionId`、槽位、当前级和最终状态。
- 点击动态指令后仅高亮与它相关的模块、数据边和控制事件。
- 可以选择“跟随指令”，让周期自动跳转到它的下一次级间迁移。
- 被 flush 的指令必须明确标记为“未提交”，不得显示虚构写回值。
- load/store 和 CSR 指令在详情中显示体系结构地址和值与总线原始值的区别。

### 信号检查器

- 支持按名称、模块和功能分组搜索。
- 支持十六进制、无符号十进制、有符号十进制和指令解码显示。
- 支持将最多若干信号固定到观察列表。
- 对 MUX 选择信号同时高亮被选择输入，未选输入保持可见但降低透明度。
- 对前递路径显示“生产者动态指令 → 阶段/槽位 → 消费者源操作数”。

### 状态面板

- 寄存器：展示 x0—x31，改变的寄存器高亮，并标出本拍写入来源。
- CSR：展示已实现 CSR 和本拍变化。
- 内存：仅展示场景声明的观察区间和发生变化的地址。
- L0：展示 64 项 valid/tag/data，可切换仅看有效行或命中行。
- 预测器：默认只显示当前 PC 对应的 BHT/hint 表项，避免一次渲染全部状态。

## 指令与场景覆盖

### 单指令基础场景

为每个已支持指令建立最小可观察微程序，覆盖：

- RV32I 算术、逻辑、比较、移位和立即数变体。
- LUI、AUIPC、JAL、JALR。
- BEQ、BNE、BLT、BGE、BLTU、BGEU 的 taken/not-taken。
- LB、LH、LW、LBU、LHU 的不同地址 lane 和符号位。
- SB、SH、SW 的不同 mask 和地址 lane。
- MUL、MULH、MULHSU、MULHU、DIV、DIVU、REM、REMU。
- 除零和有符号除法溢出。
- CSRRW/CSRRS/CSRRC 及三个立即数变体。
- `ecall` trap 进入和 `mret` 返回。

### 微架构场景

至少覆盖：

- 两条独立 ALU 指令双发射。
- 包内 RAW 导致单发射和同 rd WAW 的顺序结果。
- MEM1/MEM2/WB 各阶段及两槽同时命中的前递优先级。
- L0 hit 的零气泡 load-use 与 miss 的两拍停顿。
- 双消费者槽依赖两个 load 生产者的组合。
- 条件分支预测正确、方向错误和目标错误。
- 错路径 store/CSR 写被 flush。
- MUL、高位乘法和 DIV busy 的不同持续时间。
- 槽 1 访存时的共享数据口选择。
- byte/half load/store 与 L0 完整字缓存的一致性。

优先复用 `vivado/tests/` 中的定向测试和 `sim_cpu_only/` 回归镜像。用于教学的短微程序单独放在 `vivado/tests/visualizer/`，不得修改已有测试来迎合页面展示。

## 正确性与一致性保证

### 数据来源门禁

- 页面发布的执行值必须来自当前 RTL 仿真 trace。
- 禁止在 `site/app/content.ts` 或 React 组件中手写逐拍信号结果。
- 网站构建时检查 trace 的 RTL 摘要是否与当前关键 RTL 文件一致。
- 摘要不一致、manifest 信号不存在或仿真未通过时，构建失败。

### RTL 仿真门禁

- 新 trace 目标必须先通过现有 CPU-only regression。
- 所有预置场景必须到达明确 PASS 结果，超时不得生成可发布 trace。
- 采集开启与关闭时，退休记录、最终寄存器状态、内存副作用和完成值必须一致。
- trace probe 不得改变 `mycpu` 固定端口、组合路径或默认综合结果。

### Trace 自一致性检查

生成阶段至少检查：

- valid 为 0 的槽不得产生寄存器、store、CSR 或 redirect 副作用。
- `x0` 不得出现有效写入。
- 同一周期最多一条真实数据总线访存。
- 同拍两槽提交符合槽 0 先于槽 1 的年龄顺序。
- 每个写回事件的值等于对应 WB mux 实际输出。
- 前递高亮的值等于被选择阶段的 forward data。
- flush 后对应动态指令不再产生任何副作用。
- store 写穿和 L0 invalidate 地址按字地址一致。

### 架构参考对拍

对不涉及项目 MMIO 特殊语义的微程序，增加与 Spike 或等价 ISA 参考模型的退休结果比较：

- 比较顺序退休 PC、指令、rd 和写回值。
- 比较声明的最终寄存器和内存区域。
- trap/CSR 场景使用与本项目 CSR 实现范围一致的参考配置。
- MMIO 场景由项目 testbench 的明确期望值负责，不直接套用通用平台模型。

### 形式验证扩展

后续可为两路顺序提交增加仿真/形式专用 RVFI 绑定，配置两个退休通道，优先证明 RV32I 指令语义和副作用顺序。形式验证是增强项，不阻塞首期可视化器上线，但可视化器不得宣称其本身构成形式正确性证明。

## 自动化测试计划

### 数据生成测试

- manifest JSON schema 校验。
- 所有信号路径和模块实例路径存在性检查。
- 采样周期单调、无重复和无缺口检查。
- 动态指令 tag 生命周期检查。
- chunk 重建结果与原始 JSONL 逐字段一致。
- 同一镜像重复生成得到相同的功能数据；时间戳等非功能元数据排除在比较外。

### 前端单元测试

- delta frame 重建完整状态。
- 32 位十六进制、有符号值和 X/Z 格式化。
- signal 到 edge/node 的映射和过滤。
- MUX/forwarding 选择解码。
- 指令状态机对 hold、bubble、flush 和 retire 的呈现。

### 前端集成测试

- 页面能加载 graph 和至少一个 trace 场景。
- 缩放、拖动、fit view、模块搜索和信号搜索可用。
- 上一拍/下一拍和时间轴跳转后信号值正确。
- 选择动态指令后只高亮对应路径。
- 切换场景不会保留上一场景的错误状态。
- 减少动态效果模式和键盘操作可用。

### RTL 回归

涉及前递、冒险、分支和访存的修改至少运行：

```sh
./sim_cpu_only/run_regression.sh
./sim_cpu_only/run_regression_t05_t08.sh
```

站点执行：

```sh
cd site
npm test
npm run lint
```

### 视觉回归

- 为总览、展开 EX、展开 MEM 和移动端布局保存基准截图。
- 检查标签遮挡、连线穿过模块、缩放后字体不可读和高亮颜色混淆。
- 视觉截图只检查展示稳定性，信号正确性仍由 trace 数据测试负责。

## 文件改动规划

建议新增或调整以下文件：

```text
docs/
  interactive-cpu-visualizer-plan.md

tools/cpu_visualizer/
  manifest.json
  manifest.schema.json
  validate_manifest.mjs
  build_trace_index.mjs

sim_cpu_only/
  tb_visual_trace.sv
  visual_trace_probe.sv
  visual_trace.mk
  run_visual_trace.sh
  visual_trace/
    README.md
    scenarios.json

vivado/tests/visualizer/
  *.S

site/app/simulator/
  page.tsx
  CpuVisualizer.tsx
  SchematicCanvas.tsx
  Timeline.tsx
  InstructionList.tsx
  SignalInspector.tsx
  StatePanels.tsx
  visualizer.css
  lib/
    trace-loader.ts
    trace-reducer.ts
    format-value.ts
    graph-model.ts

site/public/generated/cpu-visualizer/
  graph.json
  traces/index.json
  traces/<scenario>/...

site/tests/
  visualizer-data.test.mjs
  visualizer-trace.test.mjs
```

生成目录是否提交到 Git 在实现第一阶段确定。若构建环境始终具备 Verilator 和 RISC-V 工具链，可以构建时生成；否则提交经过哈希校验的发布数据，并在 CI 中重新生成后比较。

## 分阶段实施

### 阶段 0：冻结展示契约

任务：

- 盘点 `mycpu` 实例树和首期信号白名单。
- 定义 graph manifest、trace metadata 和 cycle frame schema。
- 确定采样时刻、动态指令身份和 X/Z 表示方式。
- 编写两个最小场景：独立双发射和 load-use miss。

完成条件：

- schema 通过评审并有样例数据。
- 每个展示信号都能追溯到唯一 RTL 层次路径。
- 两个场景的预期事件与现有 RTL 波形核对一致。

### 阶段 1：只读交互原理图

任务：

- 增加 `/simulator` 页面和画布组件。
- 建立流水线总览、模块分组和主要端口连线。
- 完成缩放、拖动、fit view、缩略图、搜索和层级展开。
- 增加信号分组过滤和减少动态效果支持。

完成条件：

- `mycpu` 下所有功能模块实例在图中可定位。
- 所有 manifest 边和端口均能渲染，无悬空引用。
- 桌面和移动端均可浏览，不要求此阶段播放真实数据。

### 阶段 2：RTL trace 导出

任务：

- 增加独立 visual trace 仿真目标和采样 probe。
- 导出原始 JSONL、提交事件和最终状态。
- 实现动态指令 tag、schema 校验和自一致性检查。
- 实现分块、增量编码和 trace index。

完成条件：

- 开关 trace 不改变现有测试结果。
- 两个最小场景可以稳定生成并重复比较。
- 页面不需要解析 VCD/FST 即可取得全部首期信号。

### 阶段 3：逐拍播放器

任务：

- 接入 trace loader 和完整状态重建。
- 实现逐拍、播放速度、时间轴和事件跳转。
- 将 signal 值映射到 node/edge，并实现有效数据流高亮。
- 加入指令列表、跟随指令、信号检查器和寄存器/CSR/内存面板。

完成条件：

- 页面任一显示值都能定位到 trace frame 或明确的格式化派生。
- hold、bubble、flush、retire 和双槽路径显示正确。
- 选中一条动态指令可以完整追踪到退休或被 flush。

### 阶段 4：完整指令和微架构场景

任务：

- 为全部支持指令类型补齐最小场景。
- 复用 t07/t08/t09/t18/t19 等测试补齐前递、load-use、分支、M 和 CSR/trap。
- 为每个场景增加预期提交、寄存器和内存检查。
- 完成场景索引、分类、说明和错误状态提示。

完成条件：

- 支持指令矩阵无空项。
- 所有场景通过 CPU-only 仿真和 trace 自一致性检查。
- 网站自动化测试能逐场景加载首尾 frame 并核对完成状态。

### 阶段 5：正确性门禁与发布优化

任务：

- 加入 RTL/manifest/trace 摘要校验。
- 对适用场景增加 Spike 结果比较。
- 加入视觉回归、可访问性检查和性能测量。
- 优化大 trace 分块、缓存和首次加载体积。
- 更新 `site/README.md` 和课程页面入口。

完成条件：

- RTL 或信号映射发生不兼容变化时构建能够明确失败。
- 首屏只加载 graph、场景索引和首个必要 chunk。
- 常用交互在目标浏览器中保持流畅，长 DIV 场景不会阻塞主线程。

### 可选阶段 6：任意程序在线仿真

该阶段不与静态网站首期绑定。若需要用户输入汇编：

- 部署隔离的容器服务执行汇编器、链接器和 Verilator。
- 使用固定工具链镜像、CPU/内存/时间限制和输入大小限制。
- 禁止用户控制任意编译参数、文件路径或宿主机命令。
- 使用任务 ID 轮询生成状态，完成后返回相同 trace schema。
- 对相同源码和配置按内容哈希缓存结果。

浏览器端 WebAssembly 仿真可作为独立调研项，但在证明其与 CPU-only 时序模型一致之前，不作为正确性优先的默认路线。

## 验收标准

功能验收：

- 用户可以缩放、拖动、复位视口并搜索任一 CPU 模块。
- 主图覆盖全部 CPU 功能模块，关键线可按类别筛选。
- 用户可以选择场景、周期和动态指令，并逐拍播放。
- 每拍能够查看关键控制信号、数据值、stall/flush/busy 和副作用。
- 所有已支持指令类型至少有一个可运行演示。

正确性验收：

- 页面执行数据全部由当前 RTL trace 生成。
- trace 开关不改变 CPU 最终结果或退休行为。
- 每个场景有明确 PASS 条件，超时或 FAIL 数据不能发布。
- signal、module、edge 和 trace schema 由自动化测试校验。
- RTL 摘要不匹配时网站构建失败，而不是继续显示旧数据。
- 典型前递、load-use、分支误预测、RV32M、L0 和 CSR/trap 场景与 testbench 结果一致。

可用性验收：

- 1920×1080 和常见笔记本分辨率下可以完整操作。
- 窄屏下允许折叠左右面板，原理图仍可平移和缩放。
- 键盘能够完成逐拍和播放控制。
- 减少动态效果模式下不依赖动画传达唯一信息。
- 未知值、无效值和零值有不同的可辨识表达。

## 主要风险与应对

### 原理图过密

应对：采用分层展开、信号过滤、语义总线和局部详情，不在默认视图同时显示全部内部 net。

### Trace 体积过大

应对：信号白名单、按变化记录、周期分块、按需加载和 HTTP 压缩；完整 FST 仅保留为开发调试产物。

### 页面与 RTL 漂移

应对：统一 manifest、RTL 摘要、信号存在性检查和构建失败门禁，禁止手工复制逐拍结果。

### 动态指令 tag 跟踪错误

应对：tag 与每级 valid/PC 联合断言，退休唯一性检查，失败时禁止生成发布 trace。

### 仿真模型与 Vivado 时序不一致

应对：复用当前 CPU-only IROM/BRAM/MMIO 模型，并继续用现有 Vivado 定向测试核对同步返回拍数和地址语义。

### 自动布局不稳定

应对：自动布局只产生初始坐标，关键布局落入版本化清单；测试对节点重叠和边端点做结构检查。

### “正确性保证”被误解为形式证明

应对：页面明确标注数据来源和验证级别；区分 RTL 仿真一致、参考模型对拍和形式证明三种结论。

## 建议的首个里程碑

首个可演示版本只实现两个真实 RTL 场景：

1. 两条独立 ALU 指令双发射并同拍写回。
2. `lw` L0 miss 后紧随依赖 `add`，展示 `LoadUseEX`、`LoadUseMEM` 和 WB 前递。

该里程碑必须打通完整链路：

```text
RTL 仿真 → trace 校验 → 分块数据 → 网页加载 → 原理图高亮 → 指令追踪
```

只有这条链路通过后再批量绘制模块和补齐所有指令场景，避免在数据契约尚未稳定时投入大量前端布局工作。

## 外部组件参考

- React Flow：<https://reactflow.dev/api-reference/react-flow>
- elkjs：<https://github.com/kieler/elkjs>
- Verilator tracing：<https://verilator.org/guide/latest/faq.html>
- Spike：<https://github.com/riscv-software-src/riscv-isa-sim>
- riscv-formal：<https://github.com/YosysHQ/riscv-formal>
