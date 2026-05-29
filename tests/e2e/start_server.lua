local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local ready_file = assert(vim.env.ORUI_E2E_READY, "ORUI_E2E_READY is required")
local roam_dir = assert(vim.env.ORUI_E2E_ROAM_DIR, "ORUI_E2E_ROAM_DIR is required")
local http_port = assert(tonumber(vim.env.ORUI_E2E_HTTP_PORT), "ORUI_E2E_HTTP_PORT is required")
local websocket_port = assert(tonumber(vim.env.ORUI_E2E_WS_PORT), "ORUI_E2E_WS_PORT is required")

vim.fn.mkdir(roam_dir, "p")

local function write_note(name, lines)
  local path = vim.fs.joinpath(roam_dir, name)
  vim.fn.writefile(lines, path)
  return path, table.concat(lines, "\n")
end

local alpha_path, alpha_text = write_note("alpha.org", {
  "#+title: Alpha",
  "* Alpha",
  "Links to Beta.",
})

local beta_path, beta_text = write_note("beta.org", {
  "#+title: Beta",
  "* Beta",
  "Back to Alpha.",
})

local function pos(offset, row, column)
  return { offset = offset, row = row or 0, column = column or 0 }
end

local nodes = {
  alpha = {
    id = "alpha",
    file = alpha_path,
    title = "Alpha",
    tags = { "e2e" },
    level = 0,
    linked = { beta = { pos(0) } },
    range = { start = pos(0), end_ = pos(#alpha_text + 1) },
  },
  beta = {
    id = "beta",
    file = beta_path,
    title = "Beta",
    tags = { "e2e" },
    level = 0,
    linked = {},
    range = { start = pos(0), end_ = pos(#beta_text + 1) },
  },
}

local database = {
  __nodes = nodes,
  files_path = function()
    return roam_dir
  end,
  get_sync = function(_, id)
    return nodes[id]
  end,
}

local orui = require("org-roam-ui-nvim")
orui.setup({
  host = "127.0.0.1",
  port = http_port,
  websocket_port = websocket_port,
  open_on_start = false,
  refresh_on_save = false,
  org_roam = {
    database = database,
  },
})
orui.start()

vim.fn.writefile({ "ready" }, ready_file)

vim.wait(600000, function()
  return false
end, 100)
