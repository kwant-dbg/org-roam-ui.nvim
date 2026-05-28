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
  create_immediate = false,
  create_node = nil,
  delete_node = nil,
  confirm_delete = nil,
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

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "org-roam-ui.nvim" })
end

local function normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function path_is_inside(path, root)
  local normalized_path = normalize_path(path)
  local normalized_root = normalize_path(root)
  return normalized_path == normalized_root or vim.startswith(normalized_path, normalized_root .. "/")
end

local function default_confirm_delete(args)
  local choice = vim.fn.confirm(
    ("Delete org-roam note file?\n%s"):format(args.file),
    "&Delete\n&Cancel",
    2,
    "Warning"
  )
  return choice == 1
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  local command_opts = { force = true }

  vim.api.nvim_create_user_command("OrgRoamUiStart", function()
    M.start()
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiStop", function()
    M.stop()
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiGraphData", function()
    local data = M.graph_data()
    vim.print(data)
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiRefresh", function()
    M.refresh()
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiFollow", function()
    M.follow_node_at_cursor()
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiSyncTheme", function()
    M.sync_theme()
  end, command_opts)

  vim.api.nvim_create_user_command("OrgRoamUiToggleFollow", function()
    M.toggle_follow()
  end, command_opts)

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
  end, command_opts)

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
  end, command_opts)

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
    create_node = M.config.create_node or M.create_node,
    delete_node = M.config.delete_node or M.delete_node,
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

function M.create_node(data)
  data = data or {}
  local roam = get_roam()
  if not roam or not roam.api or not roam.api.capture_node then
    notify_error("org-roam.nvim capture API is not available")
    return false
  end

  return roam.api.capture_node({
    title = data.title,
    origin = data.origin,
    immediate = data.immediate == true or M.config.create_immediate == true,
  })
end

function M.delete_node(data)
  data = data or {}
  if type(data.id) ~= "string" or type(data.file) ~= "string" then
    notify_error("delete command requires node id and file")
    return false
  end

  local roam = get_roam()
  if not roam or not roam.database then
    notify_error("org-roam.nvim database is not available")
    return false
  end

  local node = roam.database:get_sync(data.id)
  if not node then
    notify_error(("node not found: %s"):format(data.id))
    return false
  end

  if (node.level or 0) ~= 0 then
    notify_error("browser delete is only supported for file-level nodes")
    return false
  end

  local file = normalize_path(node.file)
  if file ~= normalize_path(data.file) then
    notify_error("delete command file does not match the node file")
    return false
  end

  local roam_dir = M.variables().roamDir
  if not path_is_inside(file, roam_dir) then
    notify_error(("refusing to delete file outside roam directory: %s"):format(file))
    return false
  end

  local bufnr = vim.fn.bufnr(file)
  if bufnr > 0 and vim.bo[bufnr].modified then
    notify_error(("refusing to delete modified buffer: %s"):format(file))
    return false
  end

  local confirm = M.config.confirm_delete or default_confirm_delete
  if not confirm({ id = data.id, file = file, node = node }) then
    return false
  end

  if vim.fn.delete(file) ~= 0 then
    notify_error(("failed to delete file: %s"):format(file))
    return false
  end

  if roam.database.load then
    return roam.database:load({ force = "scan" }):next(function()
      return true
    end)
  end

  return true
end

return M
