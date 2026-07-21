import { expect, test, type Page } from "@playwright/test";

async function openSimulator(page: Page) {
  await page.goto("/simulator");
  await expect(page.getByLabel("CPU 功能模块原理图")).toBeVisible();
  await expect(page.locator(".trace-provenance .pass")).toHaveText("PASS");
}

test("loads only the first chunk, then crosses a chunk boundary with next-cycle", async ({ page }) => {
  const requested: string[] = [];
  page.on("request", (request) => requested.push(request.url()));
  await openSimulator(page);
  await expect.poll(() => requested.filter((url) => /t03_branch\/cycles-/.test(url)).length).toBe(1);
  expect(requested.some((url) => /cycles-000129-/.test(url))).toBe(false);
  await page.getByLabel("周期").fill("128");
  await expect(page.getByLabel("周期")).toHaveValue("128");
  const next = page.getByTitle("下一拍（→）");
  await expect(next).toBeEnabled();
  await next.click();
  await expect(page.getByLabel("周期")).toHaveValue("129");
  expect(requested.some((url) => /cycles-000129-/.test(url))).toBe(true);
});

test("cycle, scene, instruction, module and signal interactions stay coherent", async ({ page }) => {
  await openSimulator(page);
  await page.getByLabel("周期").fill("6");
  await page.locator(".visualizer-canvas").click({ position: { x: 40, y: 120 } });
  await page.keyboard.press("ArrowLeft");
  await expect(page.getByLabel("周期")).toHaveValue("5");
  await page.keyboard.press("ArrowRight");
  await expect(page.getByLabel("周期")).toHaveValue("6");

  await page.getByText("程序静态指令", { exact: false }).click();
  await expect(page.locator(".program-list article").first()).toContainText(/0x[0-9a-f]{8}/);
  await expect(page.locator(".program-list article").first()).toContainText(/执行 \d+ 次/);
  await page.locator(".instruction-list button").first().click();
  await expect(page.locator(".instruction-list button.selected")).toHaveCount(1);
  await expect(page.locator(".cpu-node.active").first()).toBeVisible();
  await expect(page.locator(".cpu-node.active", { hasText: "ID 槽 1" })).toHaveCount(0);
  await expect(page.locator(".cpu-edge.active").first()).toBeVisible();
  await page.locator(".react-flow__edge path").first().click({ force: true });
  await expect(page.locator(".signal-inspector h2")).toContainText("连线");
  await expect(page.locator(".signal-connections").first()).toBeVisible();

  await page.getByPlaceholder("ALU、L0、实例路径…").fill("forwarding_unit");
  await page.locator(".module-results button").first().click();
  await expect(page.locator(".signal-inspector header code").first()).toContainText("mycpu.");
  await page.getByLabel("搜索信号").fill("ForwardA");
  const forwardSignal = page.locator(".signal-list article", { hasText: "ForwardA" }).first();
  await expect(forwardSignal).toBeVisible();
  await forwardSignal.getByRole("button", { name: /固定 ForwardA/ }).click();
  await expect(forwardSignal.getByLabel("ForwardA 可选输入")).toBeVisible();
  await expect(forwardSignal.locator(".mux-options li.selected")).toHaveCount(1);

  await page.getByLabel("场景").selectOption("t18_m_ext_basic");
  await expect(page.locator(".trace-provenance")).toContainText("60 retired · 220 cycles");
  await expect(page.getByLabel("周期")).toHaveValue("1");
  await expect(page.locator(".instruction-list button.selected")).toHaveCount(0);
});

test("schematic zoom, drag-to-pan and fit-view are functional", async ({ page }) => {
  await openSimulator(page);
  const viewport = page.locator(".react-flow__viewport");
  const transform = () => viewport.getAttribute("style");
  const initial = await transform();

  await page.locator(".react-flow__controls-zoomin").click();
  await expect.poll(transform).not.toBe(initial);
  await page.locator(".react-flow__controls-fitview").click();

  const pane = page.locator(".react-flow__pane");
  const emptyPoint = await pane.evaluate((element) => {
    const box = element.getBoundingClientRect();
    for (let y = box.top + 24; y < box.bottom - 24; y += 24) {
      for (let x = box.left + 24; x < box.right - 24; x += 24) {
        if (document.elementFromPoint(x, y) === element) return { x, y };
      }
    }
    return null;
  });
  expect(emptyPoint).not.toBeNull();
  if (emptyPoint) {
    const beforePan = await transform();
    await page.mouse.move(emptyPoint.x, emptyPoint.y);
    await page.mouse.down();
    await page.mouse.move(emptyPoint.x + 80, emptyPoint.y + 50, { steps: 5 });
    await page.mouse.up();
    await expect.poll(transform).not.toBe(beforePan);
  }

});

test("reduced motion, keyboard playback and accessible names are available", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openSimulator(page);
  await expect(page.locator(".visualizer-shell")).toHaveClass(/reduce-motion/);
  await page.locator(".visualizer-canvas").click({ position: { x: 40, y: 120 } });
  await page.keyboard.press("Space");
  await expect(page.getByTitle("播放/暂停（空格）")).toHaveText("暂停");
  await page.keyboard.press("Space");
  await expect(page.getByTitle("播放/暂停（空格）")).toHaveText("播放");
  const unnamed = await page.locator("button").evaluateAll((buttons) => buttons.filter((button) => !(button.textContent?.trim() || button.getAttribute("aria-label") || button.getAttribute("title"))).length);
  expect(unnamed).toBe(0);
  await expect(page.getByLabel("数值格式")).toBeVisible();
});

test("long RV32M trace remains responsive when jumping into a later chunk", async ({ page }) => {
  await openSimulator(page);
  await page.getByLabel("场景").selectOption("t18_m_ext_basic");
  await expect(page.getByLabel("周期")).toHaveValue("1");
  const started = Date.now();
  await page.getByLabel("周期").fill("200");
  await expect(page.getByLabel("周期")).toHaveValue("200");
  expect(Date.now() - started).toBeLessThan(2000);
  await page.getByLabel("搜索信号").fill("EX_any_busy");
  await expect(page.locator(".signal-list article", { hasText: "EX_any_busy" })).toBeVisible();
});
