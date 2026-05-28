const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests/e2e",
  timeout: 30000,
  expect: {
    timeout: 10000,
  },
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: "http://127.0.0.1:35911",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: {
        browserName: "chromium",
      },
    },
  ],
});
