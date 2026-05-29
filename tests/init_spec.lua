local orui = require("org-roam-ui-nvim")
local graph = require("org-roam-ui-nvim.graph")

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

    vim.cmd.edit(vim.fn.fnameescape(file))
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
