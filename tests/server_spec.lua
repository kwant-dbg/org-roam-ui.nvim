local server = require("org-roam-ui-nvim.server")
local repo_root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
local uv = vim.uv or vim.loop

local function response_body(response)
  return response:match("\r\n\r\n(.*)$")
end

local function write_binary(path, data)
  local fd = assert(uv.fs_open(path, "w", 438))
  assert(uv.fs_write(fd, data, 0))
  assert(uv.fs_close(fd))
end

local function request_raw(port, request)
  local client = assert(uv.new_tcp())
  local response = ""
  local done = false

  assert(client:connect("127.0.0.1", port, function(err)
    assert.is_nil(err)
    client:read_start(function(read_err, chunk)
      assert.is_nil(read_err)
      if chunk then
        response = response .. chunk
      else
        done = true
      end
    end)
    client:write(request)
  end))

  assert.is_true(vim.wait(2000, function()
    return done
  end))

  if not client:is_closing() then
    client:close()
  end

  return response
end

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
    read_stop = opts.read_stop
      or function()
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

describe("org-roam-ui-nvim HTTP server", function()
  after_each(function()
    server.stop()
  end)

  it("closes failed bind handles and remains startable", function()
    local failed = fake_tcp_handle({
      bind = function()
        return nil, "EADDRINUSE"
      end,
    })
    local healthy = fake_tcp_handle()

    with_fake_tcp({ failed, healthy }, function()
      local ok = pcall(server.start, {
        host = "127.0.0.1",
        port = 39990,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
      })

      assert.is_false(ok)
      assert.is_true(failed.closed)

      server.start({
        host = "127.0.0.1",
        port = 39990,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
      })
      server.stop()
      assert.is_true(healthy.closed)
    end)
  end)

  it("closes idle accepted clients on stop", function()
    local listen_cb
    local listener = fake_tcp_handle({
      listen = function(_, _, cb)
        listen_cb = cb
        return true
      end,
    })
    local client = fake_tcp_handle()

    with_fake_tcp({ listener, client }, function()
      server.start({
        host = "127.0.0.1",
        port = 39990,
        graph_data = function()
          return { nodes = {}, links = {}, tags = {} }
        end,
        variables = function()
          return {}
        end,
        node_text = function() end,
      })

      listen_cb()
      assert.is_false(client.closed)

      server.stop()
      assert.is_true(client.closed)
      assert.is_true(listener.closed)
    end)
  end)

  it("serves graph data, variables, and node text", function()
    server.start({
      host = "127.0.0.1",
      port = 39991,
      graph_data = function()
        return {
          nodes = {
            {
              id = "a",
              file = "/tmp/a.org",
              title = "A",
              level = 0,
              pos = 1,
              properties = {},
              tags = {},
            },
          },
          links = {},
          tags = {},
        }
      end,
      variables = function()
        return {
          subDirs = {},
          dailyDir = "/tmp/roam/daily",
          attachDir = "/tmp/roam/.attach",
          useInheritance = false,
          roamDir = "/tmp/roam",
          katexMacros = {},
        }
      end,
      node_text = function(id)
        if id == "a" then
          return "* A"
        end
      end,
    })

    local graph = vim.json.decode(response_body(server._handle_request("/graphdata")))
    assert.are.equal("a", graph.nodes[1].id)

    local variables = vim.json.decode(response_body(server._handle_request("/variables")))
    assert.are.equal("/tmp/roam", variables.roamDir)

    assert.are.equal("* A", response_body(server._handle_request("/node/a")))
  end)

  it("decodes encoded node ids and returns 404 for missing node text", function()
    local seen_id
    server.start({
      host = "127.0.0.1",
      port = 39992,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function(id)
        seen_id = id
        if id == "node/slash%percent space" then
          return "* Encoded"
        end
      end,
    })

    local encoded = vim.uri_encode("node/slash%percent space", "rfc2396")
    local response = server._handle_request("/node/" .. encoded)
    assert.are.equal("node/slash%percent space", seen_id)
    assert.matches("HTTP/1.1 200 OK", response, nil, true)
    assert.are.equal("* Encoded", response_body(response))

    local missing = server._handle_request("/node/" .. vim.uri_encode("missing/id", "rfc2396"))
    assert.matches("HTTP/1.1 404 Not Found", missing, nil, true)
    assert.are.equal("error", response_body(missing))
  end)

  it("does not emit wildcard CORS headers for private endpoints", function()
    server.start({
      host = "127.0.0.1",
      port = 39992,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
    })

    local response = server._handle_request("/graphdata")
    assert.is_nil(response:find("Access-Control-Allow-Origin:", 1, true))
  end)

  it("serves images only from roam and attach roots", function()
    local root = vim.fn.tempname()
    local roam_dir = vim.fs.joinpath(root, "roam")
    local attach_dir = vim.fs.joinpath(root, "attach")
    local outside_dir = vim.fs.joinpath(root, "outside")
    vim.fn.mkdir(roam_dir, "p")
    vim.fn.mkdir(attach_dir, "p")
    vim.fn.mkdir(outside_dir, "p")

    local note_image = vim.fs.joinpath(roam_dir, "image.bin")
    local attach_image = vim.fs.joinpath(attach_dir, "attach.bin")
    local outside_image = vim.fs.joinpath(outside_dir, "secret.bin")
    write_binary(note_image, "a\0b\r\nc")
    write_binary(attach_image, "attached")
    write_binary(outside_image, "secret")

    server.start({
      host = "127.0.0.1",
      port = 39993,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {
          roamDir = roam_dir,
          attachDir = attach_dir,
        }
      end,
      node_text = function() end,
    })

    local note_response = server._handle_request("/img/" .. vim.uri_encode(note_image, "rfc2396"))
    assert.are.equal("a\0b\r\nc", response_body(note_response))

    local attach_response = server._handle_request("/img/" .. vim.uri_encode(attach_image, "rfc2396"))
    assert.are.equal("attached", response_body(attach_response))

    local outside_response = server._handle_request("/img/" .. vim.uri_encode(outside_image, "rfc2396"))
    assert.matches("HTTP/1.1 403 Forbidden", outside_response, nil, true)

    local traversal = roam_dir .. "/../outside/secret.bin"
    local traversal_response = server._handle_request("/img/" .. vim.uri_encode(traversal, "rfc2396"))
    assert.matches("HTTP/1.1 403 Forbidden", traversal_response, nil, true)
  end)

  it("returns 404 for missing allowed images and rejects null-byte image paths", function()
    local root = vim.fn.tempname()
    local roam_dir = vim.fs.joinpath(root, "roam")
    vim.fn.mkdir(roam_dir, "p")

    server.start({
      host = "127.0.0.1",
      port = 39994,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {
          roamDir = roam_dir,
          attachDir = "",
        }
      end,
      node_text = function() end,
    })

    local missing = vim.fs.joinpath(roam_dir, "missing.png")
    local missing_response = server._handle_request("/img/" .. vim.uri_encode(missing, "rfc2396"))
    assert.matches("HTTP/1.1 404 Not Found", missing_response, nil, true)
    assert.are.equal("error", response_body(missing_response))

    local nul = vim.uri_encode(missing, "rfc2396") .. "%00.png"
    local nul_response = server._handle_request("/img/" .. nul)
    assert.matches("HTTP/1.1 403 Forbidden", nul_response, nil, true)
    assert.are.equal("forbidden", response_body(nul_response))
  end)

  it("waits for complete HTTP headers before handling a socket request", function()
    server.start({
      host = "127.0.0.1",
      port = 39994,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
    })

    local client = assert(uv.new_tcp())
    local response = ""
    local connected = false
    assert(client:connect("127.0.0.1", 39994, function(err)
      assert.is_nil(err)
      connected = true
      client:read_start(function(_, chunk)
        if chunk then
          response = response .. chunk
        end
      end)
      client:write("GET /variables HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    end))

    assert.is_true(vim.wait(1000, function()
      return connected
    end))
    vim.wait(100)
    assert.are.equal("", response)

    client:write("\r\n")
    assert.is_true(vim.wait(1000, function()
      return response:find("\r\n\r\n", 1, true) ~= nil
    end))
    assert.matches("HTTP/1.1 200 OK", response, nil, true)
    if not client:is_closing() then
      client:close()
    end
  end)

  it("returns 500 when a scheduled request handler raises", function()
    server.start({
      host = "127.0.0.1",
      port = 39995,
      graph_data = function()
        error("graph exploded")
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
    })

    local response = request_raw(39995, "GET /graphdata HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    assert.matches("HTTP/1.1 500 Internal Server Error", response, nil, true)
    assert.matches("graph exploded", response, nil, true)
  end)

  it("returns 431 for oversized HTTP headers", function()
    server.start({
      host = "127.0.0.1",
      port = 39996,
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
    })

    local response = request_raw(39996, "GET /variables HTTP/1.1\r\nX-Big: " .. string.rep("x", 17000) .. "\r\n")
    assert.matches("HTTP/1.1 431 Request Header Fields Too Large", response, nil, true)
    assert.are.equal("request header too large", response_body(response))
  end)

  it("serves static frontend files", function()
    server.start({
      host = "127.0.0.1",
      port = 39991,
      static_dir = vim.fs.joinpath(repo_root, "web", "org-roam-ui"),
      graph_data = function()
        return { nodes = {}, links = {}, tags = {} }
      end,
      variables = function()
        return {}
      end,
      node_text = function() end,
    })

    local html = response_body(server._handle_request("/"))
    assert.matches("__NEXT_DATA__", html, nil, true)

    local chunk_path = html:match('src="([^"]+/_next/static/chunks/pages/index%-[^"]+%.js)"')
      or html:match('src="([^"]+_next/static/chunks/pages/index%-[^"]+%.js)"')
    assert.is_truthy(chunk_path)

    local chunk = response_body(server._handle_request(chunk_path))
    assert.matches("127.0.0.1", chunk, nil, true)
    assert.matches("35913", chunk, nil, true)
    assert.is_nil(chunk:find("localhost:35903", 1, true))
    assert.is_nil(chunk:find("localhost:35901", 1, true))
    assert.is_truthy(chunk:find("/^\\s*(\\*+)(\\s+)/", 1, true))
    assert.is_truthy(chunk:find("Math.max((null!==", 1, true))

    local favicon = server._handle_request("/favicon.ico")
    assert.matches("Content-Type: image/x-icon", favicon, nil, true)
    assert.is_true(#response_body(favicon) > 0)
  end)
end)
