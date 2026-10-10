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
        local stacks, info = model.build({
            win(1, 0, FULL),
            win(2, 0, FULL),
            win(3, 1, { 700, 40, 700, 852 }),
        }, { tolerance = 30 })
        eq(#stacks, 0)
        eq(info.inconsistent, 1, 'a stacked window without partners looks mid-update')
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
        local stacks, info = model.build(windows, { tolerance = 30 })
        eq(#stacks, 3)
        eq(stacks[1].ids, { 1, 2 })
        eq(stacks[2].ids, { 3, 4 })
        eq(stacks[3].ids, { 5, 6 })
        eq(stacks[1].frame, { x = 8, y = 40, w = 700, h = 852 }, 'the smallest window approximates the node')
        eq(stacks[2].frame, { x = 716, y = 40, w = 716, h = 420 })
        eq(info.inconsistent, 0)

        local exact, exactInfo = model.build(windows, { tolerance = 0 })
        eq(#exact, 2, 'without tolerance the 1px offset splits stack 3/4')
        eq(exactInfo.inconsistent, 2, 'two lone windows')
    end)

    it('skips windows with degenerate frames', function()
        t.fresh()
        local model = require 'stackline.model'
        local nullFrame = win(4, 4, FULL)
        nullFrame.frame = { x = nil, y = 40, w = 1424, h = 852 } -- yabai printed inf/nan, decoded as null
        local stacks, info = model.build({
            win(1, 1, FULL), win(2, 2, { 0, 0, 0, 0 }), win(3, 3, FULL), nullFrame,
        }, { tolerance = 30 })
        eq(#stacks, 1)
        eq(stacks[1].ids, { 1, 3 })
        eq(info.inconsistent, 1, 'indexes 1, 3 have a gap')
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

local CHILD = { 8, 40, 700, 852 }     -- first child of a split
local PARENT = { 8, 40, 1424, 852 }   -- the parent's area: where zoom-parent puts the other child

describe('model.build with zoom, duplicates and focus', function()
    it('keeps a zoom-parent stack apart from the sibling stack whose origin it now shares', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks, info = model.build({
            -- front to back: the zoomed second child covers the parent area, its sibling sits behind
            win(3, 1, PARENT, { ['has-parent-zoom'] = true, ['has-focus'] = true }),
            win(4, 2, PARENT, { ['has-parent-zoom'] = true }),
            win(1, 1, CHILD),
            win(2, 2, CHILD),
        }, { tolerance = 30 })
        eq(#stacks, 2)
        eq(stacks[1].ids, { 3, 4 })
        eq(stacks[2].ids, { 1, 2 })
        eq(info.inconsistent, 0)
        eq(stacks[1].visible, true)
        eq(stacks[2].occluded, true, 'the zoomed stack covers its sibling')
        eq(stacks[2].visible, false)
    end)

    it('keeps zoom-fullscreen and unzoomed windows apart, also with yabai < 4.0 field names', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks = model.build({
            win(3, 1, PARENT, { ['has-fullscreen-zoom'] = true }),
            win(4, 2, PARENT, { ['has-fullscreen-zoom'] = true }),
            win(1, 1, PARENT),
            win(2, 2, PARENT),
            win(5, 1, { 8, 40, 700, 420 }, { space = 2, ['zoom-parent'] = 1 }),
            win(6, 2, { 8, 40, 700, 420 }, { space = 2, ['zoom-parent'] = 1 }),
            win(7, 1, { 8, 40, 700, 420 }, { space = 2 }),
            win(8, 2, { 8, 40, 700, 420 }, { space = 2 }),
        }, { tolerance = 30 })
        eq(#stacks, 4)
        eq(stacks[1].ids, { 3, 4 })
        eq(stacks[2].ids, { 1, 2 })
        eq(stacks[3].ids, { 5, 6 })
        eq(stacks[4].ids, { 7, 8 })
        eq(stacks[1].windows[1].zoomFullscreen, true)
        eq(stacks[3].windows[1].zoomParent, true)
    end)

    it('splits colliding stacks by size when stack indexes repeat', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks, info = model.build({
            win(3, 1, PARENT), win(4, 2, PARENT),
            win(1, 1, CHILD), win(2, 2, CHILD),
        }, { tolerance = 30 })
        eq(#stacks, 2)
        eq(stacks[1].ids, { 3, 4 })
        eq(stacks[2].ids, { 1, 2 })
        eq(info.inconsistent, 0)
    end)

    it('keeps only the front-most window for a stack index it cannot explain', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks, info = model.build({ win(1, 1, FULL), win(2, 1, FULL), win(3, 2, FULL) }, { tolerance = 30 })
        eq(#stacks, 1)
        eq(stacks[1].ids, { 1, 3 })
        eq(info.inconsistent, 1)
    end)

    it('keeps the frame of a stack with min-size windows independent of focus', function()
        t.fresh()
        local model = require 'stackline.model'
        local narrow, wide = { 8, 40, 700, 852 }, { 8, 40, 760, 852 }
        local a = model.build({ win(2, 2, wide, { ['has-focus'] = true }), win(1, 1, narrow) }, { tolerance = 30 })
        local b = model.build({ win(1, 1, narrow, { ['has-focus'] = true }), win(2, 2, wide) }, { tolerance = 30 })
        eq(a[1].frame, { x = 8, y = 40, w = 700, h = 852 })
        eq(b[1].frame, a[1].frame)
        eq(a[1].topId, 2)
        eq(b[1].topId, 1)
        eq(a[1].visible, true, "a stack's own windows never occlude it")
    end)

    it('counts lone windows and index gaps as inconsistent', function()
        t.fresh()
        local model = require 'stackline.model'
        local stacks, info = model.build({
            win(1, 1, CHILD), win(2, 3, CHILD),                     -- gap: 1, 3
            win(3, 1, { 716, 40, 716, 852 }),                       -- partner moved away mid re-layout
            win(4, 1, FULL, { space = 2 }), win(5, 2, FULL, { space = 2 }),
        }, { tolerance = 30 })
        eq(#stacks, 2)
        eq(info.inconsistent, 2)
    end)

    it('only trusts has-focus for the frontmost process', function()
        t.fresh()
        local model = require 'stackline.model'
        local windows = { win(1, 1, FULL), win(2, 2, FULL, { ['has-focus'] = true }) }
        local elsewhere = model.build(windows, { tolerance = 30, frontPid = 999 })
        eq(elsewhere[1].focusedId, nil, 'focus is in an app yabai does not track (e.g. Raycast)')
        eq(elsewhere[1].activeId, 1, 'the front-most window stays last-active')
        local here = model.build(windows, { tolerance = 30, frontPid = 1002 })
        eq(here[1].focusedId, 2)
        local unknown = model.build(windows, { tolerance = 30 })
        eq(unknown[1].focusedId, 2, 'no frontPid: trust yabai')
    end)
end)

describe('model occlusion', function()
    -- Returns the single stack built from a 2-window stack at FULL plus `others` (placed by `where`).
    local function build(others, front)
        local model = require 'stackline.model'
        local windows = { win(1, 1, FULL), win(2, 2, FULL) }
        for _, w in ipairs(others) do
            if front then table.insert(windows, 1, w) else windows[#windows + 1] = w end
        end
        return model.build(windows, { tolerance = 30 })[1]
    end

    it('hides a stack covered by a visible window in front of it', function()
        t.fresh()
        local stack = build({ win(9, 0, { 0, 0, 1440, 900 }) }, true) -- e.g. a maximized floating window
        eq(stack.occluded, true)
        eq(stack.visible, false)
    end)

    it('keeps a stack that is only partly covered', function()
        t.fresh()
        local stack = build({ win(9, 0, { 0, 0, 720, 900 }) }, true)
        eq(stack.occluded, nil)
        eq(stack.visible, true)
    end)

    it('ignores covering windows behind the stack', function()
        t.fresh()
        local stack = build({ win(9, 0, { 0, 0, 1440, 900 }) }, false)
        eq(stack.visible, true)
    end)

    it('ignores covering windows that are not visible or on another Space', function()
        t.fresh()
        local hidden = build({ win(9, 0, { 0, 0, 1440, 900 }, { ['is-visible'] = false }) }, true)
        eq(hidden.visible, true)
        local otherSpace = build({ win(9, 0, { 0, 0, 1440, 900 }, { space = 2 }) }, true)
        eq(otherSpace.visible, true)
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
