-- Memory: Hammerspoon keeps hs.task / hs.timer callbacks in a registry that is a GC root, so a
-- callback that (indirectly) references its own task or timer keeps both alive forever. The mock
-- models that registry; these tests fail when such a cycle exists.
local t = require 'test.helper'
local json = require 'test.json'
local describe, it, eq = t.describe, t.it, t.eq

local YABAI = '/opt/homebrew/bin/yabai'

describe('memory', function()
    it('releases finished yabai commands', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath(YABAI)
        ctl.taskHandler = t.yabai(function() return 0, '[]', '' end)
        local baseline = ctl.liveRefs()
        for _ = 1, 50 do
            yabai.queryWindows(function() end)
            ctl.flushTasks()
        end
        eq(ctl.liveRefs(), baseline)
    end)

    it('releases timed-out yabai commands', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath(YABAI)
        ctl.taskHandler = t.yabai(function() return nil end)
        local baseline = ctl.liveRefs()
        for _ = 1, 10 do
            yabai.exec({ '-m', 'query', '--windows' }, function() end, 1)
            ctl.advance(1.5)
        end
        eq(ctl.liveRefs(), baseline)
    end)

    it('releases shell scripts run through yabai.spawn', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        ctl.taskHandler = function() return 0, '', '' end
        local baseline = ctl.liveRefs()
        for _ = 1, 20 do
            yabai.spawn('/bin/sh', { '-c', 'true' }, function() end)
            ctl.flushTasks()
        end
        eq(ctl.liveRefs(), baseline)
    end)

    it('releases fade-out timers once a stack disappears', function()
        local ctl = t.fresh()
        ctl.apps[501] = { name = 'A', path = '/Applications/A.app' }
        local Config = require 'stackline.config'
        local config = Config.new(require 'stackline.defaults')
        config:load()
        local model, render = require 'stackline.model', require 'stackline.render'
        local function win(id, index)
            return { id = id, pid = 501, app = 'A', space = 1, frame = { x = 8, y = 40, w = 700, h = 852 },
                ['stack-index'] = index, ['has-focus'] = false, ['is-visible'] = true }
        end
        local screens = { { id = 1, frame = { x = 0, y = 0, w = 1440, h = 900 } } }
        local baseline = ctl.liveRefs()
        for _ = 1, 5 do
            render.apply(model.build({ win(1, 1), win(2, 2) }, { tolerance = 30, screens = screens }), config:all(), function() end)
            render.apply({}, config:all(), function() end)
            ctl.advance(1)
        end
        eq(ctl.liveRefs(), baseline)
    end)

    it('keeps a steady footprint across many refreshes', function()
        local ctl = t.fresh()
        local socket = '/tmp/yabai_' .. os.getenv('USER') .. '.socket'
        ctl.files[YABAI] = { mode = 'file' }
        ctl.files[socket] = { mode = 'socket', ino = 1, change = 1 }
        ctl.files[ctl.frameworksPath .. '/hs/hs'] = { mode = 'file' }
        ctl.apps[501] = { name = 'A', path = '/Applications/A.app' }
        local windows = {}
        for i = 1, 3 do
            windows[i] = { id = 100 + i, pid = 501, app = 'A', space = 1, frame = { x = 8.0, y = 40.0, w = 700.0, h = 852.0 },
                ['stack-index'] = i, ['has-focus'] = i == 1, ['is-visible'] = true }
        end
        ctl.taskHandler = t.yabai(function(path, args)
            if path == '/bin/sh' then return 0, '', '' end
            if args[1] == '--version' then return 0, 'yabai-v7.1.25', '' end
            if args[2] == 'query' then return 0, json.encode(windows), '' end
            if args[2] == 'signal' then return 0, '[]', '' end
            return 0, '', ''
        end)
        local stackline = dofile(STACKLINE_ROOT .. '/init.lua')
        stackline:init()
        for _ = 1, 10 do
            stackline.refresh(true)
            stackline.onSignal('window_focused', '102')
            ctl.advance(0.2)
        end
        local warm = ctl.liveRefs()
        for _ = 1, 100 do
            stackline.refresh(true)
            stackline.onSignal('window_focused', '102')
            ctl.advance(0.2)
        end
        eq(ctl.liveRefs(), warm)
        stackline:stop()
    end)
end)
