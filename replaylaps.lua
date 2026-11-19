-- replaylaps.lua
-- Laps, lap times and the finish in AC replays, where CSP keeps them only for the car the replay was recorded from
-- (index 0): every other car's lap count stays 0, its last and best laps 0 and isRaceFinished false, and its racePosition
-- (worked out from those) is nonsense. What a replay does keep for every car is its spline position and lap timer, and
-- the timer resets at the line, so each reset is a lap completed: the lap just ended ran from the timer's last reading
-- plus the time since then, less what the new lap's timer already shows. Before a car's first reset its timer is junk
-- (hours), and its first lap is timed from the start instead.
--
-- Seeking breaks the chain of resets, so snapshots are kept every SNAP_FRAMES of replay: after a jump, each car's laps
-- are the count that puts it nearest to where it would be now from the latest snapshot at or before the new frame, at
-- its usual pace. With no snapshot to go on, each car is put on the lap nearest the recorded car's (CSP's count for it
-- is right), which is right for cars within half a lap of it. Plain Lua; times in ms.
local M = {}

-- Snapshots this many replay frames apart.
M.SNAP_FRAMES = 50
-- A step of more frames than this (or backwards) is a seek, not playback.
local JUMP_FRAMES = 60
-- The lap timer falling by more than this (ms) is a crossing of the line.
local RESET_DROP = 2000
-- A lap timer beyond the time since the start, plus this, belongs to no lap of this race.
local SLACK = 2000
-- Lap timers beyond this (ms) are junk, whatever the session.
local JUNK = 3600000
-- From a snapshot this recent (ms), a car with no lap time yet is where the snapshot left it.
local SHORT_JUMP = 10000
-- A lap's start is corrected only from readings this early in it (ms).
local REFINE_WINDOW = 3000

function M.new()
    return {cars = {}, snaps = {}, flagLap = nil, flagged = false, exact = false}
end

local function nearestSnap(snaps, frame)
    for bucket = math.floor(frame / M.SNAP_FRAMES), 0, -1 do
        local snap = snaps[bucket]
        if snap and snap.frame <= frame then return snap end
    end
    return nil
end

-- Once per poll, before the cars. `frame`: replay frame; `clock`: ms since the session start (smooth, unlike frames);
-- `info`: {race, started, over (time is up in a timed race), lapTarget (a lap race's laps), additional (a timed race
-- runs one lap more once the leader takes the flag)}.
function M.begin(state, frame, clock, info)
    local jumped = state.frame ~= nil and (frame < state.frame or frame - state.frame > JUMP_FRAMES)
    if jumped or state.frame == nil then
        local snap = nearestSnap(state.snaps, frame)
        state.cars, state.anchor = {}, snap or false
        state.flagLap, state.flagged = snap and snap.flagLap, snap and snap.flagged or false
        -- Counted from the start, every reset seen: snapshots taken from here on can be trusted over guessed ones.
        state.exact = snap and snap.exact or (info.race and not info.started) or false
    end
    state.frame, state.clock, state.info = frame, clock, info
end

-- How far round the race the car furthest on (other than `except`) is: completed laps plus spline.
local function furthest(state, except)
    local p = 0
    for _, car in pairs(state.cars) do
        if car ~= except then p = math.max(p, car.laps + (car.finished and 0 or car.spline or 0)) end
    end
    return p
end
-- A car level on laps but this far behind on the road is not leading.
local LEAD_MARGIN = 0.05
-- Bounds on the pace correction taken from the recorded car after a seek.
local SCALE_LOW, SCALE_HIGH = 0.85, 1.15

-- A car's first sample since the replay began or jumped: where it stands now, as best as can be told.
local function anchor(state, s)
    local info = state.info
    local car = {laps = 0, last = 0, best = 0, finished = false}
    if s.own then
        car.laps = s.laps
        car.last = (s.last or 0) > 0 and s.last or 0
        car.best = car.last
        -- Its count is right, so how far it really went since the snapshot, against how far its usual pace would
        -- have taken it, corrects everyone's pace for the stretch (best laps run quicker than a race's average).
        state.paceScale = 1
        local from = state.anchor and state.anchor.cars[s.key]
        local pace = from and (from.best > 0 and from.best or from.last > 0 and from.last)
        if pace then
            local predicted = (state.clock - state.anchor.clock) / pace
            local actual = s.laps + s.spline - from.laps - from.spline
            if predicted > 0.5 then state.paceScale = math.max(SCALE_LOW, math.min(SCALE_HIGH, actual / predicted)) end
        end
    elseif info.race and not info.started then
        car.laps = 0
    else
        local from = state.anchor and state.anchor.cars[s.key]
        local pace = from and (from.best > 0 and from.best or from.last > 0 and from.last or state.anchor.typical)
        if from and from.finished then
            car.laps, car.finished, car.finishClock = from.laps, true, from.finishClock
        elseif from and (pace or state.clock - state.anchor.clock < SHORT_JUMP) then
            local run = pace and (state.clock - state.anchor.clock) / pace * (state.paceScale or 1) or 0
            car.laps = math.max(0, math.floor(from.laps + from.spline + run - s.spline + 0.5))
        elseif state.ownProgress then
            car.laps = math.max(0, math.floor(state.ownProgress - s.spline + 0.5))
        end
    end
    if state.anchor and state.anchor.cars[s.key] then
        local from = state.anchor.cars[s.key]
        car.last, car.best, car.finalLap = from.last, from.best, from.finalLap
    end
    return car
end

-- One car's sample: {key, spline, lapTime (CSP's, ms), own (the recorded car), laps and last (CSP's, right only for
-- the recorded car)}. Returns {laps, last, best, current (this lap's time, or the time since the start for a car yet
-- to cross the line; the model shows none once finished), finished, finishClock (ms since the start, when it took the
-- flag)}.
function M.sample(state, s)
    local info, clock = state.info, state.clock
    local car = state.cars[s.key]
    if not car then
        car = anchor(state, s)
        state.cars[s.key] = car
    end
    local raced = info.race and info.started
    local valid = s.lapTime >= 0 and s.lapTime < JUNK and (not raced or s.lapTime <= clock + SLACK)
    local current = valid and s.lapTime or raced and math.max(0, clock) or 0
    -- When this lap began (ms since the start): from the timer, or the start itself for a race's first lap; nothing
    -- is timed before a race starts.
    local start
    if raced or not info.race then start = valid and clock - s.lapTime or raced and 0 or nil end
    -- CSP blends the lap timer between replay frames, so across a reset a poll can catch a value part way down from
    -- the old lap's: only a timer that has truly restarted counts as a crossing.
    local crossed = car.raw ~= nil and s.lapTime + RESET_DROP < car.raw
        and s.lapTime < RESET_DROP + (clock - car.clock) and (raced or not info.race)
    if crossed and not car.finished then
        if s.own then car.laps = s.laps else car.laps = car.laps + 1 end
        car.prevStart, car.bestBefore, car.lapStart, car.lapTimed = car.lapStart, car.best, start, false
        -- The lap just ended is timed only if its start was seen (or was the race start).
        if car.prevStart and start and start > car.prevStart then
            car.last, car.lapTimed = start - car.prevStart, true
            if car.best <= 0 or car.last < car.best then car.best = car.last end
        end
        if raced then
            if state.flagged then
                car.finished = true
            elseif info.lapTarget and info.lapTarget > 0 and car.laps >= info.lapTarget then
                car.finished, state.flagged = true, true
            elseif info.over then
                if not state.flagLap and car.laps >= furthest(state, car) - LEAD_MARGIN then
                    state.flagLap = car.laps + (info.additional and 1 or 0)
                end
                if state.flagLap and car.laps >= state.flagLap then car.finished, state.flagged = true, true end
            end
            if car.finished then car.finishClock, car.finalLap = start or clock, car.last end
        end
    elseif not car.finished then
        if s.own then car.laps = s.laps end
        if start and not car.lapStart then
            car.lapStart = start
        elseif start and start > car.lapStart and start - car.lapStart < RESET_DROP and current < REFINE_WINDOW then
            -- A blended reading at the crossing put the start early; the readings just after have it right. Later
            -- readings are left alone: at fast-forward the timer jitters, and keeping the latest start would creep.
            car.lapStart = start
            if car.lapTimed then
                car.last = start - car.prevStart
                car.best = car.bestBefore > 0 and car.bestBefore < car.last and car.bestBefore or car.last
            end
        end
    end
    car.raw, car.clock, car.spline = s.lapTime, clock, s.spline
    if s.own then state.ownProgress = car.laps + s.spline end
    return {laps = car.laps, last = car.finished and car.finalLap or car.last, best = car.best,
        current = current, finished = car.finished, finishClock = car.finishClock}
end

-- Once per poll, after the cars: a snapshot, if this stretch of the replay has none (or only a guessed one).
function M.finish(state)
    local bucket = math.floor(state.frame / M.SNAP_FRAMES)
    local old = state.snaps[bucket]
    if old and (old.exact or not state.exact) then return end
    local cars, typical = {}, nil
    for key, car in pairs(state.cars) do
        cars[key] = {laps = car.laps, spline = car.spline or 0, last = car.last, best = car.best,
            finished = car.finished, finishClock = car.finishClock, finalLap = car.finalLap}
        if car.best > 0 and (not typical or car.best < typical) then typical = car.best end
    end
    -- A pace for cars yet to complete a lap: the quickest anyone has managed.
    state.snaps[bucket] = {frame = state.frame, clock = state.clock, flagLap = state.flagLap, flagged = state.flagged,
        exact = state.exact, cars = cars, typical = typical}
end

return M
