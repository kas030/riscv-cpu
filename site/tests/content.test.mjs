import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

test("course contains every planned route and interaction", async () => {
  const content = await readFile(new URL("app/content.ts", root), "utf8");
  for (const slug of ["home", "architecture", "fetch-issue", "decode-execute", "memory-writeback", "hazards-control", "walkthroughs", "rtl-map"]) {
    assert.match(content, new RegExp(`slug: [\"']${slug}[\"']`));
  }
  for (const lab of ["architecture", "pairing", "forwarding", "load", "control", "pipeline"]) {
    assert.match(content, new RegExp(`lab: [\"']${lab}[\"']`));
  }
});

test("all RTL excerpt ids resolve to current source", async () => {
  const [content, generated] = await Promise.all([
    readFile(new URL("app/content.ts", root), "utf8"),
    readFile(new URL("app/generated/rtl-snippets.json", root), "utf8"),
  ]);
  const snippets = JSON.parse(generated);
  const expected = ["if-dual", "predictor", "decoder", "redirect", "m-unit", "l0", "writeback", "hazard", "forward", "pipeline-control"];
  assert.deepEqual(Object.keys(snippets), expected);
  for (const id of expected) {
    assert.match(content, new RegExp(`id: [\"']${id}[\"']`));
    assert.ok(snippets[id].code.length > 80);
    assert.ok(snippets[id].path.startsWith("rtl/"));
  }
});

test("critical microarchitecture constants remain grounded", async () => {
  const [ifStage, core] = await Promise.all([
    readFile(new URL("../rtl/pipeline/stage/mycpu_if_stage.sv", root), "utf8"),
    readFile(new URL("../rtl/core/mycpu.sv", root), "utf8"),
  ]);
  assert.match(ifStage, /DUAL_HINT_INDEX_WIDTH\s*=\s*8/);
  assert.match(ifStage, /INDEX_WIDTH\s*=\s*6/);
  assert.match(core, /load_l0_cache\s*#\(\.INDEX_WIDTH\(6\)\)/);
  assert.match(core, /Stall_Front\s*=\s*Stall_Hazard\s*\|\s*EX_any_busy/);
});

test("course shell exposes keyboard, mobile navigation, exercises and reduced motion", async () => {
  const [shell, css] = await Promise.all([
    readFile(new URL("app/CourseShell.tsx", root), "utf8"),
    readFile(new URL("app/globals.css", root), "utf8"),
  ]);
  assert.match(shell, /ArrowLeft/);
  assert.match(shell, /ArrowRight/);
  assert.match(shell, /aria-expanded=\{menuOpen\}/);
  assert.match(shell, /<details className="exercise">/);
  assert.match(shell, /aria-pressed=\{reducedMotion\}/);
  assert.match(css, /@media \(max-width: 640px\)/);
  assert.match(css, /prefers-reduced-motion: reduce/);
});
