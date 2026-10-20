if vim.g.loaded_markdown_render then
  return
end
vim.g.loaded_markdown_render = true

vim.api.nvim_create_user_command("MarkdownRenderSetup", function()
  require("markdown-render").setup()
end, { desc = "Set up markdown-render" })

-- Make the plugin usable without requiring setup in init.lua.
require("markdown-render").setup()
