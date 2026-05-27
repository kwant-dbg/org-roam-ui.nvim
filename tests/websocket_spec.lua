local websocket = require("org-roam-ui-nvim.websocket")

describe("org-roam-ui-nvim websocket protocol", function()
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
end)

