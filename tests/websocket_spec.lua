local websocket = require("org-roam-ui-nvim.websocket")
local uv = vim.uv or vim.loop

local function fake_tcp_handle(opts)
  opts = opts or {}
  local handle = {
    closed = false,
    is_closing = function(self)
      return self.closed
    end,
    close = function(self)
      self.closed = true
    end,
    bind = opts.bind
      or function()
        return true
      end,
    listen = opts.listen
      or function(_, _, cb)
        opts.listen_cb = cb
        return true
      end,
    accept = opts.accept
      or function()
        return true
      end,
    read_start = opts.read_start
      or function(self, cb)
        self.read_cb = cb
        return true
      end,
    write = opts.write
      or function(_, _, cb)
        if cb then
          cb()
        end
        return true
      end,
  }
  return handle
end

local function with_fake_tcp(handles, fn)
  local original_new_tcp = uv.new_tcp
  local index = 0
  uv.new_tcp = function()
    index = index + 1
    return handles[index]
  end

  local ok, err = pcall(fn)
  uv.new_tcp = original_new_tcp
  assert.is_true(ok, err)
end

local function handshake_request(origin)
  return table.concat({
    "GET / HTTP/1.1",
    "Host: 127.0.0.1:35913",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version: 13",
    origin and ("Origin: " .. origin) or nil,
    "",
    "",
  }, "\r\n")
end

local function replace_header(request, name, value)
  local replacement = value and (name .. ": " .. value) or nil
  local pattern = "\r\n" .. name .. ": [^\r\n]*"
  if replacement then
    local replaced = request:gsub(pattern, "\r\n" .. replacement, 1)
    return replaced
  end
  local replaced = request:gsub(pattern, "", 1)
  return replaced
end

local function masked_frame(opcode, payload)
  local mask = { 1, 2, 3, 4 }
  local bytes = { payload:byte(1, #payload) }
  for i = 1, #bytes do
    bytes[i] = bit.bxor(bytes[i], mask[((i - 1) % 4) + 1])
  end
  return string.char(0x80 + opcode, 0x80 + #payload, unpack(mask)) .. string.char(unpack(bytes))
end

local function u64(value)
  local high = math.floor(value / 4294967296)
  local low = value % 4294967296
  return string.char(
    bit.band(bit.rshift(high, 24), 0xff),
    bit.band(bit.rshift(high, 16), 0xff),
    bit.band(bit.rshift(high, 8), 0xff),
    bit.band(high, 0xff),
    bit.band(bit.rshift(low, 24), 0xff),
    bit.band(bit.rshift(low, 16), 0xff),
    bit.band(bit.rshift(low, 8), 0xff),
    bit.band(low, 0xff)
  )
end

local next_port = 40100

local function alloc_port()
  next_port = next_port + 1
  return next_port
end

local function command_frame(command, data)
  return masked_frame(0x1, vim.json.encode({ command = command, data = data }))
end

local function collect_messages(response)
  local frames = response:match("\r\n\r\n(.*)$") or ""
  local messages = {}
  while #frames > 0 do
    local frame = websocket.decode_frame(frames)
    if not frame then
      break
    end
    if frame.opcode == 0x1 then
      local ok, message = pcall(vim.json.decode, frame.payload)
      if ok then
        messages[#messages + 1] = message
      end
    end
    frames = frames:sub(frame.consumed + 1)
  end
  return messages
end

local function count_messages(response, type_)
  local count = 0
  for _, message in ipairs(collect_messages(response)) do
    if message.type == type_ then
      count = count + 1
    end
  end
  return count
end

local function has_message(response, type_, predicate)
  for _, message in ipairs(collect_messages(response)) do
    if message.type == type_ and (not predicate or predicate(message)) then
      return true
    end
  end
  return false
end

local function with_websocket_client(opts, fn)
  local port = alloc_port()
  local response = ""

  opts.host = opts.host or "127.0.0.1"
  opts.port = port
  opts.http_port = opts.http_port or 35911
  opts.graph_data = opts.graph_data
    or function()
      return { nodes = {}, links = {}, tags = {} }
    end
  opts.variables = opts.variables
    or function()
      return {}
    end
  opts.node_text = opts.node_text or function() end
  opts.open_node = opts.open_node or function() end

  websocket.start(opts)

  local client = assert(uv.new_tcp())
  assert(client:connect("127.0.0.1", port, function(err)
    assert.is_nil(err)
    client:read_start(function(_, chunk)
      if chunk then
        response = response .. chunk
      end
    end)
    client:write(handshake_request("http://127.0.0.1:35911"))
  end))

  assert.is_true(vim.wait(1000, function()
    return response:find("\r\n\r\n", 1, true) ~= nil
  end))

  local ok, err = pcall(fn, client, function()
    return response
  end)

  if not client:is_closing() then
    client:close()
  end
  assert.is_true(ok, err)
end

describe("org-roam-ui-nvim websocket protocol", function()
  after_each(function()
    websocket.stop()
  end)

  it("closes failed listen handles and remains startable", function()
    local failed = fake_tcp_handle({
      listen = function()
        return nil, "EADDRINUSE"
      end,
    })
    local healthy = fake_tcp_handle()

    with_fake_tcp({ failed, healthy }, function()
      local ok = pcall(websocket.start, {
        host = "127.0.0.1",
        port = 39989,
        http_port = 35911,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
        open_node = function() end,
      })

      assert.is_false(ok)
      assert.is_true(failed.closed)

      websocket.start({
        host = "127.0.0.1",
        port = 39989,
        http_port = 35911,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
        open_node = function() end,
      })
      websocket.stop()
      assert.is_true(healthy.closed)
    end)
  end)

  it("closes pre-handshake clients on stop", function()
    local listen_cb
    local listener = fake_tcp_handle({
      listen = function(_, _, cb)
        listen_cb = cb
        return true
      end,
    })
    local client = fake_tcp_handle()

    with_fake_tcp({ listener, client }, function()
      websocket.start({
        host = "127.0.0.1",
        port = 39989,
        http_port = 35911,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
        open_node = function() end,
      })

      listen_cb()
      assert.is_false(client.closed)

      websocket.stop()
      assert.is_true(client.closed)
      assert.is_true(listener.closed)
    end)
  end)

  it("computes the RFC websocket accept key", function()
    assert.are.equal(
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      websocket.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
    )
  end)

  it("encodes and decodes text frames", function()
    local encoded = websocket.encode_frame("hello")
    assert.are.equal("hello", websocket.decode_frame(encoded).payload)

    local masked = string.char(0x81, 0x80 + 5, 1, 2, 3, 4)
      .. string.char(
        bit.bxor(("h"):byte(), 1),
        bit.bxor(("e"):byte(), 2),
        bit.bxor(("l"):byte(), 3),
        bit.bxor(("l"):byte(), 4),
        bit.bxor(("o"):byte(), 1)
      )

    local decoded = websocket.decode_frame(masked)
    assert.are.equal(0x1, decoded.opcode)
    assert.are.equal("hello", decoded.payload)
  end)

  it("decodes large payloads without unpack overflow and rejects oversized frames", function()
    local payload = string.rep("x", 70000)
    assert.are.equal(payload, websocket.decode_frame(websocket.encode_frame(payload)).payload)

    local frame, err = websocket.decode_frame(string.char(0x81, 0xff) .. u64(1024 * 1024 + 1))
    assert.is_nil(frame)
    assert.are.equal("payload too large", err)
  end)

  it("validates websocket origins when present", function()
    assert.is_truthy(websocket._handshake_response(handshake_request("http://127.0.0.1:35911")))

    local response, err_response = websocket._handshake_response(handshake_request("http://example.com:35911"))
    assert.is_nil(response)
    assert.matches("HTTP/1.1 403 Forbidden", err_response, nil, true)
  end)

  it("rejects invalid websocket handshakes", function()
    local request = handshake_request("http://127.0.0.1:35911")
    local post_request = request:gsub("^GET", "POST")
    local cases = {
      post_request,
      replace_header(request, "Upgrade", "h2c"),
      replace_header(request, "Connection", "keep-alive"),
      replace_header(request, "Sec%-WebSocket%-Version", "12"),
      replace_header(request, "Sec%-WebSocket%-Key", "not-a-websocket-key"),
      replace_header(request, "Sec%-WebSocket%-Key", nil),
    }

    for _, invalid in ipairs(cases) do
      local response, err_response = websocket._handshake_response(invalid)
      assert.is_nil(response)
      assert.matches("HTTP/1.1 400 Bad Request", err_response, nil, true)
    end
  end)

  it("keeps broadcast helpers safe before start", function()
    assert.has_no.errors(function()
      websocket.broadcast_graphdata()
      websocket.broadcast_variables()
      websocket.command("follow", { id = "node-id" })
    end)
  end)

  it("closes clients on protocol frame errors", function()
    local listen_cb
    local listener = fake_tcp_handle({
      listen = function(_, _, cb)
        listen_cb = cb
        return true
      end,
    })
    local client = fake_tcp_handle()

    with_fake_tcp({ listener, client }, function()
      websocket.start({
        host = "127.0.0.1",
        port = 39989,
        http_port = 35911,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
        open_node = function() end,
      })

      listen_cb()
      client.read_cb(nil, handshake_request("http://127.0.0.1:35911"))
      assert.is_false(client.closed)

      client.read_cb(nil, websocket.encode_frame("unmasked client frame"))
      assert.is_true(client.closed)
    end)
  end)

  it("responds to ping frames with pong frames", function()
    websocket.start({
      host = "127.0.0.1",
      port = 39995,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
      open_node = function() end,
    })

    local client = assert(uv.new_tcp())
    local response = ""
    assert(client:connect("127.0.0.1", 39995, function(err)
      assert.is_nil(err)
      client:read_start(function(_, chunk)
        if chunk then
          response = response .. chunk
        end
      end)
      client:write(handshake_request("http://127.0.0.1:35911"))
    end))

    assert.is_true(vim.wait(1000, function()
      return response:find("\r\n\r\n", 1, true) ~= nil
    end))
    client:write(masked_frame(0x9, "ok"))

    assert.is_true(vim.wait(1000, function()
      local frames = response:match("\r\n\r\n(.*)$") or ""
      while #frames > 0 do
        local frame = websocket.decode_frame(frames)
        if not frame then
          return false
        end
        if frame.opcode == 0xA and frame.payload == "ok" then
          return true
        end
        frames = frames:sub(frame.consumed + 1)
      end
      return false
    end))

    if not client:is_closing() then
      client:close()
    end
  end)

  it("handles open and getText command frames", function()
    local opened

    with_websocket_client({
      open_node = function(id)
        opened = id
      end,
      node_text = function(id)
        return "text for " .. id
      end,
    }, function(client, response)
      client:write(command_frame("open", { id = "node-a" }))
      assert.is_true(vim.wait(1000, function()
        return opened == "node-a"
      end))

      client:write(command_frame("getText", { id = "node-a" }))
      assert.is_true(vim.wait(1000, function()
        return has_message(response(), "orgText", function(message)
          return message.data == "text for node-a"
        end)
      end))
    end)
  end)

  it("broadcasts graphdata for refresh command frames", function()
    with_websocket_client({}, function(client, response)
      assert.is_true(vim.wait(1000, function()
        return count_messages(response(), "graphdata") >= 1
      end))

      client:write(command_frame("refresh", {}))
      assert.is_true(vim.wait(1000, function()
        return count_messages(response(), "graphdata") >= 2
      end))
    end)
  end)

  it("does not broadcast graphdata when create returns false", function()
    local graph_calls = 0

    with_websocket_client({
      graph_data = function()
        graph_calls = graph_calls + 1
        return { nodes = {}, links = {}, tags = {} }
      end,
      create_node = function()
        return false
      end,
    }, function(client)
      assert.is_true(vim.wait(1000, function()
        return graph_calls == 1
      end))

      client:write(command_frame("create", { title = "New note" }))
      vim.wait(100)
      assert.are.equal(1, graph_calls)
    end)
  end)

  it("broadcasts graphdata after promise create resolves", function()
    local graph_calls = 0
    local resolve_create

    with_websocket_client({
      graph_data = function()
        graph_calls = graph_calls + 1
        return { nodes = {}, links = {}, tags = {} }
      end,
      create_node = function()
        return {
          next = function(_, cb)
            resolve_create = cb
            return {
              catch = function() end,
            }
          end,
        }
      end,
    }, function(client)
      assert.is_true(vim.wait(1000, function()
        return graph_calls == 1
      end))

      client:write(command_frame("create", { title = "New note" }))
      assert.is_true(vim.wait(1000, function()
        return resolve_create ~= nil
      end))
      assert.are.equal(1, graph_calls)

      resolve_create()
      assert.is_true(vim.wait(1000, function()
        return graph_calls == 2
      end))
    end)
  end)

  it("broadcasts graphdata after synchronous delete", function()
    local deleted

    with_websocket_client({
      delete_node = function(data)
        deleted = data.id
        return true
      end,
    }, function(client, response)
      assert.is_true(vim.wait(1000, function()
        return count_messages(response(), "graphdata") >= 1
      end))

      client:write(command_frame("delete", { id = "node-a" }))
      assert.is_true(vim.wait(1000, function()
        return deleted == "node-a" and count_messages(response(), "graphdata") >= 2
      end))
    end)
  end)
end)
