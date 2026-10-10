-- stackline: visual indicators for yabai window stacks.
--
-- yabai is the source of truth: each refresh runs one `yabai -m query --windows` and reconciles
-- the indicators with the result. Refreshes are triggered by yabai signals (registered
-- automatically), Space/screen watchers, and indicator clicks.
local log       = require 'stackline.log'
local Config    = require 'stackline.config'
local defaults  = require 'stackline.defaults'
local model     = require 'stackline.model'
local render    = require 'stackline.render'
local Scheduler = require 'stackline.scheduler'
local signals   = require 'stackline.signals'
local yabai     = require 'stackline.yabai'

local HEALTH_INTERVAL = 5 -- seconds between checks that yabai is (still) running

local stackline = { version = '0.2.0' }
stackline.config = Config.new(defaults)

-- yabai signal actions call `stackline.onSignal(...)` through the `hs` CLI, which needs a global.
_G.stackline = stackline

local state = { initialized = false, stacks = {} }
local notified = {}

-- Returns monotonic time in seconds.
local function now()
    return hs.timer.absoluteTime() / 1e9
end

-- Shows a macOS notification for `key` at most once per Hammerspoon session.
local function notifyOnce(key, title, text)
    if notified[key] then return end
    notified[key] = true
    hs.notify.new(nil, { title = title, informativeText = text, withdrawAfter = 10 }):send()
end

-- Returns the call arguments with a leading `stackline` (from `stackline:fn()`) dropped, so
-- every public function works with both `:` and `.` call styles.
local function args(first, ...)
    if first == stackline then return ... end
    return first, ...
end

-- Returns every screen as { id, frame } using absolute full-frame coordinates.
local function screens()
    local list = {}
    for _, screen in ipairs(hs.screen.allScreens() or {}) do
        local f = screen:fullFrame()
        list[#list + 1] = { id = screen:id(), frame = { x = f.x, y = f.y, w = f.w, h = f.h } }
    end
    return list
end

-- Focuses the window behind a clicked indicator.
local function onClick(id)
    if not id or not state.initialized then return end
    if #model.applyFocus(state.stacks, id) > 0 then render.restyle(stackline.config:all()) end

    yabai.focusWindow(id, function(ok, err)
        if ok then return end
        log.w(('yabai could not focus window %d (%s); trying Hammerspoon'):format(id, tostring(err)))
        local _, win = model.find(state.stacks, id)
        local app = win and win.pid and hs.application.applicationForPID(win.pid)
        for _, w in ipairs(app and app:allWindows() or {}) do
            if w:id() == id then
                w:focus()
                return
            end
        end
    end)
end

-- Hides every indicator because yabai cannot be reached.
local function yabaiDown(reason)
    if state.yabaiUp ~= false then log.w('yabai is unavailable (' .. tostring(reason) .. '); hiding indicators') end
    state.yabaiUp = false
    state.stacks = {}
    render.clear(0)
end

-- Queries yabai and redraws whatever changed; calls `done()` when finished.
local function refresh(done)
    signals.clearMarker() -- signals after this point must trigger another refresh
    local started = now()

    yabai.queryWindows(function(windows, err)
        local ok, problem = xpcall(function()
            if not state.initialized then return end
            if not windows then
                state.lastError = err
                if yabai.isConnectionError(err) then yabaiDown(err) else log.w('yabai query failed: ' .. tostring(err)) end
                return
            end

            local cfg = stackline.config:all()
            local fuzzy = cfg.features.fzyFrameDetect
            state.yabaiUp, state.lastError = true, nil
            state.stacks = model.build(windows, {
                tolerance = fuzzy.enabled and fuzzy.fuzzFactor or 0,
                screens = screens(),
            })
            render.apply(state.stacks, cfg, onClick)
            state.lastRefresh = { duration = now() - started, windows = #windows, stacks = #state.stacks }
        end, debug.traceback)
        if not ok then log.e('refresh failed: ' .. tostring(problem)) end
        done()
    end)
end

-- Registers (or updates) stackline's yabai signals when the feature is enabled.
local function syncSignals()
    if not stackline.config:get('features.yabaiSignals') or not yabai.path() then return end
    local cli = signals.resolveCli(stackline.config:get('paths.hs'))
    if not cli then
        notifyOnce('hs-cli', 'stackline cannot find the hs CLI',
            'Indicators will only refresh on Space changes. Set paths.hs to the hs command line tool.')
        return
    end
    signals.sync(signals.desired(cli, signals.markerPath()))
end

-- Probes a (re)started yabai, registers signals and refreshes.
local function yabaiStarted()
    state.yabaiUp = true
    yabai.reset()
    yabai.probe(function(version)
        if not state.initialized then return end
        log.i(('using yabai %s at %s'):format(version and table.concat(version, '.') or '(unknown version)', yabai.path()))
        syncSignals()
        state.scheduler:request()
    end)
end

-- Finds yabai and notices when it starts, stops or restarts (signals do not survive a restart).
local function checkYabai()
    if not state.initialized then return end

    if not yabai.path() then
        local path, tried = yabai.resolve(stackline.config:get('paths.yabai'))
        if not path then
            if not state.yabaiMissing then
                state.yabaiMissing = true
                log.e('yabai not found; looked in: ' .. table.concat(tried or {}, ', '))
                notifyOnce('no-yabai', 'stackline cannot find yabai',
                    'Install yabai or set paths.yabai, e.g. stackline:init({ paths = { yabai = "/opt/homebrew/bin/yabai" } })')
            end
            return
        end
        state.yabaiMissing = nil
        yabai.setPath(path)
    end

    -- A restarted yabai recreates its socket, so a new inode means "re-register signals".
    local socket = hs.fs.attributes(yabai.socketPath())
    if not socket then
        if state.socketId or state.yabaiUp ~= false then yabaiDown('no socket at ' .. yabai.socketPath()) end
        state.socketId = nil
        return
    end
    local id = tostring(socket.ino) .. ':' .. tostring(socket.change)
    if id ~= state.socketId then
        state.socketId = id
        yabaiStarted()
    end
end

-- Wires configuration changes to the parts of stackline they affect.
local function watchConfig()
    local config = stackline.config
    local function redraw()
        render.invalidate()
        state.scheduler:request()
    end
    config:onChange('appearance', redraw)
    config:onChange('features.clickToFocus', redraw)
    config:onChange('features.fzyFrameDetect', function() state.scheduler:request() end)
    config:onChange('features.yabaiSignals', function(_, enabled)
        if enabled then syncSignals() elseif yabai.path() then signals.removeAll() end
    end)
    config:onChange('paths', function(path)
        if path == 'paths.hs' then return syncSignals() end
        yabai.setPath(nil)
        state.socketId = nil
        checkYabai()
    end)
end

-- Public API -----------------------------------------------------------------------------

-- Starts stackline with optional config overrides (see stackline/defaults.lua); returns stackline.
-- Calling it again while running does nothing; call stackline:stop() first to restart.
function stackline.init(...)
    local overrides = args(...)
    if state.initialized then
        log.i('stackline is already initialized')
        return stackline
    end
    local started = now()

    local problems = stackline.config:load(overrides)
    if #problems > 0 then
        notifyOnce('config', 'Invalid stackline config', table.concat(problems, '\n'))
    end

    -- The `hs` CLI used by yabai signals talks to Hammerspoon through hs.ipc.
    local ipcOk = pcall(require, 'hs.ipc')
    if not ipcOk then log.w('hs.ipc could not be loaded; yabai signals cannot reach stackline') end

    state = { initialized = true, stacks = {}, startedAt = started }
    state.scheduler = Scheduler.new({
        interval = function() return stackline.config:get('advanced.maxRefreshRate') end,
        run = refresh,
    })
    signals.clearMarker()
    watchConfig()

    -- In-process watchers are cheap and react without waiting for yabai's signals.
    local function request() state.scheduler:request() end
    state.watchers = {}
    if hs.spaces and hs.spaces.watcher then state.watchers[#state.watchers + 1] = hs.spaces.watcher.new(request):start() end
    if hs.screen and hs.screen.watcher then state.watchers[#state.watchers + 1] = hs.screen.watcher.new(request):start() end
    state.health = hs.timer.doEvery(HEALTH_INTERVAL, checkYabai)
    checkYabai()

    state.initDuration = now() - started
    log.i(('stackline %s initialized in %.1f ms'):format(stackline.version, state.initDuration * 1000))
    return stackline
end

-- Re-queries yabai and updates the indicators; `refresh(true)` also rebuilds every indicator.
-- Bind it to keys or yabai signals for actions yabai reports no event for.
function stackline.refresh(...)
    local force = args(...)
    if not state.initialized then return end
    if force then render.invalidate() end
    state.scheduler:request()
end

-- Handles a yabai signal forwarded by the `hs` CLI (see stackline/signals.lua).
function stackline.onSignal(...)
    local event, windowId = args(...)
    if not state.initialized then return end
    if event == 'window_focused' then
        -- Move the highlight right away; the refresh below confirms it.
        local id = tonumber(windowId)
        if id and #model.applyFocus(state.stacks, id) > 0 then render.restyle(stackline.config:all()) end
    end
    state.scheduler:request()
end

-- Stops stackline: removes indicators, watchers and yabai signals; returns stackline.
function stackline.stop()
    if not state.initialized then return stackline end
    state.initialized = false
    state.scheduler:stop()
    state.health:stop()
    for _, watcher in ipairs(state.watchers) do watcher:stop() end
    render.clear(0)
    stackline.config:clearListeners()
    if stackline.config:get('features.yabaiSignals') and yabai.path() then signals.removeAll() end
    signals.clearMarker()
    state = { initialized = false, stacks = {} }
    log.i('stackline stopped')
    return stackline
end

-- Returns a readable summary of stackline's state, for `hs -c 'stackline.status()'`.
function stackline.status()
    local drawn, showing = render.counts()
    local version = yabai.version()
    local summary = {
        version = stackline.version,
        initialized = state.initialized,
        initMs = state.initDuration and math.floor(state.initDuration * 1000 + 0.5) or nil,
        yabai = {
            path = yabai.path(),
            version = version and table.concat(version, '.') or nil,
            running = state.yabaiUp,
        },
        signals = stackline.config:get('features.yabaiSignals') and signals.status() or 'disabled',
        stacks = { known = #state.stacks, drawn = drawn, showing = showing },
        lastRefreshMs = state.lastRefresh and math.floor(state.lastRefresh.duration * 1000 + 0.5) or nil,
        lastError = state.lastError,
    }
    return hs.inspect(summary)
end

-- Sets the log level of every stackline module ('error', 'warning', 'info', 'debug', 'verbose').
function stackline.setLogLevel(...)
    local level = args(...)
    log.setLogLevel(level)
    log.i('log level set to ' .. tostring(level))
end

-- Compatibility with older docs and yabai snippets: `stackline.manager:update({ forceRedraw = true })`.
stackline.manager = {
    update = function(_, opts)
        stackline.refresh(type(opts) == 'table' and opts.forceRedraw)
    end,
}

return stackline
