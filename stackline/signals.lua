-- yabai signals that tell stackline when to refresh. They are registered under labels starting
-- with `stackline_`, so registering again replaces them instead of piling up duplicates.
local log   = require 'stackline.log'
local util  = require 'stackline.util'
local yabai = require 'stackline.yabai'

local signals = {}

signals.PREFIX = 'stackline_'

-- Passes the focused window id so the highlight can move before the follow-up query returns.
signals.FOCUS_EVENTS = { 'window_focused' }

-- Only need a refresh. Bursts (e.g. resizing) are collapsed: an event is forwarded only while no
-- refresh is pending, which a marker directory tracks without any extra processes.
signals.REFRESH_EVENTS = {
    'application_front_switched', -- focus moved to an app whose window yabai may not track
    'application_hidden', 'application_visible',
    'window_created', 'window_destroyed', 'window_moved', 'window_resized',
    'window_minimized', 'window_deminimized',
    'space_changed', 'mission_control_exit',
    'display_added', 'display_removed', 'display_moved', 'display_resized', 'display_changed',
    'system_woke', 'dock_did_restart',
}

local state = { registered = 0, expected = 0, lastSync = nil }

-- Returns the marker directory that is present while a forwarded refresh signal is pending.
function signals.markerPath()
    local dir = (hs.fs.temporaryDirectory and hs.fs.temporaryDirectory()) or '/tmp/'
    if dir:sub(-1) ~= '/' then dir = dir .. '/' end
    return dir .. 'stackline.pending'
end

-- Removes the marker so the next refresh signal is forwarded again.
function signals.clearMarker()
    hs.fs.rmdir(signals.markerPath())
end

-- Returns the `hs` CLI to call from signal actions, or nil when none exists.
-- The CLI bundled inside Hammerspoon.app works without running hs.ipc.cliInstall().
function signals.resolveCli(configured)
    local candidates = {}
    if configured and configured ~= 'auto' then candidates[#candidates + 1] = configured end
    local frameworks = hs.processInfo and hs.processInfo.frameworksPath
    if frameworks then candidates[#candidates + 1] = frameworks .. '/hs/hs' end
    candidates[#candidates + 1] = '/opt/homebrew/bin/hs'
    candidates[#candidates + 1] = '/usr/local/bin/hs'

    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path, 'mode') == 'file' then return path end
    end
    return nil
end

-- Returns the shell command that runs Lua `code` in Hammerspoon through the `hs` CLI at `cli`.
local function hsCommand(cli, code)
    -- -a: exit quietly instead of prompting "Hammerspoon is not running, launch it?"
    -- -q, -t 2: no console echo; give up after 2 s if Hammerspoon is busy.
    -- </dev/null: the CLI reads stdin when it is not a TTY; never let it wait on yabai's stdin.
    return ('%s -a -q -t 2 -c "%s" </dev/null >/dev/null 2>&1'):format(util.shellQuote(cli), code)
end

-- Returns the signals stackline should have registered: a list of { label, event, action }.
function signals.desired(cli, marker)
    local list = {}
    for _, event in ipairs(signals.FOCUS_EVENTS) do
        local code = ("if stackline then stackline.onSignal('%s', '$YABAI_WINDOW_ID') end"):format(event)
        list[#list + 1] = { label = signals.PREFIX .. event, event = event, action = hsCommand(cli, code) }
    end

    local m = util.shellQuote(marker)
    for _, event in ipairs(signals.REFRESH_EVENTS) do
        local code = ("if stackline then stackline.onSignal('%s') end"):format(event)
        -- mkdir is atomic: only the first event of a burst gets through; stackline removes the
        -- marker when the refresh starts, and the action removes it again if delivery failed.
        local action = ('/bin/mkdir %s 2>/dev/null && { %s || /bin/rmdir %s 2>/dev/null; }')
            :format(m, hsCommand(cli, code), m)
        list[#list + 1] = { label = signals.PREFIX .. event, event = event, action = action }
    end
    return list
end

-- Returns the yabai argument lists needed to turn `current` (from `signal --list`) into `desired`.
function signals.plan(current, desired)
    local have = {}
    for _, s in ipairs(current or {}) do
        if type(s) == 'table' and type(s.label) == 'string' and s.label:sub(1, #signals.PREFIX) == signals.PREFIX then
            have[s.label] = s
        end
    end

    local commands, wanted = {}, {}
    for _, d in ipairs(desired) do
        wanted[d.label] = true
        local s = have[d.label]
        local upToDate = s and s.event == d.event and s.action == d.action
            and (s.app or '') == '' and (s.title or '') == ''
        if not upToDate then
            commands[#commands + 1] = { '-m', 'signal', '--add', 'label=' .. d.label, 'event=' .. d.event, 'action=' .. d.action }
        end
    end
    for label in pairs(have) do
        if not wanted[label] then commands[#commands + 1] = { '-m', 'signal', '--remove', label } end
    end
    table.sort(commands, function(x, y) return table.concat(x, ' ') < table.concat(y, ' ') end)
    return commands
end

-- Runs yabai `commands` sequentially in one /bin/sh process; calls `cb(ok)`.
local function runAll(commands, cb)
    local bin = util.shellQuote(yabai.path())
    local lines = { 'failed=0' }
    for _, args in ipairs(commands) do
        local quoted = {}
        for i, arg in ipairs(args) do quoted[i] = util.shellQuote(arg) end
        lines[#lines + 1] = bin .. ' ' .. table.concat(quoted, ' ') .. ' >/dev/null || failed=1'
    end
    lines[#lines + 1] = 'exit $failed'
    yabai.spawn('/bin/sh', { '-c', table.concat(lines, '\n') }, function(ok, _, err)
        if not ok then log.w('some yabai signal commands failed: ' .. util.trim(err)) end
        if cb then cb(ok) end
    end, 15)
end

-- Makes yabai's stackline signals match `desired`; calls `cb(ok, changedCount)`.
function signals.sync(desired, cb)
    yabai.listSignals(function(current, err)
        if not current then
            log.w('could not list yabai signals: ' .. tostring(err))
            if cb then cb(false, 0) end
            return
        end
        local commands = signals.plan(current, desired)
        state.expected = #desired
        if #commands == 0 then
            state.registered, state.lastSync = #desired, hs.timer.secondsSinceEpoch()
            if cb then cb(true, 0) end
            return
        end
        log.i(('updating %d yabai signal(s)'):format(#commands))
        runAll(commands, function(ok)
            state.registered = ok and #desired or 0
            state.lastSync = hs.timer.secondsSinceEpoch()
            if cb then cb(ok, #commands) end
        end)
    end)
end

-- Removes every stackline signal from yabai; calls `cb(ok)`.
function signals.removeAll(cb)
    signals.sync({}, function(ok)
        state.registered, state.expected = 0, 0
        if cb then cb(ok) end
    end)
end

-- Returns { registered, expected, lastSync } from the latest sync.
function signals.status()
    return { registered = state.registered, expected = state.expected, lastSync = state.lastSync }
end

return signals
