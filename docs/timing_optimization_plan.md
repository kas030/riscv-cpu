# RV32I CPU 时序优化 Agent 工作计划

## 0. 工作流

本文档用于后续让 agent 分阶段修改 RTL。默认协作方式固定为：

```text
agent：分析当前阶段 -> 修改 RTL -> 做语法/静态检查 -> 汇报改动和风险
人工：跑 Verilator 功能验证 -> 跑 Vivado 综合/实现 -> 提供 timing report/结果
agent：根据人工结果判断下一阶段或修正当前阶段
```

agent 不默认运行 Verilator、综合或实现。

当前总体目标：

```text
先让 150 MHz routed timing 收敛
  -> 再提高 timing 余量和实现稳定性
  -> 最后用 cache/预取降低 BRAM 相关 CPI
```

当前第一优先级不是 cache，而是切断 CPU 内部 EX/forwarding/branch flush 长路径。

## 1. 基本边界

- `rtl/core/mycpu.sv` 对外端口固定，不改名、不改宽度、不改方向。

- 保持 `rf_inst` 等 testbench 依赖的层次名。
- 保持 flush/reset 注入无副作用 bubble 的语义。
- 不自动 commit，除非用户明确要求。

其他实现细节允许 agent 在阶段目标内自行权衡，例如增加流水级、增加寄存器、
复制控制信号、牺牲分支/load 惩罚或使用更多资源。

## 2. Baseline timing

当前人工已完成综合和实现，baseline report：

- `vivado/digital_twin.runs/impl_1/top_timing_summary_routed.rpt`

关键数据：

- CPU clock：`clk_out2_pll`
- Period：`6.667 ns`
- Target：`150 MHz`
- WNS：`-1.585 ns`
- TNS：`-494.188 ns`
- Setup failing endpoints：`398`
- Hold：无失败

最差路径概要：

```text
Source:
  student_top_inst/Core_cpu/u_ex_mem_reg/MEM_rd_oh_reg[16]/C

Destination:
  student_top_inst/Core_cpu/u_id_ex_reg/EX_rR2_data_reg[21]/R

Data Path Delay:
  7.848 ns
  logic 2.373 ns
  route 5.475 ns

Logic Levels:
  26
```

路径功能归类：

```text
MEM_rd_oh
  -> forwarding_unit
  -> EX_forward_A/B mux/hold
  -> alu_in_a/b
  -> ALU/branch compare
  -> IF_npc_redirect / BranchMispredict
  -> Flush_ID_EX / ID_EX reset
```

判断：

- 第一关键路径不是 BRAM。
- 第一关键路径是前递、EX 执行、分支重定向、flush 控制串联太长。
- cache/预取留到主频路径收敛后再做。

## 3. 阶段 1：redirect/flush 打拍

### 目标

先切断最差路径尾部：

```text
ALU/branch compare -> BranchMispredict -> Flush_ID_EX -> ID/EX reset
```

### 实现方向

把 EX 组合产生的 redirect/flush 信息打一拍后提交：

```text
EX 计算 redirect_valid/raw_target/raw_taken
  -> redirect_valid_q / redirect_target_q
  -> 下一拍驱动 IF redirect 和流水 flush
```

可接受代价：

- branch/jal/jalr/ecall/mret 惩罚增加 1 拍。

优先关注文件：

- `rtl/core/mycpu.sv`
- `rtl/pipeline/stage/mycpu_ex_stage.sv`
- `rtl/hazard/hazard_unit.sv`
- `rtl/pipeline/register/mycpu_if_id_reg.sv`
- `rtl/pipeline/register/mycpu_id_ex_reg.sv`

实现关注点：

- redirect 与 `EX_busy`、`Stall_DMemLoad` 同时出现时不能丢。
- 错误路径指令不能产生 RegWrite/MemWrite。
- 若 flush 仍走 reset/R 端导致 timing 差，可以改为 bubble 数据 mux。

人工验证关注点：

- taken branch、not-taken branch。
- `jal`、`jalr`、`ecall`、`mret`。
- load stall 与 branch redirect 相邻或同时出现。
- 新 timing 中最差路径是否还终止在 `u_id_ex_reg/*/R`。

进入下一阶段条件：

- 人工确认功能通过。
- 新 timing 显示最差路径已离开 branch flush reset，或该路径明显改善。

若失败：

- 若功能失败，修正 redirect/flush 优先级。
- 若 timing 仍卡在 flush/reset，把 ID/EX 运行期 flush 改为 bubble mux 或做控制复制。

## 4. 阶段 2：EX 前递与 ALU 拆级

### 当前状态

阶段 1 已完成 redirect/flush 打拍，人工验证结果：

- Verilator regression 全部通过：`default`、`t03_branch`、
  `t09_branch_hazard`、`t19_zicsr_trap`、`perf_test`。
- 新 routed timing：
  - WNS：`-0.423 ns`
  - TNS：`-25.843 ns`
  - Setup failing endpoints：`82`
  - Hold：无失败

阶段 1 已明显改善 baseline `WNS -1.585 ns / TNS -494.188 ns / 398`
个失败端点，但 150 MHz routed timing 仍未收敛。

新最差路径概要：

```text
Source:
  student_top_inst/Core_cpu/u_ex_mem_reg/MEM_rd_oh_reg[11]/C

Destination:
  student_top_inst/Core_cpu/redirect_taken_q_reg/CE
  或 redirect_target_q_reg[*]/CE / redirect_valid_q_reg/D

Data Path Delay:
  6.808 ns
  logic 2.149 ns
  route 4.659 ns

Logic Levels:
  22
```

路径功能归类：

```text
MEM_rd_oh
  -> forwarding_unit
  -> EX_forward_A/B mux/hold
  -> alu_in_a/b
  -> ALU/branch compare/jalr target
  -> redirect capture registers
```

判断：

- 最差路径已离开 `u_id_ex_reg/*/R` 的 flush/reset 尾部。
- 当前瓶颈仍是 `forwarding -> EX 执行 -> redirect capture`，不是 BRAM。
- 虽然 route delay 占比约 68%，但 logic levels 仍有 22/23，尚不宜直接转
  阶段 3 做控制网复制。
- 下一步应进入阶段 2，优先切断 forwarding 到 EX 执行/redirect capture 的
  组合链。

### 目标

切断阶段 1 后的新最差路径：

```text
MEM_rd_oh
  -> forwarding_unit
  -> EX_forward_A/B
  -> alu_in_a/b
  -> ALU/branch compare/jalr target
  -> redirect capture
```

### 实现方向

先做“阶段 2 前半步”：将 EX 拆成 `EX1` 和 `EX2`，目标是最小化改动面并
尽快验证 timing 是否收敛：

```text
ID/EX
  -> EX1: forwarding compare + operand mux + operand/store-data latch
  -> EX1/EX2 reg
  -> EX2: ALU + branch/jalr/csr redirect + RV32M handling
  -> EX/MEM
```

推荐新增一级 `EX1/EX2` 流水寄存器：

- EX1 锁存前递后的 `rs1`、`rs2`、ALU A/B operand、store data、PC、imm、
  rd、控制信号和预测信息。
- EX2 只使用 EX1/EX2 寄存后的 operand 做 ALU、branch compare、jalr target、
  csr redirect 与 redirect capture。
- redirect 仍按阶段 1 的打一拍提交方式处理，必要时保留 pending 语义。
- EX2 产生的错误路径 flush 需要覆盖 IF/ID、ID/EX，以及新增 EX1/EX2 中的
  错路径指令。

可接受代价：

- branch 惩罚增加。
- load-use 多 stall。
- 增加大量寄存器和旁路控制。

优先关注文件：

- `rtl/core/mycpu.sv`
- `rtl/pipeline/stage/mycpu_ex_stage.sv`
- `rtl/pipeline/register/mycpu_id_ex_reg.sv`
- `rtl/pipeline/register/mycpu_ex_mem_reg.sv`
- 可新增 `rtl/pipeline/register/mycpu_ex1_ex2_reg.sv`
- `rtl/hazard/forwarding_unit.sv`
- `rtl/hazard/hazard_unit.sv`

实现关注点：

- store data 独立于 ALU B operand 保存。
- forwarding 优先级仍是最近结果优先。
- load-use stall 拍数需要重新审计。
- branch 解析阶段后移后，flush 范围要同步调整到 IF/ID、ID/EX、EX1/EX2。
- RV32M busy 要冻结正确阶段，不能让 ID/EX 或 EX1/EX2 覆盖正在执行的 M 指令。
- `EX_kill` / redirect pending 语义要保留，错误路径 CSR 写入、M 指令启动和
  MemWrite/RegWrite 不能提交。
- 若仅拆 operand latch 后最差路径仍终止到 redirect capture，可继续把
  redirect capture 的 CE/D 条件简化或复制。

人工验证关注点：

- `t07_forwarding.S`
- `t08_load_use.S`
- `t09_branch_hazard.S`
- `t19_zicsr_trap.S`
- `t18_m_ext_basic` 或等价 M 扩展测试。
- ALU -> ALU、ALU -> store、ALU -> jalr。
- load -> ALU、load -> store、load -> branch。
- 新 timing 中是否还存在完整 `forwarding -> ALU -> branch -> flush` 链。
- 新 timing 中最差路径是否仍从 `MEM_rd_oh` 终止到 redirect capture 寄存器。

进入下一阶段条件：

- 人工确认功能通过。
- 150 MHz timing 收敛，或最差路径已转移到 route/high-fanout、RV32M、IF/PC 等其他类别。

若失败：

- 若功能失败，优先修正 EX1/EX2 flush、stall、forwarding 与 RV32M busy 语义。
- 若 timing 仍卡在 `MEM_rd_oh -> forwarding -> redirect capture`，继续阶段 2，
  考虑进一步寄存 forwarding 选择或简化 redirect capture 使能。
- 若 logic levels 已明显下降但 route delay 仍主导，再进入阶段 3。

## 5. 阶段 3：控制网和高扇出优化

### 目标

当 logic levels 已下降但 route delay 仍高时，降低扇出和布线压力。

### 实现方向

- 复制或分组寄存 `Flush_IF_ID`、`Flush_ID_EX`、`Stall_Front`、
  `BranchMispredict`。
- 运行期 flush 尽量用 bubble mux，不让单一控制网驱动大量 reset/R 端。
- 对 PC 高扇出用途做局部副本，例如 IROM 地址、预测器索引、IF/ID PC。

优先关注文件：

- `rtl/core/mycpu.sv`
- `rtl/pipeline/register/*.sv`
- `rtl/pipeline/stage/mycpu_if_stage.sv`
- `rtl/hazard/hazard_unit.sv`

人工验证关注点：

- high fanout report 中 CPU 控制网是否下降。
- WNS 是否有余量，建议目标 `WNS >= 0.5 ns`。
- reset、branch flush、load stall 语义是否保持。

## 6. 阶段 4：RV32M 宽乘法器处理

### 目标

如果最差路径或拥塞与 `product_uu_fast`、宽乘法器或 DSP 周边相关，处理 M 扩展。

### 实现方向

选择一种即可：

- 迭代乘法：牺牲乘法延迟，避免大组合乘法器，最利于收敛。
- DSP pipeline：输入/输出寄存，固定多拍返回，用 DSP 换性能。
- 16x16 分块乘法：部分积流水相加，用 LUT/DSP 换频率。

优先关注文件：

- `rtl/pipeline/stage/mycpu_ex_stage.sv`
- 可新增独立 M 单元文件，但要确保 Vivado 工程能加入该源文件。

人工验证关注点：

- `mul`、`mulh`、`mulhsu`、`mulhu`。
- `div`、`divu`、`rem`、`remu`。
- 除零。
- `INT_MIN / -1`。
- `EX_busy` 是否正确冻结流水。

## 7. 阶段 5：IF/PC 路径优化

### 目标

如果最差路径转移到 IF、PC 或 branch predictor，缩短 next PC 路径。

### 实现方向

- 增加小型 BTB，用 PC index 读取 `valid/tag/target/taken`。
- IF 不再依赖 `IF_instr` 组合解析 branch immediate 来预测 target。
- redirect 永远优先于预测。

优先关注文件：

- `rtl/pipeline/stage/mycpu_if_stage.sv`
- `rtl/core/mycpu.sv`
- `rtl/pipeline/register/mycpu_if_id_reg.sv`

人工验证关注点：

- `t09_branch_hazard.S`。
- 预测命中、tag miss、redirect flush 后 PC/指令对齐。
- IF/PC 是否离开 top critical path。

## 8. 阶段 6：BRAM cache / 预取 / load buffer

### 目标

主频收敛后降低 CPI，减少同步 BRAM load stall。

### 前置条件

- 人工确认 150 MHz routed timing 已收敛，或用户明确要求先做 cache。
- 当前最差路径不再是 EX/forwarding/branch flush。

### 推荐顺序

1. 指令预取 buffer。
2. 小型 I-cache。
3. 小型 D-cache 或 load buffer。
4. store buffer。

关注点：

- MMIO 不能缓存。
- `perip_bridge.sv` 地址映射是权威。
- BRAM 范围：`0x8010_0000 <= addr < 0x8013_FFFF`。
- store 到 LED/SEG/COUNTER 必须保持可见顺序。
- flush/redirect 后错误路径访存请求不能提交。

人工验证关注点：

- CPI 或性能计数是否改善。
- MMIO 行为是否保持。
- timing 是否因 cache 控制逻辑重新失败。

## 9. 阶段选择规则

人工完成 Verilator、综合和实现后，把新结果交给 agent。agent 按以下规则选下一步：

- 若功能失败，先修功能，不进入下一阶段。
- 若 WNS 失败且最差路径含 `BranchMispredict`、`Flush_ID_EX` 或 ID/EX reset，
  继续阶段 1。
- 若 WNS 失败且最差路径含 `forwarding_unit`、`EX_forward_A/B`、`alu_in_a/b`，
  进入或继续阶段 2。
- 若 WNS 失败但 route delay 占比高、logic levels 不高，进入阶段 3。
- 若 WNS 失败且路径含 `product_uu_fast`、乘法器或 DSP 周边，进入阶段 4。
- 若 WNS 失败且路径在 IF/PC/branch predictor，进入阶段 5。
- 若 WNS 已收敛但 CPI 受取指或 load stall 限制，进入阶段 6。

## 10. 当前推荐下一步

下一次 agent 实现应进入阶段 2：

```text
EX 前递与 ALU 拆级
  -> agent 做 RTL 修改和语法检查
  -> 人工跑 Verilator 功能验证
  -> 人工跑综合/实现
  -> 根据新 timing 判断是否继续阶段 2 或进入阶段 3
```
