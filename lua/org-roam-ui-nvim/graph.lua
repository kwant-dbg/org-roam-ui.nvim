local M = {}

local function sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl or {})
  table.sort(keys)
  return keys
end

local function unique_sorted(values)
  local seen = {}
  for _, value in ipairs(values or {}) do
    if value and value ~= "" then
      seen[value] = true
    end
  end
  return sorted_keys(seen)
end

local function node_pos(node)
  local start = node.range and node.range.start
  if not start then
    return 0
  end

  return (start.offset or 0) + 1
end

local function object_or_empty(tbl)
  if tbl and next(tbl) ~= nil then
    return tbl
  end
  return vim.empty_dict()
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return table.concat(lines, "\n")
end

-- Compute the outline level path (ancestor heading titles) for a heading node.
-- Returns an array of strings or vim.NIL for file-level and headingless nodes.
local function compute_olp(node)
  if node.olp then
    return node.olp
  end

  if (node.level or 0) == 0 then
    return vim.NIL
  end

  if not node.file or not node.range then
    return vim.NIL
  end

  local start_offset = node.range.start and node.range.start.offset
  if not start_offset then
    return vim.NIL
  end

  local text = read_file(node.file)
  if not text then
    return vim.NIL
  end

  -- Walk headings in the file up to (but not including) the node's start byte.
  -- Keep the most recent title seen at each heading level.
  local level_titles = {}
  local byte_pos = 0

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if byte_pos >= start_offset then
      break
    end

    local stars, title = line:match("^(%*+)%s+(.*)")
    if stars then
      local lvl = #stars
      -- Clear all same/deeper levels so only the latest survives.
      for k in pairs(level_titles) do
        if k >= lvl then
          level_titles[k] = nil
        end
      end
      level_titles[lvl] = vim.trim(title)
    end

    byte_pos = byte_pos + #line + 1
  end

  -- Build the path from level 1 up to the parent level.
  local olp = {}
  for lvl = 1, (node.level or 1) - 1 do
    if level_titles[lvl] then
      table.insert(olp, level_titles[lvl])
    end
  end

  if #olp == 0 then
    return vim.NIL
  end

  return olp
end

-- Properties the frontend actively queries.
local FORWARDED_PROPS = { "NOTER_PAGE", "ROAM_REFS", "ROAM_ALIASES" }

function M.to_orui_node(node)
  local properties = {}

  if node.origin then
    properties.ROAM_ORIGIN = node.origin
  end

  -- refs array (org-roam.nvim native field)
  if node.refs and #node.refs > 0 then
    properties.ROAM_REFS = table.concat(node.refs, " ")
  end

  -- aliases array
  if node.aliases and #node.aliases > 0 then
    properties.ROAM_ALIASES = table.concat(node.aliases, " ")
  end

  -- Forward specific node-level properties that the frontend uses.
  if type(node.properties) == "table" then
    for _, key in ipairs(FORWARDED_PROPS) do
      if node.properties[key] and not properties[key] then
        properties[key] = tostring(node.properties[key])
      end
    end
  end

  return {
    id = node.id,
    file = node.file,
    title = node.title,
    level = node.level or 0,
    pos = node_pos(node),
    olp = compute_olp(node),
    properties = object_or_empty(properties),
    tags = vim.deepcopy(node.tags or {}),
  }
end

function M.links_from_nodes(nodes)
  local links = {}
  local seen = {}

  for _, node in pairs(nodes or {}) do
    for target in pairs(node.linked or {}) do
      local key = ("%s\0%s\0id"):format(node.id, target)
      if not seen[key] then
        seen[key] = true
        table.insert(links, {
          source = node.id,
          target = target,
          type = "id",
        })
      end
    end
  end

  table.sort(links, function(a, b)
    if a.source == b.source then
      return a.target < b.target
    end
    return a.source < b.source
  end)

  return links
end

local function all_nodes_from_core_db(core_db)
  local raw_nodes = rawget(core_db, "__nodes")
  assert(type(raw_nodes) == "table", "org-roam.nvim internal node table is unavailable")
  return raw_nodes
end

function M.from_core_database(core_db)
  local raw_nodes = all_nodes_from_core_db(core_db)
  local nodes = {}
  local tags = {}

  for _, id in ipairs(sorted_keys(raw_nodes)) do
    local node = raw_nodes[id]
    table.insert(nodes, M.to_orui_node(node))
    vim.list_extend(tags, node.tags or {})
  end

  return {
    nodes = nodes,
    links = M.links_from_nodes(raw_nodes),
    tags = unique_sorted(tags),
  }
end

function M.from_database(database)
  local core_db = database.internal_sync and database:internal_sync() or database
  return M.from_core_database(core_db)
end

function M.node_text(node)
  local text = read_file(node.file)
  if not text then
    return nil
  end

  if not node.range or (node.level or 0) == 0 then
    return text
  end

  local start_offset = node.range.start and node.range.start.offset
  local end_offset = node.range.end_ and node.range.end_.offset

  if not start_offset or not end_offset then
    return text
  end

  -- org-roam.nvim stores zero-based byte offsets. The ranges originate from
  -- parser end positions, so treating end_ as exclusive avoids leaking the
  -- first byte after a headline node into previews.
  return text:sub(start_offset + 1, end_offset - 1)
end

function M.find_subdirectories(root)
  root = vim.fs.normalize(vim.fn.expand(root))
  local dirs = {}

  local function on_entry(name, type_)
    if type_ ~= "directory" then
      return
    end

    local basename = vim.fs.basename(name)
    if basename and vim.startswith(basename, ".") then
      return
    end

    table.insert(dirs, name)
  end

  pcall(function()
    vim.fs.find(on_entry, { path = root, type = "directory", limit = math.huge })
  end)

  table.sort(dirs)
  return dirs
end

return M
