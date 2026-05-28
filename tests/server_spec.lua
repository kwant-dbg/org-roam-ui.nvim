local server = require("org-roam-ui-nvim.server")
local repo_root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

local function response_body(response)
  return response:match("\r\n\r\n(.*)$")
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

    local favicon = server._handle_request("/favicon.svg")
    assert.matches("Content-Type: image/svg+xml", favicon, nil, true)
    assert.matches("<svg", favicon, nil, true)
  end)
end)
