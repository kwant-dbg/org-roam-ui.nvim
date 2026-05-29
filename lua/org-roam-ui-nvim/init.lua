local graph = require("org-roam-ui-nvim.graph")
local server = require("org-roam-ui-nvim.server")
local websocket = require("org-roam-ui-nvim.websocket")

local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  host = "127.0.0.1",
  port = 35911,
  websocket_port = 35913,
  static_dir = nil,
  open_on_start = false,
  refresh_on_save = true,
  follow_on_switch = false,
  follow_debounce_ms = 100,
  auto_sync_theme = false,
  org_roam = nil,
  create_immediate = false,
  roam_dir = nil,
  daily_dir = nil,
  attach_dir = nil,
  use_inheritance = false,
  katex_macros = vim.empty_dict(),
  theme = vim.empty_dict(),
  create_node = nil,
  delete_node = nil,
  confirm_delete = nil,
}

M.config = vim.deepcopy(defaults)

-- follow augroup id when auto-follow is active, nil otherwise
local follow_group = nil
local follow_timer = nil

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

local function get_roam_dir()
  local roam = get_roam()
  local roam_dir = M.config.roam_dir

  if not roam_dir and roam and roam.database and roam.database.files_path then
    roam_dir = roam.database:files_path()
  end

  return roam_dir
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "org-roam-ui.nvim" })
end

local function empty_graph()
  return { nodes = {}, links = {}, tags = {} }
end

local function normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function path_is_inside(path, root)
  if not root or root == "" then
    return false
  end

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

local function schedule_refresh()
  vim.schedule(function()
    M.refresh()
  end)
end

local function refresh_after_load(load_result)
  if type(load_result) == "table" and type(load_result.next) == "function" then
    local ok = pcall(function()
      local chained = load_result:next(function()
        schedule_refresh()
      end)
      local catch_target = chained or load_result
      if type(catch_target) == "table" and type(catch_target.catch) == "function" then
        catch_target:catch(function(err)
          notify_error(("failed to refresh org-roam file: %s"):format(err or "unknown error"))
          schedule_refresh()
        end)
      end
    end)
    if ok then
      return
    end
  end

  schedule_refresh()
end

local function stop_follow_timer()
  if follow_timer and not follow_timer:is_closing() then
    follow_timer:stop()
    follow_timer:close()
  end
  follow_timer = nil
end

local function schedule_follow_node_at_cursor()
  stop_follow_timer()

  local delay = tonumber(M.config.follow_debounce_ms) or defaults.follow_debounce_ms
  if delay <= 0 then
    M.follow_node_at_cursor()
    return
  end

  follow_timer = assert(uv.new_timer())
  follow_timer:start(delay, 0, function()
    local timer = follow_timer
    follow_timer = nil
    if timer and not timer:is_closing() then
      timer:close()
    end

    vim.schedule(function()
      if follow_group then
        M.follow_node_at_cursor()
      end
    end)
  end)
end

local function configure_refresh_on_save(enabled)
  local group = vim.api.nvim_create_augroup("org_roam_ui_nvim_refresh", { clear = true })
  if not enabled then
    return
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.org",
    callback = function()
      local path = vim.fn.expand("%:p")
      local roam = get_roam()
      local roam_dir = get_roam_dir()
      if not roam or not roam.database or not path_is_inside(path, roam_dir) then
        return
      end

      local ok, load_result = pcall(function()
        if roam.database.load_file then
          return roam.database:load_file({ path = path, force = true })
        end
      end)
      if ok then
        refresh_after_load(load_result)
      else
        notify_error(("failed to refresh org-roam file: %s"):format(load_result or "unknown error"))
        schedule_refresh()
      end
    end,
  })
end

function M.enable_follow()
  if follow_group then
    return
  end

  follow_group = vim.api.nvim_create_augroup("org_roam_ui_nvim_follow", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI" }, {
    group = follow_group,
    pattern = "*.org",
    callback = function()
      schedule_follow_node_at_cursor()
    end,
  })
end

function M.disable_follow()
  if not follow_group then
    return
  end

  vim.api.nvim_del_augroup_by_id(follow_group)
  follow_group = nil
  stop_follow_timer()
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

  configure_refresh_on_save(M.config.refresh_on_save)

  if M.config.follow_on_switch then
    M.enable_follow()
  end
end

function M.graph_data()
  local roam = get_roam()
  if not roam or not roam.database then
    notify_error("org-roam.nvim database is not available")
    return empty_graph()
  end

  local data, err = graph.from_database(roam.database)
  if not data then
    notify_error(err or "failed to read org-roam.nvim graph data")
    return empty_graph()
  end

  return data
end

function M.variables()
  local roam_dir = get_roam_dir()
  local daily_dir = M.config.daily_dir
  local attach_dir = M.config.attach_dir

  if roam_dir and roam_dir ~= "" then
    daily_dir = daily_dir or vim.fs.joinpath(roam_dir, "daily")
    attach_dir = attach_dir or vim.fs.joinpath(roam_dir, ".attach")
  end

  return {
    subDirs = roam_dir and roam_dir ~= "" and graph.find_subdirectories(roam_dir) or {},
    dailyDir = daily_dir or "",
    attachDir = attach_dir or "",
    useInheritance = M.config.use_inheritance == true,
    roamDir = roam_dir or "",
    katexMacros = M.config.katex_macros,
  }
end

function M.node_text(id)
  local roam = get_roam()
  if not roam or not roam.database then
    notify_error("org-roam.nvim database is not available")
    return nil
  end

  local node = roam.database:get_sync(id)
  if not node then
    return nil
  end

  return graph.node_text(node)
end

function M.open_node(id)
  local roam = get_roam()
  if not roam or not roam.database then
    notify_error("org-roam.nvim database is not available")
    return false
  end

  local node = roam.database:get_sync(id)
  if not node then
    return false
  end

  if vim.fn.filereadable(node.file) == 0 then
    notify_error(("node file is not readable: %s"):format(node.file))
    return false
  end

  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(node.file))
  if not ok then
    notify_error(("failed to open node file: %s"):format(err))
    return false
  end

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

  local ok, err = pcall(websocket.start, {
    host = M.config.host,
    port = M.config.websocket_port,
    http_port = M.config.port,
    graph_data = M.graph_data,
    variables = M.variables,
    node_text = M.node_text,
    open_node = M.open_node,
    create_node = M.config.create_node or M.create_node,
    delete_node = M.config.delete_node or M.delete_node,
  })
  if not ok then
    server.stop()
    error(err)
  end

  if M.config.open_on_start then
    vim.ui.open(("http://%s:%d"):format(M.config.host, M.config.port))
  end
end

function M.stop()
  websocket.stop()
  server.stop()
end

function M.refresh()
  local ok, err = pcall(function()
    websocket.broadcast_variables()
    websocket.broadcast_graphdata()
  end)
  if not ok then
    notify_error(("failed to refresh org-roam-ui browser data: %s"):format(err))
  end
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
    M.disable_follow()
  else
    M.enable_follow()
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

  local roam_dir = get_roam_dir()
  if not roam_dir or roam_dir == "" then
    notify_error("roam_dir is required to delete notes")
    return false
  end

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
