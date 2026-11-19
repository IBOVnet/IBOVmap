-- sections.lua
-- Named corners for the map's corner label: the track's sections.ini (as Kunos's Track Description app reads it),
-- unless this app's own sections folder has one for the track.
local M = {}

-- Sections from sections.ini text: {from, to (lap fractions), label (the name in TEXT)} for each section with both
-- ends and a name.
function M.parse(text)
    local list, current = {}, nil
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        line = line:gsub('^\239\187\191', '')
        if line:match('^%s*%[') then
            current = {}
            list[#list + 1] = current
        elseif current then
            local key, value = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            if key then current[key:upper()] = value end
        end
    end
    local sections = {}
    for _, s in ipairs(list) do
        local from, to = tonumber(s.IN), tonumber(s.OUT)
        if from and to and s.TEXT and s.TEXT ~= '' then
            sections[#sections + 1] = {from = from, to = to, label = s.TEXT}
        end
    end
    return sections
end

-- The current track's file name key (track_layout, or the track alone) and its sections, from
-- <appFolder>\sections\<key>.ini if there is one, else the track's own data\sections.ini.
function M.load(appFolder)
    local id, layout = ac.getTrackID(), ac.getTrackLayout()
    local key = layout ~= '' and (id .. '_' .. layout) or id
    local root = ac.getFolder(ac.FolderID.ContentTracks) .. '\\' .. id
    local text = io.load(appFolder .. '\\sections\\' .. key .. '.ini')
        or io.load(root .. (layout ~= '' and '\\' .. layout or '') .. '\\data\\sections.ini')
    return key, M.parse(text)
end

return M
