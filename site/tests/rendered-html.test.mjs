import assert from "node:assert/strict";
import test from "node:test";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}-${pathname}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request(`http://localhost${pathname}`, { headers: { accept: "text/html" } }), { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } }, { waitUntil() {}, passThroughOnException() {} });
}

test("server renders the Chinese course shell without starter metadata", async () => {
  const response = await render("/");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /lang="zh-CN"/);
  assert.match(html, /先建立一张不会迷路的 CPU 地图/);
  assert.match(html, /CPU 深度课/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/);
});

test("lesson route renders structured source-grounded content", async () => {
  const response = await render("/hazards-control");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /能前递就前递/);
  assert.match(html, /forwarding_unit/);
  assert.match(html, /引导练习/);
});

test("RTL source viewer renders real line numbers and syntax highlighting", async () => {
  const response = await render("/rtl-map");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /class="code-viewer"/);
  assert.match(html, /class="line-number"[^>]*>43</);
  assert.match(html, /class="sv-keyword">localparam</);
  assert.match(html, /class="sv-number">8</);
  assert.match(html, /class="sv-comment">\/\//);
});

test("simulator route renders the RTL-grounded visualizer shell", async () => {
  const response = await render("/simulator");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /正在校验并加载 RTL 图清单/);
  assert.doesNotMatch(html, /Your site is taking shape/);
});
