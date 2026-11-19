-- timing.lua
-- Race progress for the standings order, as timing loops measure it: each car's progress round the race (completed
-- laps plus spline position, checked against the lap timer near the line) and when it took the chequered flag. CSP's
-- drivenInRace has been seen 16 laps out for the driving client's own car, so this is preferred. At the flag each car's
-- progress freezes, so victory laps and teleports to the pits change nothing. Plain Lua; clock in seconds.
local M = {}

-- Spline within this of the line is checked against the lap timer: AC's spline zero and its timing line are not always
-- in the same place, so for a moment either side of the line laps + spline can be a lap out.
local NEAR_LINE = 0.05
-- A lap timer below this share of a lap (or JUST_CROSSED ms, with no lap time yet) means the car has just crossed.
local CROSSED_SHARE, JUST_CROSSED = 0.25, 20000
-- A finish seen this late (ms on the new lap's timer) is no longer timed from the lap timer.
local FINISH_WINDOW = 60000

-- Progress in laps from completed laps, spline position and the current lap timer (ms); `estimate` is a typical lap
-- (ms), or 0 if none is known yet.
function M.progress(laps, spline, lapTime, estimate)
    local p = laps + spline
    local crossed = lapTime < (estimate > 0 and math.min(JUST_CROSSED, estimate * CROSSED_SHARE) or JUST_CROSSED)
    if spline > 1 - NEAR_LINE and crossed then return p - 1 end
    if spline < NEAR_LINE and not crossed then return p + 1 end
    return p
end

function M.new()
    return {cars = {}}
end

-- One sample of a car (by a key stable for the entry): {laps, spline, lapTime (ms), last (ms, previous lap), best (ms),
-- finished}.
function M.track(state, key, s, clock)
    local car = state.cars[key]
    if not car then
        car = {}
        state.cars[key] = car
    end
    if s.finished then
        if not car.finishLaps then
            car.finishLaps = s.laps
            -- Seen running before, so the flag fell just now: the new lap's timer says how long ago it crossed.
            if car.progress and s.lapTime < FINISH_WINDOW then car.finishAt = clock - s.lapTime / 1000 end
        end
        car.progress = car.finishLaps
        return car
    end
    car.finishLaps, car.finishAt = nil, nil
    local estimate = (s.best or 0) > 0 and s.best or (s.last or 0) > 0 and s.last or 0
    car.progress = M.progress(s.laps, s.spline, s.lapTime, estimate)
    return car
end

-- Moves a car's record to a new key (an entry whose slot has been taken by someone else).
function M.rename(state, from, to)
    state.cars[to], state.cars[from] = state.cars[from], nil
end

-- When the finished car crossed the line (clock seconds), if seen.
function M.finishAt(state, key)
    local car = state.cars[key]
    return car and car.finishLaps and car.finishAt or nil
end

-- Distance (m) round the race from the car's progress, or nil.
function M.distance(state, key, trackLength)
    local car = state.cars[key]
    return car and car.progress and trackLength > 0 and car.progress * trackLength or nil
end

return M
