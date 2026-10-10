-- yabai signals that tell stackline when to refresh. They are registered under labels starting
-- with `stackline_`, so registering again replaces them instead of piling up duplicates.
local log   = require 'stackline.log'
local util  = require 'stackline.util'
local yabai = require 'stackline.yabai'

local signals = {}

signals.PREFIX = 'stackline_'

-- Hammerspoon message port the signal actions talk to (see signals.openPort).
signals.PORT = 'stackline'

-- Pass the focused window id so the highlight can move before the follow-up query returns.
signals.FOCUS_EVENTS = { 'window_focused' }

-- Only need a refresh.
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

-- Returns how many seconds ago the marker was created, or nil when there is none.
function signals.markerAge()
    local created = hs.fs.attributes(signals.markerPath(), 'change')
    if not created then return nil end
    return os.time() - created
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

-- Returns the action yabai runs for `message`: forward it to stackline's port unless a refresh
-- is already pending.
local function action(cli, marker, message)
    -- Bursts (e.g. resizing) collapse into one delivery: mkdir is atomic and fails while the marker
    -- exists, and stackline removes the marker when the refresh starts (so later events get
    -- through again). A failed delivery leaves the marker in place, which keeps a stopped or
    -- reloading Hammerspoon from being hammered; stackline clears stale markers itself.
    --
    -- hs flags: -m talks to stackline's own port (a reply-only handler, so the CLI skips Lua
    -- evaluation and print forwarding); -a exits quietly instead of prompting to launch
    -- Hammerspoon; -t 1 bounds the wait while Hammerspoon is busy; </dev/null because the CLI
    -- reads stdin when it is not a TTY.
    return ('/bin/mkdir %s 2>/dev/null && %s -m %s -a -q -t 1 -c "%s" </dev/null >/dev/null 2>&1')
        :format(util.shellQuote(marker), util.shellQuote(cli), signals.PORT, message)
end

-- Returns the signals stackline should have registered: a list of { label, event, action }.
function signals.desired(cli, marker)
    local list = {}
    for _, event in ipairs(signals.FOCUS_EVENTS) do
        list[#list + 1] = {
            label = signals.PREFIX .. event, event = event,
            action = action(cli, marker, event .. ' ${YABAI_WINDOW_ID:-0}'),
        }
    end
    for _, event in ipairs(signals.REFRESH_EVENTS) do
        list[#list + 1] = { label = signals.PREFIX .. event, event = event, action = action(cli, marker, event) }
    end
    return list
end

-- Returns the hs.ipc.localPort callback that turns `hs -m stackline -c "<event> [arg]"` messages
-- into `onEvent(event, arg)` calls.
function signals.portHandler(onEvent)
    return function(_, msgID, data)
        -- The CLI first probes the port (msgID 900); any reply that does not start with "version:"
        -- puts it in legacy mode, where each command arrives as msgID 0 with a one-byte prefix.
        if msgID == 0 and type(data) == 'string' and #data > 1 then
            local event, arg = data:sub(2):match('^%s*([%w_]+)%s*(%S*)')
            if event then
                local ok, err = pcall(onEvent, event, arg ~= '' and arg or nil)
                if not ok then log.e(('handling yabai signal %s failed: %s'):format(event, tostring(err))) end
            end
        end
        return ''
    end
end

-- Opens stackline's message port, calling `onEvent(event, arg)` for each forwarded signal.
-- Returns the hs.ipc port (delete() it when stopping), or nil when it could not be opened.
function signals.openPort(onEvent)
    local ok, ipc = pcall(require, 'hs.ipc')
    if not ok or not ipc or not ipc.localPort then
        log.e('hs.ipc is unavailable; yabai signals cannot reach stackline')
        return nil
    end
    local opened, port = pcall(ipc.localPort, signals.PORT, signals.portHandler(onEvent))
    if not opened or not port then
        log.e('could not open the "' .. signals.PORT .. '" message port: ' .. tostring(port))
        return nil
    end
    return port
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

-- Signal updates run one at a time, in request order, so e.g. stop() followed by init() cannot
-- end with the (older) removal finishing after the (newer) registration.
local queue, busy = {}, false

-- Starts the next queued sync when none is running.
local function pump()
    if busy or #queue == 0 then return end
    busy = true
    local job = table.remove(queue, 1)
    local function finish(ok, changed)
        busy = false
        if job.cb then
            local cbOk, err = pcall(job.cb, ok, changed)
            if not cbOk then log.e('signal sync callback failed: ' .. tostring(err)) end
        end
        pump()
    end

    yabai.listSignals(function(current, err)
        if not current then
            log.w('could not list yabai signals: ' .. tostring(err))
            return finish(false, 0)
        end
        local commands = signals.plan(current, job.desired)
        state.expected = #job.desired
        if #commands == 0 then
            state.registered, state.lastSync = #job.desired, hs.timer.secondsSinceEpoch()
            return finish(true, 0)
        end
        log.i(('updating %d yabai signal(s)'):format(#commands))
        runAll(commands, function(ok)
            state.registered = ok and #job.desired or 0
            state.lastSync = hs.timer.secondsSinceEpoch()
            finish(ok, #commands)
        end)
    end)
end

-- Makes yabai's stackline signals match `desired`; calls `cb(ok, changedCount)`.
function signals.sync(desired, cb)
    queue[#queue + 1] = { desired = desired, cb = cb }
    pump()
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
