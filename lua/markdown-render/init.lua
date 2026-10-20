local M = {}

local state = {
  source = nil,
  preview = nil,
  window = nil,
  images = {},
  tempfiles = {},
  augroup = nil,
}

local config = {
  split = "right",
  width = 80,
  image_width = 60,
  image_height = 20,
  mermaid_command = "mmdc",
}

local function notify(message, level)
  vim.notify("markdown-render: " .. message, level or vim.log.levels.INFO)
end

local function clear_images()
  if vim.ui.img and vim.ui.img.del then
    for _, id in ipairs(state.images) do
      vim.ui.img.del(id)
    end
  end
  state.images = {}
  for _, path in ipairs(state.tempfiles) do
    vim.fn.delete(path)
  end
  state.tempfiles = {}
end

local function close_preview()
  clear_images()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    vim.api.nvim_win_close(state.window, true)
  end
  if state.preview and vim.api.nvim_buf_is_valid(state.preview) then
    vim.api.nvim_buf_delete(state.preview, { force = true })
  end
  state.window, state.preview = nil, nil
end

local function source_dir()
  return vim.fs.dirname(vim.api.nvim_buf_get_name(state.source)) or vim.fn.getcwd()
end

local function image_path(path)
  if path:match("^%a[%w+.-]*://") then
    return nil
  end
  return vim.fs.normalize(vim.fs.joinpath(source_dir(), path))
end

local function render_mermaid(source)
  if vim.fn.executable(config.mermaid_command) == 0 then
    notify("Mermaid needs '" .. config.mermaid_command .. "' (npm install -g @mermaid-js/mermaid-cli)", vim.log.levels.WARN)
    return nil
  end

  local input, output = vim.fn.tempname() .. ".mmd", vim.fn.tempname() .. ".png"
  vim.fn.writefile(vim.split(source, "\n", { plain = true }), input)
  local result = vim.system({ config.mermaid_command, "-i", input, "-o", output, "-b", "transparent" }):wait()
  vim.fn.delete(input)
  if result.code ~= 0 or vim.fn.filereadable(output) == 0 then
    vim.fn.delete(output)
    notify("could not render Mermaid: " .. (result.stderr or "mmdc failed"), vim.log.levels.ERROR)
    return nil
  end
  return output
end

local function add_image(path, row)
  if not vim.ui.img or vim.fn.filereadable(path) == 0 then
    return
  end
  local id = vim.ui.img.set(vim.fn.readblob(path), {
    row = row,
    col = 2,
    width = config.image_width,
    height = config.image_height,
    zindex = 10,
  })
  table.insert(state.images, id)
end

local function preview_lines(lines)
  local output, images, index = {}, {}, 0
  local in_mermaid, mermaid = false, {}

  local function blank_for_image(path, height)
    local row = #output + 1
    for _ = 1, height do
      table.insert(output, "")
    end
    table.insert(images, { path = path, row = row })
  end

  for _, line in ipairs(lines) do
    local fence = line:match("^%s*```%s*(.*)$")
    if fence and fence:lower() == "mermaid" then
      in_mermaid, mermaid = true, {}
    elseif in_mermaid and line:match("^%s*```%s*$") then
      local path = render_mermaid(table.concat(mermaid, "\n"))
      if path then
        table.insert(state.tempfiles, path)
        blank_for_image(path, config.image_height)
      else
        table.insert(output, "[Mermaid diagram unavailable]")
      end
      in_mermaid = false
    elseif in_mermaid then
      table.insert(mermaid, line)
    else
      local alt, path = line:match("!%[([^]]*)%]%(([^)]+)%)")
      if path then
        local absolute = image_path(path:gsub("%s+['\"]?.*$", ""))
        if absolute and vim.fn.filereadable(absolute) == 1 then
          blank_for_image(absolute, config.image_height)
        else
          table.insert(output, line)
          notify("image not found: " .. path, vim.log.levels.WARN)
        end
      else
        line = line:gsub("^%s*######%s*(.*)$", "      %1")
          :gsub("^%s*####%s*(.*)$", "    %1")
          :gsub("^%s*###%s*(.*)$", "  %1")
          :gsub("^%s*##%s*(.*)$", "# %1")
          :gsub("^%s*#%s*(.*)$", "# %1")
        table.insert(output, line)
      end
    end
  end
  return output, images
end

local function refresh()
  if not state.source or not vim.api.nvim_buf_is_valid(state.source) then
    return
  end
  if not state.preview or not vim.api.nvim_buf_is_valid(state.preview) then
    return
  end

  clear_images()
  local rendered, images = preview_lines(vim.api.nvim_buf_get_lines(state.source, 0, -1, false))
  vim.api.nvim_buf_set_lines(state.preview, 0, -1, false, rendered)
  vim.bo[state.preview].modifiable = false
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    local current = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(state.window)
    for _, image in ipairs(images) do
      add_image(image.path, image.row)
    end
    if vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(current)
    end
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  vim.api.nvim_create_user_command("MarkdownRender", function()
    M.toggle()
  end, { desc = "Render the current Markdown file", force = true })
end

function M.toggle()
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    close_preview()
    return
  end
  if vim.bo.filetype ~= "markdown" then
    notify("current buffer is not Markdown", vim.log.levels.WARN)
  end
  if not vim.ui.img then
    notify("Neovim 0.13+ with vim.ui.img is required", vim.log.levels.ERROR)
    return
  end

  state.source = vim.api.nvim_get_current_buf()
  vim.cmd(config.split == "left" and "vertical leftabove new" or "vertical belowright new")
  state.window, state.preview = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[state.preview].buftype = "nofile"
  vim.bo[state.preview].bufhidden = "wipe"
  vim.bo[state.preview].filetype = "markdown"
  vim.bo[state.preview].swapfile = false
  vim.bo[state.preview].modifiable = true
  vim.api.nvim_buf_set_name(state.preview, "markdown://" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(state.source), ":t"))
  vim.api.nvim_win_set_width(state.window, config.width)

  state.augroup = vim.api.nvim_create_augroup("MarkdownRenderPreview", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = state.augroup,
    buffer = state.source,
    callback = refresh,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    once = true,
    pattern = tostring(state.window),
    callback = close_preview,
  })
  refresh()
end

return M
