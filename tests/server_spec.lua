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

describe("org-roam-ui-nvim HTTP server", function()
  after_each(function()
    server.stop()
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
    assert.matches("<title>Org Roam</title>", html, nil, true)
    assert.matches('href="/favicon.svg"', html, nil, true)

    local chunk_path = html:match('src="([^"]+/_next/static/chunks/pages/index%-[^"]+%.js)"')
      or html:match('src="([^"]+_next/static/chunks/pages/index%-[^"]+%.js)"')
    assert.is_truthy(chunk_path)

    local chunk = response_body(server._handle_request(chunk_path))
    assert.matches("127.0.0.1", chunk, nil, true)
    assert.matches("35913", chunk, nil, true)
    assert.matches("35911", chunk, nil, true)
    assert.is_nil(chunk:find("localhost:35903", 1, true))
    assert.is_nil(chunk:find("localhost:35901", 1, true))
    assert.is_truthy(chunk:find("/^\\s*(\\*+)(\\s+)/", 1, true))
    assert.is_truthy(chunk:find("Math.max((null!==", 1, true))

    local favicon = server._handle_request("/favicon.svg")
    assert.matches("Content-Type: image/svg+xml", favicon, nil, true)
    assert.matches("<svg", favicon, nil, true)
  end)
end)
