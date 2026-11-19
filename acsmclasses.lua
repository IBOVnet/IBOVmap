-- acsmclasses.lua
-- Best-effort class-name discovery from ACSM championship standings and exports.
local M = {}

local function text(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or ''
end

-- Only exact class UUIDs are evidence: empty standings and driver names alone prove nothing.
function M.standings(data)
    if type(data.DriverStandings) ~= 'table' then return nil, 'Missing DriverStandings.' end
    local names = {}
    for name, rows in pairs(data.DriverStandings) do
        if type(name) == 'string' and text(name) ~= '' and type(rows) == 'table' then
            for _, row in ipairs(rows) do
                local car = type(row) == 'table' and row.Car
                if type(car) == 'table' then
                    local driver = type(car.Driver) == 'table' and car.Driver or {}
                    for _, id in ipairs({text(car.ClassID), text(driver.ClassID)}) do
                        if id ~= '' then names[id] = text(name) end
                    end
                end
            end
        end
    end
    return names
end

function M.export(data)
    if type(data.Classes) ~= 'table' then return nil, 'Missing Classes.' end
    local names = {}
    for _, class in ipairs(data.Classes) do
        if type(class) == 'table' then
            local id, name = text(class.ID), text(class.Name)
            if id ~= '' and name ~= '' then names[id] = name end
        end
    end
    return names
end

-- Requests are sequential; all cheap standings are tried before any potentially large exports.
function M.discover(endpoint, wanted, active, found, status)
    local origin = endpoint:match('^(https?://[^/?#]+)')
    local query = endpoint:match('(%?[^#]*)') or ''
    local failures, lastFailure = 0, nil

    local function problem(url, message)
        failures, lastFailure = failures + 1, message
        ac.warn('IBOVmap class discovery: ' .. url .. ': ' .. message)
    end

    local function request(path, parser, done)
        if not active() then return end
        local url = origin .. path .. query
        web.get(url, function(err, response)
            if not active() then return end
            local result, failure
            if err and err ~= '' then
                failure = tostring(err)
            elseif not response or response.status ~= 200 then
                failure = 'HTTP ' .. tostring(response and response.status or 'error')
            else
                local ok, data = pcall(JSON.parse, response.body)
                if not ok or type(data) ~= 'table' then
                    failure = 'The response is not JSON.'
                else
                    result, failure = parser(data)
                end
            end
            if failure then problem(url, failure) end
            done(result)
        end)
    end

    local function accept(names)
        for id, name in pairs(names or {}) do
            if wanted[id] then
                if found(id, name) ~= false then wanted[id] = nil end
            end
        end
    end

    local function finish()
        local remaining = 0
        for _ in pairs(wanted) do remaining = remaining + 1 end
        if failures > 0 then
            status(string.format('Class discovery: %d failed requests (%s). %d unresolved%s', failures, lastFailure,
                remaining, remaining > 0 and '; manual names or Class n still apply.' or '.'))
        elseif remaining == 0 then
            status('Class discovery complete.')
        else
            status(string.format('Class discovery: %d unresolved; manual names or Class n still apply.', remaining))
        end
    end

    status('Discovering class names...')
    request('/api/championships/list.json', function(data)
        if type(data.championships) ~= 'table' then return nil, 'Missing championships.' end
        local championships, seen = {}, {}
        for _, championship in ipairs(data.championships) do
            if type(championship) == 'table' and tonumber(championship.progress)
                and tonumber(championship.progress) < 100 then
                local id = text(championship.id)
                local path = text(championship.championship_standings_json_url):match('^([^?#]+)')
                -- Do not follow arbitrary URLs returned by the server.
                if id:match('^[%w%-]+$') and path == '/championship/' .. id .. '/standings.json' then
                    if not seen[id] then
                        seen[id] = true
                        championships[#championships + 1] = {standings = path, export = '/championship/' .. id .. '/export'}
                    end
                else
                    problem(origin .. '/api/championships/list.json' .. query, 'Invalid championship URL.')
                end
            end
        end
        return championships
    end, function(championships)
        if not championships then finish(); return end
        local index, exporting = 0, false
        local function nextRequest()
            if not active() then return end
            if not next(wanted) then finish(); return end
            index = index + 1
            if index > #championships then
                if exporting or #championships == 0 then finish(); return end
                index, exporting = 1, true
                status('Discovering class names: trying championship exports...')
            end
            local championship = championships[index]
            request(exporting and championship.export or championship.standings,
                exporting and M.export or M.standings, function(names)
                    accept(names)
                    nextRequest()
                end)
        end
        nextRequest()
    end)
end

return M
