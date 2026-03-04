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
        -- Supports: "owner/repo", dir = "path", url = "https://..."
        local name = line:match(plugin_pattern)
        if not name then
            local dir_path = line:match("dir%s*=%s*['\"]([^'\"]+)['\"]")
            if dir_path then
                name = dir_path:match("([^/]+)$") or dir_path
            end
        end
        if not name then
            local url = line:match("url%s*=%s*['\"]([^'\"]+)['\"]")
            if url then
                -- Extract owner/repo from URL (e.g. https://github.com/owner/repo.git)
                name = url:match("([%w_%-%.]+/[%w_%-%.]+)%.git$")
                    or url:match("([%w_%-%.]+/[%w_%-%.]+)$")
                    or url:match("([^/]+)$")
            end
        end
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

    local f = io.open(init_path, "r")
    if not f then
        vim.notify("LazyTree: cannot read " .. init_path, vim.log.levels.ERROR)
        return {}
    end
    local init_content = f:read("*a")
    f:close()

    local results = {}

    -- Parse init.lua itself for plugin specs
    local init_plugins = parse_file(init_path)
    if init_plugins then
        results[#results + 1] = {
            file = "init.lua",
            abs = init_path,
            plugins = init_plugins,
        }
    end

    -- Collect spec directories from two patterns:
    -- 1. { import = 'some.module' } directives
    -- 2. require("lazy").setup("dirname") string shorthand
    local dirs = {}

    for mod in init_content:gmatch("import%s*=%s*['\"]([^'\"]+)['\"]") do
        dirs[#dirs + 1] = config_dir .. "/lua/" .. mod:gsub("%.", "/")
    end

    -- Match require("lazy").setup("plugins") or require('lazy').setup('plugins')
    local setup_str = init_content:match("require%s*%(%s*['\"]lazy['\"]%s*%)%s*%.%s*setup%s*%(%s*['\"]([^'\"]+)['\"]")
    if setup_str then
        dirs[#dirs + 1] = config_dir .. "/lua/" .. setup_str:gsub("%.", "/")
    end

    for _, dir in ipairs(dirs) do
        -- Recursively glob all .lua files (lazy.nvim recurses into subdirs)
        local lua_files = vim.fn.glob(dir .. "/**/*.lua", false, true)
        -- Also include top-level .lua files (glob ** doesn't match zero dirs in all cases)
        local top_files = vim.fn.glob(dir .. "/*.lua", false, true)
        -- Merge and deduplicate
        local seen = {}
        local all_files = {}
        for _, file in ipairs(top_files) do
            if not seen[file] then
                seen[file] = true
                all_files[#all_files + 1] = file
            end
        end
        for _, file in ipairs(lua_files) do
            if not seen[file] then
                seen[file] = true
                all_files[#all_files + 1] = file
            end
        end
        table.sort(all_files)

        for _, filepath in ipairs(all_files) do
            local plugins = parse_file(filepath)
            if plugins then
                -- Build relative path from the lua/ directory
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
--- Returns (lines, meta, header_count) where meta[line_number] = { file, lnum } or nil.
function M.render(scan_data)
    local lines = {}
    local meta = {}

    -- Header
    local header = {
        "  _                    _____              ",
        " | |    __ _ _____   _|_   _| __ ___  ___ ",
        " | |   / _` |_  / | | | | || '__/ _ \\/ _ \\",
        " | |__| (_| |/ /| |_| | | || | |  __/  __/",
        " |_____\\__,_/___|\\__, | |_||_|  \\___|\\___|",
        "                 |___/                     ",
        "",
    }
    for _, h in ipairs(header) do
        lines[#lines + 1] = h
    end

    for _, entry in ipairs(scan_data) do
        -- File heading
        lines[#lines + 1] = entry.file
        meta[#lines] = { file = entry.abs, lnum = 1 }

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

    return lines, meta, #header
end

--- Open the LazyTree buffer in a vertical split.
function M.open()
    local scan_data = M.scan()
    if #scan_data == 0 then
        vim.notify("LazyTree: no plugins found", vim.log.levels.WARN)
        return
    end

    local lines, meta, header_lines = M.render(scan_data)

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
    vim.api.nvim_set_option_value("filetype", "lazytree", { buf = buf })

    -- Keymaps
    vim.keymap.set("n", "e", function()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        local entry = meta[row]
        if entry then
            -- Read file content
            local file_lines = {}
            for line in io.lines(entry.file) do
                file_lines[#file_lines + 1] = line
            end

            -- Create floating window
            local width = math.floor(vim.o.columns * 0.8)
            local height = math.floor(vim.o.lines * 0.8)
            local float_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, file_lines)
            vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
            vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = float_buf })

            -- Detect filetype from extension for syntax highlighting
            local ft = vim.filetype.match({ filename = entry.file }) or ""
            if ft ~= "" then
                vim.api.nvim_set_option_value("filetype", ft, { buf = float_buf })
            end

            local float_win = vim.api.nvim_open_win(float_buf, true, {
                relative = "editor",
                width = width,
                height = height,
                row = math.floor((vim.o.lines - height) / 2),
                col = math.floor((vim.o.columns - width) / 2),
                style = "minimal",
                border = "rounded",
                title = " " .. vim.fn.fnamemodify(entry.file, ":t") .. " ",
                title_pos = "center",
            })

            -- Jump to the relevant line
            vim.api.nvim_win_set_cursor(float_win, { entry.lnum, 0 })
            vim.cmd("normal! zz")

            -- Close float with q
            vim.keymap.set("n", "q", function()
                vim.api.nvim_win_close(float_win, true)
            end, { buffer = float_buf, nowait = true })
        end
    end, { buffer = buf, nowait = true, desc = "LazyTree: open file at line" })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true, desc = "LazyTree: close" })

    -- Highlights
    vim.api.nvim_set_hl(0, "LazyTreeHeader", { bold = true, link = "Title" })
    vim.api.nvim_set_hl(0, "LazyTreeFile", { bold = true, link = "Directory" })
    vim.api.nvim_set_hl(0, "LazyTreeGlyph", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LazyTreeLineNr", { link = "LineNr" })
    vim.api.nvim_set_hl(0, "LazyTreeFooter", { link = "Comment" })

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace("lazytree")
    for i, line in ipairs(lines) do
        local row = i - 1 -- 0-indexed
        if i <= header_lines then
            vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeHeader", row, 0, -1)
        elseif line == "Keybindings: e = open file at line | q = close" then
            vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeFooter", row, 0, -1)
        elseif meta[i] and line:match("^[├└│ ]") then
            -- Plugin line: highlight tree glyphs and line number
            local glyph_end = line:find("[%w]") or 0
            if glyph_end > 1 then
                vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeGlyph", row, 0, glyph_end - 1)
            end
            local colon_pos = line:find(":%d+$")
            if colon_pos then
                vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeLineNr", row, colon_pos - 1, -1)
            end
        elseif meta[i] and not line:match("^[├└│ ]") then
            -- File heading line
            vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeFile", row, 0, -1)
        end
    end
end

return M
