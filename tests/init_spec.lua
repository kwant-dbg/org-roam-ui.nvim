local orui = require("org-roam-ui-nvim")
local graph = require("org-roam-ui-nvim.graph")
local server = require("org-roam-ui-nvim.server")
local websocket = require("org-roam-ui-nvim.websocket")

local function resolved_promise(value)
  return {
    next = function(_, cb)
      cb(value)
      return resolved_promise(value)
    end,
    catch = function(self)
      return self
    end,
  }
end

local function with_silent_notify(fn)
  local notify = vim.notify
  vim.notify = function() end
  local ok, result = pcall(fn)
  vim.notify = notify
  assert.is_true(ok, result)
  return result
end

local expected_commands = {
  "OrgRoamUiStart",
  "OrgRoamUiStop",
  "OrgRoamUiRefresh",
  "OrgRoamUiFollow",
  "OrgRoamUiSyncTheme",
  "OrgRoamUiGraphData",
  "OrgRoamUiToggleFollow",
  "OrgRoamUiAddToLocalGraph",
  "OrgRoamUiRemoveFromLocalGraph",
}

describe("org-roam-ui-nvim entrypoint", function()
  it("stops HTTP when websocket startup fails and can retry", function()
    orui.setup({ open_on_start = false, refresh_on_save = false })

    local original_server_start = server.start
    local original_server_stop = server.stop
    local original_websocket_start = websocket.start
    local events = {}

    server.start = function()
      table.insert(events, "server.start")
    end
    server.stop = function()
      table.insert(events, "server.stop")
    end
    websocket.start = function()
      table.insert(events, "websocket.start.fail")
      error("websocket bind failed")
    end

    local ok = pcall(orui.start)
    assert.is_false(ok)
    assert.are.same({ "server.start", "websocket.start.fail", "server.stop" }, events)

    events = {}
    websocket.start = function()
      table.insert(events, "websocket.start.ok")
    end

    ok = pcall(orui.start)

    server.start = original_server_start
    server.stop = original_server_stop
    websocket.start = original_websocket_start

    assert.is_true(ok)
    assert.are.same({ "server.start", "websocket.start.ok" }, events)
  end)

  it("registers user commands", function()
    orui.setup({ open_on_start = false, refresh_on_save = false })
    local commands = vim.api.nvim_get_commands({})

    for _, command in ipairs(expected_commands) do
      assert.is_truthy(commands[command], command)
    end
  end)

  it("documents registered user commands in vimdoc", function()
    local doc_path = vim.fs.joinpath(vim.fn.getcwd(), "doc", "org-roam-ui-nvim.txt")
    local doc = table.concat(vim.fn.readfile(doc_path), "\n")

    for _, command in ipairs(expected_commands) do
      assert.is_truthy(doc:find("*:" .. command .. "*", 1, true), command)
    end
  end)

  it("auto-follow tracks cursor movement in org buffers", function()
    orui.setup({ open_on_start = false, refresh_on_save = false })

    vim.cmd.OrgRoamUiToggleFollow()
    local autocmds = vim.api.nvim_get_autocmds({ group = "org_roam_ui_nvim_follow" })
    local events = {}
    for _, autocmd in ipairs(autocmds) do
      events[autocmd.event] = true
    end
    vim.cmd.OrgRoamUiToggleFollow()

    assert.is_true(events.BufEnter)
    assert.is_true(events.CursorMoved)
    assert.is_true(events.CursorMovedI)
  end)

  it("auto-follow debounce handles org buffer events", function()
    local followed_id
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      follow_debounce_ms = 1,
      org_roam = {
        utils = {
          node_under_cursor = function(cb)
            cb({ id = "node-id" })
          end,
        },
      },
    })

    local follow_node = orui.follow_node
    orui.follow_node = function(id)
      followed_id = id
    end

    local file = vim.fn.tempname() .. ".org"

    vim.cmd.OrgRoamUiToggleFollow()
    vim.cmd("silent keepalt noswapfile edit " .. vim.fn.fnameescape(file))
    local did_follow = vim.wait(1000, function()
      return followed_id == "node-id"
    end, 10)
    vim.cmd.OrgRoamUiToggleFollow()

    orui.follow_node = follow_node
    vim.cmd.bwipeout({ bang = true })

    assert.is_true(did_follow)
    assert.are.equal("node-id", followed_id)
  end)

  it("creates nodes through org-roam.nvim capture", function()
    local captured_opts
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        api = {
          capture_node = function(opts)
            captured_opts = opts
            return resolved_promise("created-id")
          end,
        },
      },
    })

    local result = orui.create_node({ title = "New note", origin = "origin-id" })

    assert.are.equal("New note", captured_opts.title)
    assert.are.equal("origin-id", captured_opts.origin)
    assert.is_false(captured_opts.immediate)
    assert.is_table(result)
  end)

  it("uses explicit config for frontend variables before org-roam paths", function()
    local called_with
    local original_find_subdirectories = graph.find_subdirectories
    graph.find_subdirectories = function(path)
      called_with = path
      return { "projects" }
    end

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = "/tmp/config-roam",
      daily_dir = "/tmp/config-daily",
      attach_dir = "/tmp/config-attach",
      use_inheritance = true,
      katex_macros = { RR = "\\mathbb{R}" },
      org_roam = {
        database = {
          files_path = function()
            return "/tmp/org-roam"
          end,
        },
      },
    })

    local variables = orui.variables()
    graph.find_subdirectories = original_find_subdirectories

    assert.are.equal("/tmp/config-roam", called_with)
    assert.are.same({ "projects" }, variables.subDirs)
    assert.are.equal("/tmp/config-roam", variables.roamDir)
    assert.are.equal("/tmp/config-daily", variables.dailyDir)
    assert.are.equal("/tmp/config-attach", variables.attachDir)
    assert.is_true(variables.useInheritance)
    assert.are.same({ RR = "\\mathbb{R}" }, variables.katexMacros)
  end)

  it("derives frontend variable directories from org-roam roam_dir", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "daily"), "p")
    vim.fn.mkdir(vim.fs.joinpath(root, ".attach"), "p")
    vim.fn.mkdir(vim.fs.joinpath(root, "projects"), "p")

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        database = {
          files_path = function()
            return root
          end,
        },
      },
    })

    local variables = orui.variables()

    assert.are.equal(root, variables.roamDir)
    assert.are.equal(vim.fs.joinpath(root, "daily"), variables.dailyDir)
    assert.are.equal(vim.fs.joinpath(root, ".attach"), variables.attachDir)
    assert.is_false(variables.useInheritance)
    assert.are.same({ "daily", "projects" }, variables.subDirs)
  end)

  it("returns empty frontend variable paths when no roam_dir is available", function()
    local original_find_subdirectories = graph.find_subdirectories
    graph.find_subdirectories = function()
      error("variables should not scan subdirectories without a roam_dir")
    end

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {},
    })

    local variables = orui.variables()
    graph.find_subdirectories = original_find_subdirectories

    assert.are.equal("", variables.roamDir)
    assert.are.equal("", variables.dailyDir)
    assert.are.equal("", variables.attachDir)
    assert.are.same({}, variables.subDirs)
  end)

  it("returns an empty graph when org-roam is unavailable", function()
    orui.setup({ open_on_start = false, refresh_on_save = false, org_roam = {} })

    local data = with_silent_notify(function()
      return orui.graph_data()
    end)

    assert.are.same({ nodes = {}, links = {}, tags = {} }, data)
  end)

  it("returns an empty graph when org-roam private nodes are unavailable", function()
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        database = {},
      },
    })

    local data = with_silent_notify(function()
      return orui.graph_data()
    end)

    assert.are.same({ nodes = {}, links = {}, tags = {} }, data)
  end)

  it("returns nil for missing node text without throwing", function()
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        database = {
          get_sync = function()
            return nil
          end,
        },
      },
    })

    assert.is_nil(orui.node_text("missing-id"))
  end)

  it("returns false when opening a missing node", function()
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        database = {
          get_sync = function()
            return nil
          end,
        },
      },
    })

    assert.is_false(orui.open_node("missing-id"))
  end)

  it("returns false when opening without an org-roam database", function()
    orui.setup({ open_on_start = false, refresh_on_save = false, org_roam = {} })

    local result = with_silent_notify(function()
      return orui.open_node("node-id")
    end)

    assert.is_false(result)
  end)

  it("deletes confirmed file-level nodes inside the roam directory", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    local load_opts
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function(args)
        assert.are.equal("node-id", args.id)
        assert.are.equal(vim.fs.normalize(file), args.file)
        return true
      end,
      org_roam = {
        database = {
          get_sync = function(_, id)
            if id == "node-id" then
              return { id = id, file = file, level = 0 }
            end
          end,
          load = function(_, opts)
            load_opts = opts
            return resolved_promise(true)
          end,
        },
      },
    })

    local result = orui.delete_node({ id = "node-id", file = file })

    assert.are.same({ force = "scan" }, load_opts)
    assert.are.equal(0, vim.fn.filereadable(file))
    assert.is_table(result)
  end)

  it("refuses delete payloads without node id and file", function()
    orui.setup({ open_on_start = false, refresh_on_save = false })

    local result = with_silent_notify(function()
      return orui.delete_node({ id = "node-id" })
    end)

    assert.is_false(result)
  end)

  it("refuses to delete missing nodes", function()
    local looked_up_id
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      org_roam = {
        database = {
          get_sync = function(_, id)
            looked_up_id = id
          end,
        },
      },
    })

    local result = with_silent_notify(function()
      return orui.delete_node({ id = "missing-id", file = "/tmp/missing.org" })
    end)

    assert.is_false(result)
    assert.are.equal("missing-id", looked_up_id)
  end)

  it("refuses delete when payload file does not match the node file", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    local other = vim.fs.joinpath(dir, "other.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    local result = with_silent_notify(function()
      return orui.delete_node({ id = "node-id", file = other })
    end)

    assert.is_false(result)
    assert.are.equal(1, vim.fn.filereadable(file))
  end)

  it("refuses to delete files outside the roam directory", function()
    local roam_dir = vim.fn.tempname()
    local outside_dir = vim.fn.tempname()
    vim.fn.mkdir(roam_dir, "p")
    vim.fn.mkdir(outside_dir, "p")
    local file = vim.fs.joinpath(outside_dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = roam_dir,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    local result = with_silent_notify(function()
      return orui.delete_node({ id = "node-id", file = file })
    end)

    assert.is_false(result)
    assert.are.equal(1, vim.fn.filereadable(file))
  end)

  it("refuses to delete modified buffers", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    local confirmed = false
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function()
        confirmed = true
        return true
      end,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    vim.cmd("silent keepalt noswapfile edit " .. vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#+title: Changed" })
    local result = with_silent_notify(function()
      return orui.delete_node({ id = "node-id", file = file })
    end)
    vim.cmd.bwipeout({ bang = true })

    assert.is_false(result)
    assert.is_false(confirmed)
    assert.are.equal(1, vim.fn.filereadable(file))
  end)

  it("does not delete when confirmation is cancelled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function()
        return false
      end,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    assert.is_false(orui.delete_node({ id = "node-id", file = file }))
    assert.are.equal(1, vim.fn.filereadable(file))
  end)

  it("reports failed file deletion", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.mkdir(file, "p")
    vim.fn.writefile({ "child" }, vim.fs.joinpath(file, "child.txt"))

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function()
        return true
      end,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    local result = with_silent_notify(function()
      return orui.delete_node({ id = "node-id", file = file })
    end)

    assert.is_false(result)
    assert.are.equal(1, vim.fn.isdirectory(file))
  end)

  it("does not scan subdirectories while checking delete path safety", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function()
        return true
      end,
      org_roam = {
        database = {
          get_sync = function()
            return { id = "node-id", file = file, level = 0 }
          end,
        },
      },
    })

    local original_find_subdirectories = graph.find_subdirectories
    graph.find_subdirectories = function()
      error("delete path guard should not scan subdirectories")
    end

    local ok, result = pcall(orui.delete_node, { id = "node-id", file = file })
    graph.find_subdirectories = original_find_subdirectories

    assert.is_true(ok)
    assert.is_true(result)
  end)

  it("refreshes saved org files after async load_file resolves", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note" }, file)

    local load_called = false
    local resolve_load
    local refresh_called = false

    orui.setup({
      open_on_start = false,
      refresh_on_save = true,
      roam_dir = dir,
      org_roam = {
        database = {
          load_file = function(_, opts)
            load_called = true
            assert.are.equal(file, opts.path)
            assert.is_true(opts.force)
            return {
              next = function(self, cb)
                resolve_load = cb
                return self
              end,
            }
          end,
        },
      },
    })

    local original_find_subdirectories = graph.find_subdirectories
    local original_refresh = orui.refresh
    graph.find_subdirectories = function()
      error("BufWritePost path guard should not scan subdirectories")
    end
    orui.refresh = function()
      refresh_called = true
    end

    vim.cmd("silent keepalt noswapfile edit " .. vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#+title: Note", "* Changed" })
    local ok, err = pcall(vim.cmd.write)

    assert.is_true(ok, err)
    assert.is_true(load_called)
    assert.is_function(resolve_load)
    assert.is_false(refresh_called)

    resolve_load()
    vim.wait(1000, function()
      return refresh_called
    end, 10)

    graph.find_subdirectories = original_find_subdirectories
    orui.refresh = original_refresh
    vim.cmd.bwipeout({ bang = true })

    assert.is_true(refresh_called)
  end)

  it("refuses to delete heading nodes", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = vim.fs.joinpath(dir, "note.org")
    vim.fn.writefile({ "#+title: Note", "* Heading" }, file)

    local confirmed = false
    orui.setup({
      open_on_start = false,
      refresh_on_save = false,
      roam_dir = dir,
      confirm_delete = function()
        confirmed = true
        return true
      end,
      org_roam = {
        database = {
          get_sync = function(_, id)
            if id == "node-id" then
              return { id = id, file = file, level = 1 }
            end
          end,
        },
      },
    })

    local notify = vim.notify
    vim.notify = function() end
    local ok, result = pcall(orui.delete_node, { id = "node-id", file = file })
    vim.notify = notify
    assert.is_true(ok)
    assert.is_false(result)

    assert.is_false(confirmed)
    assert.are.equal(1, vim.fn.filereadable(file))
  end)
end)
