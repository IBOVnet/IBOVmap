-- classes.lua
-- Driver classes for the map: the app's own classes (car tags and driver names), or AC Server Manager live-timing
-- classes when a server URL is set.
local LiveTiming = require('livetiming')
local M = {}

local function array(value)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end

local function trim(value)
    return value:match('^%s*(.-)%s*$')
end

local function help(message)
    ui.sameLine()
    ui.icon(ui.Icons.Info, 14)
    if ui.itemHovered() then ui.setTooltip(message) end
end

-- Each class lists car tags and, optionally, exact driver names. Both must be unique across classes.
function M.decode(source)
    local ok, items = pcall(JSON.parse, source)
    if not ok or not array(items) then return nil, 'Class definitions must be a list.' end
    local used = {tags = {}, drivers = {}}
    for _, item in ipairs(items) do
        if type(item) ~= 'table' or type(item.name) ~= 'string' or not array(item.tags)
            or (item.drivers ~= nil and not array(item.drivers)) then
            return nil, 'Each class needs a name and a list of tags.'
        end
        item.drivers = item.drivers or {}
        for _, kind in ipairs({'tags', 'drivers'}) do
            for _, value in ipairs(item[kind]) do
                if type(value) ~= 'string' or value == '' or used[kind][value] then
                    return nil, 'Class tags and drivers must be non-empty, assigned to only one class.'
                end
                used[kind][value] = true
            end
        end
    end
    return items
end

function M.new(config)
    local self = {cars = {}, source = nil, items = {}, tagClasses = {}, driverClasses = {}, names = {}}
    local root = ac.getFolder(ac.FolderID.Root)
    self.live = LiveTiming.new(config)

    function self:reset()
        self.cars = {}
    end

    function self:definitions()
        if self.source ~= config.classDefinitions then
            self.source = config.classDefinitions
            self.items, self.error = M.decode(self.source)
            self.tagClasses, self.driverClasses = {}, {}
            if self.error then
                ac.warn('IBOVmap: saved classes could not be read: ' .. self.error)
                self.items = {}
            else
                for i, item in ipairs(self.items) do
                    if item.name:match('%S') then
                        for _, tag in ipairs(item.tags) do self.tagClasses[tag] = i end
                        for _, driver in ipairs(item.drivers) do self.driverClasses[driver] = i end
                    end
                end
            end
        end
        return self.items
    end

    function self:save()
        config.classDefinitions = JSON.stringify(self.items)
        self.source = nil
    end

    -- Saved manual or discovered names for server ClassIDs; missing names fall back to "Class n".
    function self:liveNames()
        if self.names.source ~= config.liveClassNames then
            local ok, value = pcall(JSON.parse, config.liveClassNames)
            self.names = {source = config.liveClassNames, value = ok and type(value) == 'table' and value or {}}
        end
        return self.names.value
    end

    function self:liveLabel(classID)
        local name = self:liveNames()[classID]
        if type(name) == 'string' and name:match('%S') then return trim(name) end
        return 'Class ' .. (self.live.data and self.live.data.classIndex[classID] or '?')
    end

    function self:tags(carID)
        if not carID or carID == '' then return {} end
        if self.cars[carID] then return self.cars[carID].tags end
        local path = root .. '\\content\\cars\\' .. carID .. '\\ui\\ui_car.json'
        local text = io.load(path)
        local ok, data = false, nil
        if text then ok, data = pcall(JSON.parse, text) end
        local tags, error = {}, nil
        if not ok or type(data) ~= 'table' then
            error = 'Cannot read car tags: ' .. path
        elseif data.tags ~= nil then
            if not array(data.tags) then
                error = 'Invalid car tags: ' .. path
            else
                local seen = {}
                for _, tag in ipairs(data.tags) do
                    if type(tag) ~= 'string' then
                        error = 'Invalid car tag: ' .. path
                    elseif tag ~= '' and not seen[tag] then
                        tags[#tags + 1], seen[tag] = tag, true
                    end
                end
            end
        end
        if error then ac.warn('IBOVmap: ' .. error) end
        self.cars[carID] = {tags = tags, error = error}
        return tags
    end

    function self:label(tags)
        self:definitions()
        local first
        for _, tag in ipairs(tags) do
            local index = self.tagClasses[tag]
            if index and (not first or index < first) then first = index end
        end
        return first and trim(self.items[first].name) or ''
    end

    -- Live server classes win; then a driver assignment; then car tags.
    -- Drivers missing from the feed (for example, joined since the last fetch) fall back to the app's classes.
    -- The result is cached on the metadata until definitions, live names or live data change.
    function self:classify(meta)
        local definitions, names, data = config.classDefinitions, config.liveClassNames, self.live.data
        if meta.classSource == definitions and meta.classNames == names and meta.classData == data
            and meta.classLabel then
            return meta.classLabel
        end
        local result = self:resolveClass(meta)
        meta.classSource, meta.classNames, meta.classData, meta.classLabel = definitions, names, data, result
        return result
    end

    function self:resolveClass(meta)
        if self.live:overrides() then
            local entry = self.live:entry(meta)
            if entry then return entry.classID and self:liveLabel(entry.classID) or '' end
        end
        self:definitions()
        local index = self.driverClasses[meta.name or '']
        if index then return trim(self.items[index].name) end
        return self:label(meta.tags or {})
    end

    function self:available()
        self:definitions()
        local used, seen, tags, errors = {}, {}, {}, {}
        for _, item in ipairs(self.items) do
            for _, tag in ipairs(item.tags) do used[tag] = true end
        end
        -- Include every entry-list slot, not just visible or connected standings rows.
        for index = 0, ac.getSim().carsCount - 1 do
            local carID = ac.getCarID(index)
            for _, tag in ipairs(self:tags(carID)) do
                if not used[tag] and not seen[tag] then tags[#tags + 1], seen[tag] = tag, true end
            end
            local car = self.cars[carID]
            if car and car.error then errors[car.error] = true end
        end
        table.sort(tags)
        return tags, errors
    end

    -- Entry-list drivers plus any from the live feed, minus those already assigned.
    function self:availableDrivers()
        self:definitions()
        local seen, names = {}, {}
        for _, item in ipairs(self.items) do
            for _, driver in ipairs(item.drivers) do seen[driver] = true end
        end
        local function add(name)
            if name and name ~= '' and not seen[name] then seen[name], names[#names + 1] = true, name end
        end
        for index = 0, ac.getSim().carsCount - 1 do add(ac.getDriverName(index)) end
        for _, entry in ipairs(self.live.data and self.live.data.entries or {}) do add(entry.name) end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        return names
    end

    local function listHeight(count)
        return math.max(64, math.min(200, 30 + 20 * count))
    end

    -- Two side-by-side lists; clicking moves an item across. Returns the requested move, if any.
    local function picker(i, kind, available, assigned, empty)
        local width = math.max(100, (ui.availableSpaceX() - 12) / 2)
        local height = listHeight(math.max(#available, #assigned))
        local move
        ui.childWindow('available-' .. kind .. '-' .. i, vec2(width, height), true, ui.WindowFlags.None, function()
            ui.textDisabled('Available')
            for _, value in ipairs(available) do
                if ui.selectable(value .. '##available-' .. (kind == 'tags' and '' or kind .. '-') .. i .. '-' .. value) then
                    move = {kind = kind, value = value}
                end
            end
            if #available == 0 then ui.textDisabled(empty) end
        end)
        ui.sameLine()
        ui.childWindow('assigned-' .. kind .. '-' .. i, vec2(width, height), true, ui.WindowFlags.None, function()
            ui.textDisabled('Assigned')
            for j, value in ipairs(assigned) do
                if ui.selectable(value .. '##assigned-' .. (kind == 'tags' and '' or kind .. '-') .. i .. '-' .. j) then
                    move = {kind = kind, index = j}
                end
            end
        end)
        return move
    end

    function self:drawLive()
        local previous = config.liveTimingUrl
        config.liveTimingUrl = ui.inputText('Server URL##live', config.liveTimingUrl)
        if previous ~= config.liveTimingUrl then self.live:update(os.preciseClock()) end
        help('Paste any page from an AC Server Manager site, for example\n'
            .. 'https://example.cc/live-timing?server=3\n'
            .. 'The address and ?server= value locate its live-timing leaderboard. When it loads and lists ClassIDs, '
            .. 'those classes are used for every driver and the Classes section is hidden. Leave blank to disable.\n'
            .. 'The ACSM must have "Live Timing > API List" enabled for public access. Proxies or firewalls '
            .. 'such as Cloudflare must allow your connection to request data.\n'
            .. 'Missing class names are discovered from unfinished championship standings, then exports '
            .. '(which can be several MB). Saved names are never overwritten. If access is denied or no UUID '
            .. 'matches, enter names below as usual. Fetch now retries discovery.')
        local endpoint = LiveTiming.endpoint(config.liveTimingUrl)
        if endpoint then
            ui.textDisabled(endpoint)
            if ui.button('Fetch now##live') then self.live:refresh() end
            ui.sameLine()
        end
        if self.live.status ~= '' then ui.textWrapped(self.live.status) end
        if self.live.discoveryStatus ~= '' then ui.textWrapped(self.live.discoveryStatus) end
        config.liveTimingInterval = ui.slider('Refresh (s)##live', config.liveTimingInterval, 10, 300, '%.0f', true)
        local data = self.live.data
        if not data then return end
        if #data.classes == 0 then
            ui.textWrapped('This server lists no classes, so the app\'s own classes apply.')
            return
        end
        local names, changed = self:liveNames(), false
        for i, classID in ipairs(data.classes) do
            local members = {}
            for _, entry in ipairs(data.entries) do
                if entry.classID == classID then members[#members + 1] = entry.name end
            end
            local current = type(names[classID]) == 'string' and names[classID] or ''
            local value = ui.inputText('Class ' .. i .. ' name##live-' .. classID, current)
            if value ~= current then names[classID], changed = value ~= '' and value or nil, true end
            ui.treeNode(#members .. ' drivers###live-members-' .. classID, function()
                ui.textDisabled(classID)
                for _, name in ipairs(members) do ui.text(name) end
            end)
        end
        if changed then
            config.liveClassNames = JSON.stringify(names)
            self.names.source = config.liveClassNames
        end
    end

    function self:draw(onReload)
        self:definitions()
        ui.treeNode('ACSM integration' .. (self.live:overrides() and ' - active' or '') .. '###live-timing',
            function() self:drawLive() end)
        -- Server classes cover every driver it lists, which is every driver in the session.
        if self.live:overrides() then return end
        ui.treeNode('Classes###classes', function() self:drawClasses(onReload) end)
    end

    function self:drawClasses(onReload)
        ui.text('Classes')
        help('Classes are saved automatically and included in presets. A driver assignment beats car tags; '
            .. 'if a car matches several classes, the highest one wins. Unmatched cars show no class.\n'
            .. 'Colour indicators by class, or label them with class positions, under Map > Indicators.')
        ui.sameLine(0, 16)
        if ui.button('Reload car tags') then
            self:reset()
            onReload()
        end
        if self.error then
            ui.textWrapped(self.error .. ' Clear damaged classes to enable editing.')
            if ui.button('Clear damaged classes') then self.items = {}; self:save() end
            return
        end
        if #self.items == 0 then self.items[1] = {name = '', tags = {}, drivers = {}} end
        local available, errors = self:available()
        local drivers = self:availableDrivers()
        for message in pairs(errors) do ui.textWrapped(message) end
        local changed, remove, move, swap = false, nil, nil, nil
        for i, item in ipairs(self.items) do
            local title = (item.name:match('%S') and trim(item.name) or 'Unnamed class')
                .. string.format('  (%d tags, %d drivers)', #item.tags, #item.drivers)
            ui.treeNode(title .. '###class-node-' .. i, function()
                local name = ui.inputText('Class name##class-' .. i, item.name)
                if name ~= item.name then item.name, changed = name, true end
                if not item.name:match('%S') then ui.textDisabled('Enter a name to display this class.') end
                for _, entry in ipairs({{-1, '⬆'}, {1, '⬇'}}) do
                    local target = i + entry[1]
                    local enabled = target >= 1 and target <= #self.items
                    if not enabled then ui.pushDisabled() end
                    if ui.button(entry[2] .. '##class-' .. i, vec2(23, 23)) and enabled then swap = {i, target} end
                    if not enabled then ui.popDisabled() end
                    ui.sameLine()
                end
                if ui.button('Remove class##class-' .. i) then remove = i end
                ui.treeNode('Car tags (' .. #item.tags .. ')###tags-' .. i, function()
                    local picked = picker(i, 'tags', available, item.tags, 'No unassigned tags in the entry list.')
                    if picked then move, picked.item = picked, item end
                end)
                ui.treeNode('Drivers (' .. #item.drivers .. ')###drivers-' .. i, function()
                    local picked = picker(i, 'drivers', drivers, item.drivers, 'No unassigned drivers.')
                    if picked then move, picked.item = picked, item end
                end)
            end)
        end
        if move then
            local list = move.item[move.kind]
            if move.index then table.remove(list, move.index) else list[#list + 1] = move.value end
            changed = true
        end
        if swap then
            self.items[swap[1]], self.items[swap[2]] = self.items[swap[2]], self.items[swap[1]]
            changed = true
        end
        if remove then table.remove(self.items, remove); changed = true end
        if ui.button('Add class') then
            self.items[#self.items + 1] = {name = '', tags = {}, drivers = {}}
            changed = true
        end
        if changed then self:save() end
    end

    return self
end

return M
