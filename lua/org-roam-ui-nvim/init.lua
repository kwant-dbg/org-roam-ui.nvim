local graph = require("org-roam-ui-nvim.graph")
local server = require("org-roam-ui-nvim.server")
local websocket = require("org-roam-ui-nvim.websocket")

local M = {}

local defaults = {
  host = "127.0.0.1",
  port = 35911,
  websocket_port = 35913,
  static_dir = nil,
  open_on_start = false,
  refresh_on_save = true,
  follow_on_switch = false,
  auto_sync_theme = false,
  org_roam = nil,
}

M.config = vim.deepcopy(defaults)

-- follow augroup id when auto-follow is active, nil otherwise
local follow_group = nil

-- Map org-roam-ui theme color keys to Neovim highlight groups + attribute.
local THEME_HL_MAP = {
  bg             = { "Normal",          "bg" },
  fg             = { "Normal",          "fg" },
  ["bg-alt"]     = { "NormalFloat",     "bg" },
  ["fg-alt"]     = { "Comment",         "fg" },
  base0          = { "Normal",          "bg" },
  base1          = { "StatusLine",      "bg" },
  base2          = { "CursorLine",      "bg" },
  base3          = { "Visual",          "bg" },
  base4          = { "Comment",         "fg" },
  base5          = { "NonText",         "fg" },
  base6          = { "LineNr",          "fg" },
  base7          = { "Normal",          "fg" },
  base8          = { "FloatBorder",     "fg" },
  red            = { "DiagnosticError", "fg" },
  orange         = { "WarningMsg",      "fg" },
  yellow         = { "DiagnosticWarn",  "fg" },
  green          = { "String",          "fg" },
  blue           = { "Function",        "fg" },
  cyan           = { "Type",            "fg" },
  violet         = { "Keyword",         "fg" },
  magenta        = { "Special",         "fg" },
  teal           = { "Operator",        "fg" },
  ["dark-blue"]  = { "Statement",       "fg" },
  ["dark-cyan"]  = { "Identifier",      "fg" },
  grey           = { "Comment",         "fg" },
}

local function extract_nvim_theme()
  local theme = {}
  for color_key, spec in pairs(THEME_HL_MAP) do
    local hl_name, attr = spec[1], spec[2]
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
    if ok and hl and type(hl[attr]) == "number" then
      theme[color_key] = ("#%06x"):format(hl[attr])
    end
  end
  return theme
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function default_static_dir()
  return vim.fs.joinpath(plugin_root(), "web", "org-roam-ui")
end

local function get_roam()
  if M.config.org_roam then
    return M.config.org_roam
  end

  local ok, roam = pcall(require, "org-roam")
  if not ok then
    return nil
  end

  return roam
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("OrgRoamUiStart", function()
    M.start()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiStop", function()
    M.stop()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiGraphData", function()
    local data = M.graph_data()
    vim.print(data)
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiRefresh", function()
    M.refresh()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiFollow", function()
    M.follow_node_at_cursor()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiSyncTheme", function()
    M.sync_theme()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiToggleFollow", function()
    M.toggle_follow()
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiAddToLocalGraph", function()
    local roam = get_roam()
    if not roam or not roam.utils or not roam.utils.node_under_cursor then
      return
    end
    roam.utils.node_under_cursor(function(node)
      if node then
        M.add_to_local_graph(node.id)
      end
    end)
  end, {})

  vim.api.nvim_create_user_command("OrgRoamUiRemoveFromLocalGraph", function()
    local roam = get_roam()
    if not roam or not roam.utils or not roam.utils.node_under_cursor then
      return
    end
    roam.utils.node_under_cursor(function(node)
      if node then
        M.remove_from_local_graph(node.id)
      end
    end)
  end, {})

  if M.config.refresh_on_save then
    local group = vim.api.nvim_create_augroup("org_roam_ui_nvim_refresh", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = "*.org",
      callback = function()
        local path = vim.fn.expand("%:p")
        local roam = get_roam()
        local roam_dir = M.variables().roamDir
        if not roam or not roam.database or not vim.startswith(vim.fs.normalize(path), vim.fs.normalize(roam_dir) .. "/") then
          return
        end

        pcall(function()
          roam.database:load_file({ path = path, force = true }):wait()
        end)
        M.refresh()
      end,
    })
  end

  if M.config.follow_on_switch then
    M.toggle_follow()
  end
end

function M.graph_data()
  local roam = get_roam()
  assert(roam and roam.database, "org-roam.nvim is not available")
  return graph.from_database(roam.database)
end

function M.variables()
  local roam = get_roam()
  local roam_dir = M.config.roam_dir

  if not roam_dir and roam and roam.database and roam.database.files_path then
    roam_dir = roam.database:files_path()
  end

  roam_dir = roam_dir or vim.fn.expand("~/notes/roam")

  return {
    subDirs = graph.find_subdirectories(roam_dir),
    dailyDir = M.config.daily_dir or (roam_dir .. "/daily"),
    attachDir = M.config.attach_dir or vim.fn.expand("~/notes/.attach"),
    useInheritance = M.config.use_inheritance or false,
    roamDir = roam_dir,
    katexMacros = M.config.katex_macros or {},
  }
end

function M.node_text(id)
  local roam = get_roam()
  assert(roam and roam.database, "org-roam.nvim is not available")

  local node = roam.database:get_sync(id)
  if not node then
    return nil
  end

  return graph.node_text(node)
end

function M.open_node(id)
  local roam = get_roam()
  assert(roam and roam.database, "org-roam.nvim is not available")

  local node = roam.database:get_sync(id)
  if not node then
    return false
  end

  vim.cmd.edit(vim.fn.fnameescape(node.file))

  if node.range and node.range.start then
    local row = (node.range.start.row or 0) + 1
    local col = node.range.start.column or 0
    pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
  end

  return true
end

function M.follow_node_at_cursor()
  local roam = get_roam()
  if not roam or not roam.utils or not roam.utils.node_under_cursor then
    return
  end

  roam.utils.node_under_cursor(function(node)
    if node then
      M.follow_node(node.id)
    end
  end)
end

function M.start()
  local static_dir = M.config.static_dir or default_static_dir()

  server.start({
    host = M.config.host,
    port = M.config.port,
    static_dir = static_dir,
    graph_data = M.graph_data,
    variables = M.variables,
    node_text = M.node_text,
    open_node = M.open_node,
    theme = M.theme,
  })

  websocket.start({
    host = M.config.host,
    port = M.config.websocket_port,
    graph_data = M.graph_data,
    variables = M.variables,
    node_text = M.node_text,
    open_node = M.open_node,
  })

  if M.config.open_on_start then
    vim.ui.open(("http://%s:%d"):format(M.config.host, M.config.port))
  end
end

function M.stop()
  websocket.stop()
  server.stop()
end

function M.refresh()
  websocket.broadcast_variables()
  websocket.broadcast_graphdata()
end

function M.follow_node(id)
  websocket.command("follow", { id = id })
end

function M.zoom_node(id, opts)
  opts = opts or {}
  websocket.command("zoom", {
    id = id,
    speed = opts.speed,
    padding = opts.padding,
  })
end

function M.local_node(id, opts)
  opts = opts or {}
  websocket.command("local", {
    id = id,
    speed = opts.speed,
    padding = opts.padding,
  })
end

function M.theme()
  if M.config.auto_sync_theme then
    local extracted = extract_nvim_theme()
    if next(extracted) ~= nil then
      return extracted
    end
  end
  return M.config.theme or {}
end

function M.sync_theme()
  websocket.broadcast("theme", M.theme())
end

function M.toggle_follow()
  if follow_group then
    vim.api.nvim_del_augroup_by_id(follow_group)
    follow_group = nil
  else
    follow_group = vim.api.nvim_create_augroup("org_roam_ui_nvim_follow", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = follow_group,
      pattern = "*.org",
      callback = function()
        M.follow_node_at_cursor()
      end,
    })
  end
end

function M.add_to_local_graph(id)
  websocket.command("change-local-graph", { id = id, manipulation = "add" })
end

function M.remove_from_local_graph(id)
  websocket.command("change-local-graph", { id = id, manipulation = "remove" })
end

function M.replace_local_graph(id)
  websocket.command("change-local-graph", { id = id, manipulation = "replace" })
end

return M
