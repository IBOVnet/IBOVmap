-- svg.lua
-- SVG textures. CSP loads only raster images, so an SVG is drawn here once into a PNG and cached.
-- Supported: paths and basic shapes, groups, <use>/<symbol>, transforms, viewBox, CSS (<style> with tag, .class and
-- #id selectors, style attributes), solid colours, linear and radial gradients, fill rules, opacity, strokes with
-- joins, caps and dashes. Not drawn: text, embedded images, clipping, masks, patterns and filters.
local M = {}

-- Pixels along the longer side of the cached image.
M.size = 2048
-- Vertical samples per pixel row for anti-aliasing (horizontal coverage is exact).
local SAMPLES = 4
-- Largest distance in pixels between a curve and the lines drawn for it.
local TOLERANCE = 0.1

local floor, ceil, sqrt, abs, min, max = math.floor, math.ceil, math.sqrt, math.abs, math.min, math.max
local pi, sin, cos, atan2 = math.pi, math.sin, math.cos, math.atan2 or math.atan

local bit = rawget(_G, 'bit')
if not bit then
    local ok, lib = pcall(require, 'bit')
    bit = ok and lib or nil
end
local ffi
do
    local ok, lib = pcall(require, 'ffi')
    ffi = ok and lib or nil
end

local function buffer(n)
    if ffi then return ffi.new('float[?]', n) end
    local t = {}
    for i = 0, n - 1 do t[i] = 0 end
    return t
end

-- Inside M.request's coroutine, drawing pauses here once the frame's time slice is spent.
local sliceEnd
local function checkpoint()
    if not sliceEnd or os.clock() < sliceEnd then return end
    local co, main = coroutine.running()
    if co and not main then coroutine.yield() end
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

---------------------------------------------------------------------------------------------------------------------
-- XML

local function utf8(code)
    if not code or code < 0 then return '' end
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then
        return string.char(0xE0 + floor(code / 4096), 0x80 + floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xF0 + floor(code / 262144), 0x80 + floor(code / 4096) % 64, 0x80 + floor(code / 64) % 64,
        0x80 + code % 64)
end

local entities = {amp = '&', lt = '<', gt = '>', quot = '"', apos = "'"}
local function decode(s)
    return (s:gsub('&(#?[xX]?)(%w+);', function(kind, body)
        if kind == '' then return entities[body] end
        return utf8(tonumber(body, kind == '#' and 10 or 16))
    end))
end

local function localName(name)
    return (name:gsub('^.*:', ''))
end

function M.parseXML(text)
    local root = {tag = '#document', attrs = {}, children = {}}
    local stack, pos, n = {root}, 1, #text
    local function append(s)
        local top = stack[#stack]
        top.text = (top.text or '') .. s
    end
    while pos <= n do
        local s = text:find('<', pos, true)
        if not s then break end
        if s > pos then append(decode(text:sub(pos, s - 1))) end
        if text:sub(s, s + 3) == '<!--' then
            pos = (text:find('-->', s + 4, true) or n) + 3
        elseif text:sub(s, s + 8) == '<![CDATA[' then
            local e = text:find(']]>', s + 9, true) or n + 1
            append(text:sub(s + 9, e - 1))
            pos = e + 3
        elseif text:sub(s + 1, s + 1) == '?' then
            pos = (text:find('?>', s + 2, true) or n) + 2
        elseif text:sub(s + 1, s + 1) == '!' then
            -- DOCTYPE, which may carry an internal subset in brackets.
            local e = text:find('>', s, true) or n
            local bracket = text:find('[', s, true)
            if bracket and bracket < e then e = text:find('>', text:find(']', bracket, true) or bracket, true) or n end
            pos = e + 1
        elseif text:sub(s + 1, s + 1) == '/' then
            local e = text:find('>', s, true) or n
            local name = localName(text:sub(s + 2, e - 1):match('^%s*([^%s>]+)') or '')
            for i = #stack, 2, -1 do
                if stack[i].tag == name then
                    for j = #stack, i, -1 do stack[j] = nil end
                    break
                end
            end
            pos = e + 1
        else
            -- The tag ends at the first '>' outside quotes.
            local i, e = s + 1, nil
            while true do
                local j = text:find('[>"\']', i)
                if not j then e = n + 1; break end
                local c = text:sub(j, j)
                if c == '>' then e = j; break end
                i = (text:find(c, j + 1, true) or n) + 1
            end
            local body = text:sub(s + 1, e - 1)
            local closed = body:sub(-1) == '/'
            if closed then body = body:sub(1, -2) end
            local top = stack[#stack]
            local node = {tag = localName(body:match('^([^%s/]+)') or ''), attrs = {}, children = {}, parent = top}
            for key, _, value in body:gmatch('([%w:_%-%.]+)%s*=%s*(["\'])(.-)%2') do
                node.attrs[localName(key)] = decode(value)
            end
            top.children[#top.children + 1] = node
            if not closed then stack[#stack + 1] = node end
            pos = e + 1
        end
    end
    return root
end

---------------------------------------------------------------------------------------------------------------------
-- CSS and properties

local function declarations(text, into)
    for decl in text:gmatch('[^;]+') do
        local key, value = decl:match('^%s*([%w%-]+)%s*:%s*(.-)%s*$')
        if key then into[key:lower()] = (value:gsub('%s*!important$', '')) end
    end
    return into
end

local function parseCSS(text, rules)
    text = text:gsub('/%*.-%*/', '')
    for selectors, body in text:gmatch('([^{}]+){([^{}]*)}') do
        local decls = declarations(body, {})
        for selector in selectors:gmatch('[^,]+') do
            selector = trim(selector)
            local tag, rest = selector:match('^([%w%-%*]*)(.*)$')
            local rule = {tag = tag ~= '' and tag ~= '*' and tag or nil, classes = {}, decls = decls,
                order = #rules + 1}
            rule.id = rest:match('^#([%w%-_]+)$')
            local valid = true
            if not rule.id then
                for class in rest:gmatch('%.([%w%-_]+)') do rule.classes[#rule.classes + 1] = class end
                valid = rest:gsub('%.[%w%-_]+', '') == ''
            end
            if valid and selector ~= '' then
                rule.specificity = (rule.id and 100 or 0) + #rule.classes * 10 + (rule.tag and 1 or 0)
                rules[#rules + 1] = rule
            end
        end
    end
end

local properties = {}
for name in ([[fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-linejoin stroke-linecap
    stroke-miterlimit stroke-dasharray stroke-dashoffset opacity color display visibility stop-color
    stop-opacity]]):gmatch('%S+') do properties[name] = true end
local notInherited = {opacity = true, display = true, ['stop-color'] = true, ['stop-opacity'] = true}

local function matches(rule, node)
    if rule.tag and rule.tag ~= node.tag then return false end
    if rule.id and rule.id ~= node.attrs.id then return false end
    if #rule.classes > 0 then
        local own = ' ' .. (node.attrs.class or '') .. ' '
        for _, class in ipairs(rule.classes) do
            if not own:find(' ' .. class .. ' ', 1, true) then return false end
        end
    end
    return true
end

-- The element's own declarations: presentation attributes, then style sheets, then its style attribute.
local function ownStyle(node, rules)
    if node.style then return node.style end
    local style = {}
    for key, value in pairs(node.attrs) do
        if properties[key] then style[key] = trim(value) end
    end
    local matched = {}
    for _, rule in ipairs(rules) do
        if matches(rule, node) then matched[#matched + 1] = rule end
    end
    table.sort(matched, function(a, b)
        if a.specificity ~= b.specificity then return a.specificity < b.specificity end
        return a.order < b.order
    end)
    for _, rule in ipairs(matched) do
        for key, value in pairs(rule.decls) do style[key] = value end
    end
    if node.attrs.style then declarations(node.attrs.style, style) end
    node.style = style
    return style
end

local function computed(node, inherited, rules)
    local result = {}
    for key, value in pairs(inherited) do
        if not notInherited[key] then result[key] = value end
    end
    for key, value in pairs(ownStyle(node, rules)) do
        if value == 'inherit' then result[key] = inherited[key] else result[key] = value end
    end
    return result
end

---------------------------------------------------------------------------------------------------------------------
-- Colours

local named = {
    black = '000000', white = 'ffffff', red = 'ff0000', lime = '00ff00', green = '008000', blue = '0000ff',
    yellow = 'ffff00', cyan = '00ffff', aqua = '00ffff', magenta = 'ff00ff', fuchsia = 'ff00ff', gray = '808080',
    grey = '808080', silver = 'c0c0c0', maroon = '800000', olive = '808000', purple = '800080', teal = '008080',
    navy = '000080', orange = 'ffa500', gold = 'ffd700', pink = 'ffc0cb', brown = 'a52a2a', darkred = '8b0000',
    darkgreen = '006400', darkblue = '00008b', darkgray = 'a9a9a9', darkgrey = 'a9a9a9', lightgray = 'd3d3d3',
    lightgrey = 'd3d3d3', dimgray = '696969', dimgrey = '696969', gainsboro = 'dcdcdc', whitesmoke = 'f5f5f5',
    crimson = 'dc143c', firebrick = 'b22222', tomato = 'ff6347', coral = 'ff7f50', orangered = 'ff4500',
    darkorange = 'ff8c00', goldenrod = 'daa520', khaki = 'f0e68c', beige = 'f5f5dc', ivory = 'fffff0',
    tan = 'd2b48c', chocolate = 'd2691e', sienna = 'a0522d', salmon = 'fa8072', violet = 'ee82ee',
    indigo = '4b0082', orchid = 'da70d6', plum = 'dda0dd', lavender = 'e6e6fa', skyblue = '87ceeb',
    lightblue = 'add8e6', steelblue = '4682b4', royalblue = '4169e1', dodgerblue = '1e90ff',
    deepskyblue = '00bfff', midnightblue = '191970', slategray = '708090', slategrey = '708090',
    turquoise = '40e0d0', seagreen = '2e8b57', forestgreen = '228b22', limegreen = '32cd32',
    yellowgreen = '9acd32', olivedrab = '6b8e23', chartreuse = '7fff00', lawngreen = '7cfc00',
    springgreen = '00ff7f', mintcream = 'f5fffa', hotpink = 'ff69b4', deeppink = 'ff1493', wheat = 'f5deb3',
    linen = 'faf0e6', snow = 'fffafa', honeydew = 'f0fff0', azure = 'f0ffff', aliceblue = 'f0f8ff'
}

local function channel(value)
    local number, percent = value:match('^%s*([%d%.%-]+)%s*(%%?)%s*$')
    number = tonumber(number)
    if not number then return nil end
    return min(1, max(0, percent == '%' and number / 100 or number / 255))
end

-- Returns r, g, b, a in 0..1, or nil for none or an unknown value.
local function parseColour(value, current)
    if not value then return nil end
    value = trim(value):lower()
    if value == 'none' or value == 'transparent' or value == '' then return nil end
    if value == 'currentcolor' then return parseColour(current or 'black') end
    value = named[value] and '#' .. named[value] or value
    local hex = value:match('^#(%x+)$')
    if hex then
        if #hex == 3 or #hex == 4 then hex = hex:gsub('.', '%0%0') end
        if #hex == 6 then hex = hex .. 'ff' end
        if #hex ~= 8 then return nil end
        return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255,
            tonumber(hex:sub(7, 8), 16) / 255
    end
    local args = value:match('^rgba?%((.*)%)$')
    if args then
        local parts = {}
        for part in args:gmatch('[^,%s/]+') do parts[#parts + 1] = part end
        local r, g, b = channel(parts[1] or ''), channel(parts[2] or ''), channel(parts[3] or '')
        if not (r and g and b) then return nil end
        local a = 1
        if parts[4] then
            local number, percent = parts[4]:match('^([%d%.]+)(%%?)$')
            a = tonumber(number) or 1
            if percent == '%' then a = a / 100 end
        end
        return r, g, b, min(1, max(0, a))
    end
    return nil
end

local function number(value, fallback)
    local n = tonumber(value and value:match('^%s*([%d%.eE%+%-]+)'))
    return n or fallback
end

local function fraction(value, fallback)
    if not value then return fallback end
    local n, percent = trim(value):match('^([%d%.eE%+%-]+)(%%?)$')
    n = tonumber(n)
    if not n then return fallback end
    return min(1, max(0, percent == '%' and n / 100 or n))
end

local units = {px = 1, pt = 4 / 3, pc = 16, mm = 96 / 25.4, cm = 96 / 2.54, ['in'] = 96, em = 16, ex = 8}
-- `reference` is what 100% means.
local function length(value, reference, fallback)
    if not value then return fallback end
    local n, unit = trim(value):match('^([%d%.eE%+%-]+)%s*(%a*%%?)$')
    n = tonumber(n)
    if not n then return fallback end
    if unit == '%' then return n / 100 * (reference or 0) end
    return n * (units[unit] or 1)
end

---------------------------------------------------------------------------------------------------------------------
-- Transforms: {a, b, c, d, e, f} maps (x, y) to (a x + c y + e, b x + d y + f).

local identity = {1, 0, 0, 1, 0, 0}

local function multiply(m, n)
    return {m[1] * n[1] + m[3] * n[2], m[2] * n[1] + m[4] * n[2], m[1] * n[3] + m[3] * n[4],
        m[2] * n[3] + m[4] * n[4], m[1] * n[5] + m[3] * n[6] + m[5], m[2] * n[5] + m[4] * n[6] + m[6]}
end

local function invert(m)
    local det = m[1] * m[4] - m[2] * m[3]
    if abs(det) < 1e-12 then return nil end
    return {m[4] / det, -m[2] / det, -m[3] / det, m[1] / det, (m[3] * m[6] - m[4] * m[5]) / det,
        (m[2] * m[5] - m[1] * m[6]) / det}
end

function M.parseTransform(text)
    local m = identity
    for name, args in (text or ''):gmatch('(%a+)%s*%(([^%)]*)%)') do
        local v = {}
        for n in args:gmatch('[%+%-]?[%d%.]+[eE]?[%+%-]?%d*') do v[#v + 1] = tonumber(n) or 0 end
        local t
        if name == 'matrix' and #v >= 6 then
            t = {v[1], v[2], v[3], v[4], v[5], v[6]}
        elseif name == 'translate' then
            t = {1, 0, 0, 1, v[1] or 0, v[2] or 0}
        elseif name == 'scale' then
            t = {v[1] or 1, 0, 0, v[2] or v[1] or 1, 0, 0}
        elseif name == 'rotate' then
            local r = (v[1] or 0) * pi / 180
            t = {cos(r), sin(r), -sin(r), cos(r), 0, 0}
            if v[2] then
                t = multiply(multiply({1, 0, 0, 1, v[2], v[3] or 0}, t), {1, 0, 0, 1, -v[2], -(v[3] or 0)})
            end
        elseif name == 'skewX' then
            t = {1, 0, math.tan((v[1] or 0) * pi / 180), 1, 0, 0}
        elseif name == 'skewY' then
            t = {1, math.tan((v[1] or 0) * pi / 180), 0, 1, 0, 0}
        end
        if t then m = multiply(m, t) end
    end
    return m
end

-- Maps a viewBox onto a viewport, following preserveAspectRatio.
local function viewBoxTransform(box, x, y, w, h, aspect)
    if not box or box[3] <= 0 or box[4] <= 0 then return {1, 0, 0, 1, x, y} end
    local sx, sy = w / box[3], h / box[4]
    aspect = trim(aspect or '')
    local align, mode = aspect:match('^(%S*)%s*(%S*)$')
    if align ~= 'none' then
        local s = mode == 'slice' and max(sx, sy) or min(sx, sy)
        local ax = (align == '' or align:find('xMid')) and 0.5 or align:find('xMax') and 1 or 0
        local ay = (align == '' or align:find('YMid')) and 0.5 or align:find('YMax') and 1 or 0
        x, y = x + (w - box[3] * s) * ax, y + (h - box[4] * s) * ay
        sx, sy = s, s
    end
    return {sx, 0, 0, sy, x - box[1] * sx, y - box[2] * sy}
end

local function parseViewBox(text)
    if not text then return nil end
    local v = {}
    for n in text:gmatch('[%+%-]?[%d%.]+[eE]?[%+%-]?%d*') do v[#v + 1] = tonumber(n) end
    if #v == 4 and v[3] > 0 and v[4] > 0 then return v end
    return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Geometry: shapes are flattened into polylines in pixel space.

local function newPath(m)
    local self = {m = m, polys = {}, minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge}
    local current, startX, startY, lastX, lastY
    local scale = sqrt(abs(m[1] * m[4] - m[2] * m[3]))
    self.scale = scale

    local function device(x, y)
        if x < self.minX then self.minX = x end
        if x > self.maxX then self.maxX = x end
        if y < self.minY then self.minY = y end
        if y > self.maxY then self.maxY = y end
        return m[1] * x + m[3] * y + m[5], m[2] * x + m[4] * y + m[6]
    end
    local function add(x, y)
        local n = #current
        if n >= 2 and current[n - 1] == x and current[n] == y then return end
        current[n + 1], current[n + 2] = x, y
    end
    local function ensure()
        if not current or current.closed then
            local x, y = startX or 0, startY or 0
            current = {}
            self.polys[#self.polys + 1] = current
            add(device(x, y))
            lastX, lastY = x, y
        end
    end

    function self.moveTo(x, y)
        current = {}
        self.polys[#self.polys + 1] = current
        startX, startY, lastX, lastY = x, y, x, y
        add(device(x, y))
    end
    function self.lineTo(x, y)
        ensure()
        add(device(x, y))
        lastX, lastY = x, y
    end
    function self.cubicTo(x1, y1, x2, y2, x, y)
        ensure()
        local n = #current
        local px, py = current[n - 1], current[n]
        local ax, ay = device(x1, y1)
        local bx, by = device(x2, y2)
        local cx, cy = device(x, y)
        -- Wang's formula for the number of lines that keep within the tolerance.
        local dd = max(sqrt((px - 2 * ax + bx) ^ 2 + (py - 2 * ay + by) ^ 2),
            sqrt((ax - 2 * bx + cx) ^ 2 + (ay - 2 * by + cy) ^ 2))
        local steps = min(256, max(1, ceil(sqrt(0.75 * dd / TOLERANCE))))
        for i = 1, steps do
            local t = i / steps
            local u = 1 - t
            local w0, w1, w2, w3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
            add(w0 * px + w1 * ax + w2 * bx + w3 * cx, w0 * py + w1 * ay + w2 * by + w3 * cy)
        end
        lastX, lastY = x, y
    end
    function self.quadTo(x1, y1, x, y)
        ensure()
        local n = #current
        local px, py = current[n - 1], current[n]
        local ax, ay = device(x1, y1)
        local cx, cy = device(x, y)
        local dd = sqrt((px - 2 * ax + cx) ^ 2 + (py - 2 * ay + cy) ^ 2)
        local steps = min(256, max(1, ceil(sqrt(dd / (4 * TOLERANCE)))))
        for i = 1, steps do
            local t = i / steps
            local u = 1 - t
            add(u * u * px + 2 * u * t * ax + t * t * cx, u * u * py + 2 * u * t * ay + t * t * cy)
        end
        lastX, lastY = x, y
    end
    -- Elliptical arc from the current point (SVG implementation notes, F.6.5), as cubic curves.
    function self.arcTo(rx, ry, angle, large, sweep, x, y)
        local x0, y0 = lastX or 0, lastY or 0
        rx, ry = abs(rx), abs(ry)
        if rx == 0 or ry == 0 or (x0 == x and y0 == y) then return self.lineTo(x, y) end
        local phi = angle * pi / 180
        local cp, sp = cos(phi), sin(phi)
        local dx, dy = (x0 - x) / 2, (y0 - y) / 2
        local x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
        local lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 then
            local s = sqrt(lambda)
            rx, ry = rx * s, ry * s
        end
        local num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        local den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        local k = sqrt(max(0, num / den)) * (large == sweep and -1 or 1)
        local cxp, cyp = k * rx * y1p / ry, -k * ry * x1p / rx
        local cx, cy = cp * cxp - sp * cyp + (x0 + x) / 2, sp * cxp + cp * cyp + (y0 + y) / 2
        local function angleOf(ux, uy, vx, vy)
            return atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        end
        local theta = angleOf(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        local delta = angleOf((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if not sweep and delta > 0 then delta = delta - 2 * pi elseif sweep and delta < 0 then delta = delta + 2 * pi end
        local segments = max(1, ceil(abs(delta) / (pi / 2) - 1e-9))
        local step = delta / segments
        local t = 4 / 3 * math.tan(step / 4)
        local function point(a)
            local ex, ey = rx * cos(a), ry * sin(a)
            return cp * ex - sp * ey + cx, sp * ex + cp * ey + cy
        end
        local function tangent(a)
            local ex, ey = -rx * sin(a), ry * cos(a)
            return cp * ex - sp * ey, sp * ex + cp * ey
        end
        local a = theta
        for i = 1, segments do
            local b = a + step
            local p1x, p1y = point(a)
            local p2x, p2y = point(b)
            local t1x, t1y = tangent(a)
            local t2x, t2y = tangent(b)
            if i == segments then p2x, p2y = x, y end
            self.cubicTo(p1x + t * t1x, p1y + t * t1y, p2x - t * t2x, p2y - t * t2y, p2x, p2y)
            a = b
        end
    end
    function self.close()
        if current and not current.closed then
            current.closed = true
            lastX, lastY = startX, startY
        end
    end
    return self
end

local function pathData(d, path)
    local i, n = 1, #d
    local function skip()
        i = d:find('[^%s,]', i) or n + 1
    end
    local function num()
        skip()
        local s, e = d:find('^[%+%-]?%d*%.?%d+[eE][%+%-]?%d+', i)
        if not s then s, e = d:find('^[%+%-]?%d*%.?%d+', i) end
        if not s then s, e = d:find('^[%+%-]?%d+%.', i) end
        if not s then return nil end
        i = e + 1
        return tonumber(d:sub(s, e))
    end
    local function flag()
        skip()
        local c = d:sub(i, i)
        if c ~= '0' and c ~= '1' then return nil end
        i = i + 1
        return c == '1'
    end
    local x, y, sx, sy = 0, 0, 0, 0
    local cx2, cy2, qx, qy, previous
    local command
    while true do
        skip()
        if i > n then break end
        local c = d:sub(i, i)
        if c:match('[MmLlHhVvCcSsQqTtAaZz]') then
            command = c
            i = i + 1
        elseif not command then
            break
        end
        local upper, relative = command:upper(), command:lower() == command
        local ox, oy = relative and x or 0, relative and y or 0
        if upper == 'Z' then
            path.close()
            x, y, previous, command = sx, sy, 'Z', nil
        elseif upper == 'M' then
            local a, b = num(), num()
            if not b then break end
            x, y = ox + a, oy + b
            sx, sy = x, y
            path.moveTo(x, y)
            command = relative and 'l' or 'L'
            previous = 'M'
        elseif upper == 'L' then
            local a, b = num(), num()
            if not b then break end
            x, y = ox + a, oy + b
            path.lineTo(x, y)
            previous = 'L'
        elseif upper == 'H' then
            local a = num()
            if not a then break end
            x = ox + a
            path.lineTo(x, y)
            previous = 'L'
        elseif upper == 'V' then
            local a = num()
            if not a then break end
            y = oy + a
            path.lineTo(x, y)
            previous = 'L'
        elseif upper == 'C' or upper == 'S' then
            local x1, y1
            if upper == 'C' then
                local a, b = num(), num()
                if not b then break end
                x1, y1 = ox + a, oy + b
            elseif previous == 'C' then
                x1, y1 = 2 * x - cx2, 2 * y - cy2
            else
                x1, y1 = x, y
            end
            local a, b, e, f = num(), num(), num(), num()
            if not f then break end
            cx2, cy2 = ox + a, oy + b
            x, y = ox + e, oy + f
            path.cubicTo(x1, y1, cx2, cy2, x, y)
            previous = 'C'
        elseif upper == 'Q' or upper == 'T' then
            if upper == 'Q' then
                local a, b = num(), num()
                if not b then break end
                qx, qy = ox + a, oy + b
            elseif previous == 'Q' then
                qx, qy = 2 * x - qx, 2 * y - qy
            else
                qx, qy = x, y
            end
            local a, b = num(), num()
            if not b then break end
            x, y = ox + a, oy + b
            path.quadTo(qx, qy, x, y)
            previous = 'Q'
        elseif upper == 'A' then
            local rx, ry, angle = num(), num(), num()
            local large, sweep = flag(), flag()
            local a, b = num(), num()
            if not b or large == nil or sweep == nil then break end
            x, y = ox + a, oy + b
            path.arcTo(rx, ry, angle, large, sweep, x, y)
            previous = 'A'
        end
    end
end

local KAPPA = 0.5522847498
local function ellipse(path, cx, cy, rx, ry)
    if rx <= 0 or ry <= 0 then return end
    local kx, ky = rx * KAPPA, ry * KAPPA
    path.moveTo(cx + rx, cy)
    path.cubicTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
    path.cubicTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
    path.cubicTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
    path.cubicTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
    path.close()
end

local function points(text, path, closed)
    local v = {}
    for n in (text or ''):gmatch('[%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*') do v[#v + 1] = tonumber(n) end
    if #v < 4 then return end
    path.moveTo(v[1], v[2])
    for i = 3, #v - 1, 2 do path.lineTo(v[i], v[i + 1]) end
    if closed then path.close() end
end

-- Builds the element's outline; returns false for elements that are not shapes.
local function shape(node, path, viewport)
    local a, w, h = node.attrs, viewport[1], viewport[2]
    local diagonal = sqrt((w * w + h * h) / 2)
    local tag = node.tag
    if tag == 'path' then
        pathData(a.d or '', path)
    elseif tag == 'rect' then
        local x, y = length(a.x, w, 0), length(a.y, h, 0)
        local rw, rh = length(a.width, w, 0), length(a.height, h, 0)
        if rw <= 0 or rh <= 0 then return true end
        local rx, ry = length(a.rx, w), length(a.ry, h)
        rx, ry = rx or ry or 0, ry or rx or 0
        rx, ry = min(max(rx, 0), rw / 2), min(max(ry, 0), rh / 2)
        if rx > 0 and ry > 0 then
            local kx, ky = rx * KAPPA, ry * KAPPA
            path.moveTo(x + rx, y)
            path.lineTo(x + rw - rx, y)
            path.cubicTo(x + rw - rx + kx, y, x + rw, y + ry - ky, x + rw, y + ry)
            path.lineTo(x + rw, y + rh - ry)
            path.cubicTo(x + rw, y + rh - ry + ky, x + rw - rx + kx, y + rh, x + rw - rx, y + rh)
            path.lineTo(x + rx, y + rh)
            path.cubicTo(x + rx - kx, y + rh, x, y + rh - ry + ky, x, y + rh - ry)
            path.lineTo(x, y + ry)
            path.cubicTo(x, y + ry - ky, x + rx - kx, y, x + rx, y)
        else
            path.moveTo(x, y)
            path.lineTo(x + rw, y)
            path.lineTo(x + rw, y + rh)
            path.lineTo(x, y + rh)
        end
        path.close()
    elseif tag == 'circle' then
        local r = length(a.r, diagonal, 0)
        ellipse(path, length(a.cx, w, 0), length(a.cy, h, 0), r, r)
    elseif tag == 'ellipse' then
        ellipse(path, length(a.cx, w, 0), length(a.cy, h, 0), length(a.rx, w, 0), length(a.ry, h, 0))
    elseif tag == 'line' then
        path.moveTo(length(a.x1, w, 0), length(a.y1, h, 0))
        path.lineTo(length(a.x2, w, 0), length(a.y2, h, 0))
    elseif tag == 'polyline' or tag == 'polygon' then
        points(a.points, path, tag == 'polygon')
    else
        return false
    end
    return true
end

---------------------------------------------------------------------------------------------------------------------
-- Strokes become filled outlines, all wound the same way so a nonzero fill unites them.

local function signedArea(poly)
    local area, n = 0, #poly
    for i = 1, n - 1, 2 do
        local j = i + 2 <= n and i + 2 or 1
        area = area + poly[i] * poly[j + 1] - poly[j] * poly[i + 1]
    end
    return area
end

local function addPoly(out, poly)
    if signedArea(poly) < 0 then
        local reversed = {}
        for i = #poly - 1, 1, -2 do reversed[#reversed + 1], reversed[#reversed + 2] = poly[i], poly[i + 1] end
        poly = reversed
    end
    out[#out + 1] = poly
end

local function circle(out, x, y, r)
    local steps = min(64, max(8, ceil(2 * pi * r / 2)))
    local poly = {}
    for i = 0, steps - 1 do
        local a = 2 * pi * i / steps
        poly[#poly + 1], poly[#poly + 2] = x + r * cos(a), y + r * sin(a)
    end
    addPoly(out, poly)
end

-- Splits polylines into dashes; `pattern` lengths are in pixels.
local function dash(polys, pattern, offset)
    local total = 0
    for _, v in ipairs(pattern) do total = total + v end
    if total <= 0 then return polys end
    local result = {}
    for _, poly in ipairs(polys) do
        local pts = {}
        for i = 1, #poly do pts[i] = poly[i] end
        if poly.closed and #pts >= 4 then pts[#pts + 1], pts[#pts + 2] = pts[1], pts[2] end
        local index, remaining, on = 1, nil, true
        local start = offset % total
        while start >= pattern[index] do
            start = start - pattern[index]
            index = index % #pattern + 1
            on = not on
        end
        remaining = pattern[index] - start
        local current = on and {pts[1], pts[2]} or nil
        for i = 1, #pts - 3, 2 do
            local x0, y0, x1, y1 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
            local len = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
            local done = 0
            while len - done > remaining do
                done = done + remaining
                local t = done / len
                local x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                if on then
                    current[#current + 1], current[#current + 2] = x, y
                    result[#result + 1] = current
                    current = nil
                else
                    current = {x, y}
                end
                on = not on
                index = index % #pattern + 1
                remaining = pattern[index]
            end
            remaining = remaining - (len - done)
            if on then current[#current + 1], current[#current + 2] = x1, y1 end
        end
        if on and current and #current >= 4 then result[#result + 1] = current end
    end
    return result
end

local function strokePolys(polys, width, join, cap, limit)
    local out, hw = {}, width / 2
    for _, poly in ipairs(polys) do
        local n = #poly / 2
        local closed = poly.closed and n > 2
        if n == 1 then
            if cap == 'round' then circle(out, poly[1], poly[2], hw)
            elseif cap == 'square' then
                addPoly(out, {poly[1] - hw, poly[2] - hw, poly[1] + hw, poly[2] - hw, poly[1] + hw, poly[2] + hw,
                    poly[1] - hw, poly[2] + hw})
            end
        else
            local segments = {}
            local count = closed and n or n - 1
            for i = 1, count do
                local j = i % n + 1
                local x0, y0, x1, y1 = poly[2 * i - 1], poly[2 * i], poly[2 * j - 1], poly[2 * j]
                local dx, dy = x1 - x0, y1 - y0
                local len = sqrt(dx * dx + dy * dy)
                if len > 0 then segments[#segments + 1] = {x0, y0, x1, y1, dx / len, dy / len} end
            end
            for k, s in ipairs(segments) do
                local x0, y0, x1, y1, ux, uy = s[1], s[2], s[3], s[4], s[5], s[6]
                if not closed and cap == 'square' then
                    if k == 1 then x0, y0 = x0 - ux * hw, y0 - uy * hw end
                    if k == #segments then x1, y1 = x1 + ux * hw, y1 + uy * hw end
                end
                local nx, ny = -uy * hw, ux * hw
                addPoly(out, {x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny})
            end
            local joins = closed and #segments or #segments - 1
            for k = 1, joins do
                local a, b = segments[k], segments[k % #segments + 1]
                local vx, vy = a[3], a[4]
                local cross = a[5] * b[6] - a[6] * b[5]
                if join == 'round' then
                    circle(out, vx, vy, hw)
                elseif abs(cross) > 1e-9 then
                    -- The outer side is the one turned away from the next segment.
                    local n1x, n1y, n2x, n2y = -a[6] * hw, a[5] * hw, -b[6] * hw, b[5] * hw
                    if n1x * b[5] + n1y * b[6] > 0 then n1x, n1y, n2x, n2y = -n1x, -n1y, -n2x, -n2y end
                    local mx, my = n1x + n2x, n1y + n2y
                    local ml = sqrt(mx * mx + my * my)
                    local cosHalf = ml / (2 * hw)
                    if join ~= 'bevel' and cosHalf > 0 and 1 / cosHalf <= limit then
                        local d = hw / cosHalf / ml
                        addPoly(out, {vx, vy, vx + n1x, vy + n1y, vx + mx * d, vy + my * d, vx + n2x, vy + n2y})
                    else
                        addPoly(out, {vx, vy, vx + n1x, vy + n1y, vx + n2x, vy + n2y})
                    end
                end
            end
            if not closed and cap == 'round' and #segments > 0 then
                circle(out, segments[1][1], segments[1][2], hw)
                circle(out, segments[#segments][3], segments[#segments][4], hw)
            end
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------------------------
-- Rasterising: scanline fill with exact horizontal coverage over SAMPLES rows per pixel, composited source-over into
-- premultiplied channels.

local function newCanvas(w, h)
    local n = w * h
    return {w = w, h = h, r = buffer(n), g = buffer(n), b = buffer(n), a = buffer(n), cov = buffer(w + 2),
        diff = buffer(w + 2)}
end

local function fill(canvas, polys, evenOdd, paint, alpha)
    local w, h = canvas.w, canvas.h
    local edges = {}
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, poly in ipairs(polys) do
        local n = #poly
        if n >= 6 then
            for i = 1, n - 1, 2 do
                local j = i + 2 <= n and i + 2 or 1
                local x0, y0, x1, y1 = poly[i], poly[i + 1], poly[j], poly[j + 1]
                if x0 < minX then minX = x0 end
                if x0 > maxX then maxX = x0 end
                if y0 < minY then minY = y0 end
                if y0 > maxY then maxY = y0 end
                if y0 ~= y1 then
                    local dir = 1
                    if y0 > y1 then x0, y0, x1, y1, dir = x1, y1, x0, y0, -1 end
                    edges[#edges + 1] = {y0, y1, x0, (x1 - x0) / (y1 - y0), dir}
                end
            end
        end
    end
    if #edges == 0 then return end
    local top, bottom = max(0, floor(minY)), min(h - 1, ceil(maxY))
    local left, right = max(0, floor(minX)), min(w - 1, ceil(maxX))
    if top > bottom or left > right then return end
    table.sort(edges, function(a, b) return a[1] < b[1] end)
    local cov, diff = canvas.cov, canvas.diff
    local R, G, B, A = canvas.r, canvas.g, canvas.b, canvas.a
    local solid = paint.solid
    local weight = 1 / SAMPLES
    local active, nextEdge = {}, 1
    local xs, ds = {}, {}
    local lo, hi = left, right + 1
    for py = top, bottom do
        while nextEdge <= #edges and edges[nextEdge][1] < py + 1 do
            active[#active + 1] = edges[nextEdge]
            nextEdge = nextEdge + 1
        end
        local k = 1
        while k <= #active do
            if active[k][2] <= py then
                active[k] = active[#active]
                active[#active] = nil
            else
                k = k + 1
            end
        end
        local touched = false
        for sample = 0, SAMPLES - 1 do
            local sy = py + (sample + 0.5) / SAMPLES
            local count = 0
            for _, e in ipairs(active) do
                if e[1] <= sy and sy < e[2] then
                    count = count + 1
                    local x, d = e[3] + (sy - e[1]) * e[4], e[5]
                    -- Insertion sort: there are few crossings per line.
                    local j = count - 1
                    while j >= 1 and xs[j] > x do
                        xs[j + 1], ds[j + 1] = xs[j], ds[j]
                        j = j - 1
                    end
                    xs[j + 1], ds[j + 1] = x, d
                end
            end
            local winding, spanStart = 0, nil
            for j = 1, count do
                local wasInside = evenOdd and winding % 2 == 1 or not evenOdd and winding ~= 0
                winding = winding + ds[j]
                local inside = evenOdd and winding % 2 == 1 or not evenOdd and winding ~= 0
                if inside and not wasInside then
                    spanStart = xs[j]
                elseif wasInside and not inside then
                    local xa, xb = max(spanStart, lo), min(xs[j], hi)
                    if xb > xa then
                        touched = true
                        local ia, ib = floor(xa), floor(xb)
                        if ia == ib then
                            cov[ia] = cov[ia] + (xb - xa) * weight
                        else
                            cov[ia] = cov[ia] + (ia + 1 - xa) * weight
                            diff[ia + 1] = diff[ia + 1] + weight
                            diff[ib] = diff[ib] - weight
                            cov[ib] = cov[ib] + (xb - ib) * weight
                        end
                    end
                end
            end
        end
        if touched then
            local running, row = 0, py * w
            for x = left, right do
                running = running + diff[x]
                local c = cov[x] + running
                cov[x], diff[x] = 0, 0
                if c > 1e-4 then
                    if c > 1 then c = 1 end
                    local sr, sg, sb, sa
                    if solid then
                        sr, sg, sb, sa = solid[1], solid[2], solid[3], solid[4]
                    else
                        sr, sg, sb, sa = paint.at(x + 0.5, py + 0.5)
                    end
                    sa = sa * c * alpha
                    if sa > 0 then
                        local i, keep = row + x, 1 - sa
                        R[i] = sr * sa + R[i] * keep
                        G[i] = sg * sa + G[i] * keep
                        B[i] = sb * sa + B[i] * keep
                        A[i] = sa + A[i] * keep
                    end
                end
            end
            cov[right + 1], diff[right + 1] = 0, 0
        end
        checkpoint()
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Paint servers

local function gradientChain(node, ids)
    local chain, seen = {}, {}
    while node and not seen[node] do
        seen[node] = true
        chain[#chain + 1] = node
        local href = node.attrs.href
        node = href and ids[href:match('^#(.+)$') or '']
    end
    return chain
end

local function gradientPaint(node, ctx, bounds, m, viewport)
    local chain = gradientChain(node, ctx.ids)
    local function attr(name)
        for _, n in ipairs(chain) do
            if n.attrs[name] then return n.attrs[name] end
        end
    end
    local stops
    for _, n in ipairs(chain) do
        for _, child in ipairs(n.children) do
            if child.tag == 'stop' then
                stops = stops or {}
                local style = ownStyle(child, ctx.rules)
                local r, g, b, a = parseColour(style['stop-color'] or 'black', style.color)
                local offset = fraction(child.attrs.offset, 0)
                if #stops > 0 then offset = max(offset, stops[#stops][1]) end
                stops[#stops + 1] = {offset, r or 0, g or 0, b or 0, (a or (r and 1 or 0)) *
                    fraction(style['stop-opacity'], 1)}
            end
        end
        if stops then break end
    end
    if not stops then return nil end
    if #stops == 1 then
        local s = stops[1]
        return {solid = {s[2], s[3], s[4], s[5]}}
    end
    local radial = node.tag == 'radialGradient'
    local userSpace = attr('gradientUnits') == 'userSpaceOnUse'
    local vw, vh = viewport[1], viewport[2]
    local function coord(name, default, reference)
        local value = attr(name)
        if userSpace then return length(value, reference, default * reference) end
        return value and (value:find('%%') and (tonumber(value:match('[%d%.%-eE%+]+')) or 0) / 100
            or tonumber(value)) or default
    end
    local space = m
    if not userSpace then
        local bw, bh = bounds.maxX - bounds.minX, bounds.maxY - bounds.minY
        if bw <= 0 or bh <= 0 then
            local s = stops[#stops]
            return {solid = {s[2], s[3], s[4], s[5]}}
        end
        space = multiply(space, {bw, 0, 0, bh, bounds.minX, bounds.minY})
    end
    space = multiply(space, M.parseTransform(attr('gradientTransform')))
    local inverse = invert(space)
    if not inverse then return nil end
    local lut = {}
    local segment = 1
    for i = 0, 255 do
        local t = i / 255
        while segment < #stops - 1 and t > stops[segment + 1][1] do segment = segment + 1 end
        local a, b = stops[segment], stops[segment + 1]
        local f = 0
        if t <= a[1] then f = 0 elseif t >= b[1] then f = 1 elseif b[1] > a[1] then f = (t - a[1]) / (b[1] - a[1]) end
        if t < stops[1][1] then a, b, f = stops[1], stops[1], 0 end
        if t > stops[#stops][1] then a, b, f = stops[#stops], stops[#stops], 0 end
        lut[i] = {a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f,
            a[5] + (b[5] - a[5]) * f}
    end
    local spread = attr('spreadMethod') or 'pad'
    local function wrap(t)
        if spread == 'repeat' then
            t = t - floor(t)
        elseif spread == 'reflect' then
            t = t % 2
            if t > 1 then t = 2 - t end
        end
        return t < 0 and 0 or t > 1 and 1 or t
    end
    local ia, ib, ic, id, ie, iff = inverse[1], inverse[2], inverse[3], inverse[4], inverse[5], inverse[6]
    local measure
    if radial then
        local cx, cy = coord('cx', 0.5, vw), coord('cy', 0.5, vh)
        local r = coord('r', 0.5, sqrt((vw * vw + vh * vh) / 2))
        if r <= 0 then
            local s = stops[#stops]
            return {solid = {s[2], s[3], s[4], s[5]}}
        end
        measure = function(u, v) return sqrt((u - cx) ^ 2 + (v - cy) ^ 2) / r end
    else
        local x1, y1, x2, y2 = coord('x1', 0, vw), coord('y1', 0, vh), coord('x2', 1, vw), coord('y2', 0, vh)
        local dx, dy = x2 - x1, y2 - y1
        local dd = dx * dx + dy * dy
        if dd <= 0 then
            local s = stops[#stops]
            return {solid = {s[2], s[3], s[4], s[5]}}
        end
        measure = function(u, v) return ((u - x1) * dx + (v - y1) * dy) / dd end
    end
    return {at = function(x, y)
        local c = lut[floor(wrap(measure(ia * x + ic * y + ie, ib * x + id * y + iff)) * 255 + 0.5)]
        return c[1], c[2], c[3], c[4]
    end}
end

local function resolvePaint(value, props, ctx, path, viewport, warn)
    if not value then return nil end
    value = trim(value)
    local ref, fallback = value:match('^url%(%s*[\'"]?#([^\'"%)]+)[\'"]?%s*%)%s*(.*)$')
    if ref then
        local node = ctx.ids[ref]
        if node and (node.tag == 'linearGradient' or node.tag == 'radialGradient') then
            return gradientPaint(node, ctx, path, path.m, viewport)
        end
        if node then warn(node.tag .. ' fills') end
        value = fallback ~= '' and fallback or 'none'
    end
    local r, g, b, a = parseColour(value, props.color)
    if not r then return nil end
    return {solid = {r, g, b, a}}
end

---------------------------------------------------------------------------------------------------------------------
-- Document

local containers = {g = true, a = true, switch = true}
local hidden = {defs = true, symbol = true, clipPath = true, mask = true, pattern = true, marker = true,
    linearGradient = true, radialGradient = true, style = true, title = true, desc = true, metadata = true,
    filter = true, script = true}
local unsupported = {text = 'text', image = 'embedded images', foreignObject = 'foreign objects'}

local function draw(node, m, inherited, opacity, ctx, viewport, depth)
    if depth > 32 then return end
    local props = computed(node, inherited, ctx.rules)
    if props.display == 'none' then return end
    local a = node.attrs
    if a.transform then m = multiply(m, M.parseTransform(a.transform)) end
    opacity = opacity * fraction(props.opacity, 1)
    if opacity <= 0 then return end
    for _, key in ipairs({'clip-path', 'mask', 'filter'}) do
        local value = a[key] or (node.attrs.style or ''):match(key .. '%s*:%s*([^;]+)')
        if value and trim(value) ~= 'none' then ctx.warn(key .. 's') end
    end
    local tag = node.tag
    if tag == 'svg' then
        local vw, vh = viewport[1], viewport[2]
        local w, h = length(a.width, vw, vw), length(a.height, vh, vh)
        local box = parseViewBox(a.viewBox)
        m = multiply(m, viewBoxTransform(box, length(a.x, vw, 0), length(a.y, vh, 0), w, h, a.preserveAspectRatio))
        viewport = box and {box[3], box[4]} or {w, h}
        for _, child in ipairs(node.children) do draw(child, m, props, opacity, ctx, viewport, depth + 1) end
    elseif containers[tag] then
        for _, child in ipairs(node.children) do draw(child, m, props, opacity, ctx, viewport, depth + 1) end
    elseif tag == 'use' then
        local target = ctx.ids[(a.href or ''):match('^#(.+)$') or '']
        if not target then return end
        m = multiply(m, {1, 0, 0, 1, length(a.x, viewport[1], 0), length(a.y, viewport[2], 0)})
        if target.tag == 'symbol' then
            local box = parseViewBox(target.attrs.viewBox)
            if box then
                local w, h = length(a.width, viewport[1], box[3]), length(a.height, viewport[2], box[4])
                m = multiply(m, viewBoxTransform(box, 0, 0, w, h, target.attrs.preserveAspectRatio))
            end
            local symbolProps = computed(target, props, ctx.rules)
            for _, child in ipairs(target.children) do
                draw(child, m, symbolProps, opacity, ctx, viewport, depth + 1)
            end
        else
            draw(target, m, props, opacity, ctx, viewport, depth + 1)
        end
    elseif unsupported[tag] then
        ctx.warn(unsupported[tag])
    elseif not hidden[tag] then
        checkpoint()
        local path = newPath(m)
        if not shape(node, path, viewport) or #path.polys == 0 then return end
        if props.visibility == 'hidden' or props.visibility == 'collapse' then return end
        local fillPaint = resolvePaint(props.fill or 'black', props, ctx, path, viewport, ctx.warn)
        if fillPaint and tag ~= 'line' then
            ctx.fill(path.polys, props['fill-rule'] == 'evenodd', fillPaint,
                opacity * fraction(props['fill-opacity'], 1))
        end
        local strokePaint = resolvePaint(props.stroke, props, ctx, path, viewport, ctx.warn)
        local width = length(props['stroke-width'], sqrt((viewport[1] ^ 2 + viewport[2] ^ 2) / 2), 1) * path.scale
        if strokePaint and width > 0 then
            local polys = path.polys
            local pattern = {}
            for v in (props['stroke-dasharray'] or ''):gmatch('[^,%s]+') do
                local n = length(v, viewport[1], 0)
                if n < 0 then pattern = {}; break end
                pattern[#pattern + 1] = n * path.scale
            end
            if #pattern % 2 == 1 then
                for i = 1, #pattern do pattern[#pattern + 1] = pattern[i] end
            end
            if #pattern > 0 then
                polys = dash(polys, pattern, length(props['stroke-dashoffset'], viewport[1], 0) * path.scale)
            end
            ctx.fill(strokePolys(polys, width, props['stroke-linejoin'] or 'miter',
                props['stroke-linecap'] or 'butt', number(props['stroke-miterlimit'], 4)), false, strokePaint,
                opacity * fraction(props['stroke-opacity'], 1))
        end
    end
end

local function indexIds(node, ids, rules)
    if node.attrs.id and not ids[node.attrs.id] then ids[node.attrs.id] = node end
    if node.tag == 'style' and node.text then parseCSS(node.text, rules) end
    for _, child in ipairs(node.children) do indexIds(child, ids, rules) end
end

-- Intrinsic size of the document in CSS pixels; nil where it is not given.
local function intrinsic(svg)
    local box = parseViewBox(svg.attrs.viewBox)
    local w, h = length(svg.attrs.width, nil), length(svg.attrs.height, nil)
    if svg.attrs.width and svg.attrs.width:find('%%') then w = nil end
    if svg.attrs.height and svg.attrs.height:find('%%') then h = nil end
    if box then
        if w and not h then h = w * box[4] / box[3] end
        if h and not w then w = h * box[3] / box[4] end
        w, h = w or box[3], h or box[4]
    end
    return w, h, box
end

local function newContext(warnings)
    local seen = {}
    return {ids = {}, rules = {}, warn = function(what)
        if not seen[what] then seen[what], warnings[#warnings + 1] = true, what end
    end}
end

-- Draws SVG source into an RGBA canvas whose longer side is `size` pixels. Returns the canvas and a list of
-- unsupported features met, or nil and an error.
function M.render(text, size)
    local document = M.parseXML(text)
    local svg
    for _, child in ipairs(document.children) do
        if child.tag == 'svg' then svg = child end
    end
    if not svg then return nil, 'no <svg> element' end
    local iw, ih, box = intrinsic(svg)
    local warnings = {}
    local ctx = newContext(warnings)
    indexIds(document, ctx.ids, ctx.rules)
    local props = computed(svg, {}, ctx.rules)
    local opacity = fraction(props.opacity, 1)
    if not box and not (iw and ih) then
        -- Without a viewBox or a full size, the image is framed by the drawing itself.
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local measure = newContext({})
        measure.ids, measure.rules = ctx.ids, ctx.rules
        measure.fill = function(polys)
            for _, poly in ipairs(polys) do
                for i = 1, #poly - 1, 2 do
                    minX, maxX = min(minX, poly[i]), max(maxX, poly[i])
                    minY, maxY = min(minY, poly[i + 1]), max(maxY, poly[i + 1])
                end
            end
        end
        local viewport = {iw or 300, ih or 150}
        for _, child in ipairs(svg.children) do draw(child, identity, props, opacity, measure, viewport, 1) end
        if maxX > minX and maxY > minY then
            box = {minX, minY, maxX - minX, maxY - minY}
            iw, ih = box[3], box[4]
        end
    end
    iw, ih = iw or 300, ih or 150
    if iw <= 0 or ih <= 0 then return nil, 'the image has no size' end
    size = size or M.size
    local scale = size / max(iw, ih)
    local w, h = max(1, floor(iw * scale + 0.5)), max(1, floor(ih * scale + 0.5))
    local canvas = newCanvas(w, h)
    ctx.fill = function(polys, evenOdd, paint, alpha) fill(canvas, polys, evenOdd, paint, alpha) end
    local m = box and viewBoxTransform(box, 0, 0, w, h, svg.attrs.preserveAspectRatio) or {scale, 0, 0, scale, 0, 0}
    local viewport = box and {box[3], box[4]} or {iw, ih}
    for _, child in ipairs(svg.children) do draw(child, m, props, opacity, ctx, viewport, 1) end
    return canvas, warnings
end

---------------------------------------------------------------------------------------------------------------------
-- PNG

local crcTable
local function crc32(s, crc)
    if not crcTable then
        crcTable = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) == 1 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
            end
            crcTable[i] = c
        end
    end
    crc = bit.bnot(crc or 0)
    for i = 1, #s do
        crc = bit.bxor(crcTable[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bnot(crc) % 4294967296
end
M.crc32 = crc32

local function u32(n)
    n = n % 4294967296
    return string.char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data)
    return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

-- Uncompressed zlib stream, for when CSP's compressor is unavailable.
local function stored(data)
    local parts, a, b = {'\120\1'}, 1, 0
    local n = #data
    for i = 1, n, 4096 do
        local piece = data:sub(i, min(n, i + 4095))
        for j = 1, #piece do
            a = (a + piece:byte(j)) % 65521
            b = (b + a) % 65521
        end
    end
    local pos = 1
    repeat
        local piece = data:sub(pos, pos + 65534)
        pos = pos + #piece
        local len = #piece
        parts[#parts + 1] = string.char(pos > n and 1 or 0, len % 256, floor(len / 256), (65535 - len) % 256,
            floor((65535 - len) / 256)) .. piece
    until pos > n
    parts[#parts + 1] = u32(b * 65536 + a)
    return table.concat(parts)
end

function M.png(canvas)
    local w, h = canvas.w, canvas.h
    local R, G, B, A = canvas.r, canvas.g, canvas.b, canvas.a
    local rows, bytes = {}, {}
    local unpack = table.unpack or unpack
    for y = 0, h - 1 do
        bytes[1] = 0
        local k = 1
        for x = 0, w - 1 do
            local i = y * w + x
            local a = A[i]
            if a > 0 then
                local inv = 1 / a
                bytes[k + 1] = min(255, floor(R[i] * inv * 255 + 0.5))
                bytes[k + 2] = min(255, floor(G[i] * inv * 255 + 0.5))
                bytes[k + 3] = min(255, floor(B[i] * inv * 255 + 0.5))
                bytes[k + 4] = min(255, floor(a * 255 + 0.5))
            else
                bytes[k + 1], bytes[k + 2], bytes[k + 3], bytes[k + 4] = 0, 0, 0, 0
            end
            k = k + 4
        end
        local parts = {}
        for s = 1, k, 4096 do parts[#parts + 1] = string.char(unpack(bytes, s, min(k, s + 4095))) end
        rows[#rows + 1] = table.concat(parts)
        checkpoint()
    end
    local raw = table.concat(rows)
    local zlib
    if rawget(_G, 'ac') and ac.compress and ac.CompressionType then
        -- A fast level: this runs in one go, so a high one would stall the frame.
        local packed = ac.compress(raw, ac.CompressionType.Zlib, 4)
        zlib = packed and packed:sub(6)
    end
    zlib = zlib or stored(raw)
    return '\137PNG\r\n\26\n' .. chunk('IHDR', u32(w) .. u32(h) .. '\8\6\0\0\0') .. chunk('IDAT', zlib)
        .. chunk('IEND', '')
end

---------------------------------------------------------------------------------------------------------------------
-- Cache

-- Returns the path of a PNG drawn from the SVG file at `source`, drawing it into `folder` if its content changed.
-- A second value lists features the image uses that were not drawn.
function M.cached(source, folder, size)
    size = size or M.size
    local text = io.load(source)
    if not text then return nil, 'could not read the file' end
    local base = (source:match('([^\\/]+)$') or 'image'):gsub('%.[^%.]*$', ''):gsub('[^%w%-_]', '_')
    local prefix = string.format('%s-%08x-', base, crc32(source:lower()))
    local target = string.format('%s\\%s%08x.png', folder, prefix, crc32(text .. '|' .. size))
    if io.fileExists(target) then return target end
    local canvas, warnings = M.render(text, size)
    if not canvas then return nil, warnings end
    io.createDir(folder)
    -- Earlier drawings of the same file are out of date.
    if io.scanDir then
        for _, file in ipairs(io.scanDir(folder, prefix .. '*.png') or {}) do io.deleteFile(folder .. '\\' .. file) end
    end
    if not io.save(target, M.png(canvas)) then return nil, 'could not write ' .. target end
    return target, #warnings > 0 and warnings or nil
end

-- M.cached spread over frames, spending about `budget` seconds (default 6 ms) per call. Returns false while
-- drawing; then the PNG path (and any warnings), or nil and an error.
local jobs = {}
function M.request(source, folder, size, budget)
    local job = jobs[source]
    if not job then
        job = coroutine.create(function() return M.cached(source, folder, size) end)
        jobs[source] = job
    end
    sliceEnd = os.clock() + (budget or 0.006)
    local ok, path, detail = coroutine.resume(job)
    sliceEnd = nil
    if coroutine.status(job) ~= 'dead' then return false end
    jobs[source] = nil
    if not ok then return nil, path end
    return path, detail
end

return M
