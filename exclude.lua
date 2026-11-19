-- exclude.lua
-- The "Exclude names" list: exact driver names separated by |, surrounding spaces ignored. A backslash escapes the
-- next character, so "My\|Name" is the name My|Name and "\\" a literal backslash. Plain Lua.
local M = {}

-- The names in `list`, as a set.
function M.parse(list)
    local names, current, escaped = {}, {}, false
    local function finish()
        local name = table.concat(current):match('^%s*(.-)%s*$')
        if name ~= '' then names[name] = true end
        current = {}
    end
    for ch in tostring(list or ''):gmatch('.') do
        if escaped then
            current[#current + 1], escaped = ch, false
        elseif ch == '\\' then
            escaped = true
        elseif ch == '|' then
            finish()
        else
            current[#current + 1] = ch
        end
    end
    -- A trailing backslash escapes nothing: keep it.
    if escaped then current[#current + 1] = '\\' end
    finish()
    return names
end

local cache = {source = nil, names = {}}

-- Whether `name` is in `list` (parsed once per change of list).
function M.has(list, name)
    if cache.source ~= list then cache.source, cache.names = list, M.parse(list) end
    return cache.names[name] == true
end

return M
