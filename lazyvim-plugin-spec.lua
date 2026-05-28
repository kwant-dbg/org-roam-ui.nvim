return {
  {
    "kwant-dbg/org-roam-ui.nvim",
    dependencies = {
      "nvim-orgmode/orgmode",
      "chipsenkbeil/org-roam.nvim",
    },
    cmd = {
      "OrgRoamUiStart",
      "OrgRoamUiStop",
      "OrgRoamUiRefresh",
      "OrgRoamUiFollow",
      "OrgRoamUiSyncTheme",
      "OrgRoamUiGraphData",
      "OrgRoamUiToggleFollow",
      "OrgRoamUiAddToLocalGraph",
      "OrgRoamUiRemoveFromLocalGraph",
    },
    config = function()
      require("org-roam-ui-nvim").setup({
        port = 35911,
        websocket_port = 35913,
      })
    end,
  },
}
