local orui = require("org-roam-ui-nvim")

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
end)

