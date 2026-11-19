-- IBOVmap.lua
-- IBOVmap: a standalone broadcast track map. Wires the map to its standings order, classes, settings and presets.
local Model = require('model')
local Fonts = require('fonts')
local Presets = require('presets')
local TrackMap = require('trackmap')
local Sections = require('sections')

local defaults = {
    -- Car data polling (s): positions and lap counts, reordering, and livery numbers.
    pollInterval = 0.1, orderInterval = 0.5, metadataInterval = 5,
    mapClicks = true, skipDrivers = '',
    -- Timed races: 1 as the session says, 2 always one more lap after time is up, 3 never.
    timedExtraLap = 1,
    classDefinitions = '[]', liveTimingUrl = '', liveClassNames = '{}', liveTimingInterval = 30
}
for key, value in pairs(TrackMap.defaults) do defaults[key] = value end
local storage = ac.storage(defaults)
-- ac.storage reads are slow; `settings` mirrors every value as a plain table for the render path,
-- and writes through `config` update both.
local settings = {}
for key in pairs(defaults) do settings[key] = storage[key] end
local config = setmetatable({}, {
    __index = settings,
    __newindex = function(_, key, value) settings[key] = value; storage[key] = value end
})
local appFolder = __dirname or ac.getFolder(ac.FolderID.ScriptOrigin)
local model = Model.new(config)
local trackMap = TrackMap.new(config, model.classes)
local colours, textureCache = {}, {}
-- Named corners for this track, read when corner names are first shown and again each session.
local corners = {}
local MIN_WIDTH, MIN_HEIGHT = 160, 100
local gripColour = rgbm(35 / 255, 141 / 255, 220 / 255, 1)

-- `newSession` starts the standings order afresh; otherwise (applying a preset, refreshing data) cars held after
-- leaving mid-race keep their places.
local function resetCaches(newSession)
    colours, textureCache = {}, {}
    model:reset(not newSession)
    if newSession then corners.sections = nil end
end
local presets = Presets.new(config, defaults, resetCaches, appFolder .. '\\presets.json')
ac.onSessionStart(function() resetCaches(true) end)

local function parseColour(value)
    local r, g, b, a = tostring(value):match('^(%x%x)(%x%x)(%x%x)(%x%x)$')
    return r and rgbm(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, tonumber(a, 16) / 255)
end

local function colour(key)
    local value = settings[key]
    local cached = colours[key]
    if cached and cached.source == value then return cached.value end
    local parsed = parseColour(value)
    if not parsed then
        ac.warn('IBOVmap: invalid colour ' .. key .. ' = ' .. tostring(value) .. '; using default')
        parsed = parseColour(defaults[key])
    end
    colours[key] = {source = value, value = parsed}
    return parsed
end

-- An image setting's file: an absolute path, or one relative to this app's folder. CSP cannot load SVG, so an SVG is
-- drawn into a cached PNG over a few frames, and shown once ready.
local function texture(key)
    local value = settings[key]
    if value == '' then return nil end
    local cached = textureCache[key]
    if cached and cached.source == value and not cached.svg then return cached.path end
    local path, problem = cached and cached.source == value and cached.svg, nil
    if not path then
        path = value:match('^%a:[\\/]') and value or appFolder .. '\\' .. value
        problem = not io.fileExists(path) and 'Image not found: ' .. path or nil
    end
    if not problem and path:lower():match('%.svg$') then
        local ok, png, detail = pcall(require('svg').request, path, appFolder .. '\\.cache\\svg')
        if ok and png == false then
            textureCache[key] = {source = value, svg = path}
            return nil
        elseif ok and png then
            if detail then ac.warn('IBOVmap: ' .. path .. ' uses SVG features not drawn: ' .. table.concat(detail, ', ')) end
            path = png
        else
            problem = 'SVG image could not be drawn: ' .. path .. ': ' .. tostring(ok and detail or png)
        end
    end
    textureCache[key] = {source = value, path = not problem and path or nil}
    if problem then
        ac.warn('IBOVmap: ' .. problem)
        ui.toast(ui.Icons.Warning, problem)
    end
    return textureCache[key].path
end

local function focus(row)
    if row.connected then
        ac.focusCar(row.index)
        model.lastPoll = -math.huge
    else
        ui.toast(ui.Icons.Warning, 'Cannot spectate a disconnected driver.')
    end
end

-- Whether the settings window is open; scanned at most 4x/second.
local settingsScan = {time = -math.huge, open = false}
local function settingsOpen()
    local now = os.preciseClock()
    if now - settingsScan.time > 0.25 then
        settingsScan.time, settingsScan.open = now, false
        for _, item in ipairs(ac.getAppWindows()) do
            local title = item.title or ''
            if item.visible and title:find('IBOVmap', 1, true) and title:find('Settings', 1, true) then
                settingsScan.open = true
                break
            end
        end
    end
    return settingsScan.open
end

local function cornerSections()
    if not corners.sections then corners.key, corners.sections = Sections.load(appFolder) end
    return corners.sections
end

-- The resize grip follows the FADING title bar: shown while hovered or while settings are open. It is submitted
-- before the map so it wins mouse input, and painted afterwards; returns whether to paint it.
local function resizeGrip(size)
    if not (ui.windowHovered(ui.HoveredFlags.AllowWhenBlockedByActiveItem) or settingsOpen()) then return false end
    ui.setCursor(vec2(size.x - 16, size.y - 16))
    ui.invisibleButton('##resize-map', vec2(16, 16))
    if ui.itemActive() and ui.mouseDown(ui.MouseButton.Left) then
        local window = Presets.window('map')
        if window then
            local target = window:size() + ui.mouseDelta()
            window:resize(vec2(math.max(MIN_WIDTH, target.x), math.max(MIN_HEIGHT, target.y)))
        end
    end
    return true
end

function script.update()
    local now = os.preciseClock()
    local sim = ac.getSim()
    local stamp = sim.isReplayActive and sim.replayCurrentFrame or nil
    if model.session ~= sim.currentSessionIndex or (stamp and model.replayFrame and stamp < model.replayFrame) then
        model:reset()
    end
    model.session, model.replayFrame = sim.currentSessionIndex, stamp
    model:update(now)
    trackMap:update()
end

function script.windowMap()
    if ui.getScrollY() ~= 0 then ui.setScrollY(0) end
    local size, origin = ui.windowSize(), ui.getCursor()
    local grip = resizeGrip(size)
    if settings.mapCorners then trackMap.sections = cornerSections() end
    trackMap.preview = settingsOpen() or os.preciseClock() < (trackMap.previewUntil or 0)
    TrackMap.draw(trackMap, model, config, origin, vec2(size.x - origin.x, size.y - origin.y), colour, texture, focus)
    if grip then ui.drawRectFilled(vec2(size.x - 16, size.y - 16), size, gripColour) end
    ui.setCursor(origin)
end

local function help(message)
    if not message then return end
    ui.sameLine()
    ui.icon(ui.Icons.Info, 14)
    if ui.itemHovered() then ui.setTooltip(message) end
end

local function heading(label, message)
    ui.separator()
    ui.text(label)
    help(message)
end

local function toggle(key, label, message)
    if ui.checkbox(label, config[key]) then
        config[key] = not config[key]
        model.lastOrder, model.lastMetadata = -math.huge, -math.huge
    end
    help(message)
end

local function slider(key, label, min, max, integer, message)
    config[key] = ui.slider(label, config[key], min, max, integer and '%.0f' or '%.2f', integer and true or 1)
    help(message)
end

local colourFlags = ui.ColorPickerFlags.AlphaBar + ui.ColorPickerFlags.AlphaPreview + ui.ColorPickerFlags.PickerHueBar

-- Compact swatch; clicking opens a popup picker with hue and opacity bars.
-- Popup edits mutate the colour in place without colorButton returning true, so always sync.
local function pickColour(key, label)
    local c = colour(key)
    ui.colorButton('##colour-' .. key, c, colourFlags, vec2(22, 22))
    local value = string.format('%02X%02X%02X%02X', math.floor(c.r * 255 + 0.5),
        math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), math.floor(c.mult * 255 + 0.5))
    if value ~= config[key] then
        config[key] = value
        colours[key].source = value
    end
    if ui.itemHovered() then ui.setTooltip(label .. ': #' .. config[key] .. ' (click to edit colour and opacity)') end
    ui.sameLine(0, 8)
    ui.text(label)
end

local function pickTexture(key, label)
    ui.text(label)
    config[key] = ui.inputText('Path##' .. key, config[key])
    if ui.button('Browse##' .. key) then
        os.openFileDialog({title = label, defaultFolder = appFolder,
            fileTypes = {{name = 'Images', mask = '*.png;*.jpg;*.jpeg;*.dds;*.bmp;*.svg'}}}, function(err, filename)
            if err then
                ac.warn('IBOVmap image picker: ' .. err)
                ui.toast(ui.Icons.Warning, 'Image selection failed: ' .. err)
            elseif filename then
                config[key], textureCache[key] = filename, nil
            end
        end)
    end
    ui.sameLine()
    if ui.button('Clear##' .. key) then config[key], textureCache[key] = '', nil end
end

-- Map rotation dial: drag the handle round the ring (0 at the top, clockwise; Shift snaps to 15 degrees), or type
-- whole degrees in the middle. While the map follows the focused car, it is disabled and shows the live angle.
local function rotationDial()
    local dialSize = vec2(104, 104)
    local live = config.mapRotateFocus
    local degrees = live and (trackMap.rotationDegrees or 0)
        or math.floor((tonumber(config.mapRotation) or 0) + 0.5) % 360
    local start = ui.getCursor()
    if live then ui.pushDisabled() end
    -- The input goes first so it, not the dial's button beneath, takes clicks in the middle.
    ui.setCursor(vec2(start.x + dialSize.x / 2 - 22, start.y + dialSize.y / 2 - 11))
    ui.setNextItemWidth(44)
    local shown = tostring(degrees)
    local typed = ui.inputText('##map-rotation', shown, ui.InputTextFlags.CharsDecimal)
    if typed ~= shown and not live then
        local n = tonumber(typed)
        if n and n == n and math.abs(n) < math.huge then config.mapRotation = math.floor(n + 0.5) % 360 end
    end
    if ui.itemHovered() then ui.setTooltip('Degrees clockwise, 0 to 359') end
    ui.setCursor(start)
    ui.invisibleButton('##map-rotation-dial', dialSize)
    local a, b = ui.itemRectMin(), ui.itemRectMax()
    local cx, cy = (a.x + b.x) / 2, (a.y + b.y) / 2
    local radius = math.min(b.x - a.x, b.y - a.y) / 2 - 8
    if not live then
        if ui.itemHovered() or ui.itemActive() then ui.setMouseCursor(ui.MouseCursor.Hand) end
        if ui.itemActive() then
            local m = ui.mouseLocalPos()
            local dx, dy = m.x - cx, m.y - cy
            if dx * dx + dy * dy > 36 then
                local angle = math.deg(math.atan2(dx, -dy))
                if ui.hotkeyShift() then angle = math.floor(angle / 15 + 0.5) * 15 end
                config.mapRotation = math.floor(angle + 0.5) % 360
                degrees = config.mapRotation
            end
        end
    end
    if live then ui.popDisabled() end
    local dim = live and 0.45 or 1
    local dialRing, dialTick, dialHandle = rgbm(1, 1, 1, 0.45 * dim), rgbm(1, 1, 1, 0.6 * dim), rgbm(1, 0.78, 0.24, dim)
    ui.drawCircle(vec2(cx, cy), radius, dialRing, 48, 2)
    for i = 0, 11 do
        local t = math.rad(i * 30)
        local sx, sy, inner = math.sin(t), -math.cos(t), radius - (i % 3 == 0 and 9 or 5)
        ui.drawLine(vec2(cx + sx * inner, cy + sy * inner), vec2(cx + sx * radius, cy + sy * radius), dialTick, 1)
    end
    local t = math.rad(degrees)
    local hx, hy = math.sin(t), -math.cos(t)
    ui.drawLine(vec2(cx + hx * (radius - 16), cy + hy * (radius - 16)), vec2(cx + hx * radius, cy + hy * radius),
        dialHandle, 2)
    ui.drawCircleFilled(vec2(cx + hx * radius, cy + hy * radius), 6, dialHandle, 16)
    ui.sameLine(0, 12)
    ui.text('Map rotation')
    help('Turns the Track presentation round the middle of the window. Drag the handle round the dial (hold Shift '
        .. 'to snap to 15 degrees) or type whole degrees, clockwise, in the middle. Name tags, the legend and the corner '
        .. 'name stay upright; the northpoint turns with the map.')
end

local function mapSettings()
    heading('View', 'Open IBOVmap from the app sidebar. Hover it to move or resize it; click an indicator to spectate. '
        .. 'Drivers excluded under Drivers are left off; disconnected cars are never plotted.')
    config.mapFormat = ui.combo('Presentation', config.mapFormat, ui.ComboFlags.None, {'Track', 'Linear', 'Circular'})
    if config.mapFormat == 1 then
        config.mapSource = ui.combo('Track artwork', config.mapSource, ui.ComboFlags.None,
            {'Track map.png with spline fallback', 'Generated AI spline'})
        if trackMap.nativeError and config.mapSource ~= 2 then ui.textWrapped(trackMap.nativeError) end
        if trackMap.error then ui.textWrapped(trackMap.error) end
        if ui.button('Reload track geometry') then trackMap:loadTrack() end
    end
    slider('mapLineWidth', 'Generated line width', 1, 12)
    slider('mapTrackBorderWidth', 'Generated line border', 0, 6, false,
        'Outline either side of the generated spline, Linear and Circular lines. Track map.png artwork is drawn as-is.')
    slider('mapZoom', 'Focus zoom', 0, 1, false,
        '0 = whole track; 1 = 100 metre radius around the focused car (on the shorter axis). '
        .. 'Linear and Circular show the equivalent 200 metres of spline. No active focus means whole track.')
    slider('mapEdgeFade', 'Edge fade (px)', 0, 100, true,
        'Fades the map to transparent over this many pixels inside each edge of the window, instead of a hard cut. '
        .. 'The whole-track view keeps clear of the fade, so the track, indicators, name tags, legend, corner name and '
        .. 'northpoint stay fully readable; dragged elements are kept clear of it too.')
    if config.mapFormat == 1 then
        rotationDial()
        toggle('mapRotateFocus', 'Rotate with focused car', 'Turns the map so the focused car always travels up the '
            .. 'screen, in place of the dial. Changing focused car eases round to the new heading; with no focused car '
            .. 'the map holds its last angle. At whole-track zoom the map is sized to fit at any angle.')
    end
    heading('Indicators')
    config.mapColourMode = ui.combo('Colour by', config.mapColourMode, ui.ComboFlags.None,
        {'Uniform', 'Class', 'Relative to focused car'})
    config.mapShape = ui.combo('Shape', config.mapShape, ui.ComboFlags.None, {'Teardrop', 'Triangle', 'Circle'})
    slider('mapMarkerSize', 'Indicator radius', 4, 36)
    slider('mapFocusScale', 'Focused-car scale', 1, 2)
    slider('mapBorderWidth', 'Border width', 0, 6)
    toggle('mapShadow', 'Drop shadow', 'Applies to indicators, name tags, the colour legend, the corner name and the '
        .. 'northpoint.')
    local labelRow = TrackMap.labelRow(config.mapLabel)
    local chosenRow = ui.combo('Indicator label', labelRow, ui.ComboFlags.None, TrackMap.labelChoices)
    if chosenRow ~= labelRow then config.mapLabel = TrackMap.labelID(chosenRow) end
    help('Positions follow the race order (grid order before the start). Class positions count connected, '
        .. 'non-excluded drivers in that order using the Classes tab; unclassified cars keep overall positions. Driver '
        .. 'letters are uppercased; the surname is the last word of the name; initials use up to three words of the '
        .. 'name. Cars without a livery number are left blank.')
    toggle('mapLegend', 'Show colour legend', 'Ctrl+drag it anywhere on the map (a plain drag moves the window); where '
        .. 'you drop it is kept for each track.')
    if config.mapLegend then
        ui.sameLine()
        if ui.button('Reset legend position') then trackMap:clearPlaces('legend') end
    end
    toggle('mapLeader', 'Race leader colour', 'The car in P1 takes its own colour (Style > Colours), over the class or '
        .. 'relative colour. The focused car keeps its colour.')
    local tagRow = TrackMap.labelRow(config.mapTag)
    local chosenTag = ui.combo('Name tag', tagRow, ui.ComboFlags.None, TrackMap.labelChoices)
    if chosenTag ~= tagRow then config.mapTag = TrackMap.labelID(chosenTag) end
    help('A short tag beside each indicator, up and to the right, as on ACSM\'s live timing map. Driver (surname, '
        .. 'three letters) matches ACSM. None turns tags off. Ctrl+drag any tag on the map to move every tag to that '
        .. 'spot beside its indicator; the map keeps room so tags stay visible at its edges.')
    if config.mapTag ~= 1 then
        ui.sameLine()
        if ui.button('Reset tag position') then config.mapTagX, config.mapTagY = defaults.mapTagX, defaults.mapTagY end
    end
    slider('mapFontSize', 'Label / legend text size', 8, 24)
    heading('Track features')
    toggle('mapSectors', 'Sector markers', 'A tick across the track at each sector split, from the track\'s timing '
        .. 'gates. On a track without them, each split is learnt the first time a car crosses it and kept for that track.')
    toggle('mapNorth', 'Northpoint', 'A compass rose pointing to the track\'s north (Track presentation), turning with '
        .. 'the map. Ctrl+drag it anywhere on the map (a plain drag moves the window); where you drop it is kept for each '
        .. 'track. An image (north at the top) can replace it under Images below.')
    if config.mapNorth then
        ui.sameLine()
        if ui.button('Reset northpoint position') then trackMap:clearPlaces('north') end
        slider('mapNorthSize', 'Northpoint size', 32, 200, true)
    end
    ui.treeNode('Corner names', function()
        toggle('mapCorners', 'Name the corner the focused car is in', 'Like Kunos\'s Track Description app: the name '
            .. 'fades in as the focused car enters a named corner, holds a moment after it leaves, and crossfades to the '
            .. 'next. Names come from the track\'s data\\sections.ini, unless IBOVmap\\sections\\<track>.ini exists for '
            .. 'the track. Ctrl+drag the name anywhere on the map (a plain drag moves the window); where you drop it is '
            .. 'kept for each track.')
        if config.mapCorners then
            -- Shows the placeholder on the map while this section is open.
            trackMap.previewUntil = os.preciseClock() + 0.5
            slider('mapCornerSize', 'Text size', 10, 48, true)
            slider('mapCornerFade', 'Fade (s)', 0, 2)
            if ui.button('Reset corner name position') then trackMap:clearPlaces('corner') end
            local sections = cornerSections()
            if #sections == 0 then
                ui.textWrapped('No named corners for ' .. corners.key .. '. Add sections\\' .. corners.key .. '.ini to this '
                    .. 'app\'s folder, in the format of a track\'s data\\sections.ini.')
            end
            ui.textWrapped('While this section is open, a placeholder shows where the name will appear.')
        end
    end)
    ui.treeNode('Class colours', function()
        local styles, labels, seen = trackMap:classStyles(), {}, {}
        if trackMap.classError then
            ui.textWrapped(trackMap.classError)
            if ui.button('Clear damaged map class colours') then config.mapClassColours = '{}' end
            return
        end
        for _, row in ipairs(model.rows) do
            local label = model.classes:classify(row.meta)
            if label ~= '' and not seen[label] then labels[#labels + 1], seen[label] = label, true end
        end
        table.sort(labels)
        ui.textWrapped('Classes take distinct Commodore 64 colours in Classes tab order; other classes (such as live '
            .. 'timing classes) take the next unused colour (14 before any repeats). Joins never recolour a class. '
            .. 'Click a swatch to override its colour and opacity.')
        for _, label in ipairs(labels) do
            local hex = trackMap:classHex(label)
            local c = TrackMap.colour(hex)
            ui.colorButton('##map-class-' .. label, c, colourFlags, vec2(22, 22))
            local value = string.format('%02X%02X%02X%02X', math.floor(c.r * 255 + 0.5),
                math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), math.floor(c.mult * 255 + 0.5))
            if value ~= hex then
                styles[label] = value
                config.mapClassColours = JSON.stringify(styles)
            end
            ui.sameLine()
            ui.text(label)
        end
        if ui.button('Restore automatic class colours') then config.mapClassColours = '{}' end
    end)
    ui.treeNode('Images', function()
        ui.textWrapped('Optional texture over the coloured indicator. Transparent areas reveal its class / relative colour. '
            .. 'Use an absolute path or one relative to this app\'s folder. SVG files are drawn once into a PNG (in '
            .. '.cache\\svg); text, embedded images, clipping, masks, patterns and filters in them are not drawn.')
        pickTexture('mapMarkerTexture', 'Map indicator')
        ui.textWrapped('Optional northpoint image in place of the drawn compass rose, with north at the top and east to '
            .. 'the right. It is stretched to a square of the northpoint size and turns with the map.')
        pickTexture('mapNorthTexture', 'Northpoint')
        if ui.button('Reload images') then textureCache = {} end
        help('Draws changed image files (and SVGs) again.')
    end)
end

local function styleSettings()
    Fonts.tools()
    ui.separator()
    Fonts.settings(config, 'mapFont', 'Default map font')
    ui.treeNode('Element fonts', function()
        for _, entry in ipairs({
            {'mapLabelFont', 'Indicator labels'}, {'mapTagFont', 'Name tags'}, {'mapLegendFont', 'Legend'},
            {'mapCornerFont', 'Corner name'}, {'mapNorthFont', 'Northpoint letters'}
        }) do
            config[entry[1]] = Fonts.picker(entry[2] .. '##' .. entry[1], config[entry[1]], 'Default map font')
        end
    end)
    heading('Colours', 'Click a swatch to edit colour and opacity. Class colours for indicators are set under '
        .. 'Map > Class colours.')
    for i, entry in ipairs({
        {'mapTrackColour', 'Track / legend'}, {'mapTrackBorderColour', 'Generated line border'},
        {'mapBackgroundColour', 'Map background'},
        {'mapMarkerColour', 'Uniform / unclassified'}, {'mapFocusColour', 'Focused car'},
        {'mapAheadColour', 'Ahead (same lap)'}, {'mapBehindColour', 'Behind (same lap)'},
        {'mapLapAheadColour', 'At least a lap ahead'}, {'mapLapBehindColour', 'At least a lap behind'},
        {'mapBorderColour', 'Indicator border'}, {'mapShadowColour', 'Drop shadow'}, {'mapTextColour', 'Indicator labels'},
        {'mapLeaderColour', 'Race leader'}, {'mapTagColour', 'Name tags'}, {'mapTagBackColour', 'Name tag background'},
        {'mapSectorColour', 'Sector markers'}, {'mapStartColour', 'Start / finish line'},
        {'mapCornerColour', 'Corner name'}, {'mapCornerBackColour', 'Corner name background'},
        {'mapNorthColour', 'Northpoint dark / outline'}, {'mapNorthFillColour', 'Northpoint light'},
        {'mapNorthTextColour', 'Northpoint letters'}
    }) do
        if i % 2 == 0 then ui.sameLine(260) end
        pickColour(entry[1], entry[2])
    end
end

local function driverSettings()
    heading('Drivers')
    local previous = config.skipDrivers
    config.skipDrivers = ui.inputText('Exclude names', config.skipDrivers)
    if previous ~= config.skipDrivers then model.lastOrder = -math.huge end
    help('Drivers left off the map and out of its positions, such as a TV car or your own car while spectating. Exact '
        .. 'driver names, separated by |. To exclude a driver with a literal | in their name, use a backslash, e.g. '
        .. '"My|Name" becomes "My\\|Name".')
    toggle('mapClicks', 'Click an indicator to spectate', 'Clicking an indicator focuses the camera on that car. '
        .. 'Hovering one always shows its position, driver and class.')
    local extra = ui.combo('Timed races: lap after time', config.timedExtraLap, ui.ComboFlags.None,
        {'As the session says', 'Always one more lap', 'Never'})
    if extra ~= config.timedExtraLap then config.timedExtraLap, model.lastPoll = extra, -math.huge end
    help('Whether a timed race runs one more lap once the leader crosses the line after time is up ("time plus one '
        .. 'lap"). Replays never say so, so their finish comes a lap early unless this is set to Always. Used for '
        .. 'positions in replays.')
    heading('Data refresh', 'Positions follow the race order: grid order before the start, cars that leave mid-race '
        .. 'held in place until passed, and replays rebuilt from each car\'s lap timer. Indicators move every frame '
        .. 'whatever these intervals.')
    slider('pollInterval', 'Car data (s)', 0.02, 2, false, 'Positions and lap counts refresh at this rate.')
    slider('orderInterval', 'Reorder (s)', 0.1, 5)
    slider('metadataInterval', 'Livery numbers (s)', 1, 60, false, 'Livery numbers are looked up again at this rate; '
        .. 'a new driver in a car shows straight away.')
    if ui.button('Refresh data now') then resetCaches() end
    help('Reloads names, car tags, colours and images. Cars held after leaving mid-race keep their places.')
end

local tabs = {'Map', 'Style', 'Classes', 'Drivers', 'Presets'}

function script.windowSettings()
    ui.text('IBOVmap')
    help('Open IBOVmap from the app sidebar. Hover the map to move or resize it; its resize grip also shows while '
        .. 'settings are open. All settings save automatically. Hover an info icon for help.')
    local contents = {mapSettings, styleSettings,
        function() model.classes:draw(function() model.lastMetadata = -math.huge end) end,
        driverSettings, function() presets:draw() end}
    ui.tabBar('IBOVmapSettings', function()
        for i, name in ipairs(tabs) do ui.tabItem(name, contents[i]) end
    end)
end
