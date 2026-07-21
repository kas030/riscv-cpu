import type { Lesson, SourceRef } from "./types";

export const sourceRefs: SourceRef[] = [
  { id: "if-dual", label: "双发射提示与配对判定", path: "rtl/pipeline/stage/mycpu_if_stage.sv", symbol: "IF_dual_candidate / IF_issue_dual", why: "确认 256 项 hint、RAW/资源限制和冷启动单发射。" },
  { id: "predictor", label: "条件分支预测器", path: "rtl/pipeline/stage/mycpu_if_stage.sv", symbol: "branch_predictor", why: "确认 64 项 2 位 BHT、BTFNT 与 JAL 预测。" },
  { id: "decoder", label: "统一译码封装", path: "rtl/control/mycpu_decoder.sv", symbol: "mycpu_decoder", why: "从指令字段追到主控、立即数、ALU 和 CSR 控制。" },
  { id: "redirect", label: "重定向判定", path: "rtl/control/mycpu_redirect_ctrl.sv", symbol: "mycpu_redirect_ctrl", why: "区分真实 taken、预测正确和需要 flush 的误预测。" },
  { id: "m-unit", label: "RV32M 多周期单元", path: "rtl/datapath/rv32m_unit.sv", symbol: "rv32m_unit", why: "确认乘法等待、32 次除法迭代及特殊值。" },
  { id: "l0", label: "L0 load cache", path: "rtl/memory/load_l0_cache.sv", symbol: "load_l0_cache", why: "确认 64 项直接映射、完整字缓存与 store 失效。" },
  { id: "writeback", label: "load 选 lane 与写回", path: "rtl/pipeline/stage/mycpu_wb_stage.sv", symbol: "mycpu_wb_stage", why: "确认 byte/half 选择、符号扩展和五路写回。" },
  { id: "hazard", label: "load-use 冒险检测", path: "rtl/hazard/hazard_unit.sv", symbol: "hazard_unit", why: "确认两个消费者槽对 EX、MEM1 两槽 load 的检查。" },
  { id: "forward", label: "前递选择", path: "rtl/hazard/forwarding_unit.sv", symbol: "forwarding_unit", why: "确认 MEM1 > MEM2 > WB，同级槽 1 > 槽 0。" },
  { id: "pipeline-control", label: "顶层流水控制", path: "rtl/core/mycpu.sv", symbol: "Stall_Front / Flush_ID_EX_comb", why: "确认 load-use、M busy 与 pending redirect 的组合优先级。" },
];

export const lessons: Lesson[] = [
  {
    slug: "home", order: "00", kicker: "从这里开始", title: "先建立一张不会迷路的 CPU 地图",
    summary: "这不是把模块列表换成网页，而是一条从体系结构状态、逐拍流动到 RTL 落点的学习路线。读完后，你应能解释任意一条受支持指令为什么在某拍停住、从哪里取数、何时产生副作用。",
    objectives: ["分清 ISA 可见状态与微架构状态", "理解双槽顺序发射但非乱序执行", "学会沿 PC、控制、数据和 valid 四条线读 RTL"],
    sections: [
      { id: "mental-model", title: "一句话模型", lead: "每拍最多把两条连续指令送入两条槽；它们顺序向后流动，共享访存端口，在 WB 按年龄提交。", paragraphs: ["功能上可说 IF、ID、EX、MEM、WB；时序上必须记住真实边界是 IF/ID、ID/EX、EX/MEM1、MEM1/MEM2、MEM2/WB。同步 BRAM 让 MEM 被拆成 MEM1 发请求、MEM2 对齐返回。", "CPU 不含乱序调度、重命名或 ROB。所谓双发射，只是同一个顺序包里允许两条彼此安全的指令并肩前进。"], lab: "architecture" },
      { id: "contract", title: "读者与 CPU 的契约", bullets: ["复位 PC 为 0x8000_0000，IROM 提供 PC 与 PC+4 两路指令。", "支持 RV32I、RV32M，以及项目测试需要的 Zicsr、ecall 和 mret。", "仅保证自然对齐访存；没有 ready/valid、总线错误、非法指令和完整特权异常体系。", "所有 reset、bubble、flush 都必须通过 valid 或副作用使能，阻止寄存器、存储器和 CSR 的错误写入。"] },
      { id: "route", title: "推荐学习顺序", paragraphs: ["先看架构总览，再按取指发射、译码执行、访存写回、冒险控制前进。逐拍案例用于把各章重新拼成一个整体；RTL 导航适合最后拿着源码对照。"], exercise: { question: "为什么不能只按 IF→ID→EX→MEM→WB 五个名字推断 load 的返回拍？", hint: "观察同步 BRAM 与两个 MEM 流水边界。", answer: "MEM1 只发起同步读，原始数据在后续拍与 MEM2 元数据对齐，再进入 MEM2/WB；因此 load-use 和前递必须区分 MEM1、MEM2、WB。" } },
    ],
  },
  {
    slug: "architecture", order: "01", kicker: "整体架构", title: "双槽、六个功能位置、五道真实边界",
    summary: "先把指令、控制和副作用放到同一张时间图里，再讨论每个模块。",
    objectives: ["说清槽 0/槽 1 的年龄关系", "区分 hold、bubble 与 flush", "知道 valid 为什么比 NOP 更接近真实语义"],
    sections: [
      { id: "stages", title: "主数据流", paragraphs: ["IF 生成 PC、预测和最多两条指令；ID 译码并从四读口寄存器堆取数；EX 计算 ALU、地址、分支、CSR 或多周期 M；MEM1 选择唯一数据请求；MEM2 接住同步读返回；WB 形成两路最终写回值。"], lab: "architecture" },
      { id: "lanes", title: "槽不是两颗独立 CPU", bullets: ["槽 0 是包内较老指令，拥有控制流和 CSR 通路。", "槽 1 只接收 IF 已筛选的普通整数、M 或单访存指令，控制流和 CSR 在 EX 被静态关闭。", "共享数据口意味着同包最多一条 load/store；两个 M 单元存在，但同包配对仍禁止双 M。", "寄存器堆有两写口；同一 rd 的 WAW 若同包发生，较年轻槽 1 的写入成为最终状态。"] },
      { id: "valid", title: "保持、气泡、冲刷", paragraphs: ["hold 是级间寄存器不更新，原指令仍在；bubble 是向后级写入一条无副作用的空操作；flush 是宣布错误路径无效。三者不能混用，否则会重复提交、覆盖多周期指令或让错路径 store 落地。", "综合数据通路主要以控制信号清零实现无副作用；仿真统计另有逐级 valid，严格复刻同样的 stall/flush/enable 语义。"], sourceIds: ["pipeline-control"], exercise: { question: "RV32M busy 时，为什么不能用普通 load-use 的 Flush_ID_EX 处理？", hint: "ID/EX 中正放着尚未完成的 M 指令。", answer: "清空 ID/EX 会直接杀死正在运行的 M 指令。当前顶层让 EX busy 优先保持 ID/EX，并阻止 EX/MEM 接收重复结果。" } },
    ],
  },
  {
    slug: "fetch-issue", order: "02", kicker: "IF 与发射", title: "先预测下一 PC，再决定这一拍走 4 还是 8 字节",
    summary: "前端同时面对同步 IROM、双发射合法性和 PC 反馈关键路径，因此使用 hint 表把复杂配对判断移出即时反馈。",
    objectives: ["解释 hint 表的训练与命中", "解释 BHT、BTFNT 与 JAL 预测", "能判断一对预设指令是否进入同包"],
    sections: [
      { id: "pc", title: "PC 的三路选择", paragraphs: ["下一 PC 的优先级是已锁存的 EX 重定向、IF 预测目标、顺序地址。顺序地址在单发射时为 PC+4，双发射时为 PC+8。PC+4 与 PC+8 并行预计算，避免 issue_dual 驱动可变加数的长进位链。", "JAL 在 IF 直接得到目标；条件分支查 64 项 2 位饱和 BHT。未训练分支使用 BTFNT：负偏移预测 taken，正偏移预测 not-taken。JALR、ecall 和 mret 要到 EX 才知道目标。"], sourceIds: ["predictor"] },
      { id: "hint", title: "256 项双发射提示表", paragraphs: ["索引取 PC[9:2]，tag 取 PC[13:8]。冷启动或 tag 冲突时保守单发射；同步 IROM 返回两条指令后，完整配对逻辑训练对应表项，下一次命中才直接采用历史结果。", "候选条件是两条都属于允许类型、不是双访存、不是双 M，且槽 0 的 rd 不被槽 1 的 rs 字段命中。为缩短关键路径，IF 对槽 1 的 rs1/rs2 字段作保守比较，即使某些指令实际不使用该字段也可能少发射，但不会算错。"], lab: "pairing", sourceIds: ["if-dual"] },
      { id: "waw", title: "一个重要的源码事实：WAW 没有被拒绝", paragraphs: ["当前 IF 配对条件没有显式比较两个 rd。若两条可双发射指令写同一非零 rd，两个写口在同拍工作，槽 1 作为较年轻指令覆盖槽 0，仍符合顺序语义。阅读旧说明时，不要把“通常应检查 WAW”误当成当前 RTL 的实际判定。"], exercise: { question: "addi x5,x0,1 与 addi x5,x0,2 能否同包？最终 x5 是多少？", hint: "配对器只检查槽 0 的 rd 是否被槽 1 读取。", answer: "能够同包；两者不构成 RAW、双访存或双 M。两路同拍写 x5 时较年轻的槽 1 生效，最终为 2。" } },
    ],
  },
  {
    slug: "decode-execute", order: "03", kicker: "ID 与 EX", title: "控制信号在 ID 展开，真正的值在 EX 汇合",
    summary: "译码器把 32 位指令拆成寄存器索引、立即数、主控制、22 位独热 ALU 控制与 CSR 控制；EX 再结合前递值完成运算和重定向。",
    objectives: ["从 opcode/funct 追到控制信号", "理解寄存器堆同拍旁路", "理解 RV32M busy 和 CSR/trap 的边界"],
    sections: [
      { id: "decode", title: "四组并行译码", paragraphs: ["mycpu_decoder 只是封装边界：main_ctrl 产生 RegWrite、MemRead、MemWrite、MemToReg、NpcOp 与 ALU 输入选择；imm_gen 拼 I/S/B/U/J 立即数；alu_ctrl 产生 22 位独热操作；csr_ctrl_decode 识别六种 Zicsr 与 ecall/mret。", "独热 ALU 低 14 位覆盖 RV32I 算术、逻辑、比较和分支，高 8 位对应 MUL 到 REMU。load/store 地址另走 rs1+imm 加法路径，避免把地址计算压在通用 ALU 关键路径上。"], sourceIds: ["decoder"] },
      { id: "regfile", title: "四读两写寄存器堆", bullets: ["两个槽各读 rs1/rs2，共四个组合读口。", "WB 的两路写口在时钟沿提交；对 x0 的写入被屏蔽。", "读口包含 WB→ID 同周期旁路；若两写口同时命中同一读地址，槽 1 数据优先。", "EX 仍需独立前递，因为结果可能尚未到 WB。"] },
      { id: "m", title: "RV32M 不是一条统一延迟的黑盒", paragraphs: ["普通 MUL 锁存操作数后等待一个周期，高位乘法等待两个周期；DIV/DIVU/REM/REMU 使用恢复除法执行 32 次迭代。除零直接返回规范值，有符号 0x80000000 ÷ -1 也单独处理。", "任一槽 EX_busy 拉高时，PC、IF/ID、ID/EX 保持，EX/MEM 不接收新结果。完成后的 M 结果与普通 ALU 结果共用后端和前递网络。"], sourceIds: ["m-unit"] },
      { id: "redirect", title: "分支、JALR、ecall 与 mret", paragraphs: ["EX 比较真实方向/目标与随指令带来的预测元数据。只有不一致才产生 mispredict；预测正确的条件分支只更新 BHT，不冲刷流水。", "重定向先锁存一拍，再驱动 IF 和 flush，以切断 EX 比较到前端控制的长组合路径。CSR 文件只实现 mstatus、mtvec、mscratch、mepc、mcause；ecall 以 mcause=11 进入 mtvec，mret 返回 mepc。"], sourceIds: ["redirect"], exercise: { question: "一条预测 taken 且目标正确的 BEQ，在 EX 真实 taken 后会不会 flush？", hint: "区分 BranchTaken 与 BranchMispredict。", answer: "不会。它会更新 BHT，但预测方向和目标都一致，错误路径并不存在。" } },
    ],
  },
  {
    slug: "memory-writeback", order: "04", kicker: "MEM1 / MEM2 / WB", title: "一条 load 要同时穿过地址、总线时序、lane 选择和写回选择",
    summary: "共享数据口、同步 BRAM 和 L0 提前探测共同决定 load 数据何时可前递。",
    objectives: ["画出 BRAM load 的返回拍", "解释完整字缓存与子字扩展", "解释 store 写穿和失效"],
    sections: [
      { id: "port", title: "唯一数据端口", paragraphs: ["EX/MEM 保存两个槽的访存元数据；MEM1 选择真正有访存的一槽送进共享 LSU。若槽 0 不访存而槽 1 访存，MEM_use_s1_bus 选择槽 1。BRAM load 强制读取完整 32 位字；store 和 MMIO 保留原访问宽度。", "CPU 核只依赖固定返回拍数，没有 ready/valid 或错误响应。网站只讲这份接口契约，不展开 perip_bridge 内部。"] },
      { id: "l0", title: "64 项直接映射 L0", paragraphs: ["L0 以字地址索引，缓存 BRAM 的完整 32 位 load 结果，不缓存 MMIO。load 在 EX 用已寄存基址加立即数提前探测；只有基址不需要任意 EX 前递、没有更老同地址 store、没有同索引冲突 fill 时，命中才被视为下一拍可用。", "store 始终写穿外部 BRAM，并使相同字地址缓存行失效。缓存无脏行，也不改变体系结构可见的外部访问。"], sourceIds: ["l0"] },
      { id: "lanes", title: "完整字如何变成 lb/lh/lw", paragraphs: ["BRAM 原始字随地址低两位进入 WB。byte 用 offset[1:0] 选四个 lane，half 用 offset[1] 选低/高半字，随后 load_mask 根据 funct3 完成符号或零扩展。MMIO 数据已经按桥接语义返回，不重复做 BRAM lane 重排。"], lab: "load", sourceIds: ["writeback"] },
      { id: "wb", title: "五路写回与顺序提交", bullets: ["MemToReg=000：PC+4，用于 JAL/JALR 链接。", "001：ALU 或 RV32M 结果。", "010：扩展后的 load 数据。", "011：U 型立即数，用于 LUI。", "100：CSR 操作前的旧值。"], exercise: { question: "为什么 L0 保存完整字而不是保存已经符号扩展的 lb 结果？", hint: "同一字地址之后可能以不同宽度和偏移访问。", answer: "缓存完整字可让 lb/lbu/lh/lhu/lw 共用一条缓存行，偏移和扩展留在请求自己的后端元数据中完成。" } },
    ],
  },
  {
    slug: "hazards-control", order: "05", kicker: "冒险与统一控制", title: "能前递就前递，数据还没出现才停；路径错了就杀死副作用",
    summary: "冒险单元只为无法及时得到的 load 停顿，普通 ALU RAW 由三阶段、双槽前递网络解决。",
    objectives: ["手算前递优先级", "区分 L0 hit/miss 的 load-use", "解释 redirect、busy 与 load hazard 同时出现时的控制"],
    sections: [
      { id: "forward", title: "六个候选源", paragraphs: ["每个 EX 槽独立为 rs1、rs2 选择值。阶段优先级为 MEM1、MEM2、WB；同阶段槽 1 比槽 0 年轻，因此优先。若都不命中才使用 ID/EX 保存的寄存器堆读值。", "前递数据必须是该阶段真正等价于未来写回的值，不能只拿 ALU_result。L0 hit、CSR、PC+4、立即数等非普通来源也必须在合适阶段形成可前递值。"], lab: "forwarding", sourceIds: ["forward"] },
      { id: "load-use", title: "为什么 miss 通常停两拍，hit 可以零气泡", paragraphs: ["消费者在 ID、load 在 EX 时：若 EX 提前 L0 命中，下一拍可从 MEM1 前递，不停；否则触发 LoadUseEX。下一拍 load 到 MEM1，miss 数据仍未返回，再触发 LoadUseMEM。随后消费者进入 EX，并从 WB 取得最终 load 值。", "冒险比较覆盖两个消费者槽，对 ID/EX 和 EX/MEM1 中两个潜在 load 生产者逐一检查，并忽略 x0。"], sourceIds: ["hazard"] },
      { id: "priority", title: "统一控制优先级", paragraphs: ["Stall_Front 是 load hazard 或任一 EX busy。pending redirect 优先要求 Flush_ID_EX；但如果 EX busy，不能用普通 load bubble 覆盖正在运行的 M 指令。pending redirect 在前端停住时保持目标，直到可消费。"], lab: "control", sourceIds: ["pipeline-control"] },
      { id: "side-effects", title: "flush 的最终目的", paragraphs: ["flush 不是为了让波形好看，而是保证错误路径的 RegWrite、MemWrite、CSR 写和再次重定向全部为零。验证时应特别观察错路径 store，因为它比错误寄存器值更难恢复。"], exercise: { question: "MEM1 槽 1 和 MEM2 槽 0 都写同一个 rs，EX 应选谁？", hint: "先比较阶段新旧，再比较同级槽位。", answer: "选 MEM1 槽 1。MEM1 比 MEM2 更新；同阶段再由较年轻槽 1 优先。" } },
    ],
  },
  {
    slug: "walkthroughs", order: "06", kicker: "逐拍案例", title: "把每个控制信号放回它发生的那一拍",
    summary: "案例不是通用指令模拟器，而是与当前 RTL 和 verification 测试对应的可检查状态表。",
    objectives: ["逐拍指出指令所在功能位置", "识别 hold/bubble/flush", "说清最终可见副作用"],
    sections: [
      { id: "stepper", title: "流水线步进器", lead: "选择场景后用前后键或按钮逐拍观察；表格同时给出槽位、停顿、前递和副作用。", lab: "pipeline" },
      { id: "read", title: "读逐拍图的顺序", bullets: ["先看本拍 EX/MEM1 中是否有尚未可用的生产者。", "再看 IF/ID 是否保持、ID/EX 是保持还是被注入 bubble。", "随后看前递源与重定向是否在本拍生效。", "最后只统计 WB 写回与 MEM1 store 等真正的体系结构副作用。"] },
      { id: "exercise", title: "引导练习", exercise: { question: "load miss 的第二个停顿周期，为什么叫 LoadUseMEM 而不是等待 MEM2？", hint: "信号名称描述生产者当前所在级，而不是数据未来到达的位置。", answer: "此时生产者位于 EX/MEM1，hazard_unit 的 EX_MEM_MemRead 分支命中；数据会继续沿 MEM2/WB 返回，但停顿条件是在生产者仍位于 MEM1 时产生。" } },
    ],
  },
  {
    slug: "rtl-map", order: "07", kicker: "RTL 导航与参考", title: "从 mycpu 顶层沿四条线读完整工程",
    summary: "推荐按接口与控制骨架、每级功能、反馈网络、特殊单元的顺序阅读，而不是从文件名首字母开始。",
    objectives: ["建立模块到机制的索引", "能从一个信号追到生产者和消费者", "知道哪些能力不能从当前实现推断"],
    sections: [
      { id: "order", title: "推荐阅读顺序", bullets: ["先读 rtl/core/mycpu.sv 的端口、阶段分区和顶层控制赋值。", "按 IF/ID/EX/MEM/WB stage 理解组合功能，再看五组 pipeline/register 的 enable、flush 和 reset。", "回到 hazard/forwarding，逐一核对生产者阶段、槽位优先级与数据值。", "最后读 load_l0_cache、rv32m_unit、csr_file 等状态单元。"] },
      { id: "signals", title: "四条追踪线", bullets: ["PC 线：IF_pc → 预测元数据 → EX 比较 → redirect_target_q → IF。", "控制线：ID_* → EX_* → MEM_* → MEM2_* → WB_*。", "数据线：reg_file → EX 前递选择 → 结果/地址 → load 返回 → WB。", "有效性线：reset/flush/stall/busy → 控制清零与仿真 valid → 副作用。"] },
      { id: "source", title: "关键源码摘录", lead: "摘录由构建前脚本从当前 RTL 读取；若唯一标记失效，构建会失败而不是继续展示旧代码。", sourceIds: sourceRefs.map((source) => source.id) },
      { id: "boundary", title: "能力边界", bullets: ["没有 fence/fence.i、ebreak、非法指令异常、非对齐异常或总线故障异常。", "没有中断、S/U 模式、PMP、虚拟内存、SBI 或 Linux 支持。", "双发射率、CPI、load-use 气泡数和 M 延迟是微架构特征，不是软件 ABI。", "IROM 与数据总线依赖当前固定时序；替换存储系统必须增加适配。"], exercise: { question: "遇到文档与 RTL 不一致时，应该以什么为判定顺序？", hint: "本课程的生成依据已经约定。", answer: "先以当前 RTL 为实现事实，再用 verification/ 的定向测试确认行为；旧报告和注释只能作为线索。" } },
    ],
  },
];

export const lessonSlugs = lessons.map((lesson) => lesson.slug);
