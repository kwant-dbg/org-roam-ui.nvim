local M = {}

local uv = vim.uv or vim.loop
local server
local config

local status_text = {
  [200] = "OK",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
}

local MAX_HEADER_SIZE = 16 * 1024

local content_types = {
  html = "text/html",
  js = "application/javascript",
  css = "text/css",
  json = "application/json",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  svg = "image/svg+xml",
  ico = "image/x-icon",
  txt = "text/plain",
}

local function percent_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function double_decode(value)
  return percent_decode(percent_decode(value or ""))
end

local function response(status, body, content_type)
  body = body or ""
  local headers = {
    ("HTTP/1.1 %d %s"):format(status, status_text[status] or "OK"),
    "Connection: close",
    ("Content-Type: %s"):format(content_type or "text/plain"),
    ("Content-Length: %d"):format(#body),
    "",
    body,
  }
  return table.concat(headers, "\r\n")
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end

  local data = ""
  if stat.size > 0 then
    data = uv.fs_read(fd, stat.size, 0)
  end
  uv.fs_close(fd)

  return data
end

local function read_static(path)
  if not config.static_dir then
    return nil, nil
  end

  local rel = path == "/" and "/index.html" or path
  rel = rel:gsub("^/+", "")
  if rel:find("%.%.", 1, true) then
    return nil, nil
  end

  local full_path = vim.fs.joinpath(config.static_dir, rel)
  local data = read_file(full_path)
  if not data then
    return nil, nil
  end

  local ext = full_path:match("%.([%w]+)$") or "txt"
  return data, content_types[ext] or "application/octet-stream"
end

local function normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function real_or_normal(path)
  return uv.fs_realpath(path) or normalize_path(path)
end

local function path_is_inside(path, root)
  if not root or root == "" then
    return false
  end

  local normalized_path = real_or_normal(path)
  local normalized_root = real_or_normal(root)
  return normalized_path == normalized_root or vim.startswith(normalized_path, normalized_root .. "/")
end

local function allowed_image_path(decoded)
  if decoded == "" or decoded:find("%z") then
    return nil
  end

  local variables = config.variables()
  local full_path = normalize_path(decoded)
  for _, root in ipairs({ variables.roamDir, variables.attachDir }) do
    if path_is_inside(full_path, root) then
      return full_path
    end
  end

  return nil
end

local function handle_request(path)
  if path == "/graphdata" then
    return response(200, vim.json.encode(config.graph_data()), "application/json")
  end

  if path == "/variables" then
    return response(200, vim.json.encode(config.variables()), "application/json")
  end

  local node_id = path:match("^/node/(.+)$")
  if node_id then
    local text = config.node_text(double_decode(node_id))
    if not text then
      return response(404, "error")
    end
    return response(200, text, "text/plain")
  end

  local img_path = path:match("^/img/(.+)$")
  if img_path then
    local decoded = double_decode(img_path)
    local full_path = allowed_image_path(decoded)
    if not full_path then
      return response(403, "forbidden")
    end

    local data = read_file(full_path)
    if not data then
      return response(404, "error")
    end
    return response(200, data, "application/octet-stream")
  end

  local body, content_type = read_static(path)
  if body then
    return response(200, body, content_type)
  end

  return response(404, "not found")
end

M._handle_request = handle_request

local function parse_path(request)
  local path = request:match("^[A-Z]+%s+([^%s]+)")
  if not path then
    return "/"
  end
  return (path:gsub("%?.*$", ""))
end

function M.start(opts)
  if server then
    return
  end

  config = opts
  server = assert(uv.new_tcp())
  assert(server:bind(opts.host, opts.port))
  server:listen(128, function(err)
    assert(not err, err)

    local client = assert(uv.new_tcp())
    local accepted = server:accept(client)
    if not accepted then
      client:close()
      return
    end

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client:close()
        return
      end

      buffer = buffer .. chunk
      if #buffer > MAX_HEADER_SIZE then
        client:write(response(431, "request header too large"), function()
          client:close()
        end)
        return
      end

      if not buffer:find("\r\n\r\n", 1, true) then
        return
      end

      local request = buffer
      buffer = ""
      client:read_stop()
      local path = parse_path(request)
      vim.schedule(function()
        if client:is_closing() then
          return
        end

        local ok, body = pcall(handle_request, path)
        if not ok then
          body = response(500, tostring(body))
        end

        client:write(body, function()
          client:close()
        end)
      end)
    end)
  end)
end

function M.stop()
  if not server then
    return
  end
  server:close()
  server = nil
end

return M
