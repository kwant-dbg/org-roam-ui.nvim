local M = {}

local uv = vim.uv or vim.loop
local bit = bit or bit32

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local MAX_HEADER_SIZE = 16 * 1024
local MAX_FRAME_SIZE = 1024 * 1024

local server
local clients = {}
local connections = {}
local config

local function rol(value, bits)
  return bit.bor(bit.lshift(value, bits), bit.rshift(value, 32 - bits))
end

local function be32(value)
  return string.char(
    bit.band(bit.rshift(value, 24), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(value, 0xff)
  )
end

local function sha1(message)
  local bytes = { message:byte(1, #message) }
  local bit_len = #bytes * 8
  table.insert(bytes, 0x80)

  while (#bytes % 64) ~= 56 do
    table.insert(bytes, 0)
  end

  -- WebSocket keys are tiny, so this implementation only needs the common
  -- SHA-1 length case where the high 32 bits are zero.
  vim.list_extend(bytes, { 0, 0, 0, 0 })
  for i = 3, 0, -1 do
    table.insert(bytes, bit.band(bit.rshift(bit_len, i * 8), 0xff))
  end

  local h0 = 0x67452301
  local h1 = 0xefcdab89
  local h2 = 0x98badcfe
  local h3 = 0x10325476
  local h4 = 0xc3d2e1f0

  for chunk = 1, #bytes, 64 do
    local w = {}

    for i = 0, 15 do
      local j = chunk + i * 4
      w[i] = bit.bor(
        bit.lshift(bytes[j], 24),
        bit.lshift(bytes[j + 1], 16),
        bit.lshift(bytes[j + 2], 8),
        bytes[j + 3]
      )
    end

    for i = 16, 79 do
      w[i] = rol(bit.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
        k = 0x5a827999
      elseif i < 40 then
        f = bit.bxor(b, c, d)
        k = 0x6ed9eba1
      elseif i < 60 then
        f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
        k = 0x8f1bbcdc
      else
        f = bit.bxor(b, c, d)
        k = 0xca62c1d6
      end

      local temp = bit.tobit(rol(a, 5) + f + e + k + w[i])
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = bit.tobit(h0 + a)
    h1 = bit.tobit(h1 + b)
    h2 = bit.tobit(h2 + c)
    h3 = bit.tobit(h3 + d)
    h4 = bit.tobit(h4 + e)
  end

  return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3) .. be32(h4)
end

function M.accept_key(key)
  return vim.base64.encode(sha1(key .. GUID))
end

local function u16(value)
  return string.char(bit.rshift(value, 8), bit.band(value, 0xff))
end

local function u64(value)
  local high = math.floor(value / 4294967296)
  local low = value % 4294967296
  return be32(high) .. be32(low)
end

function M.encode_frame(payload, opcode)
  local len = #payload
  local header = string.char(0x80 + (opcode or 0x1))

  if len < 126 then
    header = header .. string.char(len)
  elseif len <= 0xffff then
    header = header .. string.char(126) .. u16(len)
  else
    header = header .. string.char(127) .. u64(len)
  end

  return header .. payload
end

function M.decode_frame(frame)
  if #frame < 2 then
    return nil, "incomplete"
  end

  local b1, b2 = frame:byte(1, 2)
  local fin = bit.band(b1, 0x80) ~= 0
  local rsv = bit.band(b1, 0x70)
  local opcode = bit.band(b1, 0x0f)
  local masked = bit.band(b2, 0x80) ~= 0
  local len = bit.band(b2, 0x7f)
  local idx = 3
  local control = opcode >= 0x8

  if rsv ~= 0 then
    return nil, "reserved bits are not supported"
  end

  if not fin then
    return nil, "fragmented frames are not supported"
  end

  if opcode ~= 0x1 and opcode ~= 0x8 and opcode ~= 0x9 and opcode ~= 0xA then
    return nil, "unsupported opcode"
  end

  if len == 126 then
    if #frame < 4 then
      return nil, "incomplete"
    end
    local a, b = frame:byte(3, 4)
    len = a * 256 + b
    idx = 5
  elseif len == 127 then
    if #frame < 10 then
      return nil, "incomplete"
    end
    local b = { frame:byte(3, 10) }
    if bit.band(b[1], 0x80) ~= 0 then
      return nil, "invalid payload length"
    end
    len = 0
    for i = 1, 8 do
      len = len * 256 + b[i]
    end
    idx = 11
  end

  if control and len > 125 then
    return nil, "control frame payload too large"
  end

  if len > MAX_FRAME_SIZE then
    return nil, "payload too large"
  end

  local mask
  if masked then
    if #frame < idx + 3 then
      return nil, "incomplete"
    end
    mask = { frame:byte(idx, idx + 3) }
    idx = idx + 4
  end

  if #frame < idx + len - 1 then
    return nil, "incomplete"
  end

  local payload
  if masked then
    local chunks = {}
    local pos = idx
    local end_pos = idx + len - 1
    while pos <= end_pos do
      local chunk_end = math.min(pos + 4095, end_pos)
      local bytes = { frame:byte(pos, chunk_end) }
      for i = 1, #bytes do
        local offset = pos - idx + i - 1
        bytes[i] = bit.bxor(bytes[i], mask[(offset % 4) + 1])
      end
      chunks[#chunks + 1] = string.char(unpack(bytes))
      pos = chunk_end + 1
    end
    payload = table.concat(chunks)
  else
    payload = frame:sub(idx, idx + len - 1)
  end

  return {
    opcode = opcode,
    masked = masked,
    payload = payload,
    consumed = idx + len - 1,
  }
end

local function is_closing(handle)
  return handle.is_closing and handle:is_closing()
end

local function close_handle(handle)
  if handle and not is_closing(handle) then
    handle:close()
  end
end

local function close_client(client)
  clients[client] = nil
  connections[client] = nil
  close_handle(client)
end

local function send(client, payload)
  if is_closing(client) then
    return
  end
  client:write(M.encode_frame(payload))
end

local function send_pong(client, payload)
  if is_closing(client) then
    return
  end
  client:write(M.encode_frame(payload, 0xA))
end

local function send_json(client, type_, data)
  send(client, vim.json.encode({ type = type_, data = data }))
end

local function has_config_function(name)
  return config and type(config[name]) == "function"
end

local function send_initial(client)
  vim.schedule(function()
    if is_closing(client) or not config then
      return
    end
    if has_config_function("variables") then
      send_json(client, "variables", config.variables())
    end
    if has_config_function("graph_data") then
      send_json(client, "graphdata", config.graph_data())
    end
    if config.theme then
      local theme_data = config.theme()
      if type(theme_data) == "table" and next(theme_data) ~= nil then
        send_json(client, "theme", theme_data)
      end
    end
  end)
end

local function handle_message(client, payload)
  local ok, message = pcall(vim.json.decode, payload)
  if not ok or type(message) ~= "table" then
    return
  end

  vim.schedule(function()
    if not config then
      return
    end

    local function broadcast_after(result)
      if result == false then
        return
      end

      if type(result) == "table" and type(result.next) == "function" then
        local next_result = result:next(function()
          M.broadcast_graphdata()
        end)
        if type(next_result) == "table" and type(next_result.catch) == "function" then
          next_result:catch(function(err)
            vim.notify(tostring(err), vim.log.levels.ERROR, { title = "org-roam-ui.nvim" })
          end)
        end
      else
        M.broadcast_graphdata()
      end
    end

    if message.command == "open" and message.data and message.data.id and has_config_function("open_node") then
      config.open_node(message.data.id)
    elseif message.command == "refresh" then
      M.broadcast_graphdata()
    elseif message.command == "getText" and message.data and message.data.id and has_config_function("node_text") then
      send_json(client, "orgText", config.node_text(message.data.id) or "error")
    elseif message.command == "delete" and has_config_function("delete_node") and message.data then
      broadcast_after(config.delete_node(message.data))
    elseif message.command == "create" and has_config_function("create_node") and message.data then
      broadcast_after(config.create_node(message.data))
    end
  end)
end

local function parse_request_line(request)
  local line = request:match("^([^\r\n]+)")
  if not line then
    return nil
  end

  local method, target, version = line:match("^(%S+)%s+(%S+)%s+HTTP/(%d+%.%d+)$")
  if not method then
    return nil
  end

  return method, target, version
end

local function parse_headers(request)
  local headers = {}
  for line in request:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = vim.trim(value)
    end
  end
  return headers
end

local function header_token_contains(value, token)
  if not value then
    return false
  end

  token = token:lower()
  for part in value:gmatch("[^,]+") do
    if vim.trim(part):lower() == token then
      return true
    end
  end
  return false
end

local function valid_websocket_key(key)
  if not key then
    return false
  end

  key = vim.trim(key)
  if #key % 4 ~= 0 or not key:match("^[A-Za-z0-9+/=]+$") or key:find("=.-[^=]") then
    return false
  end

  local ok, decoded = pcall(vim.base64.decode, key)
  return ok and type(decoded) == "string" and #decoded == 16
end

local function parse_origin(origin)
  if not origin or origin == "" then
    return nil
  end

  local scheme, rest = origin:match("^([%w+.-]+)://(.+)$")
  if not scheme then
    return nil
  end

  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return nil
  end

  local authority = rest:match("^([^/%?#]+)")
  local host, port
  if authority and authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
  elseif authority then
    host, port = authority:match("^([^:]+):?(%d*)$")
  end

  if not host or host == "" then
    return nil
  end

  return {
    scheme = scheme,
    host = host:lower(),
    port = tonumber(port),
  }
end

local function allowed_origin(origin)
  if not origin or origin == "" then
    return true
  end

  local parsed = parse_origin(origin)
  if not parsed then
    return false
  end

  local opts = config or {}
  local configured_host = tostring(opts.host or "127.0.0.1"):lower()
  local allowed_hosts = {
    [configured_host] = true,
  }

  if configured_host == "127.0.0.1" or configured_host == "localhost" then
    allowed_hosts["127.0.0.1"] = true
    allowed_hosts["localhost"] = true
  elseif configured_host == "::1" then
    allowed_hosts["::1"] = true
    allowed_hosts["localhost"] = true
  end

  if not allowed_hosts[parsed.host] then
    return false
  end

  local http_port = tonumber(opts.http_port)
  return not http_port or parsed.port == nil or parsed.port == http_port
end

local function http_error(status, message)
  local status_text = status == 403 and "Forbidden" or "Bad Request"
  local body = message or status_text:lower()
  return table.concat({
    ("HTTP/1.1 %d %s"):format(status, status_text),
    "Connection: close",
    "Content-Type: text/plain",
    ("Content-Length: %d"):format(#body),
    "",
    body,
  }, "\r\n")
end

local function handshake_response(request)
  local method = parse_request_line(request)
  if method ~= "GET" then
    return nil, http_error(400, "invalid websocket method")
  end

  local headers = parse_headers(request)
  if (headers.upgrade or ""):lower() ~= "websocket" then
    return nil, http_error(400, "invalid websocket upgrade")
  end

  if not header_token_contains(headers.connection, "upgrade") then
    return nil, http_error(400, "invalid websocket connection")
  end

  if headers["sec-websocket-version"] ~= "13" then
    return nil, http_error(400, "invalid websocket version")
  end

  if not allowed_origin(headers.origin) then
    return nil, http_error(403, "forbidden")
  end

  local key = headers["sec-websocket-key"]
  if not valid_websocket_key(key) then
    return nil, http_error(400, "invalid websocket key")
  end

  return table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. M.accept_key(vim.trim(key)),
    "",
    "",
  }, "\r\n")
end

M._handshake_response = handshake_response

function M.broadcast(type_, data)
  local payload = vim.json.encode({ type = type_, data = data })
  for client in pairs(clients) do
    send(client, payload)
  end
end

function M.broadcast_graphdata()
  if has_config_function("graph_data") then
    M.broadcast("graphdata", config.graph_data())
  end
end

function M.broadcast_variables()
  if has_config_function("variables") then
    M.broadcast("variables", config.variables())
  end
end

function M.command(command_name, data)
  M.broadcast("command", vim.tbl_extend("force", { commandName = command_name }, data or {}))
end

function M.start(opts)
  if server then
    return
  end

  config = opts
  local listener = assert(uv.new_tcp())
  local ok, err = listener:bind(opts.host, opts.port)
  if not ok then
    close_handle(listener)
    config = nil
    error(err or ("failed to bind " .. opts.host .. ":" .. opts.port))
  end

  ok, err = listener:listen(128, function(err)
    assert(not err, err)

    local client = assert(uv.new_tcp())
    local buffer = ""
    local handshaken = false

    local accepted = listener:accept(client)
    if not accepted then
      close_handle(client)
      return
    end

    connections[client] = true
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        close_client(client)
        return
      end

      buffer = buffer .. chunk
      if not handshaken then
        if #buffer > MAX_HEADER_SIZE then
          client:write(http_error(400, "request header too large"), function()
            close_client(client)
          end)
          return
        end

        if not buffer:find("\r\n\r\n", 1, true) then
          return
        end

        local response, err_response = handshake_response(buffer)
        if not response then
          client:write(err_response or http_error(400, "bad request"), function()
            close_client(client)
          end)
          return
        end

        handshaken = true
        clients[client] = true
        buffer = ""
        client:write(response, function()
          send_initial(client)
        end)
        return
      end

      while #buffer > 0 do
        if #buffer > MAX_FRAME_SIZE + 14 then
          close_client(client)
          return
        end

        local frame, frame_err = M.decode_frame(buffer)
        if not frame then
          if frame_err ~= "incomplete" then
            close_client(client)
          end
          return
        end

        buffer = buffer:sub(frame.consumed + 1)
        if not frame.masked then
          close_client(client)
          return
        end

        if frame.opcode == 0x8 then
          close_client(client)
          return
        elseif frame.opcode == 0x9 then
          send_pong(client, frame.payload)
        elseif frame.opcode == 0x1 then
          handle_message(client, frame.payload)
        end
      end
    end)
  end)

  if not ok then
    close_handle(listener)
    config = nil
    error(err or ("failed to listen on " .. opts.host .. ":" .. opts.port))
  end

  server = listener
end

function M.stop()
  while true do
    local client = next(connections)
    if not client then
      break
    end
    close_client(client)
  end
  clients = {}

  if server then
    close_handle(server)
    server = nil
  end
  config = nil
end

return M
