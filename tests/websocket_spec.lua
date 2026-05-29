local websocket = require("org-roam-ui-nvim.websocket")
local uv = vim.uv or vim.loop

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

local function masked_frame(opcode, payload)
  local mask = { 1, 2, 3, 4 }
  local bytes = { payload:byte(1, #payload) }
  for i = 1, #bytes do
    bytes[i] = bit.bxor(bytes[i], mask[((i - 1) % 4) + 1])
  end
  return string.char(0x80 + opcode, 0x80 + #payload, unpack(mask)) .. string.char(unpack(bytes))
end

describe("org-roam-ui-nvim websocket protocol", function()
  after_each(function()
    websocket.stop()
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

  it("validates websocket origins when present", function()
    assert.is_truthy(websocket._handshake_response(handshake_request("http://127.0.0.1:35911")))

    local response, err_response = websocket._handshake_response(handshake_request("http://example.com:35911"))
    assert.is_nil(response)
    assert.matches("HTTP/1.1 403 Forbidden", err_response, nil, true)
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
end)
