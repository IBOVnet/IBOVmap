-- trackmap.lua
-- The track map: geometry loading, view maths, car indicators, legend, sectors, corner names and northpoint.
local M = {}

M.defaults = {
    mapFormat = 1, mapSource = 1, mapZoom = 0, mapColourMode = 1,
    mapShape = 1, mapMarkerSize = 12, mapFocusScale = 1.3, mapBorderWidth = 2,
    mapShadow = true, mapLabel = 2, mapLegend = false,
    mapFont = 'Segoe UI:@System', mapFontSize = 12, mapLineWidth = 3,
    -- Per-element overrides of mapFont; '' uses the default.
    mapLabelFont = '', mapTagFont = '', mapLegendFont = '', mapCornerFont = '', mapNorthFont = '',
    mapTrackBorderWidth = 0, mapTrackBorderColour = '111825FF',
    mapBackgroundColour = '00000000', mapTrackColour = 'FFFFFFFF',
    mapMarkerColour = 'A6B0C0FF', mapFocusColour = 'FFE066FF',
    mapAheadColour = 'FF7070FF', mapBehindColour = '4AE091FF',
    mapLapAheadColour = 'B68CFFFF', mapLapBehindColour = '238DDCFF',
    mapBorderColour = '111825FF', mapShadowColour = '00000090',
    mapTextColour = '111825FF', mapMarkerTexture = '', mapClassColours = '{}',
    mapLeader = false, mapLeaderColour = 'FF6A00FF', mapTag = 1, mapTagX = 12, mapTagY = -24, mapTagColour = 'FFFFFFFF', mapTagBackColour = '00000000',
    mapCorners = false, mapCornerSize = 18, mapCornerFade = 0.4,
    mapCornerColour = 'FFFFFFFF', mapCornerBackColour = '111825C0',
    mapSectors = false, mapSectorColour = 'FFC83CFF', mapStartColour = 'FF3B3BFF',
    -- Edge fade in pixels; map rotation in degrees clockwise (Track presentation), or following the focused car.
    mapEdgeFade = 0, mapRotation = 0, mapRotateFocus = false,
    mapNorth = false, mapNorthSize = 72, mapNorthTexture = '', mapNorthColour = '111825FF',
    mapNorthFillColour = 'FFFFFFFF', mapNorthTextColour = 'FFFFFFFF',
    -- Per track: dragged positions {legend = {x, y}, corner = {x, y}, north = {x, y}} (each the element's centre as a
    -- fraction of the window), and sector splits learnt from cars crossing them {sectors = {["1"] = lap fraction, ...}}.
    mapPlaces = '{}'
}

local function finite(n)
    return type(n) == 'number' and n == n and math.abs(n) < math.huge
end

local function validPoint(p)
    return p and finite(p.x) and finite(p.z)
end

local function clamp(n, low, high) return math.max(low, math.min(high, n)) end
local function lerp(a, b, t) return a + (b - a) * t end

function M.colour(value)
    if type(value) ~= 'string' then return end
    local r, g, b, a = value:match('^(%x%x)(%x%x)(%x%x)(%x%x)$')
    if r then return rgbm(tonumber(r, 16) / 255, tonumber(g, 16) / 255,
        tonumber(b, 16) / 255, tonumber(a, 16) / 255) end
end

-- `laps` and `focusLaps`, if given, stand in for CSP's lap counts (which replays keep only for the recorded car).
function M.relation(car, focus, race, open, laps, focusLaps)
    if not focus then return 'mapMarkerColour' end
    local delta = car.splinePosition - focus.splinePosition
    if race then
        delta = delta + (laps or car.lapCount) - (focusLaps or focus.lapCount)
        if delta >= 1 then return 'mapLapAheadColour' end
        if delta <= -1 then return 'mapLapBehindColour' end
    elseif not open then
        delta = (delta + 0.5) % 1 - 0.5
    end
    return delta > 0 and 'mapAheadColour' or 'mapBehindColour'
end

-- `turn` (optional, see M.turned) rotates the view: its cos/sin turn world x/z clockwise on screen, and its
-- min/max X/Z are the content's extent in that rotated frame, which the whole-track view fits.
function M.view(bounds, width, height, zoom, focus, out, turn)
    local frame = turn or bounds
    local c, s = turn and turn.cos or 1, turn and turn.sin or 0
    local scale = math.min(width / math.max(1, frame.maxX - frame.minX),
        height / math.max(1, frame.maxZ - frame.minZ))
    local u, v = (frame.minX + frame.maxX) / 2, (frame.minZ + frame.maxZ) / 2
    if validPoint(focus) then
        zoom = clamp(zoom, 0, 1)
        local fullScale, targetScale = scale, math.max(scale, math.min(width, height) / 200)
        scale = fullScale * (targetScale / fullScale) ^ zoom
        -- Keep an edge-of-map focus visible while the view tightens around it.
        local pan = targetScale > fullScale and (1 - fullScale / scale) / (1 - fullScale / targetScale) or zoom
        u, v = lerp(u, focus.x * c - focus.z * s, pan), lerp(v, focus.x * s + focus.z * c, pan)
    end
    out = out or {}
    out.x, out.z, out.scale, out.width, out.height = u * c + v * s, v * c - u * s, scale, width, height
    out.cos, out.sin = c, s
    return out
end

function M.project(view, x, z)
    local c, s, dx, dz = view.cos or 1, view.sin or 0, x - view.x, z - view.z
    return view.width / 2 + (dx * c - dz * s) * view.scale, view.height / 2 + (dx * s + dz * c) * view.scale
end

-- Extent of `points` ({x, z} each) in the frame turned by `angle` radians clockwise, for M.view.
function M.turned(points, angle, out)
    local c, s = math.cos(angle), math.sin(angle)
    local minU, maxU, minV, maxV = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #points do
        local p = points[i]
        local u, v = p.x * c - p.z * s, p.x * s + p.z * c
        if u < minU then minU = u end
        if u > maxU then maxU = u end
        if v < minV then minV = v end
        if v > maxV then maxV = v end
    end
    out = out or {}
    out.minX, out.maxX, out.minZ, out.maxZ, out.cos, out.sin = minU, maxU, minV, maxV, c, s
    return out
end

-- Map angle (radians clockwise) that points a car looking along world (lx, lz) up the screen.
function M.heading(lx, lz)
    if not (finite(lx) and finite(lz)) or lx * lx + lz * lz < 1e-8 then return end
    return -math.pi / 2 - math.atan2(lz, lx)
end

function M.progress(progress, focus, zoom, length, open)
    progress = clamp(progress, 0, 1)
    if zoom <= 0 or not finite(focus) or not finite(length) or length <= 0 then return progress end
    local minimum = math.min(1, 200 / length)
    if minimum == 1 then return progress end
    local span = minimum ^ clamp(zoom, 0, 1)
    local centre = lerp(0.5, focus, (1 - span) / (1 - minimum))
    local delta = progress - centre
    if not open then delta = (delta + 0.5) % 1 - 0.5 end
    local t = 0.5 + delta / span
    if t >= 0 and t <= 1 then return t end
end

-- Indexed by the stored mapLabel ID. New modes are appended so saved choices and presets keep their
-- meaning; labelOrder sets the order shown in the picker.
M.labels = {'None', 'Overall position', 'Class position', 'Driver (first two letters)',
    'Driver (initials)', 'Car livery number', 'Driver (surname, two letters)', 'Driver (surname, three letters)'}
M.labelOrder = {1, 2, 3, 4, 7, 8, 5, 6}
M.labelChoices = {}
for i, id in ipairs(M.labelOrder) do M.labelChoices[i] = M.labels[id] end

-- Converts between a stored mapLabel ID and its row in the picker.
function M.labelRow(id)
    for i, value in ipairs(M.labelOrder) do if value == id then return i end end
    return 2
end

function M.labelID(row)
    return M.labelOrder[row] or 2
end

-- Letters/digits, or any multibyte UTF-8 character, so accented names keep their first letter.
local letter = '[%w\194-\244][\128-\191]*'
local nameLabels = {}
local numbers = {}

-- Position numbers are formatted once rather than every frame.
function M.number(n)
    local s = numbers[n]
    if not s then s = tostring(n); numbers[n] = s end
    return s
end

function M.label(mode, marker)
    local row = marker.row
    if mode == 2 then return M.number(row.position) end
    if mode == 3 then return M.number(marker.class ~= '' and marker.classPosition or row.position) end
    if mode == 6 then return row.meta.number ~= '' and row.meta.number or nil end
    if mode ~= 4 and mode ~= 5 and mode ~= 7 and mode ~= 8 then return nil end
    local name = row.meta.name or ''
    local key = mode .. '|' .. name
    if not nameLabels[key] then
        local parts = {}
        if mode == 4 or mode == 7 or mode == 8 then
            local source, count = name, mode == 8 and 3 or 2
            if mode ~= 4 then
                -- Last word containing a letter, so a trailing tag like "(2)" is still skipped over.
                for word in name:gmatch('%S+') do
                    if word:find('[%a\194-\244]') then source = word end
                end
            end
            for char in source:gmatch(letter) do
                parts[#parts + 1] = char
                if #parts == count then break end
            end
        else
            for word in name:gmatch('%S+') do
                parts[#parts + 1] = word:match(letter)
                if #parts == 3 then break end
            end
        end
        nameLabels[key] = table.concat(parts):upper()
    end
    return nameLabels[key] ~= '' and nameLabels[key] or nil
end

local function extend(bounds, x, z)
    bounds.minX, bounds.maxX = math.min(bounds.minX, x), math.max(bounds.maxX, x)
    bounds.minZ, bounds.maxZ = math.min(bounds.minZ, z), math.max(bounds.maxZ, z)
end

-- Commodore 64 palette without black and white, ordered so the first classes contrast most.
M.palette = {'FF7777FF', 'AAFFEEFF', 'EEEE77FF', 'CC44CCFF', 'AAFF66FF', '0088FFFF', 'DD8855FF',
    '00CC55FF', 'BBBBBBFF', '880000FF', '0000AAFF', '777777FF', '664400FF', '333333FF'}

-- `classes` (optional) supplies definitions, so defined classes keep their slot in Classes-tab order.
function M.new(config, classes)
    local self = {points = {}, markers = {}, classCache = {}, slots = {}, slotCount = 0}

    function self:classStyles()
        if self.classSource ~= config.mapClassColours then
            self.classSource, self.classCache = config.mapClassColours, {}
            local ok, parsed = pcall(JSON.parse, config.mapClassColours)
            local valid = ok and type(parsed) == 'table'
            if valid then
                for label, value in pairs(parsed) do
                    if type(label) ~= 'string' or not M.colour(value) then valid = false; break end
                end
            end
            if not valid then
                self.classError = 'Invalid map class colours; correct or clear them under Map > Class colours.'
                ac.warn('IBOVmap: ' .. self.classError)
                self.classStylesCache = {}
            else
                self.classError, self.classStylesCache = nil, parsed
            end
        end
        return self.classStylesCache
    end

    -- Slots are never reassigned while definitions are unchanged, so joins cannot recolour a class.
    -- Labels outside the definitions (e.g. live timing classes) take the next free slot as first seen.
    function self:classSlot(label)
        local definitions = classes and classes:definitions()
        if definitions and self.slotSource ~= definitions then
            self.slotSource, self.slots, self.slotCount = definitions, {}, 0
            for _, item in ipairs(definitions) do
                local name = (item.name or ''):match('^%s*(.-)%s*$')
                if name ~= '' and not self.slots[name] then
                    self.slotCount = self.slotCount + 1
                    self.slots[name] = self.slotCount
                end
            end
        end
        if not self.slots[label] then
            self.slotCount = self.slotCount + 1
            self.slots[label] = self.slotCount
        end
        return self.slots[label]
    end

    function self:classHex(label)
        local styles = self:classStyles()
        if styles[label] then return styles[label] end
        return M.palette[(self:classSlot(label) - 1) % #M.palette + 1]
    end

    function self:classColour(label, fallback)
        if label == '' then return fallback end
        local hex = self:classHex(label)
        if not self.classCache[hex] then self.classCache[hex] = M.colour(hex) end
        return self.classCache[hex]
    end

    -- Dragged positions for the current track (see mapPlaces); parsed once per change of the setting.
    function self:places()
        if self.placesSource ~= config.mapPlaces then
            local ok, parsed = pcall(JSON.parse, config.mapPlaces)
            self.placesSource, self.placesCache = config.mapPlaces, ok and type(parsed) == 'table' and parsed or {}
        end
        local here = self.placesCache[self.trackID or '']
        return type(here) == 'table' and here or {}
    end

    -- Stores an element's centre ('legend' or 'corner') as a fraction of the window.
    function self:savePlace(kind, _, fx, fy)
        local all = self.placesCache or {}
        local key = self.trackID or ''
        local here = type(all[key]) == 'table' and all[key] or {}
        all[key] = here
        here[kind] = {x = clamp(fx, 0, 1), y = clamp(fy, 0, 1)}
        config.mapPlaces = JSON.stringify(all)
    end

    -- Forgets this track's dragged position for the legend or the corner name.
    function self:clearPlaces(kind)
        local here = self:places()
        here[kind] = nil
        local all = self.placesCache
        all[self.trackID or ''] = next(here) and here or nil
        config.mapPlaces = JSON.stringify(all)
    end

    -- Sector boundaries as lap fractions: from the track's timing gates (AC_TIME_n_L/R dummies, n from 1), else
    -- those learnt from cars crossing each split (see learnSplit).
    function self:sectorSplits()
        if self.splitsTrack == self.trackID then return self.splits end
        self.splitsTrack, self.splits, self.splitPoints = self.trackID, {}, {}
        for i = 1, 20 do
            local left, right = ac.findNodes('AC_TIME_' .. i .. '_L'), ac.findNodes('AC_TIME_' .. i .. '_R')
            if left:size() == 0 then break end
            local a = left:getWorldTransformationRaw().row4
            local b = right:size() > 0 and right:getWorldTransformationRaw().row4 or a
            local p = ac.worldCoordinateToTrackProgress(vec3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2))
            if finite(p) and p > 0 and p < 1 then self.splits[#self.splits + 1] = p end
        end
        self.splitsFromGates = #self.splits > 0
        if not self.splitsFromGates then
            local learnt = self:places().sectors
            for _, p in pairs(type(learnt) == 'table' and learnt or {}) do
                if finite(p) and p > 0 and p < 1 then self.splits[#self.splits + 1] = p end
            end
        end
        table.sort(self.splits)
        return self.splits
    end

    -- Records where a car crossed into `sector` (1-based split), once per track, for tracks without timing gates.
    function self:learnSplit(sector, progress)
        self:places()
        local all, key = self.placesCache, self.trackID or ''
        local here = type(all[key]) == 'table' and all[key] or {}
        all[key] = here
        here.sectors = type(here.sectors) == 'table' and here.sectors or {}
        if here.sectors[tostring(sector)] then return end
        here.sectors[tostring(sector)] = progress
        config.mapPlaces = JSON.stringify(all)
        self.splitsTrack = nil
    end

    -- World directions of compass north and east as unit {x, z} vectors, from CSP's compass for this track. Without
    -- it, north is taken as -z (up on an unrotated map) and east as +x.
    function self:compass()
        if self.compassTrack == self.trackID and self.north then return self.north, self.east end
        self.compassTrack, self.north, self.east = self.trackID, {x = 0, z = -1}, {x = 1, z = 0}
        if ac.getCompassAngle and vec3 then
            local ok1, ax = pcall(ac.getCompassAngle, vec3(1, 0, 0))
            local ok2, az = pcall(ac.getCompassAngle, vec3(0, 0, 1))
            if ok1 and ok2 and finite(ax) and finite(az) then
                ax, az = math.rad(ax), math.rad(az)
                -- A unit direction is cos(a) north + sin(a) east, so +x and +z give north's and east's components.
                local nx, nz, ex, ez = math.cos(ax), math.cos(az), math.sin(ax), math.sin(az)
                local nl, el = math.sqrt(nx * nx + nz * nz), math.sqrt(ex * ex + ez * ez)
                if nl > 0.5 and el > 0.5 then
                    self.north, self.east = {x = nx / nl, z = nz / nl}, {x = ex / el, z = ez / el}
                end
            end
        end
        return self.north, self.east
    end

    -- Content extent for a view turned by `angle`, cached until the angle or the geometry changes. `spin` fits a
    -- circle round the content instead, so a map that turns continuously keeps one scale at every angle.
    function self:turn(bounds, angle, spin)
        local cache = self.turnCache or {}
        self.turnCache = cache
        if cache.bounds == bounds and cache.angle == angle and cache.spin == spin then return cache.out end
        local points = bounds == self.native and {{x = bounds.minX, z = bounds.minZ}, {x = bounds.maxX, z = bounds.minZ},
            {x = bounds.maxX, z = bounds.maxZ}, {x = bounds.minX, z = bounds.maxZ}} or self.points
        local out = cache.out or {}
        if spin then
            if cache.radiusOf ~= bounds then
                local mx, mz, radius = (bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2, 0
                for i = 1, #points do
                    local dx, dz = points[i].x - mx, points[i].z - mz
                    radius = math.max(radius, dx * dx + dz * dz)
                end
                cache.radiusOf, cache.radius, cache.mx, cache.mz = bounds, math.sqrt(radius), mx, mz
            end
            local c, s, r = math.cos(angle), math.sin(angle), cache.radius
            local u, v = cache.mx * c - cache.mz * s, cache.mx * s + cache.mz * c
            out.minX, out.maxX, out.minZ, out.maxZ, out.cos, out.sin = u - r, u + r, v - r, v + r, c, s
        else
            M.turned(points, angle, out)
        end
        cache.bounds, cache.angle, cache.spin, cache.out = bounds, angle, spin, out
        return out
    end

    function self:loadTrack()
        self.started, self.points, self.bounds, self.native, self.error, self.nativeError = true, {}, nil, nil, nil, nil
        self.trackID = ac.getTrackFullID('\\')
        local folder = ac.getFolder(ac.FolderID.Root) .. '\\content\\tracks\\' .. self.trackID
        local image, iniPath = folder .. '\\map.png', ac.getTrackDataFilename('map.ini')
        if io.fileExists(image) and io.fileExists(iniPath) then
            local ini = ac.INIConfig.load(iniPath)
            local scale = ini:get('PARAMETERS', 'SCALE_FACTOR', 0)
            local x, z = ini:get('PARAMETERS', 'X_OFFSET', math.huge), ini:get('PARAMETERS', 'Z_OFFSET', math.huge)
            local w, h = ini:get('PARAMETERS', 'WIDTH', 0), ini:get('PARAMETERS', 'HEIGHT', 0)
            if finite(scale) and scale > 0 and finite(x) and finite(z)
                and finite(w) and w > 0 and finite(h) and h > 0 then
                self.native = {image = image, minX = -x, minZ = -z,
                    maxX = w * scale - x, maxZ = h * scale - z}
            else
                self.nativeError = 'Track map calibration is invalid; using the generated spline.'
                ac.warn('IBOVmap: ' .. self.nativeError)
            end
        else
            self.nativeError = 'No calibrated track map file; using the generated spline.'
        end
        if ac.hasTrackSpline() then
            self.sampleCount = clamp(math.ceil(ac.getSim().trackLengthM / 5), 256, 4096)
            self.nextSample = 0
            self.buildBounds = {minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge}
        else
            self.nextSample = nil
            self.error = 'No AI spline available. Use a calibrated track map, Linear or Circular.'
            ac.warn('IBOVmap: ' .. self.error)
        end
    end

    function self:update()
        if not self.started then return end
        if self.trackID ~= ac.getTrackFullID('\\') then self:loadTrack() end
        if not self.nextSample then return end
        local deadline, count = os.preciseClock() + 0.0005, 0
        repeat
            local p = ac.trackProgressToWorldCoordinate(self.nextSample / self.sampleCount)
            if not validPoint(p) then
                self.error, self.nextSample = 'The track AI spline returned invalid coordinates.', nil
                ac.warn('IBOVmap: ' .. self.error)
                return
            end
            self.points[#self.points + 1] = {x = p.x, z = p.z}
            extend(self.buildBounds, p.x, p.z)
            self.nextSample, count = self.nextSample + 1, count + 1
            if self.nextSample > self.sampleCount then
                self.bounds, self.nextSample = self.buildBounds, nil
                return
            end
        until count >= 32 or os.preciseClock() >= deadline
    end

    -- Same matching as Model.skipped (exclude.lua), parsed once per change instead of per car per frame.
    function self:skipSet()
        if self.skipSource ~= config.skipDrivers then
            self.skipSource, self.skips = config.skipDrivers, require('exclude').parse(config.skipDrivers)
        end
        return self.skips
    end

    function self:collect(model)
        local count, classes, skips = 0, self.classCounts or {}, self:skipSet()
        self.classCounts = classes
        for label in pairs(classes) do classes[label] = nil end
        for _, row in ipairs(model.rows) do
            local car = ac.getCar(row.index)
            if row.held then
                -- Left mid-race but kept in the standings: still counts towards class positions.
                if not skips[row.meta.name] then
                    local label = model.classes:classify(row.meta)
                    classes[label] = (classes[label] or 0) + 1
                end
            elseif row.connected and car and car.isActive and car.isConnected
                and not skips[row.meta.name]
                and validPoint(car.position) and finite(car.splinePosition) then
                count = count + 1
                local marker = self.markers[count] or {}
                self.markers[count] = marker
                local label = model.classes:classify(row.meta)
                classes[label] = (classes[label] or 0) + 1
                marker.row, marker.car, marker.class, marker.classPosition = row, car, label, classes[label]
            end
        end
        for i = #self.markers, count + 1, -1 do self.markers[i] = nil end
        return self.markers
    end

    -- Projects the spline into screen space only when the view moves, reusing vec2s throughout.
    -- Points closer than 2 px to the previous kept point are dropped; zoomed views keep only runs
    -- of points near the window, so the stroked path scales with what is visible, not track length.
    -- Chunks of points carry world bounds (including their neighbours), so off-screen stretches of
    -- a zoomed view are skipped without projecting them.
    function self:screenPath(view, left, top, x0, y0, w, h, margin, closed)
        local points, cache = self.points, self.path
        if not cache then
            cache = {vecs = {}, runs = {}, xs = {}, ys = {}, inside = {}, keep = {}}
            self.path = cache
        end
        local n = #points
        local vc, vs = view.cos or 1, view.sin or 0
        if cache.x == view.x and cache.z == view.z and cache.scale == view.scale and cache.left == left
            and cache.top == top and cache.w == w and cache.h == h and cache.margin == margin
            and cache.count == n and cache.closed == closed and cache.cos == vc and cache.sin == vs then return cache end
        cache.x, cache.z, cache.scale, cache.left, cache.top = view.x, view.z, view.scale, left, top
        cache.w, cache.h, cache.margin, cache.count, cache.closed, cache.cos, cache.sin = w, h, margin, n, closed, vc, vs
        if cache.chunked ~= n then
            local chunks = {}
            for first = 1, n, 32 do
                local last = math.min(n, first + 31)
                local chunk = {first = first, last = last,
                    minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge}
                for i = math.max(1, first - 1), math.min(n, last + 1) do extend(chunk, points[i].x, points[i].z) end
                if first == 1 then extend(chunk, points[n].x, points[n].z) end
                if last == n then extend(chunk, points[1].x, points[1].z) end
                chunks[#chunks + 1] = chunk
            end
            cache.chunks, cache.chunked = chunks, n
        end
        local xs, ys, inside, keep = cache.xs, cache.ys, cache.inside, cache.keep
        local vx, vz, scale = view.x, view.z, view.scale
        local ox, oy = left + view.width / 2, top + view.height / 2
        local minX, minY, maxX, maxY = x0 - margin, y0 - margin, x0 + w + margin, y0 + h + margin
        -- World box round the (possibly turned) window, for skipping whole chunks.
        local worldMinX, worldMaxX, worldMinZ, worldMaxZ = math.huge, -math.huge, math.huge, -math.huge
        for corner = 0, 3 do
            local du = ((corner % 2 == 0) and minX or maxX) - ox
            local dv = ((corner < 2) and minY or maxY) - oy
            local wx, wz = vx + (du * vc + dv * vs) / scale, vz + (dv * vc - du * vs) / scale
            worldMinX, worldMaxX = math.min(worldMinX, wx), math.max(worldMaxX, wx)
            worldMinZ, worldMaxZ = math.min(worldMinZ, wz), math.max(worldMaxZ, wz)
        end
        local all = true
        for _, chunk in ipairs(cache.chunks) do
            if chunk.maxX < worldMinX or chunk.minX > worldMaxX or chunk.maxZ < worldMinZ or chunk.minZ > worldMaxZ then
                for i = chunk.first, chunk.last do inside[i] = false end
                all = false
            else
                for i = chunk.first, chunk.last do
                    local p = points[i]
                    local dx, dz = p.x - vx, p.z - vz
                    local x, y = ox + (dx * vc - dz * vs) * scale, oy + (dx * vs + dz * vc) * scale
                    xs[i], ys[i] = x, y
                    local visible = x >= minX and x <= maxX and y >= minY and y <= maxY
                    inside[i] = visible
                    if not visible then all = false end
                end
            end
        end
        -- Fully visible closed tracks stroke as one closed loop; otherwise open runs, wrapping once.
        local total = (closed and not all) and n + 1 or n
        cache.loop = closed and all
        for i = 1, total do
            local j = (i - 1) % n + 1
            local kept = all or inside[j]
            if not kept and i > 1 then kept = inside[(i - 2) % n + 1] end
            if not kept and i < total then kept = inside[i % n + 1] end
            keep[i] = kept
        end
        keep[total + 1] = false
        local vecs, runs, count, runCount = cache.vecs, cache.runs, 0, 0
        local lastX, lastY, inRun = 0, 0, false
        for i = 1, total do
            if keep[i] then
                local j = (i - 1) % n + 1
                local x, y = xs[j], ys[j]
                local final = not keep[i + 1]
                local dx, dy = x - lastX, y - lastY
                if not inRun or final or dx * dx + dy * dy >= 4 then
                    if not inRun then
                        runCount = runCount + 1
                        local run = runs[runCount] or {}
                        runs[runCount], run.first, inRun = run, count + 1, true
                    end
                    count = count + 1
                    local v = vecs[count]
                    if not v then v = vec2(x, y); vecs[count] = v else v.x, v.y = x, y end
                    lastX, lastY = x, y
                    runs[runCount].last = count
                end
                if final then inRun = false end
            else
                inRun = false
            end
        end
        for i = #runs, runCount + 1, -1 do runs[i] = nil end
        cache.runCount = runCount
        return cache
    end

    return self
end

-- Scratch vectors reused by every draw call (CSP copies them into the draw list), so a frame of
-- markers allocates nothing. Created on first draw so tests can stub vec2 before requiring.
local S
local function scratch()
    S = {a = vec2(0, 0), b = vec2(0, 0), c = vec2(0, 0), d = vec2(0, 0)}
    return S
end
local function at(v, x, y) v.x, v.y = x, y; return v end

-- Teardrop rim as unit offsets in the car's frame: a half circle behind the tip (radius 0.75).
local rim = 10
local rimForward, rimSide = {}, {}
for i = 0, rim do
    local a = math.pi / 2 + i * math.pi / rim
    rimForward[i], rimSide[i] = math.cos(a) * 0.75, math.sin(a) * 0.75
end

local function polygon(kind, x, y, r, dx, dy, c)
    local s = S
    if kind == 2 then
        local bx, by, side = x - dx * r * 0.6, y - dy * r * 0.6, r * 0.8
        ui.drawTriangleFilled(at(s.a, x + dx * r, y + dy * r), at(s.b, bx - dy * side, by + dx * side),
            at(s.c, bx + dy * side, by - dx * side), c)
        return
    end
    ui.pathClear()
    ui.pathLineTo(at(s.a, x + dx * r, y + dy * r))
    local v = s.b
    for i = 0, rim do
        local f, sd = rimForward[i], rimSide[i]
        ui.pathLineTo(at(v, x + r * (dx * f - dy * sd), y + r * (dy * f + dx * sd)))
    end
    ui.pathFillConvex(c)
end

local function shape(kind, x, y, radius, dx, dy, tint, border, thickness)
    if kind == 3 then
        local p = at(S.a, x, y)
        if border and thickness > 0 then ui.drawCircleFilled(p, radius + thickness, border, 24) end
        ui.drawCircleFilled(p, radius, tint, 24)
        return
    end
    if border and thickness > 0 then polygon(kind, x, y, radius + thickness, dx, dy, border) end
    polygon(kind, x, y, radius, dx, dy, tint)
end

local relationLabels = {'Ahead', 'Behind', 'Lap ahead', 'Lap behind'}
local relationKeys = {'mapAheadColour', 'mapBehindColour', 'mapLapAheadColour', 'mapLapBehindColour'}

-- Northpoint arms as multiples of (north, east): the arm's direction, the side its dark half is on (anticlockwise
-- of the arm, as on a printed compass rose), and its letter.
local roseArms = {{1, 0, 0, -1, 'N'}, {0, 1, 1, 0, 'E'}, {-1, 0, 0, 1, 'S'}, {0, -1, -1, 0, 'W'}}

-- A four-pointed compass rose centred on (cx, cy) filling a `size` box, letters included. (nx, ny) and (ex, ey) are
-- unit north and east on screen, so it turns (and mirrors, if the map does) with the map; letters stay upright.
local function northpoint(cx, cy, size, nx, ny, ex, ey, dark, light, letters, shadow)
    local s = S
    local letter = math.max(9, size * 0.15)
    local arm = math.max(4, size / 2 - letter * 1.15)
    local k = arm * 0.14
    for pass = shadow and 1 or 2, 2 do
        local o = pass == 1 and math.max(1, size * 0.025) or 0
        local px, py = cx + o, cy + o * 1.5
        for _, a in ipairs(roseArms) do
            local dx, dy = nx * a[1] + ex * a[2], ny * a[1] + ey * a[2]
            local sx, sy = nx * a[3] + ex * a[4], ny * a[3] + ey * a[4]
            local tip = at(s.b, px + dx * arm, py + dy * arm)
            ui.drawTriangleFilled(at(s.a, px, py), tip, at(s.c, px + (dx + sx) * k, py + (dy + sy) * k),
                pass == 1 and shadow or dark)
            ui.drawTriangleFilled(at(s.a, px, py), tip, at(s.c, px + (dx - sx) * k, py + (dy - sy) * k),
                pass == 1 and shadow or light)
        end
    end
    ui.pathClear()
    for _, a in ipairs(roseArms) do
        local dx, dy = nx * a[1] + ex * a[2], ny * a[1] + ey * a[2]
        local sx, sy = nx * a[3] + ex * a[4], ny * a[3] + ey * a[4]
        ui.pathLineTo(at(s.a, cx + dx * arm, cy + dy * arm))
        ui.pathLineTo(at(s.a, cx + (dx - sx) * k, cy + (dy - sy) * k))
    end
    ui.pathStroke(dark, true, math.max(1, size / 90))
    local reach = arm + letter * 0.62
    for _, a in ipairs(roseArms) do
        local lx, ly = cx + (nx * a[1] + ex * a[2]) * reach, cy + (ny * a[1] + ey * a[2]) * reach
        for pass = shadow and 1 or 2, 2 do
            local o = pass == 1 and math.max(1, letter * 0.08) or 0
            ui.dwriteDrawTextClipped(a[5], letter, at(s.a, lx - letter + o, ly - letter * 0.7 + o),
                at(s.b, lx + letter + o, ly + letter * 0.7 + o), ui.Alignment.Center, ui.Alignment.Center, false,
                pass == 1 and shadow or letters)
        end
    end
end

local opaque, faded, partial
-- Draws the painted map (canvas cw × ch, at x0, y0) with its outer `f` pixels fading to transparent. Gradient shading
-- runs along one axis only, so each corner is drawn as strips faded across at the strength of their distance in.
local function fadeEdges(canvas, x0, y0, cw, ch, f)
    local s = S
    if not opaque then opaque, faded, partial = rgbm(1, 1, 1, 1), rgbm(1, 1, 1, 0), rgbm(1, 1, 1, 1) end
    local x3, y3 = x0 + cw, y0 + ch
    local x1, x2, y1, y2 = x0 + f, x3 - f, y0 + f, y3 - f
    local function piece(ax, ay, bx, by, gx1, gy1, gx2, gy2, from, to)
        local p1, p2 = at(s.a, ax, ay), at(s.b, bx, by)
        local uv1, uv2 = at(s.c, (ax - x0) / cw, (ay - y0) / ch), at(s.d, (bx - x0) / cw, (by - y0) / ch)
        if not from then ui.drawImage(canvas, p1, p2, opaque, uv1, uv2); return end
        ui.beginGradientShade()
        ui.drawImage(canvas, p1, p2, opaque, uv1, uv2)
        ui.endGradientShade(at(s.a, gx1, gy1), at(s.b, gx2, gy2), from, to, true)
    end
    piece(x1, y1, x2, y2)
    piece(x0, y1, x1, y2, x0, y1, x1, y1, faded, opaque)
    piece(x2, y1, x3, y2, x2, y1, x3, y1, opaque, faded)
    piece(x1, y0, x2, y1, x1, y0, x1, y1, faded, opaque)
    piece(x1, y2, x2, y3, x1, y2, x1, y3, opaque, faded)
    local n = math.max(1, math.ceil(f / 3))
    for k = 0, n - 1 do
        partial.mult = (k + 0.5) / n
        local top, bottom = y0 + f * k / n, y0 + f * (k + 1) / n
        local lower, upper = y3 - f * (k + 1) / n, y3 - f * k / n
        piece(x0, top, x1, bottom, x0, top, x1, top, faded, partial)
        piece(x2, top, x3, bottom, x2, top, x3, top, partial, faded)
        piece(x0, lower, x1, upper, x0, lower, x1, lower, faded, partial)
        piece(x2, lower, x3, upper, x2, lower, x3, lower, partial, faded)
    end
end

-- A box's offset along a window side `room` longer than it, kept clear of an `inset` fade where it fits.
local function within(value, inset, room)
    if room <= 0 then return 0 end
    local e = math.min(inset, room / 2)
    return clamp(value, e, room - e)
end

local SPIN_TIME = 0.5

-- The Track presentation's rotation in radians clockwise: the dial's angle, or the focused car's heading (held while
-- there is no focus). Changing focused car or mode eases round the shorter way instead of snapping.
local function mapAngle(self, config, focus, focusedCar)
    local spin = config.mapRotateFocus and true or false
    local target
    if spin then
        target = focus and focus.look and M.heading(focus.look.x, focus.look.z) or self.rotation or 0
    else
        target = math.rad((tonumber(config.mapRotation) or 0) % 360)
    end
    local key, now = spin and focusedCar or false, os.preciseClock()
    if self.spinKey ~= key then
        if self.spinKey ~= nil and self.rotation then self.spinFrom, self.spinStart = self.rotation, now end
        self.spinKey = key
    end
    local angle = target
    if self.spinStart then
        local t = (now - self.spinStart) / SPIN_TIME
        if t >= 1 or t < 0 then
            self.spinStart = nil
        else
            local delta = (target - self.spinFrom + math.pi) % (math.pi * 2) - math.pi
            angle = self.spinFrom + delta * t * t * (3 - 2 * t)
        end
    end
    angle = angle % (math.pi * 2)
    self.rotation, self.rotationDegrees = angle, math.floor(math.deg(angle) + 0.5) % 360
    return angle, spin
end

-- Paints the map with its top-left corner at (x0, y0): straight into the window, or into the edge-fade canvas. Where
-- the interactive things landed (relative to that corner) is recorded in `hits` for M.draw's mouse handling, since
-- widgets cannot work inside a canvas.
local function paint(self, model, config, x0, y0, w, h, inset, colour, texture, hits)
    local s = S
    hits.markerCount, hits.legend.shown, hits.corner.shown, hits.north.shown = 0, false, false, false
    ui.drawRectFilled(at(s.c, x0, y0), at(s.d, x0 + w, y0 + h), colour('mapBackgroundColour'))
    ui.pushClipRect(at(s.c, x0, y0), at(s.d, x0 + w, y0 + h), true)
    local sim = ac.getSim()
    local focus = ac.getCar(sim.focusedCar)
    if not (focus and focus.isActive and focus.isConnected and validPoint(focus.position)
        and finite(focus.splinePosition)) then focus = nil end
    local format = config.mapFormat
    local pad = config.mapMarkerSize * math.max(1, config.mapFocusScale) + config.mapBorderWidth + 4
    if config.mapTag ~= 1 then
        -- Room for name tags wherever they sit, so a car at the edge of the map keeps its tag in the window.
        local tagW, tagH = config.mapFontSize * 2.4 + 3, config.mapFontSize + 4
        pad = math.max(pad, math.max(math.abs(config.mapTagX), math.abs(config.mapTagX + tagW)),
            math.max(math.abs(config.mapTagY), math.abs(config.mapTagY + tagH)))
    end
    -- Also clear of the edge fade, so the whole-track view stays fully readable.
    pad = math.min(math.min(w, h) / 3, pad + inset)
    local width, height = math.max(1, w - pad * 2), math.max(1, h - pad * 2)
    local left, top = x0 + pad, y0 + pad
    local native = config.mapSource ~= 2 and self.native
    local bounds = native or self.bounds
    local angle, spin = 0, false
    if format == 1 then angle, spin = mapAngle(self, config, focus, sim.focusedCar) end
    local turn = bounds and (spin or angle ~= 0) and self:turn(bounds, angle, spin) or nil
    self.viewState = self.viewState or {}
    local view = bounds and M.view(bounds, width, height, config.mapZoom, focus and focus.position, self.viewState, turn)
    local scale, ox, oy = view and view.scale, view and left + width / 2, view and top + height / 2
    local vc, vs = view and view.cos or 1, view and view.sin or 0
    local function toScreen(x, z)
        local dx, dz = x - view.x, z - view.z
        return ox + (dx * vc - dz * vs) * scale, oy + (dx * vs + dz * vc) * scale
    end
    local function turned(dx, dz) return dx * vc - dz * vs, dx * vs + dz * vc end
    local cx, cy, ring = x0 + w / 2, y0 + h / 2, math.min(width, height) / 2
    local focusProgress, zoom, length, open = focus and focus.splinePosition, config.mapZoom, sim.trackLengthM, sim.isTrackOpen
    local function atProgress(progress)
        local t = M.progress(progress, focusProgress, zoom, length, open)
        if not t then return end
        if format == 2 then return left + t * width, top + height / 2, 1, 0 end
        local a = t * math.pi * 2 - math.pi / 2
        local ca, sa = math.cos(a), math.sin(a)
        return cx + ca * ring, cy + sa * ring, -sa, ca
    end
    local lineColour = colour('mapTrackColour')
    -- Generated lines are stroked twice: a wider border pass, then the track colour on top.
    local border, lineWidth = config.mapTrackBorderWidth, config.mapLineWidth
    local borderColour = border > 0 and colour('mapTrackBorderColour')
    if format == 1 then
        if native then
            if vs == 0 and vc == 1 then
                ui.drawImage(native.image, at(s.a, toScreen(native.minX, native.minZ)),
                    at(s.b, toScreen(native.maxX, native.maxZ)), lineColour)
            else
                ui.drawImageQuad(native.image, at(s.a, toScreen(native.minX, native.minZ)),
                    at(s.b, toScreen(native.maxX, native.minZ)), at(s.c, toScreen(native.maxX, native.maxZ)),
                    at(s.d, toScreen(native.minX, native.maxZ)), lineColour)
            end
        elseif view then
            local path = self:screenPath(view, left, top, x0, y0, w, h, lineWidth / 2 + border + 2, not open)
            local vecs, runs = path.vecs, path.runs
            for pass = borderColour and 1 or 2, 2 do
                local tint, thickness = pass == 1 and borderColour or lineColour,
                    pass == 1 and lineWidth + border * 2 or lineWidth
                for r = 1, path.runCount do
                    local run = runs[r]
                    ui.pathClear()
                    for i = run.first, run.last do ui.pathLineTo(vecs[i]) end
                    ui.pathStroke(tint, path.loop, thickness)
                end
            end
        else
            ui.setCursor(at(s.a, left, top))
            ui.textWrapped(self.error or 'Preparing track spline...')
        end
    elseif format == 2 then
        for pass = borderColour and 1 or 2, 2 do
            local extra = pass == 1 and border or 0
            ui.drawLine(at(s.a, left - extra, top + height / 2), at(s.b, left + width + extra, top + height / 2),
                pass == 1 and borderColour or lineColour, lineWidth + extra * 2)
        end
    else
        for pass = borderColour and 1 or 2, 2 do
            ui.drawCircle(at(s.a, cx, cy), ring, pass == 1 and borderColour or lineColour, 96,
                pass == 1 and lineWidth + border * 2 or lineWidth)
        end
    end
    local sx, sy, sdx, sdy
    local points = self.points
    if format ~= 1 then
        sx, sy, sdx, sdy = atProgress(0)
    elseif view and points[1] and points[2] then
        sx, sy = toScreen(points[1].x, points[1].z)
        sdx, sdy = turned(points[2].x - points[1].x, points[2].z - points[1].z)
    end
    if sx then
        local d = 7 / math.max(0.001, math.sqrt(sdx * sdx + sdy * sdy))
        ui.drawLine(at(s.a, sx - sdy * d, sy + sdx * d), at(s.b, sx + sdy * d, sy - sdx * d), colour('mapStartColour'), 3)
    end
    if config.mapSectors then
        local sectorColour = colour('mapSectorColour')
        for _, p in ipairs(self:sectorSplits()) do
            local px, py, pdx, pdy
            if format ~= 1 then
                px, py, pdx, pdy = atProgress(p)
            elseif view then
                local cached = self.splitPoints[p]
                if cached == nil then
                    local ok, a = pcall(ac.trackProgressToWorldCoordinate, p)
                    local ok2, b = pcall(ac.trackProgressToWorldCoordinate, (p + 0.002) % 1)
                    cached = ok and ok2 and validPoint(a) and validPoint(b)
                        and {x = a.x, z = a.z, dx = b.x - a.x, dz = b.z - a.z} or false
                    self.splitPoints[p] = cached
                end
                if cached then
                    px, py = toScreen(cached.x, cached.z)
                    pdx, pdy = turned(cached.dx, cached.dz)
                end
            end
            if px then
                local d = 9 / math.max(0.001, math.sqrt(pdx * pdx + pdy * pdy))
                ui.drawLine(at(s.a, px - pdy * d, py + pdx * d), at(s.b, px + pdy * d, py - pdx * d), sectorColour, 3)
            end
        end
    end
    local markers, focusMarker = self:collect(model), nil
    local markerTexture = texture('mapMarkerTexture')
    -- Per-frame constants, resolved once rather than per marker.
    local markerColour, focusColour = colour('mapMarkerColour'), colour('mapFocusColour')
    local markerBorder, textColour = colour('mapBorderColour'), colour('mapTextColour')
    local shadowColour = config.mapShadow and colour('mapShadowColour')
    local kind, colourMode, labelMode = config.mapShape, config.mapColourMode, config.mapLabel
    local baseRadius, focusScale, thickness = config.mapMarkerSize, config.mapFocusScale, config.mapBorderWidth
    local fontSize, race, focusedIndex = config.mapFontSize, model.race, sim.focusedCar
    local focusRow = model.byIndex and model.byIndex[focusedIndex]
    local leaderColour = config.mapLeader and colour('mapLeaderColour')
    local tagMode = config.mapTag ~= 1 and config.mapTag
    local tagColour = tagMode and colour('mapTagColour')
    local tagBack = tagMode and colour('mapTagBackColour')
    if tagBack and tagBack.mult <= 0 then tagBack = nil end
    ui.pushDWriteFont(config.mapFont)
    -- Real widths in the font in use (wide faces overrun any per-character guess), kept until the default font changes.
    if self.widthFont ~= config.mapFont then self.widthFont, self.widths = config.mapFont, {} end
    local widths = self.widths
    -- Pushes an element's font override; returns true when the caller must pop it.
    local function pushFace(face)
        if face and face ~= '' then ui.pushDWriteFont(face); return true end
        return false
    end
    local function textWidth(value, size, face)
        local key = (face or '') .. '|' .. size .. '|' .. value
        local width = widths[key]
        if not width then width = ui.measureDWriteText(value, size).x; widths[key] = width end
        return width
    end
    local function drawMarker(marker)
        local car, row = marker.car, marker.row
        local x, y, dx, dy
        if format == 1 then
            if not view then return end
            local p = car.position
            x, y = toScreen(p.x, p.z)
            dx, dy = turned(car.look.x, car.look.z)
            local length = math.sqrt(dx * dx + dy * dy)
            if length < 0.001 then dx, dy = 0, -1 else dx, dy = dx / length, dy / length end
        else
            x, y, dx, dy = atProgress(car.splinePosition)
            if not x then return end
        end
        local focused = row.index == focusedIndex
        local radius = baseRadius * (focused and focusScale or 1)
        if x + radius < x0 or y + radius < y0 or x - radius > x0 + w or y - radius > y0 + h then return end
        local tint = markerColour
        if focused then tint = focusColour
        elseif leaderColour and row.position == 1 then tint = leaderColour
        elseif colourMode == 2 then tint = self:classColour(marker.class, tint)
        elseif colourMode == 3 then
            tint = colour(M.relation(car, focus, race, open, row.laps, focusRow and focusRow.laps))
        end
        if shadowColour then shape(kind, x + 2, y + 3, radius + thickness, dx, dy, shadowColour) end
        shape(kind, x, y, radius, dx, dy, tint, markerBorder, thickness)
        local p1, p2 = at(s.c, x - radius, y - radius), at(s.d, x + radius, y + radius)
        if markerTexture then ui.drawImage(markerTexture, p1, p2) end
        local label = M.label(labelMode, marker)
        if label then
            local pushed = pushFace(config.mapLabelFont)
            ui.dwriteDrawTextClipped(label, fontSize, p1, p2, ui.Alignment.Center, ui.Alignment.Center, false, textColour)
            if pushed then ui.popDWriteFont() end
        end
        hits.markerCount = hits.markerCount + 1
        local hit = hits.markers[hits.markerCount] or {}
        hits.markers[hits.markerCount] = hit
        hit.marker, hit.x, hit.y, hit.r, hit.tw = marker, x - x0, y - y0, radius, nil
        -- A name tag beside the indicator, as on ACSM's live timing map, at one offset for every car (mapTagX/Y:
        -- the tag's top-left from the indicator's centre). Ctrl+drag any tag to move them all.
        local tag = tagMode and M.label(tagMode, marker)
        if tag then
            local pushed = pushFace(config.mapTagFont)
            local tw = ui.measureDWriteText(tag, fontSize).x
            local tx, ty = x + config.mapTagX, y + config.mapTagY
            hit.tx, hit.ty, hit.tw = tx - x0, ty - y0, tw
            if tagBack then
                ui.drawRectFilled(at(s.a, tx - 3, ty), at(s.b, tx + tw + 3, ty + fontSize + 4), tagBack, 2)
            end
            for pass = shadowColour and 1 or 2, 2 do
                local o = pass == 1 and math.max(1, fontSize * 0.08) or 0
                ui.dwriteDrawTextClipped(tag, fontSize, at(s.a, tx + o, ty + o), at(s.b, tx + fontSize * 4 + o,
                    ty + fontSize + 4 + o), ui.Alignment.Start, ui.Alignment.Center, false,
                    pass == 1 and shadowColour or tagColour)
            end
            if pushed then ui.popDWriteFont() end
        end
    end
    for _, marker in ipairs(markers) do
        if marker.row.index == focusedIndex then focusMarker = marker else drawMarker(marker) end
    end
    if focusMarker then drawMarker(focusMarker) end
    -- Tracks without timing gates: learn each split where a car first crosses into the next sector.
    if config.mapSectors and not self.splitsFromGates then
        self.lastSector = self.lastSector or {}
        for _, marker in ipairs(markers) do
            local car = marker.car
            local sector, was = car.currentSector, self.lastSector[car.index]
            if was and sector == was + 1 and sector >= 1 and finite(car.splinePosition) then
                self:learnSplit(sector, car.splinePosition)
            end
            self.lastSector[car.index] = sector
        end
    end
    local places = self:places()
    -- Top-left corner of a draggable element (legend, corner name or northpoint): where it is being dragged, else its
    -- stored centre (a fraction of the window) or the default, kept inside the map and clear of the edge fade.
    local function place(kindName, bw, bh, fx, fy)
        local d, bx, by = self.drag
        if d and d.kind == kindName then
            bx, by = x0 + d.x, y0 + d.y
        else
            local stored = places[kindName]
            if type(stored) == 'table' and finite(stored.x) and finite(stored.y) then
                fx, fy = x0 + stored.x * w - bw / 2, y0 + stored.y * h - bh / 2
            end
            bx, by = x0 + within(fx - x0, inset, w - bw), y0 + within(fy - y0, inset, h - bh)
        end
        local box = hits[kindName]
        box.shown, box.x, box.y, box.w, box.h = true, bx - x0, by - y0, bw, bh
        return bx, by
    end
    if config.mapNorth and format == 1 then
        local size = clamp(config.mapNorthSize, 16, 400)
        local north, east = self:compass()
        local nx, ny = turned(north.x, north.z)
        local ex, ey = turned(east.x, east.z)
        local bx, by = place('north', size, size, x0 + w - size - 4, y0 + 4)
        local mx, my, r = bx + size / 2, by + size / 2, size / 2
        local image = texture('mapNorthTexture')
        if image then
            -- The image's top is north and its right is east.
            ui.drawImageQuad(image, at(s.a, mx + (nx - ex) * r, my + (ny - ey) * r),
                at(s.b, mx + (nx + ex) * r, my + (ny + ey) * r), at(s.c, mx + (ex - nx) * r, my + (ey - ny) * r),
                at(s.d, mx - (nx + ex) * r, my - (ny + ey) * r))
        else
            local pushed = pushFace(config.mapNorthFont)
            northpoint(mx, my, size, nx, ny, ex, ey, colour('mapNorthColour'), colour('mapNorthFillColour'),
                colour('mapNorthTextColour'), shadowColour)
            if pushed then ui.popDWriteFont() end
        end
    end
    -- The corner the focused car is in, as the Kunos Track Description app shows it: one label that fades in on
    -- entry, holds briefly after the exit, and crossfades to the next name. Dragged anywhere; kept per track.
    if config.mapCorners and (self.preview or self.sections and #self.sections > 0) then
        local now = os.preciseClock()
        local dt = math.min(0.25, math.max(0, now - (self.cornerClock or now)))
        self.cornerClock = now
        local current
        if focusProgress then
            for _, section in ipairs(self.sections or {}) do
                if (focusProgress - section.from) % 1 <= (section.to - section.from) % 1 then
                    current = section.label or section.text
                    break
                end
            end
        end
        local c = self.corner or {alpha = 0}
        self.corner = c
        if current and current ~= '' then c.lastSeen = now end
        local wanted = current ~= '' and current or (c.lastSeen and now - c.lastSeen < 1 and c.name) or nil
        local fade = math.max(0.01, config.mapCornerFade)
        if wanted ~= c.name then
            -- Fade the old name out before the new one comes in.
            c.alpha = math.max(0, c.alpha - dt / fade)
            if c.alpha <= 0 then c.name = wanted end
        elseif wanted then
            c.alpha = math.min(1, c.alpha + dt / fade)
        end
        local dragging = self.drag and self.drag.kind == 'corner'
        local label = c.name or ((dragging or self.preview) and 'Corner name') or nil
        local alpha = (dragging or not c.name) and 1 or c.alpha
        if label and alpha > 0.01 then
            local size = config.mapCornerSize
            local pushed = pushFace(config.mapCornerFont)
            local bw, bh = textWidth(label, size, config.mapCornerFont) + size * 0.8 + 4, size * 1.6
            local bx, by = place('corner', bw, bh, x0 + (w - bw) / 2, y0 + h - bh - 4)
            local function faded(key)
                local t = colour(key)
                return alpha < 1 and rgbm(t.r, t.g, t.b, t.mult * alpha) or t
            end
            local back = faded('mapCornerBackColour')
            if back.mult > 0 then ui.drawRectFilled(at(s.a, bx, by), at(s.b, bx + bw, by + bh), back, size * 0.25) end
            local shade = shadowColour and faded('mapShadowColour')
            local d = math.max(1, size * 0.08)
            for pass = shade and 1 or 2, 2 do
                local o = pass == 1 and d or 0
                ui.dwriteDrawTextClipped(label, size, at(s.a, bx + o, by + o), at(s.b, bx + bw + o, by + bh + o),
                    ui.Alignment.Center, ui.Alignment.Center, false, pass == 1 and shade or faded('mapCornerColour'))
            end
            if pushed then ui.popDWriteFont() end
        end
    end
    if config.mapLegend and (colourMode == 2 or colourMode == 3) then
        local labels = relationLabels
        if colourMode == 2 then
            labels, self.legendSeen = self.legendLabels or {}, self.legendSeen or {}
            self.legendLabels = labels
            local seen = self.legendSeen
            for i = #labels, 1, -1 do labels[i] = nil end
            for key in pairs(seen) do seen[key] = nil end
            for _, marker in ipairs(markers) do
                local label = marker.class
                if label ~= '' and not seen[label] then seen[label] = true; labels[#labels + 1] = label end
            end
            table.sort(labels)
        end
        local d = math.max(1, fontSize * 0.08)
        local widest = 0
        local pushed = pushFace(config.mapLegendFont)
        for _, label in ipairs(labels) do widest = math.max(widest, textWidth(label, fontSize, config.mapLegendFont)) end
        local lw, lh = 22 + widest + d + 2, math.max(1, #labels) * (fontSize + 4) + 4
        local lx, ly = place('legend', lw, lh, x0, y0)
        for i, label in ipairs(labels) do
            local tint = colourMode == 2 and self:classColour(label, lineColour) or colour(relationKeys[i])
            local y = ly + 4 + (i - 1) * (fontSize + 4)
            for pass = shadowColour and 1 or 2, 2 do
                local o = pass == 1 and d or 0
                ui.drawCircleFilled(at(s.a, lx + 9 + o, y + fontSize / 2 + o), 4, pass == 1 and shadowColour or tint, 12)
                ui.dwriteDrawTextClipped(label, fontSize, at(s.b, lx + 18 + o, y + o),
                    at(s.c, lx + lw + o, y + fontSize + 4 + o), ui.Alignment.Start, ui.Alignment.Center, false,
                    pass == 1 and shadowColour or lineColour)
            end
        end
        if pushed then ui.popDWriteFont() end
    end
    ui.popDWriteFont()
    ui.popClipRect()
end

local dragKinds = {'legend', 'corner', 'north'}

-- Mouse handling over what `paint` recorded, with the map's top-left corner at (x0, y0) in the window: hover tooltips
-- and clicks on indicators, and Ctrl+drag for name tags, the legend, the corner name and the northpoint. Invisible
-- buttons take those clicks, which stops AC moving the window while something is dragged.
local function interact(self, config, x0, y0, w, h, inset, hits, onFocus)
    local s = S
    local hoverable = ui.windowHovered()
    local list, hovered = hits.markers, nil
    if hoverable then
        -- Later indicators are painted on top (the focused car last), so they win overlapping hit targets.
        for i = 1, hits.markerCount do
            local e = list[i]
            if ui.rectHovered(at(s.a, x0 + e.x - e.r, y0 + e.y - e.r), at(s.b, x0 + e.x + e.r, y0 + e.y + e.r)) then
                hovered = e.marker
            end
        end
    end
    local fontSize = config.mapFontSize
    local tagDrag = self.tagDrag
    if tagDrag then
        local e
        for i = 1, hits.markerCount do
            if list[i].marker.row.index == tagDrag.index then e = list[i] end
        end
        if e and e.tw then
            ui.setCursor(at(s.a, x0 + e.tx - 3, y0 + e.ty))
            ui.invisibleButton('##map-tag-drag', at(s.b, e.tw + 6, fontSize + 4))
        end
        if not ui.mouseDown(ui.MouseButton.Left) then
            self.tagDrag = nil
        elseif e then
            local m = ui.mousePos()
            config.mapTagX = math.floor(m.x - (x0 + e.x) - tagDrag.dx + 0.5)
            config.mapTagY = math.floor(m.y - (y0 + e.y) - tagDrag.dy + 0.5)
        end
    elseif not self.drag and hoverable and ui.hotkeyCtrl() then
        for i = hits.markerCount, 1, -1 do
            local e = list[i]
            local tx, ty = x0 + (e.tx or 0), y0 + (e.ty or 0)
            if e.tw and ui.rectHovered(at(s.a, tx - 3, ty), at(s.b, tx + e.tw + 3, ty + fontSize + 4)) then
                ui.setMouseCursor(ui.MouseCursor.ResizeAll)
                ui.setCursor(at(s.a, tx - 3, ty))
                ui.invisibleButton('##map-tag-drag', at(s.b, e.tw + 6, fontSize + 4))
                if ui.itemActive() then
                    local m = ui.mousePos()
                    self.tagDrag = {index = e.marker.row.index, dx = m.x - tx, dy = m.y - ty}
                end
                break
            end
        end
    end
    local d = self.drag
    if d then
        local box = hits[d.kind]
        local bw, bh = box.shown and box.w or d.w, box.shown and box.h or d.h
        ui.setCursor(at(s.a, x0 + d.x, y0 + d.y))
        ui.invisibleButton('##map-drag-' .. d.kind, at(s.b, bw, bh))
        if ui.mouseDown(ui.MouseButton.Left) then
            local m = ui.mousePos()
            d.x, d.y = within(m.x - d.dx - x0, inset, w - bw), within(m.y - d.dy - y0, inset, h - bh)
        else
            self:savePlace(d.kind, nil, (d.x + bw / 2) / w, (d.y + bh / 2) / h)
            self.drag = nil
        end
    elseif not self.tagDrag and hoverable and not hovered and ui.hotkeyCtrl() then
        -- Ctrl+drag only, so a plain drag still moves the window. Topmost (last painted) first.
        for _, kindName in ipairs(dragKinds) do
            local box = hits[kindName]
            if box.shown and ui.rectHovered(at(s.a, x0 + box.x, y0 + box.y), at(s.b, x0 + box.x + box.w, y0 + box.y + box.h)) then
                ui.setMouseCursor(ui.MouseCursor.ResizeAll)
                ui.setCursor(at(s.a, x0 + box.x, y0 + box.y))
                ui.invisibleButton('##map-drag-' .. kindName, at(s.b, box.w, box.h))
                if ui.itemActive() then
                    local m = ui.mousePos()
                    self.drag = {kind = kindName, dx = m.x - (x0 + box.x), dy = m.y - (y0 + box.y),
                        x = box.x, y = box.y, w = box.w, h = box.h}
                end
                break
            end
        end
    end
    if hovered then
        ui.setTooltip(tostring(hovered.row.position) .. ' - ' .. hovered.row.meta.name
            .. (hovered.class ~= '' and ('\n' .. hovered.class .. ' P' .. hovered.classPosition) or ''))
        if config.mapClicks and ui.mouseClicked(ui.MouseButton.Left) then onFocus(hovered.row) end
    end
end

-- Draws the map into the window area at `origin`. With an edge fade, it is painted into a canvas first and drawn
-- back with its edges fading out, since fading the shapes themselves would fade whole lines and the map image.
function M.draw(self, model, config, origin, size, colour, texture, onFocus)
    if not self.started then self:loadTrack() end
    S = S or scratch()
    local x0, y0, w, h = origin.x, origin.y, size.x, size.y
    if w <= 0 or h <= 0 then return end
    local hits = self.hits
    if not hits then
        hits = {markers = {}, markerCount = 0, legend = {}, corner = {}, north = {}}
        self.hits = hits
    end
    local fade = math.min(math.floor(clamp(tonumber(config.mapEdgeFade) or 0, 0, 100)), math.floor(math.min(w, h) / 2))
    if fade > 0 then
        local cw, ch = math.max(1, math.ceil(w)), math.max(1, math.ceil(h))
        if not self.fadeCanvas or self.fadeW ~= cw or self.fadeH ~= ch then
            if self.fadeCanvas then self.fadeCanvas:dispose() end
            self.fadeCanvas, self.fadeW, self.fadeH = ui.ExtraCanvas(vec2(cw, ch)), cw, ch
        end
        self.fadeCanvas:clear()
        self.fadeCanvas:update(function() paint(self, model, config, 0, 0, w, h, fade, colour, texture, hits) end)
        fadeEdges(self.fadeCanvas, x0, y0, cw, ch, fade)
    else
        if self.fadeCanvas then self.fadeCanvas:dispose(); self.fadeCanvas = nil end
        paint(self, model, config, x0, y0, w, h, 0, colour, texture, hits)
    end
    interact(self, config, x0, y0, w, h, fade, hits, onFocus)
end

return M
