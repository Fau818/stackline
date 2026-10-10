local t = require 'test.helper'
local describe, it, eq = t.describe, t.it, t.eq

local SCREENS = {
    { id = 1, frame = { x = 0, y = 0, w = 1440, h = 900 } },
    { id = 2, frame = { x = 1440, y = -200, w = 1920, h = 1080 } },
}

-- Returns a yabai window record (as decoded from `query --windows`).
local function win(id, stackIndex, frame, extra)
    local w = {
        id = id, pid = 1000 + id, app = 'App' .. id, space = 1,
        frame = { x = frame[1], y = frame[2], w = frame[3], h = frame[4] },
        ['stack-index'] = stackIndex, ['has-focus'] = false, ['is-visible'] = true,
    }
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end

local FULL = { 8, 40, 1424, 852 }

describe('model.build', function()
    it('builds one stack per layout-stack space, ordered by stack-index', function()
        t.fresh()
        local model = require 'stackline.model'
        -- yabai output is front-to-back: window 3 is on top.
        local stacks = model.build({
            win(3, 3, FULL),
            win(1, 1, FULL),
            win(2, 2, FULL, { ['has-focus'] = true }),
        }, { tolerance = 30, screens = SCREENS })
        eq(#stacks, 1)
        local s = stacks[1]
        eq(s.ids, { 1, 2, 3 })
        eq(s.topId, 3)
        eq(s.focusedId, 2)
        eq(s.activeId, 2)
        eq(s.visible, true)
        eq(s.screen.id, 1)
        eq(s.frame, { x = 8, y = 40, w = 1424, h = 852 })
    end)

    it('marks the front-most window as last-active when the stack is not focused', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks = model.build({ win(2, 2, FULL), win(1, 1, FULL) }, { tolerance = 30 })
        eq(stacks[1].focusedId, nil)
        eq(stacks[1].activeId, 2)
    end)

    it('ignores unstacked windows and lone clusters', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks = model.build({
            win(1, 0, FULL),
            win(2, 0, FULL),
            win(3, 1, { 700, 40, 700, 852 }),
        }, { tolerance = 30 })
        eq(#stacks, 0)
    end)

    it('separates stacks on different spaces even with identical frames', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks = model.build({
            win(1, 1, FULL), win(2, 2, FULL),
            win(3, 1, FULL, { space = 2, ['is-visible'] = false }),
            win(4, 2, FULL, { space = 2, ['is-visible'] = false }),
        }, { tolerance = 30 })
        eq(#stacks, 2)
        eq(stacks[1].visible, true)
        eq(stacks[2].visible, false)
        eq(stacks[2].space, 2)
    end)

    it('splits a bsp space into stacks by top-left corner, tolerating min-size windows', function()
        t.fresh()
        local model = require 'stackline.model'
        local windows = {
            win(1, 1, { 8, 40, 700, 852 }),
            win(2, 2, { 8, 40, 760, 852 }),     -- min-size app: wider, same origin
            win(3, 1, { 716, 40, 716, 420 }),
            win(4, 2, { 717, 41, 716, 420 }),   -- off by a pixel
            win(5, 1, { 716, 468, 716, 424 }),
            win(6, 2, { 716, 468, 716, 424 }),
        }
        local stacks = model.build(windows, { tolerance = 30 })
        eq(#stacks, 3)
        eq(stacks[1].ids, { 1, 2 })
        eq(stacks[2].ids, { 3, 4 })
        eq(stacks[3].ids, { 5, 6 })

        local exact = model.build(windows, { tolerance = 0 })
        eq(#exact, 2, 'without tolerance the 1px offset splits stack 3/4')
    end)

    it('skips windows with degenerate frames', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks = model.build({ win(1, 1, FULL), win(2, 2, { 0, 0, 0, 0 }), win(3, 3, FULL) }, { tolerance = 30 })
        eq(stacks[1].ids, { 1, 3 })
    end)

    it('understands yabai < 4.0 field names', function()
        t.fresh()
        local model = require 'stackline.model'
        local old = function(id, idx, focused)
            return {
                id = id, pid = id, app = 'A', space = 1, frame = { x = 0, y = 0, w = 10, h = 10 },
                ['stack-index'] = idx, focused = focused, visible = 1,
            }
        end
        local stacks = model.build({ old(1, 1, 0), old(2, 2, 1) })
        eq(stacks[1].focusedId, 2)
        eq(stacks[1].visible, true)
    end)

    it('attaches stacks to the screen containing their center', function()
        t.fresh()
        local model = require 'stackline.model'
        eq(model.screenFor({ x = 1500, y = 0, w = 800, h = 600 }, SCREENS).id, 2)
        eq(model.screenFor({ x = 1300, y = 0, w = 100, h = 600 }, SCREENS).id, 1)
        eq(model.screenFor({ x = 5000, y = 0, w = 100, h = 100 }, SCREENS).id, 1, 'off-screen falls back')
        eq(model.screenFor({ x = 0, y = 0, w = 1, h = 1 }, {}), nil)
    end)
end)

describe('model.match', function()
    it('pairs stacks by shared windows, regardless of order or space renumbering', function()
        t.fresh()
        local model = require 'stackline.model'
        local old = { { ids = { 1, 2 }, space = 1 }, { ids = { 3, 4, 5 }, space = 2 } }
        local new = {
            { ids = { 5, 4, 3, 6 }, space = 3 },
            { ids = { 9, 10 }, space = 1 },
            { ids = { 2, 1 }, space = 1 },
        }
        eq(model.match(old, new), { [1] = 2, [3] = 1 })
    end)

    it('gives a contested old stack to the new stack sharing the most windows', function()
        t.fresh()
        local model = require 'stackline.model'
        local old = { { ids = { 1, 2, 3, 4 } } }
        local new = { { ids = { 1, 9 } }, { ids = { 2, 3, 4 } } }
        eq(model.match(old, new), { [2] = 1 })
    end)
end)

describe('model.applyFocus', function()
    it('moves focus into a stack and keeps the last-active window of the stack it left', function()
        t.fresh()
        local model = require 'stackline.model'
        local a = { windows = { { id = 1 }, { id = 2 } }, focusedId = 1, activeId = 1 }
        local b = { windows = { { id = 3 }, { id = 4 } }, focusedId = nil, activeId = 4 }
        local changed = model.applyFocus({ a, b }, 3)
        eq(#changed, 2)
        eq(a.focusedId, nil)
        eq(a.activeId, 1)
        eq(b.focusedId, 3)
        eq(b.activeId, 3)

        changed = model.applyFocus({ a, b }, 999)
        eq(#changed, 1)
        eq(b.focusedId, nil)
        eq(b.activeId, 3)
        eq(#model.applyFocus({ a, b }, 999), 0, 'no-op when nothing changes')
    end)
end)
