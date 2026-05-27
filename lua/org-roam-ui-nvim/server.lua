local M = {}

local uv = vim.uv or vim.loop
local server
local config

local status_text = {
  [200] = "OK",
  [404] = "Not Found",
  [500] = "Internal Server Error",
}

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
    "Access-Control-Allow-Origin: *",
    "Connection: close",
    ("Content-Type: %s; charset=utf-8"):format(content_type or "text/plain"),
    ("Content-Length: %d"):format(#body),
    "",
    body,
  }
  return table.concat(headers, "\r\n")
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
  local ok, lines = pcall(vim.fn.readfile, full_path, "b")
  if not ok then
    return nil, nil
  end

  local ext = full_path:match("%.([%w]+)$") or "txt"
  return table.concat(lines, "\n"), content_types[ext] or "application/octet-stream"
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
    local ok, data = pcall(vim.fn.readfile, decoded, "b")
    if not ok then
      return response(404, "error")
    end
    return response(200, table.concat(data, "\n"), "application/octet-stream")
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
    server:accept(client)
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client:close()
        return
      end

      local path = parse_path(chunk)
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
