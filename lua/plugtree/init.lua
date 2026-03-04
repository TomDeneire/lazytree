local M = {}

--- Parse a single spec file for plugin names.
--- Returns a list of { name, line, is_dep } entries, or nil if no plugins found.
local function parse_file(filepath)
    local lines = {}
    for line in io.lines(filepath) do
        lines[#lines + 1] = line
    end

    local plugin_pattern = "['\"]([%w_%-%.]+/[%w_%-%.]+)['\"]"
    local results = {}
    local dep_depth = 0 -- brace depth inside a dependencies block
    local in_deps = false

    for i, line in ipairs(lines) do
        -- Detect start of dependencies block
        if not in_deps and line:match("dependencies%s*=%s*{") then
            in_deps = true
            -- Count opening braces on this line (after "dependencies")
            local after = line:match("dependencies%s*=%s*(.*)")
            if after then
                for _ in after:gmatch("{") do dep_depth = dep_depth + 1 end
                for _ in after:gmatch("}") do dep_depth = dep_depth - 1 end
            end
            if dep_depth <= 0 then
                in_deps = false
                dep_depth = 0
            end
        elseif in_deps then
            for _ in line:gmatch("{") do dep_depth = dep_depth + 1 end
            for _ in line:gmatch("}") do dep_depth = dep_depth - 1 end
            if dep_depth <= 0 then
                in_deps = false
                dep_depth = 0
            end
        end

        -- Match plugin name on this line
        local name = line:match(plugin_pattern)
        if name then
            results[#results + 1] = { name = name, line = i, is_dep = in_deps }
        end
    end

    if #results == 0 then
        return nil
    end
    return results
end

--- Scan the Neovim config for all lazy.nvim plugin specs.
--- Returns a list of { file (relative path), abs (absolute path), plugins } entries.
function M.scan()
    local config_dir = vim.fn.stdpath("config")
    local init_path = config_dir .. "/init.lua"

    -- Read init.lua to find { import = 'modules.X' } patterns
    local modules = {}
    local f = io.open(init_path, "r")
    if not f then
        vim.notify("PlugTree: cannot read " .. init_path, vim.log.levels.ERROR)
        return {}
    end
    local init_content = f:read("*a")
    f:close()

    for mod in init_content:gmatch("import%s*=%s*['\"]([^'\"]+)['\"]") do
        modules[#modules + 1] = mod
    end

    local results = {}

    for _, mod in ipairs(modules) do
        -- Convert module path (e.g. "modules.editor") to directory path
        local dir = config_dir .. "/lua/" .. mod:gsub("%.", "/")
        local lua_files = vim.fn.glob(dir .. "/*.lua", false, true)
        table.sort(lua_files)

        for _, filepath in ipairs(lua_files) do
            local plugins = parse_file(filepath)
            if plugins then
                -- Build relative path like "modules/editor/telescope.lua"
                local rel = filepath:sub(#config_dir + #"/lua/" + 1)
                results[#results + 1] = {
                    file = rel,
                    abs = filepath,
                    plugins = plugins,
                }
            end
        end
    end

    return results
end

--- Render scan data into display lines and a metadata table.
--- Returns (lines, meta) where meta[line_number] = { file, lnum } or nil.
function M.render(scan_data)
    local lines = {}
    local meta = {}

    -- Header
    lines[#lines + 1] = "PlugTree — Plugin Map"
    lines[#lines + 1] = string.rep("═", 40)
    lines[#lines + 1] = ""

    for _, entry in ipairs(scan_data) do
        -- File heading
        lines[#lines + 1] = entry.file
        meta[#lines] = nil -- heading line, no navigation

        -- Separate main plugins and their dependencies
        -- Group: each main plugin followed by deps until the next main plugin
        local groups = {}
        for _, p in ipairs(entry.plugins) do
            if not p.is_dep then
                groups[#groups + 1] = { main = p, deps = {} }
            else
                if #groups > 0 then
                    local g = groups[#groups]
                    g.deps[#g.deps + 1] = p
                end
            end
        end

        for gi, group in ipairs(groups) do
            local is_last_group = (gi == #groups)
            local branch = is_last_group and "└── " or "├── "
            local prefix = is_last_group and "    " or "│   "

            -- Main plugin line
            local main_text = branch .. group.main.name
            local line_suffix = ":" .. group.main.line
            lines[#lines + 1] = main_text .. string.rep(" ", math.max(1, 60 - #main_text - #line_suffix)) .. line_suffix
            meta[#lines] = { file = entry.abs, lnum = group.main.line }

            -- Dependency lines
            for di, dep in ipairs(group.deps) do
                local is_last_dep = (di == #group.deps)
                local dep_branch = is_last_dep and "└── " or "├── "
                local dep_text = prefix .. dep_branch .. dep.name
                local dep_suffix = ":" .. dep.line
                lines[#lines + 1] = dep_text .. string.rep(" ", math.max(1, 60 - #dep_text - #dep_suffix)) .. dep_suffix
                meta[#lines] = { file = entry.abs, lnum = dep.line }
            end
        end

        -- Blank line between files
        lines[#lines + 1] = ""
    end

    -- Footer
    lines[#lines + 1] = "Keybindings: e = open file at line | q = close"

    return lines, meta
end

--- Open the PlugTree buffer in a vertical split.
function M.open()
    local scan_data = M.scan()
    if #scan_data == 0 then
        vim.notify("PlugTree: no plugins found", vim.log.levels.WARN)
        return
    end

    local lines, meta = M.render(scan_data)

    -- Create scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

    -- Write lines
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    -- Open in vertical split
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    -- Set filetype
    vim.api.nvim_set_option_value("filetype", "plugtree", { buf = buf })

    -- Keymaps
    vim.keymap.set("n", "e", function()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        local entry = meta[row]
        if entry then
            -- Close the plugtree window first, then open the file
            vim.api.nvim_win_close(win, true)
            vim.cmd("edit +" .. entry.lnum .. " " .. vim.fn.fnameescape(entry.file))
        end
    end, { buffer = buf, nowait = true, desc = "PlugTree: open file at line" })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true, desc = "PlugTree: close" })

    -- Highlights
    vim.api.nvim_set_hl(0, "PlugTreeHeader", { bold = true, link = "Title" })
    vim.api.nvim_set_hl(0, "PlugTreeSeparator", { link = "Comment" })
    vim.api.nvim_set_hl(0, "PlugTreeFile", { bold = true, link = "Directory" })
    vim.api.nvim_set_hl(0, "PlugTreeGlyph", { link = "NonText" })
    vim.api.nvim_set_hl(0, "PlugTreeLineNr", { link = "LineNr" })
    vim.api.nvim_set_hl(0, "PlugTreeFooter", { link = "Comment" })

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace("plugtree")
    for i, line in ipairs(lines) do
        local row = i - 1 -- 0-indexed
        if i == 1 then
            vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeHeader", row, 0, -1)
        elseif i == 2 then
            vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeSeparator", row, 0, -1)
        elseif line == "Keybindings: e = open file at line | q = close" then
            vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeFooter", row, 0, -1)
        elseif meta[i] then
            -- Plugin line: highlight tree glyphs and line number
            local glyph_end = line:find("[%w]") or 0
            if glyph_end > 1 then
                vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeGlyph", row, 0, glyph_end - 1)
            end
            local colon_pos = line:find(":%d+$")
            if colon_pos then
                vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeLineNr", row, colon_pos - 1, -1)
            end
        elseif line ~= "" and not meta[i] then
            -- File heading line
            vim.api.nvim_buf_add_highlight(buf, ns, "PlugTreeFile", row, 0, -1)
        end
    end
end

return M
