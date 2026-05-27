local graph = require("org-roam-ui-nvim.graph")

local function pos(offset, row, column)
  return { offset = offset, row = row or 0, column = column or 0 }
end

describe("org-roam-ui-nvim graph serialization", function()
  it("converts org-roam.nvim nodes to org-roam-ui graphdata", function()
    local core_db = {
      __nodes = {
        a = {
          id = "a",
          file = "/tmp/a.org",
          title = "A",
          tags = { "permanent", "aws" },
          level = 0,
          linked = { b = { pos(10) } },
          range = { start = pos(0), end_ = pos(100) },
        },
        b = {
          id = "b",
          file = "/tmp/b.org",
          title = "B",
          tags = { "aws" },
          level = 1,
          origin = "a",
          linked = {},
          range = { start = pos(5), end_ = pos(50) },
        },
      },
    }

    local data = graph.from_core_database(core_db)

    assert.are.same({ "aws", "permanent" }, data.tags)
    assert.are.same({
      {
        id = "a",
        file = "/tmp/a.org",
        title = "A",
        level = 0,
        pos = 1,
        olp = vim.NIL,
        properties = {},
        tags = { "permanent", "aws" },
      },
      {
        id = "b",
        file = "/tmp/b.org",
        title = "B",
        level = 1,
        pos = 6,
        olp = vim.NIL,
        properties = { ROAM_ORIGIN = "a" },
        tags = { "aws" },
      },
    }, data.nodes)
    assert.are.same({ { source = "a", target = "b", type = "id" } }, data.links)
  end)

  it("extracts headline text by byte range", function()
    local path = "/tmp/org-roam-ui-nvim-node.org"
    vim.fn.writefile({ "#+title: Test", "* One", "body", "* Two" }, path)

    local text = graph.node_text({
      file = path,
      level = 1,
      range = {
        start = pos(14, 1, 0),
        end_ = pos(25, 2, 4),
      },
    })

    assert.are.equal("* One\nbody", text)
  end)

  it("encodes empty properties as a JSON object and olp as null", function()
    local node = graph.to_orui_node({
      id = "a",
      file = "/tmp/a.org",
      title = "A",
      level = 0,
      tags = {},
      linked = {},
      range = { start = pos(0), end_ = pos(10) },
    })

    local encoded = vim.json.encode(node)
    assert.matches('"properties":{}', encoded, nil, true)
    assert.matches('"olp":null', encoded, nil, true)
  end)
end)
