-- model.lua
-- The standings order behind the map's positions, worked out as Broadcasting's standings do it: grid order before a
-- race start, CSP's race order, cars held where they left mid-race, and replays rebuilt from each car's lap timer. Each
-- row carries the metadata the indicators show and classify by.
local Classes = require('classes')
local Timing = require('timing')
local ReplayLaps = require('replaylaps')
local Exclude = require('exclude')
local M = {}

-- Whether a timed race runs one more lap once the leader crosses the line after time is up: the timedExtraLap setting
-- (1 as the session says, 2 always, 3 never). Replays never say so.
function M.extraLap(config, session)
    local mode = config.timedExtraLap or 1
    if mode == 2 then return true end
    if mode == 3 then return false end
    return session ~= nil and session.hasAdditionalLap == true
end

-- Whether `name` is in the "Exclude names" list (exclude.lua: | separated, \ escapes).
function M.skipped(list, name)
    return Exclude.has(list, name)
end

local function before(a, b, race)
    if a.connected ~= b.connected then return a.connected end
    if race then
        -- Before the start, cars on the grid in grid order, ahead of any in the pits.
        if a.grid or b.grid then
            if a.grid and b.grid then
                if a.grid ~= b.grid then return a.grid < b.grid end
            else
                return a.grid ~= nil
            end
        end
        if a.racePosition > 0 and b.racePosition > 0 and a.racePosition ~= b.racePosition then
            return a.racePosition < b.racePosition
        end
        if a.distance ~= b.distance then return a.distance > b.distance end
        -- Finished on the same lap (replays, where racePosition is no help): in the order they took the flag.
        if a.finishAt and b.finishAt and a.finishAt ~= b.finishAt then return a.finishAt < b.finishAt end
    else
        if (a.best > 0) ~= (b.best > 0) then return a.best > 0 end
        if a.best > 0 and a.best ~= b.best then return a.best < b.best end
    end
    return a.index < b.index
end

-- Whether `h`, held where it left the server mid-race, stays ahead of `r`: until `r` covers more distance, or
-- finished the same distance later.
local function stays(h, r)
    if not r.connected and not r.held then return true end
    local hd, rd = h.distance or 0, r.distance or 0
    if hd ~= rd then return hd > rd end
    if h.finishAt and r.finishAt and h.finishAt ~= r.finishAt then return h.finishAt < r.finishAt end
    if r.held then return h.entryKey < r.entryKey end
    return true
end

-- In races, rows `held` after leaving keep their place: the rest are ordered as usual, then each held row goes in
-- ahead of the first it has covered more distance than.
function M.sort(rows, race)
    local held, n = {}, 0
    for i = 1, #rows do
        local row = rows[i]
        if race and row.held then held[#held + 1] = row else n = n + 1; rows[n] = row end
    end
    for i = #rows, n + 1, -1 do rows[i] = nil end
    table.sort(rows, function(a, b) return before(a, b, race) end)
    if #held > 0 then
        table.sort(held, stays)
        local merged, j = {}, 1
        for _, h in ipairs(held) do
            while j <= #rows and not stays(h, rows[j]) do merged[#merged + 1], j = rows[j], j + 1 end
            merged[#merged + 1] = h
        end
        for k = j, #rows do merged[#merged + 1] = rows[k] end
        for k, row in ipairs(merged) do rows[k] = row end
    end
    for i, row in ipairs(rows) do row.position = i end
    return rows
end

-- Metres from a grid box within which a car is taken to be on it.
local GRID_REACH = 8

-- Grid order before a race start, when CSP's racePosition (worked out from distance driven, nothing yet) is only the
-- order of the entry list. `cars`: {index, x, z, spline} for cars out of the pit lane; `slots`: the track's grid boxes
-- in order (AC_START_0 is pole) as {x, z}. A car on a box takes that box's number; any other sits behind them, the
-- furthest round the lap (counting just behind the line as before it) first. Returns sort keys by car index.
function M.gridKeys(cars, slots)
    local keys = {}
    for _, c in ipairs(cars) do
        local best, bestDistance = nil, GRID_REACH * GRID_REACH
        for i, s in ipairs(slots) do
            local d = (c.x - s.x) ^ 2 + (c.z - s.z) ^ 2
            if d < bestDistance then best, bestDistance = i, d end
        end
        local ahead = c.spline > 0.5 and c.spline - 1 or c.spline
        keys[c.index] = best or #slots + 1.5 - ahead
    end
    return keys
end

function M.new(config)
    local self = {rows = {}, byIndex = {}, metadata = {}, lastPoll = -math.huge, lastOrder = -math.huge,
        lastMetadata = -math.huge, focus = -1, clock = 0, timing = Timing.new(), departed = {}}
    self.classes = Classes.new(config)

    -- `preserveHeld` keeps cars held after leaving mid-race (and the race progress behind their places), as when
    -- a preset is applied; a new session or a replay rewind starts afresh.
    function self:reset(preserveHeld)
        self.classes:reset()
        local kept, departed = {}, {}
        if preserveHeld then
            for index, row in pairs(self.byIndex) do if row.held then kept[index] = row end end
            departed = self.departed or {}
        end
        self.rows, self.byIndex, self.metadata, self.departed = {}, kept, {}, departed
        for index, row in pairs(kept) do self.metadata[index] = row.meta end
        self.lastPoll, self.lastOrder, self.lastMetadata = -math.huge, -math.huge, -math.huge
        if not preserveHeld then self.clock, self.timing = 0, Timing.new() end
    end

    -- A held car's slot taken by another entry (or a finished car back): its row stays in the order under a key of
    -- its own, so the newcomer's progress starts afresh.
    function self:depart(row)
        self.departures = (self.departures or 0) + 1
        local key = row.entryKey .. '|left' .. self.departures
        Timing.rename(self.timing, row.entryKey, key)
        if self.byIndex[row.index] == row then self.byIndex[row.index] = nil end
        row.entryKey, row.departed = key, true
        self.departed[#self.departed + 1] = row
    end

    -- The track's grid boxes (AC_START_0 is pole), read once.
    function self:startSlots()
        if not self.slots then
            self.slots = {}
            local root = ac.findNodes and ac.findNodes('trackRoot:yes')
            for i = 0, 499 do
                local node = root and root:findNodes('AC_START_' .. i)
                local m = node and node:size() > 0 and node:getWorldTransformationRaw()
                if not m then break end
                self.slots[#self.slots + 1] = {x = m.position.x, z = m.position.z}
            end
        end
        return self.slots
    end

    -- What the indicators show and classify by: the driver's name, livery number, entry slot and car (with its tags).
    function self:refreshMetadata(index)
        local carID = ac.getCarID(index) or ''
        local car = ac.getCar(index)
        self.metadata[index] = {
            tags = self.classes:tags(carID), carID = carID,
            slot = car and car.sessionID and car.sessionID >= 0 and car.sessionID or index,
            name = ac.getDriverName(index) or '', number = tostring(ac.getDriverNumber(index) or '')
        }
    end

    function self:update(now)
        local sim = ac.getSim()
        self.classes.live:update(now)
        self.clock = self.clock + math.max(0, sim.dt)
        local focusChanged = self.focus ~= sim.focusedCar
        self.focus = sim.focusedCar
        if now - self.lastPoll < config.pollInterval and not focusChanged then return end
        self.lastPoll = now
        self.race = sim.raceSessionType == ac.SessionType.Race
        local preStart = self.race and ((sim.timeToSessionStart or -1) > 0 or sim.isSessionStarted == false)
        local session = ac.getSession and ac.getSession(sim.currentSessionIndex)
        local lapRace = self.race and session and not session.isTimedRace and (session.laps or 0) > 0
        -- In replays CSP keeps laps, lap times and the finish only for the recorded car: replaylaps.lua rebuilds them.
        -- It outlives resets (a seek back resets the rest), but not a change of session.
        local replay = sim.isReplayActive and sim.replayCurrentFrame ~= nil
        -- Race progress runs on the sim clock live; in replays on the session clock, which keeps true time whatever
        -- the playback speed (the sim's dt is 0 while a replay is paused or stepped).
        local timingClock = self.clock
        if replay then
            if not self.replayLaps or self.replayLapsSession ~= sim.currentSessionIndex then
                self.replayLaps, self.replayLapsSession = ReplayLaps.new(), sim.currentSessionIndex
            end
            local clock = -(sim.timeToSessionStart or 0)
            timingClock = clock / 1000
            ReplayLaps.begin(self.replayLaps, sim.replayCurrentFrame, clock, {race = self.race,
                started = clock >= 0, over = (sim.sessionTimeLeft or 1) <= 0 and not lapRace,
                lapTarget = lapRace and session.laps or nil, additional = M.extraLap(config, session)})
        end
        local metadataDue = now - self.lastMetadata >= config.metadataInterval
        local orderDue = now - self.lastOrder >= config.orderInterval
        local present, changed = {}, false
        -- A car that leaves the race once it has raced is held where it was: frozen, keeping its place until passed.
        local function holds(row) return row.held or (self.race and row.raced and row.connected) end
        local function hold(row)
            row.held, row.connected, row.inPit, row.inPitlane = true, false, false, false
            changed = true
        end
        for index = 0, sim.carsCount - 1 do
            local car = ac.getCar(index)
            local row = self.byIndex[index]
            if car and car.isActive and not car.isConnected and row and holds(row) then
                present[index] = true
                if not row.held then hold(row) end
            elseif car and car.isActive then
                present[index] = true
                local slot = car.sessionID and car.sessionID >= 0 and car.sessionID or index
                local entryKey = tostring(slot) .. '|' .. (ac.getCarID(index) or '')
                if row and row.held and row.entryKey ~= entryKey then
                    -- The slot taken by another entry: the held row stays in the order under a key of its own.
                    self:depart(row)
                    row = nil
                end
                if not row or row.entryKey ~= entryKey then
                    -- A held entry back at a different local index (CSP can move it on reconnect).
                    for other, candidate in pairs(self.byIndex) do
                        if other ~= index and candidate.held and candidate.entryKey == entryKey then
                            self.byIndex[other], self.metadata[other] = nil, nil
                            candidate.index, self.byIndex[index], row = index, candidate, candidate
                            break
                        end
                    end
                end
                if row and row.held then
                    -- Back: the same entry resumes (a rejoin or a driver swap keeps the car's place), but a finished
                    -- result stays as it was, with the newcomer in a row of their own.
                    if row.finished then
                        self:depart(row)
                        row = nil
                    else
                        row.held, changed = nil, true
                    end
                end
                if not row or row.entryKey ~= entryKey then
                    row = {index = index, entryKey = entryKey}
                    self.byIndex[index], changed = row, true
                    self.metadata[index] = nil
                end
                if metadataDue or not self.metadata[index]
                    or self.metadata[index].name ~= (ac.getDriverName(index) or '') then self:refreshMetadata(index) end
                if row.connected ~= car.isConnected then changed = true end
                row.meta, row.connected = self.metadata[index], car.isConnected
                row.racePosition = car.racePosition
                row.grid = nil
                if preStart and car.isConnected and not car.isInPitlane and not car.isInPit then
                    local p = car.position
                    row.grid = M.gridKeys({{index = index, x = p.x, z = p.z, spline = car.splinePosition}},
                        self:startSlots())[index]
                end
                row.best, row.last, row.current = car.bestLapTimeMs, car.previousLapTimeMs, car.lapTimeMs
                row.laps, row.inPit, row.inPitlane = car.lapCount, car.isInPit, car.isInPitlane
                row.finished, row.finishAt = car.isRaceFinished, nil
                if replay then
                    local r = ReplayLaps.sample(self.replayLaps, {key = entryKey, spline = car.splinePosition,
                        lapTime = car.lapTimeMs, own = index == 0, laps = car.lapCount, last = car.previousLapTimeMs})
                    row.laps, row.last, row.best, row.current = r.laps, r.last, r.best, r.current
                    row.finished, row.finishAt = r.finished, r.finishClock
                    -- CSP ranks replayed cars by lap counts it keeps only for the recorded car: order by distance.
                    if self.race then row.racePosition = 0 end
                end
                row.distance = car.drivenInRace
                if self.race then
                    Timing.track(self.timing, entryKey, {laps = row.laps, spline = car.splinePosition,
                        lapTime = row.current, last = row.last, best = row.best, finished = row.finished}, timingClock)
                    row.distance = Timing.distance(self.timing, entryKey, sim.trackLengthM) or row.distance
                    row.finishAt = row.finishAt or Timing.finishAt(self.timing, entryKey)
                    if not preStart and car.isConnected
                        and (row.laps > 0 or row.finished or not (row.inPit or row.inPitlane)) then
                        row.raced = true
                    end
                end
            end
        end
        for index, row in pairs(self.byIndex) do
            if not present[index] then
                if holds(row) then
                    if not row.held then hold(row) end
                else
                    self.byIndex[index], self.metadata[index], changed = nil, nil, true
                end
            end
        end
        if metadataDue then self.lastMetadata = now end
        if orderDue or changed then
            local rows, finishedLeft = {}, {}
            for _, row in ipairs(self.departed) do
                if row.finished then finishedLeft[row.meta.name] = true end
            end
            local function include(row)
                -- Disconnected cars that are not held would sort below every other row, so they are left out.
                local skip = not row.connected and not row.held
                    or M.skipped(config.skipDrivers, row.meta.name)
                    -- Back after their result was kept: the race is over for them.
                    or not row.held and finishedLeft[row.meta.name]
                if not skip then rows[#rows + 1] = row end
            end
            for _, row in pairs(self.byIndex) do include(row) end
            for _, row in ipairs(self.departed) do include(row) end
            self.rows, self.lastOrder = M.sort(rows, self.race), now
        end
        if replay then ReplayLaps.finish(self.replayLaps) end
    end

    return self
end

return M
