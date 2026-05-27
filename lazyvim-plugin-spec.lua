return {
  {
    dir = "/path/to/org-roam-ui.nvim",
    name = "org-roam-ui-nvim",
    dependencies = { "chipsenkbeil/org-roam.nvim" },
    config = function()
      require("org-roam-ui-nvim").setup({
        port = 35911,
        websocket_port = 35913,
      })
    end,
  },
}
