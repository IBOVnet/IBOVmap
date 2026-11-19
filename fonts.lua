-- fonts.lua
-- Font lists for the map's font settings: installed system TTF fonts and AC/CSP fonts, read from their name tables.
local M = {items = nil, filter = '', labels = {}}

M.default = 'Segoe UI:@System'

local function u16(data, i)
    local a, b = data:byte(i, i + 1)
    return a and b and a * 256 + b or nil
end

local function u32(data, i)
    local a, b, c, d = data:byte(i, i + 3)
    return a and d and ((a * 256 + b) * 256 + c) * 256 + d or nil
end

local function decode(raw, unicode)
    if not unicode then return (raw:gsub('%z', '')) end
    local out = {}
    for i = 1, #raw - 1, 2 do
        local high, low = raw:byte(i, i + 1)
        if high == 0 and low >= 32 and low < 127 then out[#out + 1] = string.char(low) end
    end
    return table.concat(out)
end

-- Reads names from a TTF/OTF/TTC name table: returns the DirectWrite family (typographic nameID 16,
-- else legacy nameID 1), full name (nameID 4), legacy family (nameID 1) and subfamily (nameID 2).
-- DirectWrite groups e.g. "Finlandica Headline Medium" (nameID 1) under "Finlandica Headline" (nameID 16).
-- Collections only report their first font, matching CSP's direct-path behaviour.
function M.readNames(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local base = 0
    local header = file:read(12)
    if header and header:sub(1, 4) == 'ttcf' then
        file:seek('set', 12)
        local offset = file:read(4)
        base = offset and u32(offset, 1) or 0
        file:seek('set', base)
        header = file:read(12)
    end
    local count = header and #header == 12 and u16(header, 5)
    if not count or count == 0 or count > 100 then file:close(); return nil end
    local directory = file:read(count * 16)
    local nameOffset, nameLength
    for i = 0, count - 1 do
        local entry = i * 16 + 1
        if not directory or entry + 15 > #directory then break end
        if directory:sub(entry, entry + 3) == 'name' then
            nameOffset, nameLength = u32(directory, entry + 8), u32(directory, entry + 12)
            break
        end
    end
    if not nameOffset then file:close(); return nil end
    file:seek('set', nameOffset)
    local data = file:read(math.min(nameLength, 16384))
    file:close()
    if not data or #data < 6 then return nil end
    local records, strings = u16(data, 3), u16(data, 5)
    if not records or not strings or records > 1000 then return nil end
    local best = {}
    for i = 0, records - 1 do
        local r = 7 + i * 12
        if r + 11 > #data then break end
        local platform, encoding, language, id = u16(data, r), u16(data, r + 2), u16(data, r + 4), u16(data, r + 6)
        if id == 1 or id == 2 or id == 4 or id == 16 then
            local score = (platform == 3 and encoding == 1 and 4 or platform == 0 and 3 or platform == 1 and encoding == 0 and 2 or 0)
                + ((platform == 3 and language == 0x0409 or platform == 1 and language == 0 or platform == 0) and 1 or 0)
            if score > 0 and score > (best[id] and best[id].score or 0) then
                local first = strings + u16(data, r + 10) + 1
                local last = first + u16(data, r + 8) - 1
                if last <= #data then
                    local name = decode(data:sub(first, last), platform ~= 1):match('^%s*(.-)%s*$')
                    if name ~= '' then best[id] = {score = score, name = name} end
                end
            end
        end
    end
    local legacy = best[1] or best[4]
    if not legacy then return nil end
    return (best[16] or legacy).name, (best[4] or legacy).name, legacy.name, best[2] and best[2].name
end

local function env(name)
    local ok, value = pcall(function() return os.getenv and os.getenv(name) end)
    return ok and value or nil
end

local function scanFolder(folder, callback)
    local ok, files = pcall(io.scanDir, folder, '*.ttf')
    if ok and files then
        for _, name in ipairs(files) do
            if name:lower():match('%.ttf$') then callback(folder .. '\\' .. name, name) end
        end
    end
end

function M.scan()
    local items, seen = {}, {}
    local function add(label, value, group)
        if not seen[value] then
            seen[value] = true
            items[#items + 1] = {label = label, value = value, group = group}
            M.labels[value] = label
        end
    end
    add('Segoe UI (system default)', M.default, 'System')
    -- Every choice is a full .ttf path: CSP loads those reliably, while Family:@System lookups fail for fonts whose
    -- legacy family name differs from DirectWrite's, and other formats do not render reliably.
    local function addFile(path, file, group)
        local _, full = M.readNames(path)
        add((full or file:gsub('%.[Tt][Tt][Ff]$', '')) .. ' [' .. file .. ']', path, group)
    end
    local windows = env('WINDIR') or env('SystemRoot') or 'C:\\Windows'
    local systemFolders = {windows .. '\\Fonts'}
    local localAppData = env('LOCALAPPDATA')
    if localAppData then systemFolders[#systemFolders + 1] = localAppData .. '\\Microsoft\\Windows\\Fonts' end
    for _, folder in ipairs(systemFolders) do
        scanFolder(folder, function(path, file) addFile(path, file, 'System') end)
    end
    for _, folder in ipairs({ac.getFolder(ac.FolderID.ContentFonts), ac.getFolder(ac.FolderID.ExtFonts)}) do
        scanFolder(folder, function(path, file) addFile(path, file, 'AC') end)
    end
    table.sort(items, function(a, b)
        if a.value == M.default or b.value == M.default then return a.value == M.default end
        if a.group ~= b.group then return a.group == 'System' end
        return a.label:lower() < b.label:lower()
    end)
    M.items = items
end

function M.label(value)
    if M.labels[value] then return M.labels[value] end
    local family = value:match('^(.-):@System$')
    return family or value:match('[^\\/]+$') or value
end

-- Compact override picker: '' means the default font. Returns the (possibly changed) value.
function M.picker(label, value, defaultLabel)
    if not M.items then M.scan() end
    local result = value
    ui.combo(label, value == '' and defaultLabel or M.label(value), function()
        if ui.selectable(defaultLabel, value == '') then result = '' end
        local group
        for _, font in ipairs(M.items) do
            if font.group ~= group then
                group = font.group
                ui.textDisabled(group == 'System' and 'Installed system fonts' or 'Assetto Corsa / CSP fonts')
            end
            if ui.selectable(font.label .. '##' .. font.value, value == font.value) then result = font.value end
        end
    end)
    return result
end

-- One filter and rescan for every font list on the page.
function M.tools()
    if not M.items then M.scan() end
    M.filter = ui.inputText('Filter font lists##fonts', M.filter)
    ui.sameLine()
    if ui.button('Rescan fonts##fonts') then M.labels = {}; M.scan() end
end

function M.settings(config, key, label)
    if not M.items then M.scan() end
    ui.text(label)
    ui.combo('Font##' .. key, M.label(config[key]), function()
        local filter = M.filter:lower()
        local group
        for _, font in ipairs(M.items) do
            if filter == '' or font.label:lower():find(filter, 1, true) then
                if font.group ~= group then
                    group = font.group
                    ui.textDisabled(group == 'System' and 'Installed system fonts' or 'Assetto Corsa / CSP fonts')
                end
                if ui.selectable(font.label .. '##' .. font.value, config[key] == font.value) then config[key] = font.value end
            end
        end
    end)
    config[key] = ui.inputText('Advanced value##' .. key, config[key])
    if ui.itemHovered() then
        ui.setTooltip('An absolute .ttf path, Family:@System for an installed TTF font, or CSP syntax such as\n'
            .. 'Segoe UI:@System;Weight=Bold')
    end
end

return M
