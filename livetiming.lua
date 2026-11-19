-- livetiming.lua
-- Optional driver classes from an AC Server Manager live-timing leaderboard.
local ClassDiscovery = require('acsmclasses')
local M = {}

local noClass = '00000000-0000-0000-0000-000000000000'

-- Any page on a Server Manager site works: only the origin and its ?server= value are kept.
function M.endpoint(url)
    url = tostring(url or ''):match('^%s*(.-)%s*$')
    if url == '' then return nil end
    local origin = url:match('^(https?://[^/?#]+)')
    if not origin then return nil, 'Enter a full address starting with http:// or https://' end
    local server = url:match('[?&]server=([^&#]+)')
    return origin .. '/api/live-timings/leaderboard.json' .. (server and '?server=' .. server or '')
end

local function text(value)
    return type(value) == 'string' and value or ''
end

function M.parse(body)
    local ok, data = pcall(JSON.parse, body)
    if not ok or type(data) ~= 'table' then return nil, 'The response is not JSON.' end
    if data.Track == nil and data.ConnectedDrivers == nil and data.DisconnectedDrivers == nil then
        return nil, 'The response is not a Server Manager live-timing leaderboard.'
    end
    local result = {entries = {}, classes = {}, bySlot = {}, byName = {}, server = text(data.ServerName)}
    local seen = {}
    for _, group in ipairs({{data.ConnectedDrivers, true}, {data.DisconnectedDrivers, false}}) do
        for _, driver in ipairs(type(group[1]) == 'table' and group[1] or {}) do
            local info = type(driver) == 'table' and driver.CarInfo
            if type(info) == 'table' then
                local classID = text(info.ClassID)
                if classID == '' or classID == noClass then classID = nil end
                if classID and not seen[classID] then
                    seen[classID] = true
                    result.classes[#result.classes + 1] = classID
                end
                local entry = {slot = tonumber(info.CarID), name = text(info.DriverName), model = text(info.CarModel),
                    classID = classID, connected = group[2]}
                result.entries[#result.entries + 1] = entry
                if entry.connected and entry.slot then result.bySlot[entry.slot] = entry end
                -- Connected drivers are listed first, so they win a name shared with an old entry.
                if entry.name ~= '' and not result.byName[entry.name] then result.byName[entry.name] = entry end
            end
        end
    end
    -- Sorted so default names stay put as the running order changes.
    table.sort(result.classes)
    result.classIndex = {}
    for i, id in ipairs(result.classes) do result.classIndex[id] = i end
    return result
end

-- A connected car in the same entry slot with the same model is definitive; otherwise match the driver name.
function M.find(data, slot, model, name)
    if not data then return nil end
    local entry = slot and data.bySlot[slot]
    if entry and entry.model == model then return entry end
    return name ~= '' and data.byName[name] or nil
end

function M.new(config)
    local self = {status = '', discoveryStatus = '', lastFetch = -math.huge, pending = false}

    function self:refresh()
        self.lastFetch = -math.huge
        self.discovery, self.discoveryKey, self.discoveryStatus = nil, nil, ''
    end

    function self:discoverClasses()
        local key = self.url .. '|' .. table.concat(self.data.classes, ',')
        if self.discoveryKey == key then return end
        local token, url = {}, self.url
        self.discovery, self.discoveryKey, self.discoveryStatus = token, key, ''
        local ok, names = pcall(JSON.parse, config.liveClassNames or '{}')
        if not ok or type(names) ~= 'table' then
            self.discoveryStatus = 'Class discovery: saved class names could not be read; not overwriting them.'
            ac.warn('IBOVmap: ' .. self.discoveryStatus)
            return
        end
        local wanted = {}
        for _, id in ipairs(self.data.classes) do
            if type(names[id]) ~= 'string' or not names[id]:match('%S') then wanted[id] = true end
        end
        if not next(wanted) then return end
        ClassDiscovery.discover(url, wanted, function()
            return self.url == url and self.discovery == token
        end, function(id, name)
            -- Re-read so edits made while requests were pending always win.
            local valid, current = pcall(JSON.parse, config.liveClassNames or '{}')
            if not valid or type(current) ~= 'table' then
                ac.warn('IBOVmap class discovery: saved class names could not be read; not overwriting them.')
                return false
            end
            if type(current[id]) ~= 'string' or not current[id]:match('%S') then
                current[id] = name
                config.liveClassNames = JSON.stringify(current)
            end
        end, function(message)
            self.discoveryStatus = message
        end)
    end

    function self:describe()
        local data = self.data
        if not data then return end
        self.status = string.format('%d drivers, %d classes (updated %s)', #data.entries, #data.classes, self.updated)
    end

    function self:update(now)
        local url, problem = M.endpoint(config.liveTimingUrl)
        if url ~= self.url then
            self.url, self.data, self.lastFetch = url, nil, -math.huge
            self.discovery, self.discoveryKey, self.discoveryStatus = nil, nil, ''
            self.status = problem or ''
        end
        if not url or self.pending or now - self.lastFetch < config.liveTimingInterval then return end
        self.pending, self.lastFetch = true, now
        self.status = self.data and self.status or 'Connecting...'
        web.get(url, function(err, response)
            self.pending = false
            if url ~= self.url then return end
            local data, failure
            if err and err ~= '' then
                failure = tostring(err)
            elseif not response or response.status ~= 200 then
                failure = 'HTTP ' .. tostring(response and response.status or 'error')
            else
                data, failure = M.parse(response.body)
            end
            if data then
                self.data, self.updated = data, os.date('%H:%M:%S')
                self:describe()
                self:discoverClasses()
            else
                -- Keep the last good data through a temporary outage.
                self.status = 'Failed: ' .. failure .. (self.data and ' - using data from ' .. self.updated or '')
                ac.warn('IBOVmap live timing: ' .. url .. ': ' .. failure)
            end
        end)
    end

    -- Only an active feed with at least one ClassID overrides the classes defined in the app.
    function self:overrides()
        return self.data ~= nil and #self.data.classes > 0
    end

    function self:entry(meta)
        return M.find(self.data, meta.slot, meta.carID, meta.name)
    end

    return self
end

return M
