local t = require 'test.helper'
local describe, it, eq, contains, excludes = t.describe, t.it, t.eq, t.contains, t.excludes

local CLI = '/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs'

-- Returns the desired signal with `label`.
local function find(list, label)
    for _, s in ipairs(list) do
        if s.label == label then return s end
    end
end

-- Runs `script` with /bin/sh and returns true on success.
local function sh(script)
    local ok = os.execute(script)
    return ok == true or ok == 0
end

-- Returns the content of file `path`, or '' when it does not exist.
local function read(path)
    local f = io.open(path)
    if not f then return '' end
    local text = f:read('a')
    f:close()
    return text
end

describe('signals.desired', function()
    it('forwards window_focused with the window id to stackline\'s port, never prompting', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local focus = find(signals.desired(CLI, '/tmp/T/stackline.pending'), 'stackline_window_focused')
        eq(focus.event, 'window_focused')
        contains(focus.action, "'" .. CLI .. "' -m stackline -a -q -t 1 -c \"window_focused ${YABAI_WINDOW_ID:-0}\"")
        contains(focus.action, '</dev/null')
        contains(focus.action, "/bin/mkdir '/tmp/T/stackline.pending' 2>/dev/null &&")
    end)

    it('collapses every signal through the marker and never removes it from the shell', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local desired = signals.desired(CLI, '/tmp/T/stackline.pending')
        eq(#desired, #signals.FOCUS_EVENTS + #signals.REFRESH_EVENTS)
        for _, s in ipairs(desired) do
            contains(s.action, "/bin/mkdir '/tmp/T/stackline.pending' 2>/dev/null && ")
            excludes(s.action, 'rmdir')
            excludes(s.action, 'stackline.onSignal', 'no Lua code is sent to Hammerspoon')
        end
        contains(find(desired, 'stackline_window_moved').action, '-c "window_moved"')
    end)

    it('produces actions that work in a real shell', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local q = require('stackline.util').shellQuote
        local dir = (os.getenv('TMPDIR') or '/tmp'):gsub('/$', '') .. ('/stackline-test-%d'):format(math.random(1e9))
        assert(sh('mkdir -p ' .. q(dir)))
        local cli = dir .. "/fake hs 'cli'" -- spaces and quotes must survive quoting
        local log = dir .. '/calls.log'
        local f = assert(io.open(cli, 'w'))
        f:write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a" >> "$CALL_LOG"; done\nexit ${FAKE_EXIT:-0}\n')
        f:close()
        assert(sh('chmod +x ' .. q(cli)))

        local marker = dir .. '/marker dir'
        local desired = signals.desired(cli, marker)
        local focus = find(desired, 'stackline_window_focused').action
        local moved = find(desired, 'stackline_window_moved').action
        -- yabai runs actions as `sh -c <action>` with YABAI_* variables in the environment.
        local function run(action, extraEnv)
            return sh(('%sCALL_LOG=%s YABAI_WINDOW_ID=4242 sh -c %s'):format(extraEnv or '', q(log), q(action)))
        end

        assert(run(focus))
        eq(read(log), '-m\nstackline\n-a\n-q\n-t\n1\n-c\nwindow_focused 4242\n')

        os.remove(log)
        run(moved)
        run(focus)
        eq(read(log), '', 'events are swallowed while a refresh is pending')
        eq(sh('test -d ' .. q(marker)), true)

        assert(sh('rmdir ' .. q(marker)))
        run(moved, 'FAKE_EXIT=1 ')
        eq(sh('test -d ' .. q(marker)), true, 'a failed delivery leaves the marker for stackline to clear')
        contains(read(log), 'window_moved')

        sh('rm -rf ' .. q(dir))
    end)
end)

describe('signals port', function()
    it('speaks the hs CLI legacy protocol', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local calls = {}
        local handler = signals.portHandler(function(event, arg) calls[#calls + 1] = { event, arg } end)
        local reply = handler(nil, 900, '1 + 1')
        eq(reply, '')
        t.falsy(reply:find('^version:'), 'anything but "version:" keeps the CLI in legacy mode')
        handler(nil, 0, 'xwindow_focused 42')
        handler(nil, 0, 'xwindow_moved')
        handler(nil, 0, 'x') -- the CLI's empty stdin
        handler(nil, 0, 'x$(rm -rf /)') -- not an event name: ignored
        eq(calls, { { 'window_focused', '42' }, { 'window_moved' } })
    end)

    it('logs handler errors instead of failing the CLI', function()
        local ctl = t.fresh()
        local signals = require 'stackline.signals'
        local handler = signals.portHandler(function() error('boom') end)
        eq(handler(nil, 0, 'xwindow_moved'), '')
        contains(ctl.logText('e'), 'boom')
    end)

    it('opens the stackline port once', function()
        local ctl = t.fresh()
        local signals = require 'stackline.signals'
        local received = {}
        local port = signals.openPort(function(event, arg) received[#received + 1] = event .. ':' .. tostring(arg) end)
        t.truthy(port)
        t.truthy(ctl.cli('stackline', 'window_focused 7'))
        eq(received, { 'window_focused:7' })
        eq(signals.openPort(function() end), nil, 'the name is taken while the first port is open')
        port:delete()
        t.truthy(signals.openPort(function() end), 'reopened after delete()')
    end)
end)

describe('signals.plan', function()
    it('adds missing signals, updates changed ones, removes stale ones and ignores foreign ones', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local desired = signals.desired(CLI, '/tmp/m')
        local current = {
            { label = 'stackline_window_focused', event = 'window_focused', action = find(desired, 'stackline_window_focused').action, app = '', title = '' },
            { label = 'stackline_window_moved', event = 'window_moved', action = 'old action' },
            { label = 'stackline_window_title_changed', event = 'window_title_changed', action = 'x' },
            { label = 'sketchybar_focus', event = 'window_focused', action = 'sketchybar --trigger x' },
            { label = '', event = 'window_destroyed', action = 'user script' },
        }
        local commands = signals.plan(current, desired)
        local adds, removes = {}, {}
        for _, c in ipairs(commands) do
            if c[3] == '--add' then adds[#adds + 1] = c[4] else removes[#removes + 1] = c[4] end
        end
        eq(#adds, #desired - 1)
        eq(removes, { 'stackline_window_title_changed' })
        local text = table.concat(adds, ' ')
        contains(text, 'label=stackline_window_moved')
        excludes(text, 'label=stackline_window_focused')
    end)

    it('is empty when everything is registered', function()
        t.fresh()
        local signals = require 'stackline.signals'
        local desired = signals.desired(CLI, '/tmp/m')
        local current = {}
        for i, d in ipairs(desired) do current[i] = { label = d.label, event = d.event, action = d.action, app = '', title = '' } end
        eq(signals.plan(current, desired), {})
    end)
end)

describe('signals.sync', function()
    it('lists signals, then applies all changes in one shell process', function()
        local ctl = t.fresh()
        local json = require 'test.json'
        local yabai = require 'stackline.yabai'
        local signals = require 'stackline.signals'
        yabai.setPath('/opt/homebrew/bin/yabai')
        local script
        ctl.taskHandler = t.yabai(function(path, args)
            if path == '/bin/sh' then script = args[2] return 0, '', '' end
            return 0, json.encode({ { label = 'stackline_old', event = 'window_moved', action = 'x' } }), ''
        end)
        local result
        signals.sync(signals.desired(CLI, '/tmp/m'), function(ok, changed) result = { ok, changed } end)
        ctl.flushTasks()
        eq(result, { true, #signals.FOCUS_EVENTS + #signals.REFRESH_EVENTS + 1 })
        contains(script, "'/opt/homebrew/bin/yabai' '-m' 'signal' '--add' 'label=stackline_window_focused'")
        contains(script, "'/opt/homebrew/bin/yabai' '-m' 'signal' '--remove' 'stackline_old'")
        contains(script, 'exit $failed')
        eq(signals.status().registered, #signals.FOCUS_EVENTS + #signals.REFRESH_EVENTS)
    end)

    it('runs signal updates one at a time, in request order', function()
        local ctl = t.fresh()
        local json = require 'test.json'
        local yabai = require 'stackline.yabai'
        local signals = require 'stackline.signals'
        yabai.setPath('/opt/homebrew/bin/yabai')
        local registered, log = {}, {}
        ctl.taskHandler = t.yabai(function(path, args)
            if path == '/bin/sh' then
                -- Apply the script to the fake yabai signal table.
                for label in args[2]:gmatch("'%-%-remove' '([^']+)'") do registered[label] = nil log[#log + 1] = '-' .. label end
                for label, event in args[2]:gmatch("'label=([^']+)' 'event=([^']+)'") do
                    registered[label] = { label = label, event = event, action = '?' }
                    log[#log + 1] = '+' .. label
                end
                return 0, '', ''
            end
            local list = {}
            for _, s in pairs(registered) do list[#list + 1] = s end
            return 0, json.encode(list), ''
        end)
        local desired = { { label = 'stackline_window_moved', event = 'window_moved', action = '?' } }
        signals.sync(desired)
        ctl.flushTasks()
        -- stop() then init(): the removal must finish before the registration starts.
        signals.removeAll()
        signals.sync(desired)
        ctl.flushTasks()
        eq(log, { '+stackline_window_moved', '-stackline_window_moved', '+stackline_window_moved' })
        t.truthy(registered.stackline_window_moved, 'signals end up registered')
    end)

    it('removeAll() removes only stackline signals', function()
        local ctl = t.fresh()
        local json = require 'test.json'
        local yabai = require 'stackline.yabai'
        local signals = require 'stackline.signals'
        yabai.setPath('/opt/homebrew/bin/yabai')
        local script
        ctl.taskHandler = t.yabai(function(path, args)
            if path == '/bin/sh' then script = args[2] return 0, '', '' end
            return 0, json.encode({
                { label = 'stackline_window_moved', event = 'window_moved', action = 'x' },
                { label = 'mine', event = 'window_moved', action = 'y' },
            }), ''
        end)
        signals.removeAll()
        ctl.flushTasks()
        contains(script, "'--remove' 'stackline_window_moved'")
        excludes(script, 'mine')
    end)
end)

describe('signals helpers', function()
    it('prefers the hs CLI bundled with Hammerspoon', function()
        local ctl = t.fresh()
        local signals = require 'stackline.signals'
        eq(signals.resolveCli('auto'), nil)
        ctl.files['/opt/homebrew/bin/hs'] = { mode = 'file' }
        eq(signals.resolveCli('auto'), '/opt/homebrew/bin/hs')
        ctl.files[CLI] = { mode = 'file' }
        eq(signals.resolveCli('auto'), CLI)
        ctl.files['/custom/hs'] = { mode = 'file' }
        eq(signals.resolveCli('/custom/hs'), '/custom/hs')
    end)

    it('keeps the marker in the per-user temporary directory and reports its age', function()
        local ctl = t.fresh()
        local signals = require 'stackline.signals'
        eq(signals.markerPath(), ctl.tmpdir .. 'stackline.pending')
        eq(signals.markerAge(), nil)
        ctl.files[signals.markerPath()] = { mode = 'directory', change = os.time() - 5 }
        t.truthy(signals.markerAge() >= 5)
        signals.clearMarker()
        eq(ctl.files[signals.markerPath()], nil)
    end)
end)
