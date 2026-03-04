vim.api.nvim_create_user_command("PlugTree", function()
    require("plugtree").open()
end, { desc = "Show plugin tree map" })
