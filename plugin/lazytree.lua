vim.api.nvim_create_user_command("LazyTree", function()
    require("lazytree").open()
end, { desc = "Show lazy.nvim plugin tree map" })
