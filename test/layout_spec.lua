local t = require 'test.helper'
local describe, it, eq, near = t.describe, t.it, t.eq, t.near

local SCREEN = { x = 0, y = 0, w = 1440, h = 900 }

-- Returns the default appearance config with `overrides` applied.
local function appearance(overrides)
    local a = require('stackline.util').deepCopy(require('stackline.defaults').appearance)
    for k, v in pairs(overrides or {}) do a[k] = v end
    return a
end

-- Returns a minimal stack description with `n` windows covering `frame`.
local function stack(frame, n, focusedId, activeId)
    local windows = {}
    for i = 1, n do windows[i] = { id = i } end
    return {
        frame = { x = frame[1], y = frame[2], w = frame[3], h = frame[4] },
        windows = windows, focusedId = focusedId, activeId = activeId or focusedId or 1,
    }
end

describe('layout.compute', function()
    it('places a full-width stack on the left, clamped to the screen edge', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local g = layout.compute(stack({ 8, 40, 1424, 852 }, 3), appearance(), SCREEN)
        eq(g.side, 'left')
        eq(g.items[1].rect, { x = 0, y = 42, w = 32, h = 32 })
        near(g.items[2].rect.y, 42 + 32 * 1.2)
        near(g.items[3].rect.y, 42 + 2 * 32 * 1.2)
        eq(g.items[1].iconRect, { x = 4, y = 46, w = 24, h = 24 })
        near(g.radius, 32 / 3)
    end)

    it('places indicators outside the window when there is room', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local g = layout.compute(stack({ 100, 40, 500, 800 }, 2), appearance(), SCREEN)
        eq(g.side, 'left')
        eq(g.items[1].rect.x, 100 - 32 - 4)
    end)

    it('places a right-half stack on the right, clamped to the screen edge', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local g = layout.compute(stack({ 724, 40, 708, 852 }, 2), appearance(), SCREEN)
        eq(g.side, 'right')
        eq(g.items[1].rect.x, 1440 - 32)
        local roomy = layout.compute(stack({ 724, 40, 600, 852 }, 2), appearance(), SCREEN)
        eq(roomy.items[1].rect.x, 724 + 600 + 4)
    end)

    it('clamps relative to a secondary screen with a negative origin', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local screen = { x = -1920, y = -300, w = 1920, h = 1080 }
        local left = layout.compute(stack({ -1912, -260, 940, 1032 }, 2), appearance(), screen)
        eq(left.side, 'left')
        eq(left.items[1].rect.x, -1920)
        local right = layout.compute(stack({ -964, -260, 956, 1032 }, 2), appearance(), screen)
        eq(right.side, 'right')
        eq(right.items[1].rect.x, -32)
    end)

    it('uses thin pills with a literal radius when icons are off', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local g = layout.compute(stack({ 100, 40, 500, 800 }, 2), appearance({ showIcons = false }), SCREEN)
        near(g.items[1].rect.w, 32 / 6)
        eq(g.radius, 3)
    end)

    it('pads the canvas for shadows but keeps it on the stack screen', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local g = layout.compute(stack({ 100, 40, 500, 800 }, 2), appearance(), SCREEN)
        eq(g.bounds, { x = 64, y = 42, w = 32, h = 32 * 1.2 + 32 })
        eq(g.canvasFrame, { x = 40, y = 18, w = 80, h = 32 * 1.2 + 32 + 48 })
        local edge = layout.compute(stack({ 8, 40, 1424, 852 }, 2), appearance(), SCREEN)
        eq(edge.canvasFrame.x, 0, 'clipped at the screen edge')
    end)
end)

describe('layout styles', function()
    it('maps focus to the four indicator states', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local focused = stack({ 0, 0, 10, 10 }, 2, 1)
        eq(layout.stateFor(focused, 1), 'focused')
        eq(layout.stateFor(focused, 2), 'inactive')
        local unfocused = stack({ 0, 0, 10, 10 }, 2, nil, 2)
        eq(layout.stateFor(unfocused, 2), 'lastActive')
        eq(layout.stateFor(unfocused, 1), 'idle')
    end)

    it('reproduces the original alpha math', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local a = appearance()
        eq(layout.style(a, 'focused', 'left').fill, { white = 0.9, alpha = 1 })
        near(layout.style(a, 'inactive', 'left').fill.alpha, 1 / 2.5)
        near(layout.style(a, 'inactive', 'left').iconAlpha, 1 / 1.1)
        near(layout.style(a, 'lastActive', 'left').fill.alpha, 1 / (2.5 / 1.2))
        eq(layout.style(a, 'lastActive', 'left').iconAlpha, 1)
        eq(layout.style(a, 'idle', 'left').fill.alpha, 0)
        near(layout.style(a, 'idle', 'left').iconAlpha, 1 / (1.1 * 1.7))
        eq(layout.style(appearance({ showIcons = false }), 'idle', 'left').fill.alpha, 0.2, 'pills stay visible (#85)')
        eq(a.color, { white = 0.9 }, 'the config color is never mutated')
    end)

    it('casts shadows towards the nearest screen edge', function()
        t.fresh()
        local layout = require 'stackline.layout'
        local a = appearance()
        local strong = layout.style(a, 'focused', 'left').shadow
        eq(strong.offset, { h = -3, w = -7 })
        eq(strong.blurRadius, 15)
        near(strong.color.alpha, 1 / 6)
        local soft = layout.style(a, 'idle', 'right').shadow
        eq(soft.offset, { h = -2, w = 6 })
        local pill = layout.style(appearance({ showIcons = false }), 'focused', 'right').shadow
        near(pill.offset.w, 7 / 5)
        near(pill.color.alpha, 1 / 30)
    end)
end)
