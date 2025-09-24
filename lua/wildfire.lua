-- luacheck: push ignore
local v = vim
-- luacheck: pop

local api = v.api
local ts = v.treesitter

local M = {}

M.options = {
    surrounds = { { "(", ")" }, { "{", "}" }, { "<", ">" }, { "[", "]" } },
    keymaps = {
        init_selection = "<CR>",
        node_incremental = "<CR>",
        node_decremental = "<BS>",
    },
    filetype_exclude = { "qf" },
}

---@type table<integer, table<TSNode|nil>>
local selections, nodes_all = {}, {}
local count = 1

-- Safe parser getter (modern nvim-treesitter)
local function get_parser(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local ok, parser = pcall(ts.get_parser, bufnr)
    if ok then
        return parser
    end
end

-- Get node at cursor (modern replacement for ts_utils.get_node_at_cursor)
function M.get_node_at_cursor(winnr)
    winnr = winnr or 0
    local buf = api.nvim_win_get_buf(winnr)
    local row, col = unpack(api.nvim_win_get_cursor(winnr))
    row = row - 1

    local parser = get_parser(buf)
    if not parser then
        return
    end

    local node
    for _, tree in ipairs(parser:trees()) do
        local root = tree:root()
        node = root:named_descendant_for_range(row, col, row, col)
        if node then
            break
        end
    end

    return node
end

-- Node -> Vim range
function M.node_range_to_vim_range(node)
    local srow, scol, erow, ecol = node:range()
    return srow + 1, scol, erow + 1, ecol
end

-- Generic range helpers
function M.get_range(node_or_range)
    if type(node_or_range) == "table" then
        return unpack(node_or_range)
    end
    return M.node_range_to_vim_range(node_or_range)
end

function M.range_larger(r1, r2)
    local s1, c1, e1, ce1 = M.get_range(r1)
    local s2, c2, e2, ce2 = M.get_range(r2)
    return s1 < s2 or (s1 == s2 and c1 < c2) or e1 > e2 or (e1 == e2 and ce1 > ce2)
end

function M.range_match(r1, r2)
    if not r1 or not r2 then
        return false
    end
    return table.concat({ M.get_range(r1) }, ",") == table.concat({ M.get_range(r2) }, ",")
end

function M.visual_selection_range()
    local _, sr, sc = unpack(v.fn.getpos("'<"))
    local _, er, ec = unpack(v.fn.getpos("'>"))
    if sr < er or (sr == er and sc <= ec) then
        return sr, sc, er, ec
    else
        return er, ec, sr, sc
    end
end

-- Update visual selection
function M.update_selection(buf, node_or_range, selection_mode)
    local sr, sc, er, ec = M.get_range(node_or_range)
    buf = buf or api.nvim_get_current_buf()
    local lines = api.nvim_buf_line_count(buf)
    sr = math.max(1, math.min(sr, lines))
    er = math.max(1, math.min(er, lines))
    sc = math.max(0, sc)
    ec = math.max(0, ec)

    selection_mode = selection_mode or "charwise"
    local mode_table = { charwise = "v", linewise = "V", blockwise = "<C-v>" }
    if mode_table[selection_mode] then
        selection_mode = mode_table[selection_mode]
    end
    selection_mode = api.nvim_replace_termcodes(selection_mode, true, true, true)

    api.nvim_win_set_cursor(0, { sr, sc })
    v.cmd("normal! " .. selection_mode)
    api.nvim_win_set_cursor(0, { er, ec })
end

-- Bracket-aware selection trimming
function M.unsurround_coordinates(node_or_range, buf)
    buf = buf or api.nvim_get_current_buf()
    local sr, sc, er, ec = M.get_range(node_or_range)
    local ok, lines = pcall(api.nvim_buf_get_text, buf, sr - 1, sc - 1, er - 1, ec, {})
    if not ok then
        return false, { sr, sc, er, ec }
    end
    local text = table.concat(lines, "\n")

    local matched
    for _, pair in ipairs(M.options.surrounds) do
        if text:match("^%" .. pair[1] .. ".*%" .. pair[2] .. "$") then
            matched = true
            break
        end
    end
    if not matched then
        return false, { sr, sc, er, ec }
    end

    lines[1] = lines[1]:sub(2)
    lines[#lines] = lines[#lines]:sub(1, -2)

    local ns, ne = sr, er
    local nscol, necol = sc, ec
    for i, line in ipairs(lines) do
        if line:match("%S") then
            ns = sr + i - 1
            nscol = (i == 1) and sc + line:match("^%s*"):len() or 0
            break
        end
    end
    for i = #lines, 1, -1 do
        if lines[i]:match("%S") then
            ne = sr + i - 1
            local llen = #lines[i]
            necol = (i == #lines) and ec - 1 or llen
            break
        end
    end
    return true, { ns, nscol, ne, necol }
end

-- Incremental selection helpers
local function update_selection_by_node(node)
    local buf = api.nvim_get_current_buf()
    local node_has_brackets, sel = M.unsurround_coordinates(node, buf)
    selections[buf] = selections[buf] or {}
    nodes_all[buf] = nodes_all[buf] or {}

    local last_sel = selections[buf][#selections[buf]]
    local use_node = not node_has_brackets or M.range_match(last_sel, sel)
    M.update_selection(buf, use_node and node or sel)

    if use_node then
        table.insert(nodes_all[buf], node)
        table.insert(selections[buf], node)
    else
        table.insert(selections[buf], sel)
    end
end

local function init_by_node(node)
    local buf = api.nvim_get_current_buf()
    selections[buf] = {}
    nodes_all[buf] = {}
    update_selection_by_node(node)
end

function M.init_selection()
    count = v.v.count1
    local node = M.get_node_at_cursor()
    if not node then
        return
    end
    init_by_node(node)
    for _ = 1, count - 1 do
        M.node_incremental()
    end
end

local function select_incremental(get_parent)
    return function()
        local buf = api.nvim_get_current_buf()
        local nodes = nodes_all[buf]
        local sr, sc, er, ec
        if count <= 1 then
            sr, sc, er, ec = M.visual_selection_range()
        else
            sr, sc, er, ec = M.get_range(selections[buf][#selections[buf]])
        end

        if not nodes or #nodes == 0 then
            local root = get_parser():parse()[1]:root()
            local node = root:named_descendant_for_range(sr - 1, sc - 1, er - 1, ec)
            update_selection_by_node(node)
            return
        end

        local node = nodes[#nodes]
        while true do
            local parent = get_parent(node)
            if not parent or parent == node then
                local root = get_parser():parse()[1]:root()
                parent = root:named_descendant_for_range(sr - 1, sc - 1, er - 1, ec)
                if not parent or parent == node then
                    M.update_selection(buf, node)
                    return
                end
            end
            node = parent
            local nsr, nsc, ner, nec = M.node_range_to_vim_range(node)
            if M.range_larger({ nsr, nsc, ner, nec }, { sr, sc, er, ec }) then
                update_selection_by_node(node)
                return
            end
        end
    end
end

M.node_incremental = select_incremental(function(n)
    return n:parent() or n
end)

function M.node_decremental()
    local buf = api.nvim_get_current_buf()
    local nodes = nodes_all[buf]
    if not nodes or #nodes < 2 then
        return
    end
    local local_sel = selections[buf]
    table.remove(local_sel)
    local last_sel = local_sel[#local_sel]
    M.update_selection(buf, last_sel)
    if type(last_sel) ~= "table" then
        table.remove(nodes)
    end
end

function M.visual_inner()
    local buf = api.nvim_get_current_buf()
    local sr, sc, er, ec = M.visual_selection_range()
    local _, sel = M.unsurround_coordinates({ sr, sc, er, ec }, buf)
    M.update_selection(buf, sel)
end

function M.setup(opts)
    if type(opts) == "table" then
        M.options = v.tbl_deep_extend("force", M.options, opts)
    end

    local desc = {
        init_selection = "Start selecting nodes",
        node_incremental = "Increment selection",
        node_decremental = "Shrink selection",
    }

    for func, key in pairs(M.options.keymaps) do
        local rhs = func == "init_selection" and M[func] or string.format(":lua require'wildfire'.%s()<CR>", func)
        local mode = func == "init_selection" and "n" or "x"
        v.keymap.set(mode, key, rhs, { noremap = true, silent = true, desc = desc[func] })
    end
end

return M
