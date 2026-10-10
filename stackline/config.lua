-- Configuration manager: merges user overrides into the defaults, validates every value against a
-- schema, coerces strings coming from the `hs` CLI, and notifies listeners when values change.
local log  = require 'stackline.log'
local util = require 'stackline.util'

-- Value kinds ---------------------------------------------------------------------------------

local COLOR_KEYS = {
    red = true, green = true, blue = true, alpha = true, white = true,
    hue = true, saturation = true, brightness = true,
}

-- Returns a color table parsed from '#RRGGBB', '#RRGGBBAA' or '0xAARRGGBB', or nil.
local function parseHexColor(s)
    local hex = s:match('^#(%x+)$')
    local yabaiStyle = false
    if not hex then
        hex = s:match('^0[xX](%x+)$')
        yabaiStyle = true -- yabai & JankyBorders write colors as 0xAARRGGBB
    end
    if not hex or (#hex ~= 6 and #hex ~= 8) then return nil end

    local bytes = {}
    for byte in hex:gmatch('%x%x') do bytes[#bytes + 1] = tonumber(byte, 16) / 255 end
    if #bytes == 3 then return { red = bytes[1], green = bytes[2], blue = bytes[3], alpha = 1 } end
    if yabaiStyle then return { alpha = bytes[1], red = bytes[2], green = bytes[3], blue = bytes[4] } end
    return { red = bytes[1], green = bytes[2], blue = bytes[3], alpha = bytes[4] }
end

local BOOLEAN_WORDS = {
    ['true'] = true, yes = true, on = true, ['1'] = true,
    ['false'] = false, no = false, off = false, ['0'] = false,
}

-- Returns `value` as a boolean when it unambiguously names one, otherwise nil.
local function toBoolean(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    if type(value) == 'string' then return BOOLEAN_WORDS[util.trim(value):lower()] end
    return nil
end

-- Returns a number validator/coercer that also enforces `test` (with `desc` for error messages).
local function numberKind(desc, test)
    return {
        desc = desc,
        coerce = function(value)
            local n = tonumber(value)
            if n and util.isFinite(n) and test(n) then return n end
        end,
    }
end

-- Returns an enum kind accepting only the given values (booleans may arrive as strings from the CLI).
local function enumKind(values)
    local names = {}
    for _, v in ipairs(values) do names[#names + 1] = tostring(v) end
    return {
        desc = 'one of: ' .. table.concat(names, ', '),
        coerce = function(value)
            local candidates = { value }
            if type(value) == 'string' then candidates[2] = toBoolean(value) end
            for _, candidate in ipairs(candidates) do
                for _, v in ipairs(values) do
                    if candidate == v then return v end
                end
            end
        end,
    }
end

local KINDS = {
    number      = numberKind('a number', function() return true end),
    positive    = numberKind('a number greater than 0', function(n) return n > 0 end),
    nonnegative = numberKind('a number >= 0', function(n) return n >= 0 end),
    fraction    = numberKind('a number between 0 and 1', function(n) return n >= 0 and n <= 1 end),

    boolean = {
        desc = 'a boolean',
        coerce = toBoolean,
    },

    string = {
        desc = 'a non-empty string',
        coerce = function(value)
            if type(value) == 'string' and util.trim(value) ~= '' then return util.trim(value) end
        end,
    },

    color = {
        desc = "a color table such as { white = 0.9 } or a hex string such as '#e6e6e6'",
        coerce = function(value)
            if type(value) == 'string' then return parseHexColor(util.trim(value)) end
            if type(value) ~= 'table' or next(value) == nil then return nil end
            for k, v in pairs(value) do
                if not (COLOR_KEYS[k] and type(v) == 'number') and not (k == 'hex' and type(v) == 'string') then
                    return nil
                end
            end
            return util.deepCopy(value)
        end,
    },

    windowLevel = {
        desc = 'a name from hs.canvas.windowLevels (e.g. "floating") or an integer level',
        coerce = function(value)
            local levels = hs.canvas and hs.canvas.windowLevels or {}
            if math.type(tonumber(value)) == 'integer' then return math.tointeger(tonumber(value)) end
            if type(value) == 'string' and levels[util.trim(value)] ~= nil then return util.trim(value) end
        end,
    },

    winTitles         = enumKind({ true, false, 'when_switching', 'not_implemented' }),
    dynamicLuminosity = enumKind({ true, false, 'not_implemented' }),
}

-- Schema: nested tables mirror the config layout; strings name the kind of each leaf.
local SCHEMA = {
    paths = {
        yabai = 'string',
        hs    = 'string',
    },
    appearance = {
        color        = 'color',
        alpha        = 'fraction',
        dimmer       = 'positive',
        iconDimmer   = 'positive',
        showIcons    = 'boolean',
        size         = 'positive',
        radius       = 'positive',
        iconPadding  = 'nonnegative',
        pillThinness = 'positive',
        vertSpacing  = 'nonnegative',
        offset       = { x = 'number', y = 'number' },
        shouldFade   = 'boolean',
        fadeDuration = 'nonnegative',
        windowLevel  = 'windowLevel',
    },
    features = {
        clickToFocus      = 'boolean',
        yabaiSignals      = 'boolean',
        fzyFrameDetect    = { enabled = 'boolean', fuzzFactor = 'nonnegative' },
        hsBugWorkaround   = 'boolean',
        winTitles         = 'winTitles',
        dynamicLuminosity = 'dynamicLuminosity',
    },
    advanced = {
        maxRefreshRate = 'nonnegative',
    },
}

-- Helpers -------------------------------------------------------------------------------------

-- Returns the list of segments in a dot-separated path such as 'appearance.offset.x'.
local function segments(path)
    local list = {}
    for segment in tostring(path):gmatch('[^%.]+') do list[#list + 1] = segment end
    return list
end

-- Returns the schema node (a kind name or a nested table) at `path`, or nil when the path is unknown.
local function schemaAt(path)
    local node = SCHEMA
    for _, segment in ipairs(segments(path)) do
        if type(node) ~= 'table' then return nil end
        node = node[segment]
        if node == nil then return nil end
    end
    return node
end

-- Returns every valid leaf path, sorted, e.g. { 'advanced.maxRefreshRate', 'appearance.alpha', ... }.
local function leafPaths()
    local paths = {}
    local function walk(node, prefix)
        for key, child in pairs(node) do
            if type(child) == 'table' then walk(child, prefix .. key .. '.')
            else paths[#paths + 1] = prefix .. key end
        end
    end
    walk(SCHEMA, '')
    table.sort(paths)
    return paths
end

-- Returns a message for an unknown path, including the closest valid path when there is one.
local function unknownPathMessage(path)
    local suggestion = util.closest(path, leafPaths())
    return suggestion
        and ('unknown config key "%s" (did you mean "%s"?)'):format(path, suggestion)
        or ('unknown config key "%s"'):format(path)
end

-- Returns the coerced value for `kind`, or nil plus an error message when `value` is invalid.
local function coerce(kind, value, path)
    local coerced = KINDS[kind].coerce(value)
    if coerced == nil then
        return nil, ('invalid value for "%s": %s is not %s'):format(path, tostring(value), KINDS[kind].desc)
    end
    return coerced
end

-- Config objects -------------------------------------------------------------------------------

local Config = {}
Config.__index = Config

-- Returns a new config holding a copy of `defaults`.
function Config.new(defaults)
    local self = setmetatable({}, Config)
    self.defaults = util.deepCopy(defaults)
    self.conf = util.deepCopy(defaults)
    self.listeners = {}
    return self
end

-- Resets to the defaults and applies `overrides`; returns the list of problems found (empty when valid).
-- Invalid or unknown keys are reported and skipped, so the defaults stay in effect for them.
function Config:load(overrides)
    self.conf = util.deepCopy(self.defaults)
    local problems = {}

    local function merge(schemaNode, target, values, prefix)
        for key, value in pairs(values) do
            local path = prefix .. tostring(key)
            local kind = schemaNode[key]
            if kind == nil then
                problems[#problems + 1] = unknownPathMessage(path)
            elseif type(kind) == 'table' then
                if type(value) == 'table' then
                    merge(kind, target[key], value, path .. '.')
                else
                    problems[#problems + 1] = ('invalid value for "%s": expected a table'):format(path)
                end
            else
                local coerced, err = coerce(kind, value, path)
                if coerced == nil then problems[#problems + 1] = err else target[key] = coerced end
            end
        end
    end

    if overrides ~= nil and type(overrides) ~= 'table' then
        problems[#problems + 1] = 'stackline:init() expects a table of config overrides'
    elseif overrides then
        merge(SCHEMA, self.conf, overrides, '')
    end

    for _, problem in ipairs(problems) do log.e(problem) end
    return problems
end

-- Returns the whole (live) config table.
function Config:all()
    return self.conf
end

-- Returns the value at `path` (the whole config table when `path` is nil), or nil for unknown paths.
function Config:get(path)
    if path == nil then return self.conf end
    local node = self.conf
    for _, segment in ipairs(segments(path)) do
        if type(node) ~= 'table' or node[segment] == nil then
            log.w(unknownPathMessage(path))
            return nil
        end
        node = node[segment]
    end
    return node
end

-- Validates and stores `value` at `path`, then notifies listeners of changed leaves.
-- Returns the config object and the stored value (nil when rejected).
function Config:set(path, value)
    local kind = schemaAt(path)
    if kind == nil then
        log.e(unknownPathMessage(path))
        return self, nil
    end

    local changes = {}
    local function assign(node, schemaNode, key, val, fullPath)
        if type(schemaNode) == 'table' then
            if type(val) ~= 'table' then
                log.e(('invalid value for "%s": expected a table'):format(fullPath))
                return false
            end
            for childKey, childVal in pairs(val) do
                if schemaNode[childKey] == nil then
                    log.e(unknownPathMessage(fullPath .. '.' .. childKey))
                    return false
                end
                if not assign(node[key], schemaNode[childKey], childKey, childVal, fullPath .. '.' .. childKey) then
                    return false
                end
            end
            return true
        end
        local coerced, err = coerce(schemaNode, val, fullPath)
        if coerced == nil then
            log.e(err)
            return false
        end
        changes[#changes + 1] = { node = node, key = key, value = coerced, path = fullPath }
        return true
    end

    local parts = segments(path)
    local parent = self.conf
    for i = 1, #parts - 1 do parent = parent[parts[i]] end

    -- Validate everything first so a partially invalid table never half-applies.
    if not assign(parent, kind, parts[#parts], value, table.concat(parts, '.')) then return self, nil end

    for _, change in ipairs(changes) do
        local old = change.node[change.key]
        change.node[change.key] = change.value
        if type(old) == 'table' or old ~= change.value then self:emit(change.path, change.value, old) end
    end
    return self, self:get(path)
end

-- Flips the boolean at `path`; returns the config object and the new value (nil when not boolean).
function Config:toggle(path)
    local value = self:get(path)
    if type(value) ~= 'boolean' then
        log.w(('"%s" cannot be toggled because it is not a boolean'):format(path))
        return self, nil
    end
    return self:set(path, not value)
end

-- Sets `path` to `value` when a value is given, otherwise returns the current value.
function Config:getOrSet(path, value)
    if path ~= nil and value ~= nil then return self:set(path, value) end
    return self:get(path)
end

-- Registers `fn(path, new, old)` to run whenever a leaf at or below `prefix` changes.
function Config:onChange(prefix, fn)
    self.listeners[#self.listeners + 1] = { prefix = prefix, fn = fn }
end

-- Removes every change listener.
function Config:clearListeners()
    self.listeners = {}
end

-- Calls the listeners registered for `path` (or one of its parents).
function Config:emit(path, new, old)
    for _, listener in ipairs(self.listeners) do
        local p = listener.prefix
        if path == p or path:sub(1, #p + 1) == p .. '.' then
            local ok, err = pcall(listener.fn, path, new, old)
            if not ok then log.e(('config listener for "%s" failed: %s'):format(p, err)) end
        end
    end
end

-- Returns every valid config path, for autocompletion and suggestions.
function Config:keys()
    return leafPaths()
end

Config.parseHexColor = parseHexColor
Config.schema = SCHEMA

return Config
