const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "../..");
const readyTimeoutMs = 10000;

let nvim;
let tempDir;
let nvimExit;

async function waitForFile(file, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (nvimExit) {
      throw new Error(nvimExit);
    }
    if (fs.existsSync(file)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out waiting for ${file}`);
}

test.beforeAll(async () => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "org-roam-ui-nvim-e2e-"));
  const readyFile = path.join(tempDir, "ready");
  const roamDir = path.join(tempDir, "roam");
  const logFile = path.join(tempDir, "nvim.log");
  const out = fs.openSync(logFile, "a");

  nvim = spawn(
    "nvim",
    [
      "--headless",
      "-i",
      "NONE",
      "-u",
      path.join(repoRoot, "tests", "minimal_init.lua"),
      "-c",
      `luafile ${path.join(repoRoot, "tests", "e2e", "start_server.lua")}`,
    ],
    {
      cwd: repoRoot,
      env: {
        ...process.env,
        ORUI_E2E_READY: readyFile,
        ORUI_E2E_ROAM_DIR: roamDir,
      },
      stdio: ["ignore", out, out],
    }
  );

  nvim.on("exit", (code) => {
    if (code !== null && code !== 0) {
      nvimExit = `Neovim E2E server exited with code ${code}. See ${logFile}`;
    }
  });

  try {
    await waitForFile(readyFile, readyTimeoutMs);
  } catch (err) {
    nvim.kill("SIGTERM");
    throw new Error(`${err.message}. See ${logFile}`);
  }
});

test.afterAll(async () => {
  if (nvim && !nvim.killed) {
    nvim.kill("SIGTERM");
  }
  if (tempDir) {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("renders the vendored graph UI from the Neovim backend", async ({ page }) => {
  const messages = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        messages.push(JSON.parse(frame.payload));
      } catch {
        // Ignore non-JSON frames from the browser runtime.
      }
    });
  });

  const graphResponse = await page.request.get("/graphdata");
  await expect(graphResponse).toBeOK();
  await expect(await graphResponse.json()).toMatchObject({
    nodes: [
      { id: "alpha", title: "Alpha" },
      { id: "beta", title: "Beta" },
    ],
    links: [{ source: "alpha", target: "beta", type: "id" }],
  });

  await page.goto("/");

  await expect
    .poll(() => messages.some((message) => message.type === "variables"))
    .toBe(true);
  await expect
    .poll(() =>
      messages.some(
        (message) =>
          message.type === "graphdata" &&
          message.data.nodes.some((node) => node.id === "alpha") &&
          message.data.links.some((link) => link.source === "alpha" && link.target === "beta")
      )
    )
    .toBe(true);

  const canvas = page.locator("canvas").first();
  await expect(canvas).toBeVisible();
  await expect
    .poll(async () =>
      canvas.evaluate((element) => {
        const context = element.getContext("2d");
        if (!context || element.width === 0 || element.height === 0) {
          return false;
        }

        const data = context.getImageData(0, 0, element.width, element.height).data;
        for (let index = 0; index < data.length; index += 4) {
          if (data[index] !== 255 || data[index + 1] !== 255 || data[index + 2] !== 255) {
            return true;
          }
        }
        return false;
      })
    )
    .toBe(true);
});
