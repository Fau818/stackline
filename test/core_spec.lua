local t = require 'test.helper'
local json = require 'test.json'
local describe, it, eq, contains = t.describe, t.it, t.eq, t.contains

local YABAI = '/opt/homebrew/bin/yabai'
local SOCKET = '/tmp/yabai_' .. os.getenv('USER') .. '.socket'
local LEFT = { 8, 40, 700, 852 }
local RIGHT = { 716, 40, 716, 852 }

-- Returns a yabai window record.
local function win(id, pid, index, frame, extra)
    local w = {
        id = id, pid = pid, app = 'App' .. pid, space = 1,
        frame = { x = frame[1] + 0.0, y = frame[2] + 0.0, w = frame[3] + 0.0, h = frame[4] + 0.0 },
        ['stack-index'] = index, ['has-focus'] = false, ['is-visible'] = true,
        ['has-parent-zoom'] = false, ['has-fullscreen-zoom'] = false,
    }
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end

-- Sets up a machine running yabai 7.1.25 with one 3-window stack; returns ctl, world and stackline.
local function boot(overrides)
    local ctl = t.fresh()
    ctl.files[YABAI] = { mode = 'file' }
    ctl.files[SOCKET] = { mode = 'socket', ino = 11, change = 100 }
    ctl.files[ctl.frameworksPath .. '/hs/hs'] = { mode = 'file' }
    for pid = 501, 504 do
        ctl.apps[pid] = { name = 'App' .. pid, bundleID = 'com.example.app' .. pid, path = '/Applications/App' .. pid .. '.app', windows = { pid - 400 } }
    end
    ctl.frontPid = 502

    local world = {
        windows = {
            win(102, 502, 2, LEFT, { ['has-focus'] = true }),
            win(101, 501, 1, LEFT),
            win(103, 503, 3, LEFT),
            win(104, 504, 0, RIGHT),
        },
        signals = {},
        scripts = {},
        focused = {},
        queries = 0,
        version = 'yabai-v7.1.25\n',
    }
    ctl.taskHandler = t.yabai(function(path, args)
        if path == '/bin/sh' then
            world.scripts[#world.scripts + 1] = args[2]
            return 0, '', ''
        end
        if path ~= YABAI then return 1, '', 'unexpected binary ' .. path end
        if args[1] == '--version' then return 0, world.version, '' end
        if world.down then return 1, '', 'yabai-msg: failed to connect to socket..\n' end
        if args[2] == 'query' then
            world.queries = world.queries + 1
            return 0, json.encode(world.windows), ''
        end
        if args[2] == 'signal' and args[3] == '--list' then return 0, json.encode(world.signals), '' end
        if args[2] == 'window' and args[3] == '--focus' then
            world.focused[#world.focused + 1] = tonumber(args[4])
            return world.focusExit or 0, '', world.focusError or ''
        end
        return 0, '', ''
    end)

    local stackline = dofile(STACKLINE_ROOT .. '/init.lua')
    stackline:init(overrides)
    ctl.advance(0)
    return ctl, world, stackline
end

-- Returns the visual and click canvases currently on screen.
local function canvases(ctl)
    local visual, hit = {}, {}
    for _, c in ipairs(ctl.liveCanvases()) do
        if c.showing then
            if c.mouseCallbackFn then hit[#hit + 1] = c else visual[#visual + 1] = c end
        end
    end
    return visual, hit
end

-- Returns the app numbers of a visual canvas' icons, top to bottom.
local function iconOrder(canvas)
    local list = {}
    for _, e in ipairs(canvas.elements) do
        if e.type == 'image' then list[#list + 1] = e.image.source:match('App(%d+)%.app$') or e.image.source:match('app(%d+)$') end
    end
    return table.concat(list, ',')
end

describe('stackline (integration)', function()
    it('draws the current stacks, opens its port and registers yabai signals on init', function()
        local ctl, world, stackline = boot()
        local visual, hit = canvases(ctl)
        eq(#visual, 1)
        eq(#hit, 1)
        eq(iconOrder(visual[1]), '501,502,503')
        eq(ctl.ipcLoaded, true)
        eq(ctl.ports.stackline.valid, true, 'the stackline message port is open')
        eq(#world.scripts, 1)
        contains(world.scripts[1], "'label=stackline_window_focused'")
        contains(world.scripts[1], "'label=stackline_space_changed'")
        contains(world.scripts[1], '-m stackline')
        local status = stackline.status()
        contains(status, 'running = true')
        contains(status, 'version = "7.1.25"')
        contains(status, 'drawn = 1')
    end)

    it('moves the highlight on window_focused before the confirming query returns', function()
        local ctl, world = boot()
        local visual = canvases(ctl)[1]
        eq(visual.elements[3].fillColor.alpha, 1, '102 focused')
        local queries = world.queries

        t.truthy(ctl.cli('stackline', 'window_focused 103'), 'the signal action reaches the port')
        eq(visual.elements[5].fillColor.alpha, 1, '103 highlighted immediately')
        t.near(visual.elements[3].fillColor.alpha, 1 / 2.5)
        eq(world.queries, queries, 'no query has completed yet')

        world.windows[1]['has-focus'] = false
        world.windows[3]['has-focus'] = true
        ctl.frontPid = 503
        ctl.advance(0.2)
        eq(world.queries, queries + 1)
        eq(visual.elements[5].fillColor.alpha, 1)
        eq(#ctl.canvases, 2, 'focus changes never create canvases')
    end)

    it('dims the stack when focus leaves it, keeping the last-active window brighter', function()
        local ctl, _, stackline = boot()
        local visual = canvases(ctl)[1]
        stackline:onSignal('window_focused', '104')
        t.near(visual.elements[3].fillColor.alpha, 1 / (2.5 / 1.2), '102 is last active')
        eq(visual.elements[1].fillColor.alpha, 0)
    end)

    it('treats focus in an app yabai does not track as leaving the stack', function()
        local ctl, world = boot()
        local visual = canvases(ctl)[1]
        ctl.frontPid = 999 -- e.g. Raycast: yabai still reports 102 as focused
        ctl.fireAppEvent('Raycast', ctl.hs.application.watcher.activated, 999)
        ctl.advance(0.2)
        t.near(visual.elements[3].fillColor.alpha, 1 / (2.5 / 1.2), '102 shown as last active')
        ctl.frontPid = 502
        ctl.fireAppEvent('App502', ctl.hs.application.watcher.activated, 502)
        ctl.advance(0.2)
        eq(visual.elements[3].fillColor.alpha, 1)
        local queries = world.queries
        ctl.fireAppEvent('App502', ctl.hs.application.watcher.deactivated, 502)
        ctl.advance(0.2)
        eq(world.queries, queries, 'deactivation alone does not refresh')
    end)

    it('coalesces bursts of refresh signals and clears the marker', function()
        local ctl, world, stackline = boot()
        local signals = require 'stackline.signals'
        ctl.advance(1)
        local before = world.queries
        for _ = 1, 20 do
            ctl.files[signals.markerPath()] = { mode = 'directory', change = os.time() }
            stackline.onSignal('window_resized')
            ctl.advance(0.01)
        end
        ctl.advance(1)
        t.truthy(world.queries - before <= 3, 'at most one query per 0.1s interval, got ' .. (world.queries - before))
        eq(ctl.files[signals.markerPath()], nil, 'the marker is removed when a refresh starts')
    end)

    it('recovers from a stale signal marker', function()
        local ctl, world = boot()
        local signals = require 'stackline.signals'
        ctl.files[signals.markerPath()] = { mode = 'directory', change = os.time() - 10 }
        local queries = world.queries
        ctl.advance(5)
        eq(ctl.files[signals.markerPath()], nil)
        eq(world.queries, queries + 1)
    end)

    it('re-orders indicators after a swap inside the stack', function()
        local ctl, world, stackline = boot()
        -- `yabai -m window --swap stack.next` from 102: 102 and 103 trade places, focus moves to 103.
        world.windows[1]['stack-index'], world.windows[3]['stack-index'] = 3, 2
        world.windows[1]['has-focus'], world.windows[3]['has-focus'] = false, true
        ctl.frontPid = 503
        stackline.onSignal('window_focused', '103')
        ctl.advance(0.2)
        local visual = canvases(ctl)
        eq(#visual, 1)
        eq(iconOrder(visual[1]), '501,503,502')
        eq(#ctl.canvases, 2, 'the canvases are reused')
    end)

    it('leaves canvases of other Spaces alone and draws the new Space', function()
        local ctl, world = boot()
        local oldVisual = canvases(ctl)[1]
        for i = 1, 3 do world.windows[i]['is-visible'] = false end
        world.windows[#world.windows + 1] = win(105, 501, 1, LEFT, { space = 2 })
        world.windows[#world.windows + 1] = win(106, 502, 2, LEFT, { space = 2 })
        ctl.fireSpaceChange()
        ctl.advance(0.2)
        eq(oldVisual.showing, true, 'a shown canvas stays on its own Space')
        eq(oldVisual.deleted, false)
        local visual = canvases(ctl)
        eq(#visual, 2, 'plus the stack on the new Space')
    end)

    it('hides indicators of a stack covered by a zoomed window and restores them', function()
        local ctl, world = boot()
        local visual = canvases(ctl)[1]
        -- 104 (right half) is zoomed over the whole space and focused, covering the stack.
        world.windows[4] = win(104, 504, 0, { 8, 40, 1424, 852 }, { ['has-parent-zoom'] = true, ['has-focus'] = true })
        table.insert(world.windows, 1, table.remove(world.windows, 4))
        world.windows[2]['has-focus'] = false
        ctl.frontPid = 504
        ctl.cli('stackline', 'window_focused 104')
        ctl.advance(0.2)
        eq(visual.showing, false)
        table.insert(world.windows, table.remove(world.windows, 1))
        world.windows[4]['has-parent-zoom'] = false
        world.windows[4].frame = { x = 716.0, y = 40.0, w = 716.0, h = 852.0 }
        ctl.cli('stackline', 'window_moved')
        ctl.advance(0.2)
        eq(visual.showing, true)
    end)

    it('keeps what is drawn while yabai reports a half-updated layout, then catches up', function()
        local ctl, world, stackline = boot()
        local visual = canvases(ctl)[1]
        local before = visual.frameRect
        -- The stack is moving right: 103 already reports its new frame, the others not yet,
        -- so 103 shows up as a lone stacked window.
        local MOVED = { 300, 40, 600, 852 }
        world.windows[3] = win(103, 503, 3, MOVED)
        stackline.onSignal('window_moved')
        ctl.advance(0.15)
        eq(#visual.elements, 6, 'still drawn with three windows')
        eq(visual.frameRect, before, 'and where it was')

        world.windows[1] = win(102, 502, 2, MOVED, { ['has-focus'] = true })
        world.windows[2] = win(101, 501, 1, MOVED)
        ctl.advance(0.5)
        local now = canvases(ctl)
        eq(#now, 1)
        eq(#now[1].elements, 6)
        eq(now[1].frameRect.x, 300 - 32 - 4 - 24, 'the indicators followed the stack')
    end)

    it('gives up waiting after a few inconsistent snapshots', function()
        local ctl, world, stackline = boot()
        world.windows[3]['stack-index'] = 5 -- a gap yabai never resolves
        stackline.onSignal('window_destroyed')
        ctl.advance(2)
        eq(#canvases(ctl), 1)
        t.truthy(world.queries >= 4, 'retried before rendering')
    end)

    it('clears indicators when yabai stops and re-registers signals when it restarts', function()
        local ctl, world, stackline = boot()
        ctl.files[SOCKET] = nil
        world.down = true
        ctl.advance(5)
        eq(#canvases(ctl), 0)
        contains(stackline.status(), 'running = false')

        world.down = false
        ctl.files[SOCKET] = { mode = 'socket', ino = 12, change = 200 }
        ctl.advance(5)
        eq(#world.scripts, 2, 'signals registered again for the new yabai process')
        eq(#canvases(ctl), 1)
        contains(stackline.status(), 'running = true')
    end)

    it('hides indicators when queries fail to connect, and recovers on the next signal', function()
        local ctl, world, stackline = boot()
        world.down = true
        stackline.onSignal('window_moved')
        ctl.advance(0.2)
        eq(#canvases(ctl), 0)
        world.down = false
        stackline.onSignal('window_moved')
        ctl.advance(0.2)
        eq(#canvases(ctl), 1)
    end)

    it('focuses the clicked window through yabai, with a Hammerspoon fallback', function()
        local ctl, world = boot()
        local _, hit = canvases(ctl)
        ctl.click(hit[1], '101')
        ctl.advance(0)
        eq(world.focused, { 101 })
        eq(canvases(ctl)[1].elements[1].fillColor.alpha, 1, 'optimistic highlight')

        world.focusExit, world.focusError = 1, 'could not focus window'
        ctl.click(hit[1], '103')
        ctl.advance(0)
        eq(ctl.focusedWindows, { 103 })
    end)

    it('rebuilds indicators when the appearance changes', function()
        local ctl, _, stackline = boot()
        stackline.config:set('appearance.showIcons', false)
        ctl.advance(0.2)
        local visual = canvases(ctl)
        eq(#visual, 1)
        eq(#visual[1].elements, 3, 'pills only')
        stackline.config:toggle('features.clickToFocus')
        ctl.advance(0.2)
        local _, hit = canvases(ctl)
        eq(#hit, 0)
    end)

    it('polls while stacks exist when advanced.pollInterval is set', function()
        local ctl, world = boot({ advanced = { pollInterval = 2 } })
        local queries = world.queries
        ctl.advance(2)
        eq(world.queries, queries + 1)
        world.windows = {}
        ctl.advance(2)
        local afterEmpty = world.queries
        ctl.advance(10)
        eq(world.queries, afterEmpty, 'no polling without stacks')
    end)

    it('does not poll by default', function()
        local ctl, world = boot()
        local queries = world.queries
        ctl.advance(30)
        eq(world.queries, queries)
    end)

    it('stop() removes indicators, watchers, the port and yabai signals', function()
        local ctl, world, stackline = boot()
        world.signals = { { label = 'stackline_window_moved', event = 'window_moved', action = 'x' } }
        stackline:stop()
        ctl.advance(0)
        eq(#ctl.liveCanvases(), 0)
        contains(world.scripts[#world.scripts], "'--remove' 'stackline_window_moved'")
        for _, w in ipairs(ctl.spacesWatchers) do eq(w.active, false) end
        for _, w in ipairs(ctl.appWatchers) do eq(w.active, false) end
        eq(ctl.ports.stackline.valid, false)
        local queries = world.queries
        stackline.onSignal('window_moved')
        ctl.advance(10)
        eq(world.queries, queries, 'signals are ignored once stopped')

        stackline:init()
        ctl.advance(0)
        eq(#canvases(ctl), 1, 'can be started again')
        eq(ctl.ports.stackline.valid, true)
    end)

    it('ignores a second init() and keeps working', function()
        local ctl, _, stackline = boot()
        stackline:init({ appearance = { size = 99 } })
        eq(stackline.config:get('appearance.size'), 32)
        contains(ctl.logText('i'), 'already initialized')
    end)

    it('starts with a notification when yabai is missing', function()
        local ctl = t.fresh()
        local stackline = dofile(STACKLINE_ROOT .. '/init.lua')
        stackline.init()
        ctl.advance(10)
        eq(#ctl.notifications, 1)
        contains(ctl.notifications[1].title, 'cannot find yabai')
        eq(#ctl.liveCanvases(), 0)
    end)

    it('reports invalid config but still starts', function()
        local ctl, _, stackline = boot({ appearance = { size = 'huge' } })
        eq(#ctl.notifications, 1)
        contains(ctl.notifications[1].informativeText, 'appearance.size')
        eq(stackline.config:get('appearance.size'), 32)
        eq(#canvases(ctl), 1)
    end)

    it('skips signal registration when features.yabaiSignals is off', function()
        local _, world = boot({ features = { yabaiSignals = false } })
        eq(#world.scripts, 0)
    end)

    it('keeps old call styles working', function()
        local ctl, world, stackline = boot()
        local queries = world.queries
        stackline.manager:update({ forceRedraw = true })
        ctl.advance(0.2)
        eq(world.queries, queries + 1)
        stackline.refresh()
        ctl.advance(0.2)
        stackline:refresh(true)
        ctl.advance(0.2)
        eq(world.queries, queries + 3)
        stackline:setLogLevel('info')
        stackline.setLogLevel('warning')
    end)

    it('adds no globals besides `stackline`', function()
        t.fresh()
        local before = {}
        for k in pairs(_G) do before[k] = true end
        local stackline = dofile(STACKLINE_ROOT .. '/init.lua')
        stackline:init()
        stackline:stop()
        local added = {}
        for k in pairs(_G) do
            if not before[k] then added[#added + 1] = k end
        end
        eq(added, { 'stackline' })
    end)
end)
