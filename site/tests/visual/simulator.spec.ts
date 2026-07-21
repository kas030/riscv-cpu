import { expect, test, type Page } from "@playwright/test";

async function openSimulator(page: Page) {
  await page.goto("/simulator");
  await expect(page.getByLabel("CPU 功能模块原理图")).toBeVisible();
  await expect(page.locator(".trace-provenance .pass")).toHaveText("PASS");
  await expect(page.locator(".cpu-node").first()).toBeVisible();
}

async function expectNoNodeOverlap(page: Page) {
  const overlaps = await page.locator(".react-flow__node").evaluateAll((nodes) => {
    const boxes = nodes.map((node) => ({ id: node.getAttribute("data-id"), rect: node.getBoundingClientRect() }));
    return boxes.flatMap((left, index) => boxes.slice(index + 1).flatMap((right) => {
      const width = Math.min(left.rect.right, right.rect.right) - Math.max(left.rect.left, right.rect.left);
      const height = Math.min(left.rect.bottom, right.rect.bottom) - Math.max(left.rect.top, right.rect.top);
      return width > 2 && height > 2 ? [`${left.id}/${right.id}`] : [];
    }));
  });
  expect(overlaps).toEqual([]);
}

test("desktop overview", async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await openSimulator(page);
  await expectNoNodeOverlap(page);
  await expect(page).toHaveScreenshot("desktop-overview.png", { fullPage: true });
});

test("common laptop overview", async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 768 });
  await openSimulator(page);
  await expectNoNodeOverlap(page);
  await expect(page.getByTitle("播放/暂停（空格）")).toBeVisible();
  await expect(page.getByLabel("周期")).toBeVisible();
  await expect(page).toHaveScreenshot("laptop-overview.png", { fullPage: true });
});

test("expanded EX hierarchy", async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await openSimulator(page);
  await page.getByPlaceholder("ALU、L0、实例路径…").fill("EX 槽 0");
  await page.locator(".module-results button").filter({ has: page.getByText("EX 槽 0", { exact: true }) }).click();
  await expect(page.locator(".cpu-node", { hasText: "ALU 0" })).toBeVisible();
  await expectNoNodeOverlap(page);
  await expect(page).toHaveScreenshot("desktop-ex-expanded.png", { fullPage: true });
});

test("expanded MEM hierarchy", async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await openSimulator(page);
  await page.getByPlaceholder("ALU、L0、实例路径…").fill("MEM1 shared bus");
  await page.locator(".module-results button", { hasText: "MEM1 shared bus" }).first().click();
  await expect(page.locator(".cpu-node", { hasText: "LSU" })).toBeVisible();
  await expectNoNodeOverlap(page);
  await expect(page).toHaveScreenshot("desktop-mem-expanded.png", { fullPage: true });
});

test("mobile starts with unobstructed schematic", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openSimulator(page);
  await expect(page.locator(".visualizer-left")).not.toBeInViewport();
  await expect(page.locator(".signal-inspector")).not.toBeInViewport();
  await expect(page).toHaveScreenshot("mobile-overview.png", { fullPage: true });
});
