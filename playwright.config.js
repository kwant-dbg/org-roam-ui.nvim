const { defineConfig } = require("@playwright/test");
const { spawnSync } = require("node:child_process");

const host = "127.0.0.1";

function assertPort(value, name) {
  const port = Number(value);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`${name} must be a TCP port number, got ${value}`);
  }
  return port;
}

function canBind(port) {
  const script = `
    const net = require("node:net");
    const server = net.createServer();
    server.once("error", () => process.exit(1));
    server.listen(${port}, "${host}", () => server.close(() => process.exit(0)));
  `;
  return spawnSync(process.execPath, ["-e", script], { stdio: "ignore" }).status === 0;
}

function selectedPort(name, used) {
  if (process.env[name]) {
    const port = assertPort(process.env[name], name);
    if (!canBind(port)) {
      throw new Error(`${name}=${port} is already in use`);
    }
    used.add(port);
    return port;
  }

  for (let attempt = 0; attempt < 100; attempt += 1) {
    const port = 30000 + Math.floor(Math.random() * 20000);
    if (!used.has(port) && canBind(port)) {
      process.env[name] = String(port);
      used.add(port);
      return port;
    }
  }

  throw new Error(`Could not find an available port for ${name}`);
}

const usedPorts = new Set();
const httpPort = selectedPort("ORUI_E2E_HTTP_PORT", usedPorts);
selectedPort("ORUI_E2E_WS_PORT", usedPorts);

module.exports = defineConfig({
  testDir: "./tests/e2e",
  timeout: 30000,
  expect: {
    timeout: 10000,
  },
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: `http://${host}:${httpPort}`,
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
