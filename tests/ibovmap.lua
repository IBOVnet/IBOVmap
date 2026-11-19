-- tests\ibovmap.lua
-- Checks IBOVmap's own wiring: its standings order, corner names, presets, live-timing status and windows.
-- Run from the app folder with Lua for Windows: lua tests\ibovmap.lua
package.path = '.\\?.lua;' .. package.path
local json = require('json')
JSON = {parse = json.decode, stringify = json.encode}

local function equal(actual, expected, message)
    assert(actual == expected, (message and message .. ': ' or '') .. tostring(actual) .. ' ~= ' .. tostring(expected))
end

local vectors = {__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end}
vec2 = function(x, y) return setmetatable({x = x, y = y}, vectors) end
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
rgbm = function(r, g, b, a) return {r = r, g = g, b = b, mult = a} end
local clock = 0
os.preciseClock = function() return clock end

local files, saves, warnings, toasts = {}, {}, {}, {}
io.load = function(path, fallback) return files[path] or fallback end
io.save = function(path, data, ensure)
    files[path], saves[#saves + 1] = data, {path = path, ensure = ensure}
    return true
end
io.fileExists = function(path) return files[path] ~= nil end
io.scanDir = function() return {} end

local cars, names, ids = {}, {}, {}
local sim = {carsCount = 0, focusedCar = 0, currentSessionIndex = 0, dt = 0.016, isSessionStarted = true,
    raceSessionType = 3, trackLengthM = 1000, isTrackOpen = false}
local windowList, accessors, focused = {}, {}, nil
ac = {
    FolderID = {Root = 1, ACApps = 2, ContentTracks = 3, ContentFonts = 4, ExtFonts = 5, ScriptOrigin = 6},
    SessionType = {Practice = 1, Qualify = 2, Race = 3},
    getFolder = function(id) return ({'root', 'root\\apps', 'root\\content\\tracks', 'fonts', 'ext', 'app'})[id] end,
    getSim = function() return sim end,
    getSession = function() return {isTimedRace = false, laps = 10} end,
    getCar = function(i) return cars[i] end, getCarID = function(i) return ids[i] end,
    getDriverName = function(i) return names[i] end, getDriverNumber = function(i) return i + 1 end,
    warn = function(message) warnings[#warnings + 1] = message end,
    findNodes = function() return {size = function() return 0 end, findNodes = function(self) return self end} end,
    getTrackID = function() return 'ring' end, getTrackLayout = function() return '' end,
    getTrackFullID = function() return 'ring' end,
    getTrackDataFilename = function(name) return 'root\\content\\tracks\\ring\\data\\' .. name end,
    hasTrackSpline = function() return true end,
    trackProgressToWorldCoordinate = function(t)
        return vec3(math.cos(t * math.pi * 2) * 100, 0, math.sin(t * math.pi * 2) * 100)
    end,
    getAppWindows = function() return windowList end,
    accessAppWindow = function(name) return accessors[name] end,
    focusCar = function(i) focused = i end
}

local function makeCar(index, slot, racePosition, laps, spline)
    local a = spline * math.pi * 2
    return {index = index, sessionID = slot, isActive = true, isConnected = true, racePosition = racePosition,
        drivenInRace = 0, bestLapTimeMs = 0, previousLapTimeMs = 0, lapTimeMs = 30000, lapCount = laps,
        isInPit = false, isInPitlane = false, isRaceFinished = false, splinePosition = spline, currentSector = 0,
        position = vec3(math.cos(a) * 100, 0, math.sin(a) * 100), look = vec3(-math.sin(a), 0, math.cos(a))}
end

local function order(model)
    local result = {}
    for i, row in ipairs(model.rows) do
        equal(row.position, i)
        result[i] = row.meta.name .. (row.held and '*' or '')
    end
    return table.concat(result, ',')
end

files['root\\content\\cars\\gt3\\ui\\ui_car.json'] = '{"tags":["gt3"]}'
files['root\\content\\cars\\gt4\\ui\\ui_car.json'] = '{"tags":["gt4"]}'
local settings = {pollInterval = 0.1, orderInterval = 0.5, metadataInterval = 5, skipDrivers = '', timedExtraLap = 1,
    classDefinitions = '[{"name":"GT3","tags":["gt3"]},{"name":"GT4","tags":["gt4"]}]', liveTimingUrl = '',
    liveClassNames = '{}', liveTimingInterval = 30}
local function setRoster()
    sim.carsCount = 3
    cars[0], cars[1], cars[2] = makeCar(0, 10, 2, 2, 0.5), makeCar(1, 11, 1, 2, 0.6), makeCar(2, 12, 3, 2, 0.4)
    names[0], names[1], names[2] = 'Ann', 'Bob', 'Cy'
    ids[0], ids[1], ids[2] = 'gt3', 'gt3', 'gt4'
end

-- The standings order: CSP's race order, exclusions closing up, a car that leaves mid-race held in its place until
-- passed (still counting towards class positions), replays from lap timers and practice by best lap.
do
    local Model = require('model')
    local Map = require('trackmap')
    setRoster()
    local model = Model.new(settings)
    local now = 0
    local function poll() now = now + 1; model:update(now) end
    poll()
    equal(order(model), 'Bob,Ann,Cy')
    settings.skipDrivers = ' Bob '
    poll()
    equal(order(model), 'Ann,Cy', 'excluded drivers leave the order')
    settings.skipDrivers = ''
    poll()
    cars[1].isConnected = false
    cars[0].racePosition, cars[2].racePosition = 1, 2
    poll()
    equal(order(model), 'Bob*,Ann,Cy', 'held where it left')
    local mapConfig = {skipDrivers = '', mapClassColours = '{}'}
    local markers = Map.new(mapConfig, model.classes):collect(model)
    equal(#markers, 2)
    equal(markers[1].row.meta.name, 'Ann'); equal(markers[1].class, 'GT3'); equal(markers[1].classPosition, 2)
    equal(markers[2].class, 'GT4'); equal(markers[2].classPosition, 1)
    cars[0].splinePosition = 0.7
    poll()
    equal(order(model), 'Ann,Bob*,Cy', 'until passed')
    cars[1].isConnected = true
    poll()
    equal(order(model), 'Ann,Bob,Cy', 'and resumes on return')

    -- Replays keep laps only for the recorded car (index 0): the others' come from their lap timers.
    model:reset()
    sim.carsCount = 2
    sim.isReplayActive, sim.replayCurrentFrame, sim.timeToSessionStart, sim.sessionTimeLeft = true, 5000, -300000, 600000
    cars[0], cars[1] = makeCar(0, 10, 1, 3, 0.5), makeCar(1, 11, 2, 0, 0.6)
    poll()
    equal(order(model), 'Bob,Ann', 'the car further round leads')
    equal(model.byIndex[1].laps, 3)
    sim.isReplayActive, sim.replayCurrentFrame, sim.timeToSessionStart, sim.sessionTimeLeft = nil, nil, nil, nil

    -- Outside races: best lap first, cars without a lap last.
    model:reset()
    sim.raceSessionType = 1
    setRoster()
    cars[0].bestLapTimeMs, cars[1].bestLapTimeMs, cars[2].bestLapTimeMs = 0, 91000, 90000
    poll()
    equal(order(model), 'Cy,Bob,Ann')
    sim.raceSessionType = 3
end

-- Corner names: each section's TEXT, from this app's file for the track if there is one, else the track's own. Other
-- keys, such as a spoken TTS form, never name a section.
do
    local Sections = require('sections')
    local parsed = Sections.parse('\239\187\191[SECTION_0]\nIN = 0.1\nOUT = 0.2\nTEXT = Turn 1\n'
        .. '[SECTION_1]\nIN=0.3\nOUT=0.4\nTTS=Spoken only\n[SECTION_2]\nIN=0.5\nTEXT=No end\n')
    equal(#parsed, 1, 'a section needs both ends and a TEXT name')
    equal(parsed[1].label, 'Turn 1'); equal(parsed[1].from, 0.1); equal(parsed[1].to, 0.2)
    local function first() local _, list = Sections.load('app'); return list[1] and list[1].label end
    files['root\\content\\tracks\\ring\\data\\sections.ini'] = '[S]\nIN=0\nOUT=0.1\nTEXT=Track file\n'
    equal(first(), 'Track file')
    files['app\\sections\\ring.ini'] = '[S]\nIN=0\nOUT=0.1\nTEXT=Own\n'
    equal(first(), 'Own')
    files['app\\sections\\ring.ini'] = nil
end

-- Presets: every setting and, while the map is open, its position, size and pinning, stored in their own file.
local window = {at = vec2(10, 20), extent = vec2(300, 200), shown = true, locked = false}
function window:valid() return true end
function window:position() return self.at end
function window:size() return self.extent end
function window:visible() return self.shown end
function window:pinned() return self.locked end
function window:resize(size) self.extent = size end
function window:move(position) self.at = position end
function window:setPinned(value) self.locked = value end
function window:setVisible(value) self.shown = value end
windowList = {{name = 'IMGUI_LUA_IBOVmap_map', title = 'IBOVmap', visible = true}}
accessors.IMGUI_LUA_IBOVmap_map = window
ui = {Icons = {Info = 0, Warning = 1, Confirm = 2}, toast = function(_, message) toasts[#toasts + 1] = message end}
do
    local Presets = require('presets')
    local defaults = {mapZoom = 0, classDefinitions = '[]', mapLegend = false}
    local config = {mapZoom = 0.5, classDefinitions = '[{"name":"GT3","tags":["gt3"]}]', mapLegend = true}
    local applied = 0
    local presets = Presets.new(config, defaults, function() applied = applied + 1 end, 'app\\presets.json')
    presets.name = ' Broadcast '
    presets:save()
    equal(saves[#saves].path, 'app\\presets.json'); equal(saves[#saves].ensure, true)
    local stored = json.decode(files['app\\presets.json'])[1]
    equal(stored.name, 'Broadcast'); equal(stored.values.mapZoom, 0.5)
    equal(stored.geometry.map.w, 300); equal(stored.geometry.map.pinned, false)
    config.mapZoom, config.mapLegend, config.classDefinitions = 0, false, '[]'
    window.at, window.extent = vec2(500, 500), vec2(100, 100)
    local restored = Presets.new(config, defaults, function() applied = applied + 1 end, 'app\\presets.json')
    restored.selected = 1
    restored:apply()
    equal(config.mapZoom, 0.5); equal(config.mapLegend, true); assert(config.classDefinitions:find('GT3', 1, true))
    equal(window.at.x, 10); equal(window.extent.y, 200); equal(applied, 1)
    -- Damaged classes apply nothing at all.
    restored.items[1].values.classDefinitions, config.mapZoom = 'damaged', 0
    restored:apply()
    equal(config.mapZoom, 0); equal(applied, 1)
    assert(toasts[#toasts]:find('Invalid preset classes', 1, true))
    -- With the map closed, a preset holds settings alone, and applying it leaves the window where it is.
    window.shown, presets.name = false, 'Hidden'
    presets:save()
    equal(presets.items[presets.selected].geometry.map, nil)
    window.at = vec2(1, 2)
    presets:apply()
    equal(window.at.x, 1)
    window.shown = true
    files['app\\presets.json'] = 'not JSON'
    local damaged = Presets.new(config, defaults, function() end, 'app\\presets.json')
    damaged.name = 'Any'
    damaged:save()
    equal(files['app\\presets.json'], 'not JSON', 'damaged presets are not overwritten')
    files['app\\presets.json'] = nil
end

-- Live timing reports drivers and classes (teams are not part of the map).
do
    local LiveTiming = require('livetiming')
    local reply
    web = {get = function(_, callback) reply = callback end}
    local live = LiveTiming.new({liveTimingUrl = 'https://example.cc/live-timing?server=1', liveTimingInterval = 30,
        liveClassNames = '{"a":"Pro"}'})
    live:update(0)
    reply(nil, {status = 200, body = json.encode({Track = 'ring', ConnectedDrivers = {
        {CarInfo = {CarID = 1, DriverName = 'Ann', CarModel = 'gt3', ClassID = 'a', TeamName = 'Red'}}}})})
    assert(live.status:match('^1 drivers, 1 classes %(updated .+%)$'), live.status)
    web = nil
end

-- The app: settings persist through the storage mirror, every tab draws, the map plots cars, names the focused
-- car's corner and spectates a clicked car only while clicks are enabled.
do
    local storage, tabs, clicked, mouse, drawnText = nil, {}, false, vec2(-1, -1), {}
    ac.storage = function(values) storage = values; return values end
    ac.onSessionStart = function() end
    __dirname = 'app'
    local function call(fn) if type(fn) == 'function' then fn() end end
    ui = setmetatable({
        Icons = {Info = 0, Warning = 1, Confirm = 2}, Alignment = {Start = 0, Center = 1, End = 2},
        MouseButton = {Left = 0}, MouseCursor = {Hand = 1, ResizeAll = 2}, ComboFlags = {None = 0},
        WindowFlags = {None = 0}, InputTextFlags = {CharsDecimal = 1}, HoveredFlags = {AllowWhenBlockedByActiveItem = 1},
        ColorPickerFlags = {AlphaBar = 1, AlphaPreview = 2, PickerHueBar = 4},
        toast = function(_, message) toasts[#toasts + 1] = message end,
        checkbox = function() return false end, button = function() return false end,
        selectable = function() return false end, itemHovered = function() return false end,
        itemActive = function() return false end, colorButton = function() return false end,
        slider = function(label, value) return label == 'Focus zoom' and 0.25 or value end,
        inputText = function(_, value) return value end,
        combo = function(_, value, flags) call(flags); return value end,
        treeNode = function(_, content) call(content) end, tabBar = function(_, content) content() end,
        tabItem = function(name, content) tabs[#tabs + 1] = name; content() end,
        childWindow = function(_, _, _, _, content) content() end, availableSpaceX = function() return 600 end,
        getCursor = function() return vec2(0, 0) end, windowSize = function() return vec2(400, 400) end,
        getScrollY = function() return 0 end, itemRectMin = function() return vec2(0, 0) end,
        itemRectMax = function() return vec2(104, 104) end, mouseLocalPos = function() return vec2(0, 0) end,
        windowHovered = function() return true end, hotkeyCtrl = function() return false end,
        hotkeyShift = function() return false end, mouseDown = function() return false end,
        mousePos = function() return mouse end, mouseClicked = function() return clicked end,
        rectHovered = function(a, b) return mouse.x >= a.x and mouse.x <= b.x and mouse.y >= a.y and mouse.y <= b.y end,
        setTooltip = function(message) drawnText.tooltip = message end,
        measureDWriteText = function(t, s) return vec2(#t * s * 0.6, s) end,
        dwriteDrawTextClipped = function(value) drawnText[value] = true end
    }, {__index = function() return function() end end})
    script = {}
    setRoster()
    sim.focusedCar = 0
    dofile('IBOVmap.lua')
    local function upvalue(fn, key)
        for i = 1, math.huge do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == key then return value end
        end
        error('Missing upvalue: ' .. key)
    end
    local config, trackMap = upvalue(script.windowMap, 'config'), upvalue(script.windowMap, 'trackMap')
    script.windowSettings()
    equal(table.concat(tabs, ','), 'Map,Style,Classes,Drivers,Presets')
    equal(storage.mapZoom, 0.25, 'settings write through to storage')
    equal(config.mapZoom, 0.25)
    config.mapZoom, config.mapCorners, config.mapLabel = 0, true, 2
    script.windowMap() -- The first draw starts loading the track; sampling then runs in script.update.
    for _ = 1, 20 do script.update() end
    script.windowMap()
    equal(trackMap.sections[1].label, 'Track file')
    assert(trackMap.bounds, 'spline sampled')
    local hit
    for i = 1, trackMap.hits.markerCount do
        if trackMap.hits.markers[i].marker.row.index == 1 then hit = trackMap.hits.markers[i] end
    end
    assert(hit and drawnText['1'] and drawnText['2'], 'indicators drawn with positions')
    mouse, clicked = vec2(hit.x, hit.y), true
    script.windowMap()
    equal(focused, 1)
    assert(drawnText.tooltip:find('Bob', 1, true))
    focused, config.mapClicks = nil, false
    script.windowMap()
    equal(focused, nil, 'clicks can be turned off')
end

print('IBOVmap tests passed: standings order, corner names, presets, live timing and app wiring')
