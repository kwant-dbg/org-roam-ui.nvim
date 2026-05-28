local orui = require("org-roam-ui-nvim")

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

describe("org-roam-ui-nvim entrypoint", function()
  it("registers user commands", function()
    orui.setup({ open_on_start = false, refresh_on_save = false })
    local commands = vim.api.nvim_get_commands({})

    assert.is_truthy(commands.OrgRoamUiStart)
    assert.is_truthy(commands.OrgRoamUiStop)
    assert.is_truthy(commands.OrgRoamUiRefresh)
    assert.is_truthy(commands.OrgRoamUiFollow)
    assert.is_truthy(commands.OrgRoamUiSyncTheme)
    assert.is_truthy(commands.OrgRoamUiGraphData)
    assert.is_truthy(commands.OrgRoamUiToggleFollow)
    assert.is_truthy(commands.OrgRoamUiAddToLocalGraph)
    assert.is_truthy(commands.OrgRoamUiRemoveFromLocalGraph)
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
