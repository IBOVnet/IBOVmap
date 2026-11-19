-- presets.lua
-- Saved presets: every setting (map, style, classes and drivers) and, when the map is open, its window's position,
-- size and pinning. Kept in their own JSON file, as CSP's settings storage mangles long values containing apostrophes.
local M = {}
local Classes = require('classes')
local titles = {map = 'IBOVmap'}

function M.window(kind)
    for _, item in ipairs(ac.getAppWindows()) do
        if item.title == titles[kind] or item.name == titles[kind] then
            local window = ac.accessAppWindow(item.name)
            if window and window:valid() then return window end
        end
    end
end

local function finite(n)
    return type(n) == 'number' and n == n and math.abs(n) < math.huge
end

local function notify(message)
    ac.warn('IBOVmap: ' .. message)
    ui.toast(ui.Icons.Warning, message)
end

-- `onApply` runs after a preset's settings are in place; `file` is the presets JSON file.
function M.new(config, defaults, onApply, file)
    local self = {items = {}, selected = 0, name = '', overwrite = false}
    local function usable(item)
        return type(item) == 'table' and type(item.values) == 'table' and type(item.name) == 'string' and item.name ~= ''
    end
    local text = io.load(file)
    if text then
        local ok, parsed = pcall(JSON.parse, text)
        if ok and type(parsed) == 'table' then
            for _, item in ipairs(parsed) do
                if usable(item) then self.items[#self.items + 1] = item end
            end
            if #self.items ~= #parsed then
                ac.warn('IBOVmap: dropped ' .. (#parsed - #self.items) .. ' entries that are not presets')
            end
        else
            self.error = 'Saved presets could not be read from ' .. file .. '. Clear damaged presets below to enable saving.'
            ac.warn('IBOVmap: ' .. self.error .. ' ' .. tostring(parsed))
        end
    end

    function self:store()
        if not io.save(file, JSON.stringify(self.items), true) then notify('Could not write presets to ' .. file) end
    end

    function self:save()
        if self.error then notify(self.error); return end
        local name = self.name:match('^%s*(.-)%s*$')
        if name == '' then notify('Enter a preset name first.'); return end
        local index
        for i, item in ipairs(self.items) do
            if item.name == name then index = i; break end
        end
        if index and not self.overwrite then notify('Tick Allow overwrite to replace this preset.'); return end
        local item = {name = name, values = {}, geometry = {}}
        for key in pairs(defaults) do item.values[key] = config[key] end
        for kind in pairs(titles) do
            local window = M.window(kind)
            if window and window:visible() then
                local pos, size = window:position(), window:size()
                item.geometry[kind] = {x = pos.x, y = pos.y, w = size.x, h = size.y, pinned = window:pinned()}
            end
        end
        self.items[index or (#self.items + 1)] = item
        table.sort(self.items, function(a, b) return a.name:lower() < b.name:lower() end)
        for i, entry in ipairs(self.items) do if entry.name == name then self.selected = i end end
        self:store()
        self.overwrite = false
        ui.toast(ui.Icons.Confirm, 'Saved preset: ' .. name)
    end

    -- All or nothing: damaged classes or window geometry leave every setting as it was.
    function self:apply()
        local item = self.items[self.selected]
        if not item then notify('Select a preset first.'); return end
        if type(item.values) ~= 'table' or (item.geometry ~= nil and type(item.geometry) ~= 'table') then
            notify('This preset is damaged; no changes were applied.'); return
        end
        local values, skipped = {}, 0
        for key, value in pairs(item.values) do
            if defaults[key] ~= nil and type(value) == type(defaults[key])
                and (type(value) ~= 'number' or finite(value)) then
                values[key] = value
            else
                skipped = skipped + 1
            end
        end
        values.classDefinitions = item.values.classDefinitions
        if values.classDefinitions == nil then values.classDefinitions = defaults.classDefinitions end
        local classes, classError = Classes.decode(values.classDefinitions)
        if not classes then
            notify('Invalid preset classes; no changes were applied. ' .. classError); return
        end
        local geometry = item.geometry or {}
        for kind in pairs(titles) do
            local g = geometry[kind]
            if g ~= nil and (type(g) ~= 'table' or not finite(g.x) or not finite(g.y)
                or not finite(g.w) or not finite(g.h) or g.w <= 0 or g.h <= 0 or type(g.pinned) ~= 'boolean') then
                notify('Invalid preset window geometry; no changes were applied.'); return
            end
        end
        for key, value in pairs(values) do config[key] = value end
        for kind in pairs(titles) do
            local g, window = geometry[kind], M.window(kind)
            if g and window then
                window:resize(vec2(g.w, g.h))
                window:move(vec2(g.x, g.y))
                window:setPinned(g.pinned)
            end
        end
        onApply()
        if skipped > 0 then
            ac.warn('IBOVmap: preset ' .. item.name .. ' skipped ' .. skipped .. ' obsolete or invalid settings')
        end
        ui.toast(ui.Icons.Confirm, 'Applied preset: ' .. item.name)
    end

    function self:draw()
        ui.textWrapped('A preset holds every setting (map, style, classes and drivers) and, when the map is open, its '
            .. 'position, size and pinning. Referenced images and fonts are not copied. Presets are kept in presets.json '
            .. 'in this app\'s folder.')
        if self.error then
            ui.textWrapped(self.error)
            if ui.button('Clear damaged presets') then
                self.items, self.selected, self.error = {}, 0, nil
                self:store()
            end
            return
        end
        local names = {}
        for i, item in ipairs(self.items) do names[i] = item.name end
        self.selected = ui.combo('Saved preset', self.selected, ui.ComboFlags.None, names)
        if ui.button('Apply selected preset') then self:apply() end
        self.name = ui.inputText('Preset name', self.name)
        if ui.checkbox('Allow overwrite', self.overwrite) then self.overwrite = not self.overwrite end
        if ui.button('Save current settings and map position') then self:save() end
        local item = self.items[self.selected]
        if item and ui.button('Delete selected preset: ' .. item.name) then
            table.remove(self.items, self.selected)
            self.selected = math.min(self.selected, #self.items)
            self:store()
        end
        ui.separator()
        if ui.button('Recover map window to screen') then
            local window = M.window('map')
            if window then
                window:setVisible(true)
                window:move(vec2(100, 100))
            else
                notify('Open IBOVmap from the app sidebar first.')
            end
        end
    end

    return self
end

return M
