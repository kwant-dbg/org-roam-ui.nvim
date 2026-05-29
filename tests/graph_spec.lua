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

  it("reports missing org-roam.nvim private node table without throwing", function()
    local data, err = graph.from_core_database({})

    assert.is_nil(data)
    assert.are.equal("org-roam.nvim internal node table is unavailable", err)
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

  it("forwards refs, aliases, and NOTER_PAGE properties", function()
    local node = graph.to_orui_node({
      id = "paper",
      file = "/tmp/paper.org",
      title = "Paper",
      level = 0,
      refs = { "cite:key", "https://example.test" },
      aliases = { "Alias One", "Alias Two" },
      properties = {
        NOTER_PAGE = 42,
      },
      tags = {},
      linked = {},
      range = { start = pos(0), end_ = pos(10) },
    })

    assert.are.same({
      ROAM_REFS = "cite:key https://example.test",
      ROAM_ALIASES = "Alias One Alias Two",
      NOTER_PAGE = "42",
    }, node.properties)
  end)

  it("keeps native refs and aliases ahead of duplicate node properties", function()
    local node = graph.to_orui_node({
      id = "a",
      file = "/tmp/a.org",
      title = "A",
      level = 0,
      refs = { "native-ref" },
      aliases = { "Native Alias" },
      properties = {
        ROAM_REFS = "property-ref",
        ROAM_ALIASES = "Property Alias",
        NOTER_PAGE = "7",
      },
      tags = {},
      linked = {},
      range = { start = pos(0), end_ = pos(10) },
    })

    assert.are.same({
      ROAM_REFS = "native-ref",
      ROAM_ALIASES = "Native Alias",
      NOTER_PAGE = "7",
    }, node.properties)
  end)

  it("deduplicates and sorts links by source then target", function()
    local links = graph.links_from_nodes({
      z = {
        id = "z",
        linked = {
          b = { pos(1), pos(2) },
          a = { pos(3) },
        },
      },
      a = {
        id = "a",
        linked = {
          c = { pos(4) },
          b = { pos(5) },
        },
      },
      m = {
        id = "m",
        linked = {
          a = { pos(6) },
        },
      },
    })

    assert.are.same({
      { source = "a", target = "b", type = "id" },
      { source = "a", target = "c", type = "id" },
      { source = "m", target = "a", type = "id" },
      { source = "z", target = "a", type = "id" },
      { source = "z", target = "b", type = "id" },
    }, links)
  end)

  it("reads org-roam.nvim databases through internal_sync when present", function()
    local called = false
    local database
    database = {
      internal_sync = function(self)
        called = self == database
        return {
          __nodes = {
            a = {
              id = "a",
              file = "/tmp/a.org",
              title = "A",
              tags = {},
              level = 0,
              linked = {},
              range = { start = pos(0), end_ = pos(10) },
            },
          },
        }
      end,
    }

    local data = graph.from_database(database)

    assert.is_true(called)
    assert.are.equal("a", data.nodes[1].id)
  end)

  it("computes nested outline paths from ancestor headings", function()
    local path = "/tmp/org-roam-ui-nvim-olp.org"
    local lines = {
      "#+title: Test",
      "* Parent",
      "** Older",
      "** Child",
      "*** Leaf",
      "body",
    }
    vim.fn.writefile(lines, path)

    local text = table.concat(lines, "\n")
    local parent_offset = text:find("* Parent", 1, true) - 1
    local child_offset = text:find("** Child", 1, true) - 1
    local leaf_offset = text:find("*** Leaf", 1, true) - 1

    local data = graph.from_core_database({
      __nodes = {
        parent = {
          id = "parent",
          file = path,
          title = "Parent",
          level = 1,
          tags = {},
          linked = {},
          range = { start = pos(parent_offset), end_ = pos(child_offset) },
        },
        child = {
          id = "child",
          file = path,
          title = "Child",
          level = 2,
          tags = {},
          linked = {},
          range = { start = pos(child_offset), end_ = pos(leaf_offset) },
        },
        leaf = {
          id = "leaf",
          file = path,
          title = "Leaf",
          level = 3,
          tags = {},
          linked = {},
          range = { start = pos(leaf_offset), end_ = pos(#text) },
        },
      },
    })

    local by_id = {}
    for _, node in ipairs(data.nodes) do
      by_id[node.id] = node
    end

    assert.are.same({ "Parent", "Child" }, by_id.leaf.olp)
  end)

  it("finds nested visible subdirectories relative to the roam root", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "a", "b"), "p")
    vim.fn.mkdir(vim.fs.joinpath(root, "z"), "p")
    vim.fn.mkdir(vim.fs.joinpath(root, ".hidden", "inside"), "p")
    vim.fn.mkdir(vim.fs.joinpath(root, "a", ".secret"), "p")

    local dirs = graph.find_subdirectories(root)

    assert.are.same({ "a", "a/b", "z" }, dirs)
  end)
end)
