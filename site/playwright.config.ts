import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/visual",
  fullyParallel: false,
  retries: 0,
  reporter: "line",
  expect: {
    toHaveScreenshot: {
      animations: "disabled",
      maxDiffPixelRatio: 0.001,
    },
  },
  use: {
    baseURL: "http://127.0.0.1:3000",
    browserName: "chromium",
    colorScheme: "dark",
    reducedMotion: "reduce",
    locale: "zh-CN",
    timezoneId: "Asia/Shanghai",
  },
  webServer: {
    command: "npm start",
    url: "http://127.0.0.1:3000/simulator",
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
