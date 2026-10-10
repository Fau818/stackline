local t = require 'test.helper'
local describe, it, eq, contains = t.describe, t.it, t.eq, t.contains

-- Returns a config loaded with the real defaults plus `overrides`, and the problems found.
local function load(overrides)
    local Config = require 'stackline.config'
    local config = Config.new(require 'stackline.defaults')
    local problems = config:load(overrides)
    return config, problems
end

describe('config', function()
    it('uses the defaults when there are no overrides', function()
        local config, problems = load(nil)
        eq(problems, {})
        eq(config:get('appearance.size'), 32)
        eq(config:get('paths.yabai'), 'auto')
        eq(config:get('appearance.windowLevel'), 'floating')
        eq(config:get('advanced.maxRefreshRate'), 0.1)
    end)

    it('deep-merges partial overrides instead of replacing whole sections (#127)', function()
        local config = load({ appearance = { showIcons = false, offset = { x = 10 } } })
        eq(config:get('appearance.showIcons'), false)
        eq(config:get('appearance.offset.x'), 10)
        eq(config:get('appearance.offset.y'), 2, 'sibling keys keep their defaults')
        eq(config:get('appearance.size'), 32)
    end)

    it('replaces colors wholesale rather than mixing color models', function()
        local config = load({ appearance = { color = { red = 0.5, blue = 0, green = 0.2 } } })
        eq(config:get('appearance.color'), { red = 0.5, blue = 0, green = 0.2 })
    end)

    it('reports unknown and invalid keys, keeping defaults for them', function()
        local config, problems = load({
            appearance = { showIcon = false, size = -4, color = { purple = 1 } },
            feature = {},
        })
        eq(#problems, 4)
        local text = table.concat(problems, '\n')
        contains(text, 'did you mean "appearance.showIcons"')
        contains(text, 'invalid value for "appearance.size"')
        contains(text, 'invalid value for "appearance.color"')
        contains(text, 'unknown config key "feature"')
        eq(config:get('appearance.size'), 32)
        eq(config:get('appearance.showIcons'), true)
    end)

    it('accepts a Homebrew-prefix style yabai path as a plain string', function()
        local config = load({ paths = { yabai = '/opt/homebrew/opt/yabai' } })
        eq(config:get('paths.yabai'), '/opt/homebrew/opt/yabai')
    end)

    it('coerces CLI strings when setting values', function()
        local config = load(nil)
        local _, v = config:set('appearance.size', '40')
        eq(v, 40)
        config:set('appearance.showIcons', 'false')
        eq(config:get('appearance.showIcons'), false)
        config:set('features.winTitles', 'true')
        eq(config:get('features.winTitles'), true)
    end)

    it('parses hex colors, including yabai 0xAARRGGBB', function()
        local config = load(nil)
        config:set('appearance.color', '#ff0000')
        eq(config:get('appearance.color'), { red = 1, green = 0, blue = 0, alpha = 1 })
        config:set('appearance.color', '0x80000000')
        t.near(config:get('appearance.color').alpha, 128 / 255)
    end)

    it('rejects invalid sets without changing the value', function()
        local config = load(nil)
        local _, v = config:set('appearance.alpha', 3)
        eq(v, nil)
        eq(config:get('appearance.alpha'), 1)
        local _, v2 = config:set('appearance.nope', 1)
        eq(v2, nil)
    end)

    it('toggles booleans and refuses to toggle others', function()
        local config = load(nil)
        config:toggle('appearance.showIcons')
        eq(config:get('appearance.showIcons'), false)
        local _, v = config:toggle('appearance.size')
        eq(v, nil)
        eq(config:get('appearance.size'), 32)
    end)

    it('notifies listeners registered on a section prefix', function()
        local config = load(nil)
        local calls = {}
        config:onChange('appearance', function(path, new) calls[#calls + 1] = path .. '=' .. tostring(new) end)
        config:onChange('features.clickToFocus', function() calls[#calls + 1] = 'click' end)
        config:set('appearance.offset', { x = 7, y = 9 })
        config:set('appearance.size', 32) -- unchanged: no event
        config:toggle('features.clickToFocus')
        table.sort(calls)
        eq(calls, { 'appearance.offset.x=7', 'appearance.offset.y=9', 'click' })
    end)

    it('getOrSet reads without a value and writes with one', function()
        local config = load(nil)
        eq(config:getOrSet('appearance.radius'), 3)
        config:getOrSet('appearance.radius', 5)
        eq(config:get('appearance.radius'), 5)
    end)

    it('validates window levels against hs.canvas.windowLevels', function()
        local config = load({ appearance = { windowLevel = 'screenSaver' } })
        eq(config:get('appearance.windowLevel'), 'screenSaver')
        local _, problems = load({ appearance = { windowLevel = 'sky-high' } })
        eq(#problems, 1)
    end)
end)
