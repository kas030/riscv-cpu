"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import generatedSnippets from "./generated/rtl-snippets.json";
import { CodeViewer } from "./CodeViewer";
import { lessons, sourceRefs } from "./content";
import type { LabKind, LessonSection, PipelineStage } from "./types";
import {
  analyzePair,
  instructionPresets,
  resolveControl,
  selectForward,
  selectLoad,
} from "./lib/labs.mjs";

type SnippetMap = Record<string, { path: string; line: number; code: string }>;
const snippets = generatedSnippets as SnippetMap;
const stageOrder: PipelineStage[] = ["IF", "ID", "EX", "MEM1", "MEM2", "WB"];

const stageFacts = {
  IF: { title: "IF · 取指", text: "PC、双路 IROM、hint 表与分支预测。重定向优先于预测，预测优先于顺序 PC。", signal: "IF_pc / IF_issue_dual / IF_pred_*" },
  ID: { title: "ID · 译码", text: "两个译码器并行展开控制，四读口寄存器堆提供两个槽的源数据。", signal: "ID_instr / ID_*Control / ID_rR*_data" },
  EX: { title: "EX · 执行", text: "前递在这里汇合；ALU、M、CSR、分支比较与地址生成在这里发生。", signal: "Forward* / EX_alu_result / EX_busy" },
  MEM1: { title: "MEM1 · 请求", text: "从两个槽选择唯一访存请求；L0 hit 可从这里提前前递。", signal: "MEM_* / perip_* / MEM_cache_hit" },
  MEM2: { title: "MEM2 · 对齐", text: "同步 BRAM 返回与 load 元数据对齐，完整字继续进入写回。", signal: "MEM2_mdata / MEM2_forward_data" },
  WB: { title: "WB · 提交", text: "两路五选一写回；槽 0 较老、槽 1 较年轻，x0 写入被屏蔽。", signal: "WB_wdata / WB_RegWrite" },
};

function ArchitectureLab() {
  const [selected, setSelected] = useState<PipelineStage>("EX");
  const fact = stageFacts[selected];
  return (
    <div className="lab" aria-label="CPU 流水线架构交互图">
      <div className="pipeline-strip" role="group" aria-label="选择流水级">
        {stageOrder.map((stage, index) => (
          <button key={stage} className={stage === selected ? "stage-node active" : "stage-node"} onClick={() => setSelected(stage)} aria-pressed={stage === selected}>
            <span>{stage}</span><small>{index === 0 ? "PC" : index === 5 ? "commit" : "register"}</small>
          </button>
        ))}
      </div>
      <div className="lane-lines" aria-hidden="true"><span>槽 0 · older</span><i /><span>槽 1 · younger</span><i /></div>
      <div className="lab-readout" aria-live="polite">
        <div><span className="readout-label">当前焦点</span><strong>{fact.title}</strong></div>
        <p>{fact.text}</p><code>{fact.signal}</code>
      </div>
    </div>
  );
}

function PairingLab() {
  const keys = Object.keys(instructionPresets);
  const [firstKey, setFirstKey] = useState("addi_x5");
  const [secondKey, setSecondKey] = useState("add_x6_x5");
  const first = instructionPresets[firstKey as keyof typeof instructionPresets];
  const second = instructionPresets[secondKey as keyof typeof instructionPresets];
  const result = analyzePair(first, second);
  return (
    <div className="lab">
      <div className="control-grid">
        <label>槽 0（较老）<select value={firstKey} onChange={(event) => setFirstKey(event.target.value)}>{keys.map((key) => <option key={key} value={key}>{instructionPresets[key as keyof typeof instructionPresets].label}</option>)}</select></label>
        <label>槽 1（较年轻）<select value={secondKey} onChange={(event) => setSecondKey(event.target.value)}>{keys.map((key) => <option key={key} value={key}>{instructionPresets[key as keyof typeof instructionPresets].label}</option>)}</select></label>
      </div>
      <div className={result.allowed ? "verdict pass" : "verdict stop"} aria-live="polite">
        <span>{result.allowed ? "可以双发射" : "退化为单发射"}</span>
        <strong>{result.allowed ? "PC 顺序前进 8 字节" : result.reasons[0]}</strong>
        <p>{result.note}</p>
      </div>
      {result.reasons.length > 1 && <ul className="compact-list">{result.reasons.slice(1).map((reason) => <li key={reason}>{reason}</li>)}</ul>}
    </div>
  );
}

const forwardCases = {
  newest: { label: "MEM1 槽 1 与旧结果同时命中", rs: 5, producers: { MEM1_S1: { valid: true, rd: 5 }, MEM2_0: { valid: true, rd: 5 }, WB_0: { valid: true, rd: 5 } } },
  stage: { label: "MEM2 槽 0 与 WB 槽 1 同时命中", rs: 8, producers: { MEM2_0: { valid: true, rd: 8 }, WB_S1: { valid: true, rd: 8 } } },
  none: { label: "没有在途生产者", rs: 6, producers: { MEM1_0: { valid: true, rd: 7 } } },
};

function ForwardingLab() {
  const [caseKey, setCaseKey] = useState<keyof typeof forwardCases>("newest");
  const item = forwardCases[caseKey];
  const selected = selectForward(item.rs, item.producers);
  return (
    <div className="lab">
      <label className="single-control">消费者与生产者组合<select value={caseKey} onChange={(event) => setCaseKey(event.target.value as keyof typeof forwardCases)}>{Object.entries(forwardCases).map(([key, value]) => <option key={key} value={key}>{value.label}</option>)}</select></label>
      <div className="priority-track" aria-label="前递优先级从高到低">
        {["MEM1 S1", "MEM1 0", "MEM2 S1", "MEM2 0", "WB S1", "WB 0", "REGFILE"].map((label) => <span key={label} className={label.replace(" ", "_") === selected ? "chosen" : ""}>{label}</span>)}
      </div>
      <p className="lab-result">rs = x{item.rs}，选择 <strong>{selected}</strong>。比较顺序固定，不由数据值大小决定。</p>
    </div>
  );
}

function LoadLab() {
  const [wordText, setWordText] = useState("80ff7f01");
  const [offset, setOffset] = useState(0);
  const [width, setWidth] = useState<"byte" | "half" | "word">("byte");
  const [unsigned, setUnsigned] = useState(false);
  const sanitized = wordText.replace(/[^0-9a-f]/gi, "").slice(0, 8) || "0";
  const word = Number.parseInt(sanitized, 16) >>> 0;
  const result = selectLoad(word, offset, width, unsigned);
  return (
    <div className="lab">
      <div className="control-grid three">
        <label>缓存完整字<input value={wordText} onChange={(event) => setWordText(event.target.value)} inputMode="text" aria-label="十六进制缓存字" /></label>
        <label>地址低两位<select value={offset} onChange={(event) => setOffset(Number(event.target.value))}>{[0, 1, 2, 3].map((value) => <option value={value} key={value}>{value}</option>)}</select></label>
        <label>访问宽度<select value={width} onChange={(event) => setWidth(event.target.value as "byte" | "half" | "word")}><option value="byte">byte</option><option value="half">half</option><option value="word">word</option></select></label>
      </div>
      <label className="check"><input type="checkbox" checked={unsigned} disabled={width === "word"} onChange={(event) => setUnsigned(event.target.checked)} /> 零扩展（lbu/lhu）</label>
      <div className="byte-lanes" aria-label={`完整字 0x${word.toString(16).padStart(8, "0")} 的四个字节`}>
        {[3, 2, 1, 0].map((lane) => <span key={lane} className={width === "word" || lane === offset || (width === "half" && Math.floor(lane / 2) === Math.floor(offset / 2)) ? "selected" : ""}><small>+{lane}</small>{((word >>> (lane * 8)) & 0xff).toString(16).padStart(2, "0")}</span>)}
      </div>
      <p className="lab-result">写回结果：<strong>0x{result.toString(16).padStart(8, "0")}</strong></p>
    </div>
  );
}

function ControlLab() {
  const [redirectPending, setRedirect] = useState(false);
  const [exBusy, setBusy] = useState(false);
  const [loadHazard, setHazard] = useState(true);
  const state = resolveControl({ redirectPending, exBusy, loadHazard });
  return (
    <div className="lab">
      <div className="check-row">
        <label className="check"><input type="checkbox" checked={redirectPending} onChange={(e) => setRedirect(e.target.checked)} /> pending redirect</label>
        <label className="check"><input type="checkbox" checked={exBusy} onChange={(e) => setBusy(e.target.checked)} /> EX busy</label>
        <label className="check"><input type="checkbox" checked={loadHazard} onChange={(e) => setHazard(e.target.checked)} /> load-use</label>
      </div>
      <div className="signal-grid">
        <span><small>Stall_Front</small><strong>{Number(state.stallFront)}</strong></span>
        <span><small>Flush_IF_ID</small><strong>{Number(state.flushIfId)}</strong></span>
        <span><small>Flush_ID_EX</small><strong>{Number(state.flushIdEx)}</strong></span>
      </div>
      <p className="lab-result">{state.action}</p>
    </div>
  );
}

function PipelineLab() {
  return (
    <div className="lab pipeline-lab">
      <div className="section-number">REAL RTL TRACE</div>
      <h3>逐拍案例已经迁移到真实 RTL 播放器</h3>
      <p>播放器中的值、动态指令身份、停顿、冲刷和副作用全部来自 Verilator 采样；课程正文不再保存手写逐拍结果。</p>
      <Link className="simulator-launch" href="/simulator">打开交互式 CPU 原理图与逐拍播放器 →</Link>
    </div>
  );
}

function Lab({ kind }: { kind: LabKind }) {
  if (kind === "architecture") return <ArchitectureLab />;
  if (kind === "pairing") return <PairingLab />;
  if (kind === "forwarding") return <ForwardingLab />;
  if (kind === "load") return <LoadLab />;
  if (kind === "control") return <ControlLab />;
  return <PipelineLab />;
}

function SourceExcerpt({ id }: { id: string }) {
  const source = sourceRefs.find((item) => item.id === id);
  const snippet = snippets[id];
  if (!source || !snippet) return null;
  return (
    <details className="source-block">
      <summary><span>{source.label}</span><code>{source.path}:{snippet.line}</code></summary>
      <p>{source.why}</p><CodeViewer code={snippet.code} startLine={snippet.line} />
    </details>
  );
}

function Section({ section }: { section: LessonSection }) {
  return (
    <section id={section.id} className="lesson-section">
      <div className="section-number">{section.id.replace(/-/g, " · ")}</div><h2>{section.title}</h2>
      {section.lead && <p className="lead">{section.lead}</p>}
      {section.paragraphs?.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
      {section.bullets && <ul>{section.bullets.map((bullet) => <li key={bullet}>{bullet}</li>)}</ul>}
      {section.code && <CodeViewer code={section.code} />}
      {section.lab && <Lab kind={section.lab} />}
      {section.sourceIds?.map((id) => <SourceExcerpt id={id} key={id} />)}
      {section.exercise && <details className="exercise"><summary>引导练习 · {section.exercise.question}</summary><p><strong>提示：</strong>{section.exercise.hint}</p><p className="answer"><strong>答案：</strong>{section.exercise.answer}</p></details>}
    </section>
  );
}

export function CourseShell({ slug }: { slug: string }) {
  const lesson = useMemo(() => lessons.find((item) => item.slug === slug) ?? lessons[0], [slug]);
  const [menuOpen, setMenuOpen] = useState(false);
  const [reducedMotion, setReducedMotion] = useState(false);
  const currentIndex = lessons.findIndex((item) => item.slug === lesson.slug);
  return (
    <div className={reducedMotion ? "site-shell reduce-motion" : "site-shell"}>
      <header className="mobile-header"><Link href="/" className="mobile-brand">RV32 · LAB</Link><button onClick={() => setMenuOpen((value) => !value)} aria-expanded={menuOpen} aria-controls="course-nav">{menuOpen ? "关闭" : "目录"}</button></header>
      <aside id="course-nav" className={menuOpen ? "sidebar open" : "sidebar"}>
        <Link href="/" className="brand" onClick={() => setMenuOpen(false)}><span className="brand-mark">RV</span><span><strong>CPU 深度课</strong><small>RTL-grounded course</small></span></Link>
        <nav aria-label="课程章节">{lessons.map((item) => <Link href={item.slug === "home" ? "/" : `/${item.slug}`} className={item.slug === lesson.slug ? "nav-link active" : "nav-link"} key={item.slug} onClick={() => setMenuOpen(false)}><span>{item.order}</span><strong>{item.title}</strong></Link>)}</nav>
        <button className="motion-toggle" onClick={() => setReducedMotion((value) => !value)} aria-pressed={reducedMotion}>{reducedMotion ? "已减少动态效果" : "减少动态效果"}</button>
        <p className="authority">实现依据<br /><code>rtl/ @ current workspace</code></p>
      </aside>
      <main>
        <article>
          <header className="hero"><div className="eyebrow"><span>{lesson.order}</span>{lesson.kicker}</div><h1>{lesson.title}</h1><p>{lesson.summary}</p><div className="objective-row">{lesson.objectives.map((objective) => <span key={objective}>{objective}</span>)}</div></header>
          {lesson.slug === "home" && <div className="course-map"><div className="map-label">LEARNING PATH</div><Link href="/simulator" className="simulator-map-link"><span>LIVE</span><div><strong>交互式 CPU 原理图与 RTL Trace</strong><p>搜索全部功能实例，逐拍回放由当前 Verilator 仿真生成的真实执行记录。</p></div><b>↗</b></Link>{lessons.slice(1).map((item) => <Link href={`/${item.slug}`} key={item.slug}><span>{item.order}</span><div><strong>{item.title}</strong><p>{item.summary}</p></div><b>→</b></Link>)}</div>}
          {lesson.sections.map((section) => <Section section={section} key={section.id} />)}
          <footer className="lesson-footer">
            {currentIndex > 0 ? <Link href={currentIndex === 1 ? "/" : `/${lessons[currentIndex - 1].slug}`}>← {lessons[currentIndex - 1].title}</Link> : <span />}
            {currentIndex < lessons.length - 1 ? <Link className="next" href={`/${lessons[currentIndex + 1].slug}`}>{lessons[currentIndex + 1].title} →</Link> : <Link className="next" href="/">回到课程地图 ↑</Link>}
          </footer>
        </article>
      </main>
    </div>
  );
}
