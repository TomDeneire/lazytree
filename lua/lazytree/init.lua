local M = {}

function M.setup(opts)
    opts = opts or {}
end

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
        -- Skip commented-out lines
        if line:match("^%s*%-%-") then
            goto continue
        end

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

        ::continue::
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

--- Feature 1: Get plugin load status from lazy.nvim
local function get_plugin_status()
    local ok, lazy = pcall(require, "lazy")
    if not ok then
        return {}
    end
    local status = {}
    local plugins = lazy.plugins()
    for _, plugin in ipairs(plugins) do
        local short = plugin.name or (plugin[1] and plugin[1]:match("[^/]+$")) or ""
        if plugin._.loaded then
            status[short] = "loaded"
        else
            status[short] = "not_loaded"
        end
    end
    return status
end

--- Feature 2: Build reverse dependency map from scan data
local function build_reverse_deps(scan_data)
    local reverse = {} -- dep_short_name -> { parent1, parent2, ... }
    for _, entry in ipairs(scan_data) do
        local groups = {}
        for _, p in ipairs(entry.plugins) do
            if not p.is_dep then
                groups[#groups + 1] = { main = p, deps = {} }
            else
                if #groups > 0 then
                    groups[#groups].deps[#groups[#groups].deps + 1] = p
                end
            end
        end
        for _, group in ipairs(groups) do
            local parent = group.main.name:match("[^/]+$") or group.main.name
            for _, dep in ipairs(group.deps) do
                local dep_short = dep.name:match("[^/]+$") or dep.name
                if not reverse[dep_short] then
                    reverse[dep_short] = {}
                end
                -- Avoid duplicates
                local found = false
                for _, existing in ipairs(reverse[dep_short]) do
                    if existing == parent then found = true; break end
                end
                if not found then
                    reverse[dep_short][#reverse[dep_short] + 1] = parent
                end
            end
        end
    end
    return reverse
end

--- Feature 7: Extract brace-matched spec block from a file starting at a given line
local function extract_spec_block(filepath, start_line)
    local file_lines = {}
    for line in io.lines(filepath) do
        file_lines[#file_lines + 1] = line
    end

    -- Find the opening brace on or near start_line
    local brace_line = nil
    for i = start_line, math.min(start_line + 5, #file_lines) do
        if file_lines[i] and file_lines[i]:find("{") then
            brace_line = i
            break
        end
    end
    if not brace_line then
        return nil
    end

    local depth = 0
    local result = {}
    for i = brace_line, #file_lines do
        result[#result + 1] = file_lines[i]
        for _ in file_lines[i]:gmatch("{") do depth = depth + 1 end
        for _ in file_lines[i]:gmatch("}") do depth = depth - 1 end
        if depth <= 0 then
            break
        end
    end
    return result
end

--- Render scan data into display lines and a metadata table.
--- Returns (lines, meta, header_count, group_ranges) where:
---   meta[line_number] = { file, lnum, plugin_name }
---   group_ranges = list of { start_line, end_line } for cursor-follow highlights
function M.render(scan_data, opts)
    opts = opts or {}
    local fold_state = opts.fold_state or {}
    local filter_text = opts.filter_text or ""
    local plugin_status = opts.plugin_status or {}
    local reverse_deps = opts.reverse_deps or {}

    local lines = {}
    local meta = {}
    local group_ranges = {}

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

    -- Keybindings bar right after header
    lines[#lines + 1] = "Keybindings: e = edit | q/<Esc> = close | za/zo/zc = fold | / = filter | gx = homepage | K = preview"
    lines[#lines + 1] = ""

    local filter_lower = filter_text:lower()

    for _, entry in ipairs(scan_data) do
        -- Separate main plugins and their dependencies
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

        -- Feature 4: Filter groups by search term
        local filtered_groups = {}
        if filter_text ~= "" then
            for _, group in ipairs(groups) do
                local match = group.main.name:lower():find(filter_lower, 1, true)
                if not match then
                    for _, dep in ipairs(group.deps) do
                        if dep.name:lower():find(filter_lower, 1, true) then
                            match = true
                            break
                        end
                    end
                end
                if match then
                    filtered_groups[#filtered_groups + 1] = group
                end
            end
        else
            filtered_groups = groups
        end

        if #filtered_groups == 0 then
            goto continue_entry
        end

        -- File heading
        local heading_key = entry.file
        local is_folded = fold_state[heading_key]

        if is_folded then
            -- Feature 3: Show folded heading with plugin count
            local plugin_count = #filtered_groups
            local dep_count = 0
            for _, g in ipairs(filtered_groups) do
                dep_count = dep_count + #g.deps
            end
            local total = plugin_count + dep_count
            lines[#lines + 1] = entry.file .. "  [+" .. total .. " plugins]"
            meta[#lines] = { file = entry.abs, lnum = 1, is_heading = true, heading_key = heading_key }
        else
            lines[#lines + 1] = entry.file
            meta[#lines] = { file = entry.abs, lnum = 1, is_heading = true, heading_key = heading_key }

            for gi, group in ipairs(filtered_groups) do
                local is_last_group = (gi == #filtered_groups)
                local branch = is_last_group and "└── " or "├── "
                local prefix = is_last_group and "    " or "│   "

                -- Feature 1: Status indicator
                local short_name = group.main.name:match("[^/]+$") or group.main.name
                local status_icon = ""
                if plugin_status[short_name] == "loaded" then
                    status_icon = "● "
                elseif plugin_status[short_name] == "not_loaded" then
                    status_icon = "○ "
                end

                -- Main plugin line
                local main_text = branch .. status_icon .. group.main.name
                local line_suffix = ":" .. group.main.line
                lines[#lines + 1] = main_text .. string.rep(" ", math.max(1, 60 - vim.fn.strdisplaywidth(main_text) - #line_suffix)) .. line_suffix
                meta[#lines] = { file = entry.abs, lnum = group.main.line, plugin_name = group.main.name }

                local group_start = #lines

                -- Dependency lines
                for di, dep in ipairs(group.deps) do
                    local is_last_dep = (di == #group.deps)
                    local dep_branch = is_last_dep and "└── " or "├── "

                    -- Feature 1: Status indicator for dep
                    local dep_short = dep.name:match("[^/]+$") or dep.name
                    local dep_status_icon = ""
                    if plugin_status[dep_short] == "loaded" then
                        dep_status_icon = "● "
                    elseif plugin_status[dep_short] == "not_loaded" then
                        dep_status_icon = "○ "
                    end

                    -- Feature 2: Reverse dependency info
                    local used_by = ""
                    if reverse_deps[dep_short] then
                        local users = {}
                        for _, u in ipairs(reverse_deps[dep_short]) do
                            if u ~= short_name then
                                users[#users + 1] = u
                            end
                        end
                        if #users > 0 then
                            used_by = " (used by: " .. table.concat(users, ", ") .. ")"
                        end
                    end

                    local dep_text = prefix .. dep_branch .. dep_status_icon .. dep.name
                    local dep_suffix = ":" .. dep.line
                    local dep_line = dep_text .. string.rep(" ", math.max(1, 60 - vim.fn.strdisplaywidth(dep_text) - #dep_suffix)) .. dep_suffix
                    if used_by ~= "" then
                        dep_line = dep_line .. used_by
                    end
                    lines[#lines + 1] = dep_line
                    meta[#lines] = { file = entry.abs, lnum = dep.line, plugin_name = dep.name }
                end

                group_ranges[#group_ranges + 1] = { start_line = group_start, end_line = #lines }
            end
        end

        -- Blank line between files
        lines[#lines + 1] = ""

        ::continue_entry::
    end

    return lines, meta, #header, group_ranges
end

--- Open the LazyTree buffer in a floating window.
function M.open()
    local scan_data = M.scan()
    if #scan_data == 0 then
        vim.notify("LazyTree: no plugins found", vim.log.levels.WARN)
        return
    end

    -- State
    local fold_state = {}
    local filter_text = ""
    local plugin_status = get_plugin_status()
    local reverse_deps = build_reverse_deps(scan_data)

    -- Create scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

    -- Open in floating window
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
    })

    -- Set filetype
    vim.api.nvim_set_option_value("filetype", "lazytree", { buf = buf })

    -- Highlight definitions
    vim.api.nvim_set_hl(0, "LazyTreeHeader", { default = true, bold = true, link = "Title" })
    vim.api.nvim_set_hl(0, "LazyTreeFile", { default = true, bold = true, link = "Directory" })
    vim.api.nvim_set_hl(0, "LazyTreeGlyph", { default = true, link = "NonText" })
    vim.api.nvim_set_hl(0, "LazyTreeLineNr", { default = true, link = "LineNr" })
    vim.api.nvim_set_hl(0, "LazyTreeFooter", { default = true, link = "Comment" })
    vim.api.nvim_set_hl(0, "LazyTreeLoaded", { default = true, bold = true, link = "DiagnosticOk" })
    vim.api.nvim_set_hl(0, "LazyTreeNotLoaded", { default = true, link = "Comment" })
    vim.api.nvim_set_hl(0, "LazyTreeUsedBy", { default = true, italic = true, link = "Special" })
    vim.api.nvim_set_hl(0, "LazyTreeCursorGroup", { default = true, link = "CursorLine" })

    local ns = vim.api.nvim_create_namespace("lazytree")
    local ns_cursor = vim.api.nvim_create_namespace("lazytree_cursor")

    -- Current metadata and group_ranges (updated by refresh)
    local meta = {}
    local header_lines = 0
    local group_ranges = {}

    --- Refresh: re-render buffer from current state
    local function refresh()
        local cursor_pos = nil
        if vim.api.nvim_win_is_valid(win) then
            cursor_pos = vim.api.nvim_win_get_cursor(win)
        end

        local lines
        lines, meta, header_lines, group_ranges = M.render(scan_data, {
            fold_state = fold_state,
            filter_text = filter_text,
            plugin_status = plugin_status,
            reverse_deps = reverse_deps,
        })

        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

        -- Apply highlights
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for i, line in ipairs(lines) do
            local row = i - 1
            if i <= header_lines then
                vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeHeader", row, 0, -1)
            elseif line:match("^Keybindings:") then
                vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeFooter", row, 0, -1)
            elseif meta[i] and meta[i].is_heading then
                vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeFile", row, 0, -1)
            elseif meta[i] and line:match("^[├└│ ]") then
                -- Tree glyphs
                local glyph_end = line:find("[%w●○]") or 0
                if glyph_end > 1 then
                    vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeGlyph", row, 0, glyph_end - 1)
                end
                -- Status indicator
                local loaded_pos = line:find("● ")
                local notloaded_pos = line:find("○ ")
                if loaded_pos then
                    vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeLoaded", row, loaded_pos - 1, loaded_pos + #"●" - 1 + 1)
                elseif notloaded_pos then
                    vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeNotLoaded", row, notloaded_pos - 1, notloaded_pos + #"○" - 1 + 1)
                end
                -- Line number suffix
                local colon_pos = line:find(":%d+")
                if colon_pos then
                    -- Find the end of the line number part (before any "used by" text)
                    local num_end = line:find("[^%d]", colon_pos + 1) or (#line + 1)
                    vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeLineNr", row, colon_pos - 1, num_end - 1)
                end
                -- "used by" annotation
                local ub_start = line:find("%(used by:")
                if ub_start then
                    vim.api.nvim_buf_add_highlight(buf, ns, "LazyTreeUsedBy", row, ub_start - 1, -1)
                end
            end
        end

        -- Restore cursor
        if cursor_pos and vim.api.nvim_win_is_valid(win) then
            local max_line = vim.api.nvim_buf_line_count(buf)
            local row = math.min(cursor_pos[1], max_line)
            vim.api.nvim_win_set_cursor(win, { row, cursor_pos[2] })
        end
    end

    -- Initial render
    refresh()

    -- Feature 5: Cursor-follow group highlights
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            vim.api.nvim_buf_clear_namespace(buf, ns_cursor, 0, -1)
            if not vim.api.nvim_win_is_valid(win) then return end
            local cursor = vim.api.nvim_win_get_cursor(win)
            local row = cursor[1]
            for _, range in ipairs(group_ranges) do
                if row >= range.start_line and row <= range.end_line then
                    for r = range.start_line, range.end_line do
                        vim.api.nvim_buf_add_highlight(buf, ns_cursor, "LazyTreeCursorGroup", r - 1, 0, -1)
                    end
                    break
                end
            end
        end,
    })

    -- Keymap: e = open file in float (real buffer, editable)
    vim.keymap.set("n", "e", function()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        local entry = meta[row]
        if not entry then return end

        local is_new = vim.fn.bufnr(entry.file) == -1

        local scratch = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = scratch })

        local fw = math.floor(vim.o.columns * 0.8)
        local fh = math.floor(vim.o.lines * 0.8)
        local file_win = vim.api.nvim_open_win(scratch, true, {
            relative = "editor",
            width = fw,
            height = fh,
            row = math.floor((vim.o.lines - fh) / 2),
            col = math.floor((vim.o.columns - fw) / 2),
            style = "minimal",
            border = "rounded",
            title = " " .. vim.fn.fnamemodify(entry.file, ":t") .. " ",
            title_pos = "center",
        })

        vim.cmd("edit " .. vim.fn.fnameescape(entry.file))
        local file_buf = vim.api.nvim_get_current_buf()

        -- Auto-wipe buffer when float closes if it didn't exist before
        if is_new then
            vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = file_buf })
        end

        local line_count = vim.api.nvim_buf_line_count(file_buf)
        local target_line = math.min(entry.lnum, line_count)
        vim.api.nvim_win_set_cursor(file_win, { target_line, 0 })
        vim.cmd("normal! zz")

        -- q closes the file float, returning to LazyTree
        local function close_file()
            pcall(vim.keymap.del, "n", "q", { buffer = file_buf })
            if vim.api.nvim_win_is_valid(file_win) then
                vim.api.nvim_win_close(file_win, true)
            end
        end
        vim.keymap.set("n", "q", close_file, { buffer = file_buf, nowait = true })
    end, { buffer = buf, nowait = true, desc = "LazyTree: open file at line" })

    -- Keymap: q / <Esc> = close
    local function close()
        vim.api.nvim_win_close(win, true)
    end
    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "LazyTree: close" })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "LazyTree: close" })

    -- Feature 3: Fold keybindings
    local function get_heading_at_cursor()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        -- If on a heading, use it directly
        if meta[row] and meta[row].is_heading then
            return meta[row].heading_key
        end
        -- Otherwise walk upward to find the heading for this section
        for r = row, 1, -1 do
            if meta[r] and meta[r].is_heading then
                return meta[r].heading_key
            end
        end
        return nil
    end

    vim.keymap.set("n", "za", function()
        local key = get_heading_at_cursor()
        if key then
            fold_state[key] = not fold_state[key]
            refresh()
        end
    end, { buffer = buf, nowait = true, desc = "LazyTree: toggle fold" })

    vim.keymap.set("n", "zc", function()
        local key = get_heading_at_cursor()
        if key then
            fold_state[key] = true
            refresh()
        end
    end, { buffer = buf, nowait = true, desc = "LazyTree: fold section" })

    vim.keymap.set("n", "zo", function()
        local key = get_heading_at_cursor()
        if key then
            fold_state[key] = false
            refresh()
        end
    end, { buffer = buf, nowait = true, desc = "LazyTree: unfold section" })

    -- Feature 4: Filter with /
    vim.keymap.set("n", "/", function()
        local input = vim.fn.input("Filter: ", filter_text)
        filter_text = input or ""
        refresh()
    end, { buffer = buf, nowait = true, desc = "LazyTree: filter plugins" })

    -- Feature 6: Open plugin homepage with gx
    vim.keymap.set("n", "gx", function()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        local entry = meta[row]
        if not entry or not entry.plugin_name then return end
        local name = entry.plugin_name
        -- Check if it looks like owner/repo
        if not name:match("/") then
            vim.notify("LazyTree: no GitHub URL for " .. name, vim.log.levels.WARN)
            return
        end
        local url = "https://github.com/" .. name
        if vim.ui.open then
            vim.ui.open(url)
        else
            local cmd = vim.fn.has("mac") == 1 and "open" or "xdg-open"
            vim.fn.jobstart({ cmd, url }, { detach = true })
        end
    end, { buffer = buf, nowait = true, desc = "LazyTree: open plugin homepage" })

    -- Feature 7: Config snippet preview with K
    vim.keymap.set("n", "K", function()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row = cursor[1]
        local entry = meta[row]
        if not entry or not entry.lnum then return end

        local spec_lines = extract_spec_block(entry.file, entry.lnum)
        if not spec_lines then
            vim.notify("LazyTree: could not extract spec block", vim.log.levels.WARN)
            return
        end

        local preview_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, spec_lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = preview_buf })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = preview_buf })

        local pw = math.min(80, math.floor(vim.o.columns * 0.6))
        local ph = math.min(#spec_lines + 2, math.floor(vim.o.lines * 0.5))
        local preview_win = vim.api.nvim_open_win(preview_buf, true, {
            relative = "editor",
            width = pw,
            height = ph,
            row = math.floor((vim.o.lines - ph) / 2),
            col = math.floor((vim.o.columns - pw) / 2),
            style = "minimal",
            border = "rounded",
            title = " Spec Preview ",
            title_pos = "center",
        })

        local function close_preview()
            vim.api.nvim_win_close(preview_win, true)
        end
        vim.keymap.set("n", "q", close_preview, { buffer = preview_buf, nowait = true })
        vim.keymap.set("n", "<Esc>", close_preview, { buffer = preview_buf, nowait = true })
    end, { buffer = buf, nowait = true, desc = "LazyTree: preview spec" })
end

return M
