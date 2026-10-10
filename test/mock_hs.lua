-- A fake `hs` global covering the Hammerspoon APIs stackline uses. `install()` returns a controller
-- that tests use to drive time, answer hs.task launches, and inspect canvases, logs and notifications.
local json = require 'test.json'

local M = {}

-- A real directory standing in for hs.fs.temporaryDirectory(): yabai output is captured in files.
local TMP
local function tmpdir()
    if not TMP then
        TMP = (os.getenv('TMPDIR') or '/tmp/'):gsub('/?$', '/') .. ('stackline-tests-%d/'):format(math.random(1, 1e9))
        assert(os.execute("mkdir -p '" .. TMP .. "'"), 'cannot create ' .. TMP)
    end
    return TMP
end

-- Removes the temporary directory used by the mocks.
function M.cleanup()
    if TMP then os.execute("rm -rf '" .. TMP .. "'") end
    TMP = nil
end

-- Returns a shallow copy of `t`.
local function copy(t)
    local c = {}
    for k, v in pairs(t or {}) do c[k] = v end
    return c
end

-- Returns a compact, deterministic string for `value` (stands in for hs.inspect).
local function inspect(value, depth)
    depth = depth or 0
    if type(value) == 'string' then return ('%q'):format(value) end
    if type(value) ~= 'table' then return tostring(value) end
    if depth > 4 then return '{...}' end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. ' = ' .. inspect(value[k], depth + 1) end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

-- Installs a fresh fake `hs` global and returns its controller.
function M.install()
    local ctl = {
        now = 0,                 -- fake clock, seconds
        timers = {},
        pendingTasks = {},       -- launched tasks waiting for the controller to complete them
        hungTasks = {},
        taskLog = {},            -- every launched hs.task, in order
        taskHandler = nil,       -- function(path, args, task) -> exitCode, stdout, stderr (exitCode nil = hang)
        canvases = {},
        screens = { { id = 1, frame = { x = 0, y = 0, w = 1440, h = 900 } } },
        files = {},              -- path -> attributes table (mode, ino, change, ...)
        apps = {},               -- pid -> { name, bundleID, path, windows = { id, ... } }
        focusedWindows = {},     -- ids focused through hs.window objects
        notifications = {},
        logs = {},
        spacesWatchers = {},
        screenWatchers = {},
        imageLookups = 0,
        appLookups = 0,
        frameworksPath = '/Applications/Hammerspoon.app/Contents/Frameworks',
        tmpdir = tmpdir(),
        ports = {},              -- hs.ipc.localPort name -> port
        appWatchers = {},
        frontPid = nil,          -- pid returned by hs.application.frontmostApplication()
    }

    local hs = {}

    -- hs.logger ----------------------------------------------------------------------------
    hs.logger = {
        new = function(name, level)
            local logger = { name = name, level = level }
            for _, method in ipairs({ 'e', 'w', 'i', 'd', 'v', 'ef', 'wf', 'f', 'df', 'vf' }) do
                logger[method] = function(...)
                    local parts = {}
                    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
                    ctl.logs[#ctl.logs + 1] = { level = method, msg = table.concat(parts, ' ') }
                end
            end
            logger.setLogLevel = function(lvl) logger.level = lvl end
            logger.getLogLevel = function() return logger.level end
            return logger
        end,
    }

    -- Hammerspoon keeps Lua callbacks in a registry (LuaSkin's refTable) that is a garbage
    -- collection root; an object's callback is released only when the object itself is collected.
    -- Modelling that lets tests catch reference cycles that would leak in the real app.
    ctl.registry = {}
    local lastRef = 0
    local function ref(value)
        lastRef = lastRef + 1
        ctl.registry[lastRef] = value
        return lastRef
    end
    local function unref(r)
        if r then ctl.registry[r] = nil end
        return nil
    end

    -- hs.timer -----------------------------------------------------------------------------
    -- `native` is what the run loop holds; the returned table stands in for the Lua userdata.
    local function addTimer(delay, fn, every)
        local native = { at = ctl.now + delay, every = every, active = true, fnRef = ref(fn) }
        ctl.timers[#ctl.timers + 1] = native
        local timer = {}
        function timer:stop() native.active = false return self end
        function timer:running() return native.active end
        function timer:start() native.active = true; native.at = ctl.now + (native.every or delay) return self end
        return setmetatable(timer, { __gc = function()
            native.active = false -- collecting a timer stops it, as in Hammerspoon
            native.fnRef = unref(native.fnRef)
        end })
    end
    hs.timer = {
        doAfter = function(delay, fn) return addTimer(delay, fn) end,
        doEvery = function(interval, fn) return addTimer(interval, fn, interval) end,
        absoluteTime = function() return math.floor(ctl.now * 1e9 + 0.5) end,
        secondsSinceEpoch = function() return 1.7e9 + ctl.now end,
    }

    -- hs.task --------------------------------------------------------------------------------
    -- Like timers, a task's callback lives in the registry until the task is collected, and
    -- Hammerspoon holds a self reference from creation until the process terminates.
    hs.task = {
        new = function(path, callback, a, b)
            local args = (type(a) == 'table') and a or b or {}
            local native = {
                path = path, args = args, running = false, terminated = false,
                callbackRef = callback and ref(callback) or nil,
            }
            local task = {}
            function task:start()
                native.running = true
                ctl.taskLog[#ctl.taskLog + 1] = { path = path, args = args }
                ctl.pendingTasks[#ctl.pendingTasks + 1] = native
                return self
            end
            function task:isRunning() return native.running end
            function task:terminate()
                if not native.running then return self end
                native.terminated = true
                ctl.complete(native, 15, '', '')
                return self
            end
            setmetatable(task, { __gc = function()
                native.callbackRef = unref(native.callbackRef)
                native.selfRef = unref(native.selfRef)
            end })
            native.selfRef = ref(task)
            return task
        end,
    }

    -- Finishes a task: runs its callback, then drops Hammerspoon's self reference.
    function ctl.complete(native, code, out, err)
        if not native.running then return end
        native.running = false
        local callback = native.callbackRef and ctl.registry[native.callbackRef]
        if callback then callback(code, out or '', err or '') end
        native.selfRef = unref(native.selfRef)
    end

    -- Completes launched tasks (including ones launched by callbacks) until none are pending.
    function ctl.flushTasks()
        while #ctl.pendingTasks > 0 do
            local native = table.remove(ctl.pendingTasks, 1)
            if native.running then
                local code, out, err = 0, '', ''
                if ctl.taskHandler then code, out, err = ctl.taskHandler(native.path, native.args, native) end
                if code == nil then
                    ctl.hungTasks[#ctl.hungTasks + 1] = native
                else
                    ctl.complete(native, code, out, err)
                end
            end
        end
    end

    -- Returns the number of live registry references (callbacks and self references).
    function ctl.liveRefs()
        collectgarbage('collect')
        collectgarbage('collect')
        local n = 0
        for _ in pairs(ctl.registry) do n = n + 1 end
        return n
    end

    -- Advances the fake clock by `dt` seconds, completing tasks and firing due timers in order.
    function ctl.advance(dt)
        local target = ctl.now + (dt or 0)
        while true do
            ctl.flushTasks()
            local nextTimer
            for _, t in ipairs(ctl.timers) do
                if t.active and t.at <= target + 1e-9 and (not nextTimer or t.at < nextTimer.at) then nextTimer = t end
            end
            if not nextTimer then break end
            ctl.now = math.max(ctl.now, nextTimer.at)
            if nextTimer.every then nextTimer.at = nextTimer.at + nextTimer.every else nextTimer.active = false end
            local fn = nextTimer.fnRef and ctl.registry[nextTimer.fnRef]
            if fn then fn() end -- Hammerspoon calls timer callbacks without arguments
        end
        ctl.now = target
        ctl.flushTasks()
    end

    -- Returns launched tasks whose argument list contains `needle`.
    function ctl.tasksMatching(needle)
        local found = {}
        for _, task in ipairs(ctl.taskLog) do
            for _, arg in ipairs(task.args) do
                if tostring(arg):find(needle, 1, true) then found[#found + 1] = task break end
            end
        end
        return found
    end

    -- hs.canvas ------------------------------------------------------------------------------
    local windowLevels = {
        _MinimumWindowLevelKey = -2147483648, desktop = -2147483623, desktopIcon = -2147483603,
        normal = 0, floating = 3, tornOffMenu = 3, modalPanel = 8, utility = 19, dock = 20,
        mainMenu = 24, status = 25, popUpMenu = 101, overlay = 102, help = 200, dragging = 500,
        screenSaver = 1000, assistiveTechHigh = 1500, cursor = 2147483630, _MaximumWindowLevelKey = 2147483631,
    }
    local windowBehaviors = {
        default = 0, canJoinAllSpaces = 1, moveToActiveSpace = 2, managed = 4, transient = 8, stationary = 16,
        participatesInCycle = 32, ignoresCycle = 64, fullScreenPrimary = 128, fullScreenAuxiliary = 256,
    }

    local function newCanvas(frame)
        assert(type(frame) == 'table' and frame.x and frame.y and frame.w and frame.h, 'canvas frame required')
        local canvas = {
            frameRect = copy(frame), elements = {}, showing = false, deleted = false,
            levelValue = windowLevels.screenSaver, behaviorValue = 0, subrole = nil,
            clickActivatingValue = true, mouseCallbackFn = nil, attributeWrites = 0,
            showCount = 0, hideCount = 0, frameWrites = 0, levelWrites = 0, replaceCount = 0,
        }
        -- Like canvas.lua: an integer level or a name from hs.canvas.windowLevels, nothing else.
        function canvas:level(v)
            if v == nil then return self.levelValue end
            if math.type(v) == 'integer' then
                self.levelValue = v
            elseif type(v) == 'string' and windowLevels[v] then
                self.levelValue = windowLevels[v]
            elseif type(v) == 'string' then
                error('unrecognized level specified: ' .. v)
            else
                error('integer or string expected, got ' .. type(v))
            end
            self.levelWrites = self.levelWrites + 1
            return self
        end
        function canvas:behavior(v)
            if v == nil then return self.behaviorValue end
            self.behaviorValue = v
            return self
        end
        function canvas:_accessibilitySubrole(v) self.subrole = v return self end
        function canvas:clickActivating(v) self.clickActivatingValue = v return self end
        function canvas:appendElements(...)
            local list = { ... }
            if select('#', ...) == 1 and #list[1] > 0 then list = list[1] end
            assert(#list > 0, 'appendElements called without elements')
            for _, e in ipairs(list) do self.elements[#self.elements + 1] = copy(e) end
            return self
        end
        -- Like canvas.lua: varargs or one array of elements; extra old elements are removed.
        function canvas:replaceElements(...)
            assert(not self.deleted, 'replaceElements() on a deleted canvas')
            local list = { ... }
            if select('#', ...) == 1 and #list[1] > 0 then list = list[1] end
            assert(#list > 0, 'replaceElements called without elements')
            self.elements = {}
            for i, e in ipairs(list) do self.elements[i] = copy(e) end
            self.replaceCount = self.replaceCount + 1
            return self
        end
        function canvas:elementAttribute(i, key, value)
            assert(self.elements[i], 'no element at index ' .. tostring(i))
            if value == nil then return self.elements[i][key] end
            self.elements[i][key] = value
            self.attributeWrites = self.attributeWrites + 1
            return self
        end
        function canvas:show(fade)
            assert(not self.deleted, 'show() on a deleted canvas')
            self.showing = true
            self.lastShowFade = fade
            self.showCount = self.showCount + 1
            return self
        end
        function canvas:hide(fade)
            assert(not self.deleted, 'hide() on a deleted canvas')
            self.showing = false
            self.lastHideFade = fade
            self.hideCount = self.hideCount + 1
            return self
        end
        -- Like Hammerspoon: delete() only hides; the window goes away when Lua collects the canvas.
        function canvas:delete(fade)
            self.deleted = true
            self.showing = false
            self.deleteFade = fade
        end
        function canvas:isShowing() return self.showing end
        -- Like canvas.lua: frame(rect) sets size then topLeft; elements keep absolute frames.
        function canvas:frame(f)
            if f == nil then return copy(self.frameRect) end
            assert(not self.deleted, 'frame() on a deleted canvas')
            self.frameRect = { x = f.x, y = f.y, w = f.w, h = f.h }
            self.frameWrites = self.frameWrites + 1
            return self
        end
        function canvas:mouseCallback(fn) self.mouseCallbackFn = fn return self end
        ctl.canvases[#ctl.canvases + 1] = canvas
        return canvas
    end
    hs.canvas = { new = newCanvas, windowLevels = windowLevels, windowBehaviors = windowBehaviors }

    -- Returns canvases that have not been deleted.
    function ctl.liveCanvases()
        local live = {}
        for _, c in ipairs(ctl.canvases) do
            if not c.deleted then live[#live + 1] = c end
        end
        return live
    end

    -- Simulates a mouse-down on the element with `id` of a canvas that has a mouse callback.
    -- Like Hammerspoon, hit areas only exist on a canvas that is showing.
    function ctl.click(canvas, id)
        assert(canvas.mouseCallbackFn, 'canvas has no mouse callback')
        assert(canvas.showing and not canvas.deleted, 'clicks only reach canvases that are showing')
        canvas.mouseCallbackFn(canvas, 'mouseDown', id, 1, 1)
    end

    -- Returns canvases that are currently showing.
    function ctl.showingCanvases()
        local list = {}
        for _, c in ipairs(ctl.canvases) do
            if c.showing and not c.deleted then list[#list + 1] = c end
        end
        return list
    end

    -- hs.screen ------------------------------------------------------------------------------
    local function screenObject(s)
        return {
            id = function() return s.id end,
            fullFrame = function() return copy(s.frame) end,
            frame = function() return copy(s.visibleFrame or s.frame) end,
        }
    end
    local function watcherFactory(list)
        return {
            new = function(fn)
                local w = { fn = fn, active = false }
                function w:start() self.active = true return self end
                function w:stop() self.active = false return self end
                list[#list + 1] = w
                return w
            end,
        }
    end
    hs.screen = {
        allScreens = function()
            local list = {}
            for i, s in ipairs(ctl.screens) do list[i] = screenObject(s) end
            return list
        end,
        watcher = watcherFactory(ctl.screenWatchers),
    }
    hs.spaces = { watcher = watcherFactory(ctl.spacesWatchers) }

    -- Calls every active watcher in `list`.
    local function fire(list, ...)
        for _, w in ipairs(list) do
            if w.active then w.fn(...) end
        end
    end
    function ctl.fireSpaceChange() fire(ctl.spacesWatchers, -1) end
    function ctl.fireScreenChange() fire(ctl.screenWatchers) end

    -- hs.fs ----------------------------------------------------------------------------------
    hs.fs = {
        attributes = function(path, attribute)
            local attrs = ctl.files[path]
            if not attrs then return nil end
            if attribute then return attrs[attribute] end
            return copy(attrs)
        end,
        rmdir = function(path)
            if ctl.files[path] and ctl.files[path].mode == 'directory' then
                ctl.files[path] = nil
                return true
            end
            return nil, 'No such file or directory'
        end,
        temporaryDirectory = function() return ctl.tmpdir end,
    }

    -- hs.application / hs.image -------------------------------------------------------------
    local function appObject(pid, app)
        return {
            pid = function() return pid end,
            name = function() return app.name end,
            bundleID = function() return app.bundleID end,
            path = function() return app.path end,
            allWindows = function()
                local list = {}
                for _, id in ipairs(app.windows or {}) do
                    list[#list + 1] = {
                        id = function() return id end,
                        focus = function(self) ctl.focusedWindows[#ctl.focusedWindows + 1] = id return self end,
                    }
                end
                return list
            end,
        }
    end
    hs.application = {
        applicationForPID = function(pid)
            ctl.appLookups = ctl.appLookups + 1
            local app = ctl.apps[pid]
            if not app then return nil end
            return appObject(pid, app)
        end,
        frontmostApplication = function()
            if not ctl.frontPid then return nil end
            return appObject(ctl.frontPid, ctl.apps[ctl.frontPid] or { name = 'front' })
        end,
        watcher = {
            launching = 0, launched = 1, terminated = 2, hidden = 3, unhidden = 4, activated = 5, deactivated = 6,
            new = function(fn)
                local w = { fn = fn, active = false }
                function w:start() self.active = true return self end
                function w:stop() self.active = false return self end
                ctl.appWatchers[#ctl.appWatchers + 1] = w
                return w
            end,
        },
    }

    -- Calls active application watchers with (name, event, app).
    function ctl.fireAppEvent(name, event, pid)
        for _, w in ipairs(ctl.appWatchers) do
            if w.active then w.fn(name, event, pid and appObject(pid, ctl.apps[pid] or {}) or nil) end
        end
    end
    hs.image = {
        imageFromAppBundle = function(bundleID)
            ctl.imageLookups = ctl.imageLookups + 1
            return { kind = 'image', source = 'bundle:' .. bundleID }
        end,
        iconForFile = function(path)
            ctl.imageLookups = ctl.imageLookups + 1
            return { kind = 'image', source = 'file:' .. path }
        end,
    }

    -- misc ---------------------------------------------------------------------------------
    hs.json = {
        decode = function(text)
            local ok, value = pcall(json.decode, text)
            if ok then return value end
            ctl.logs[#ctl.logs + 1] = { level = 'json', msg = value }
            return nil
        end,
        encode = json.encode,
    }
    hs.notify = {
        new = function(_, attributes)
            return {
                send = function(self)
                    ctl.notifications[#ctl.notifications + 1] = attributes
                    return self
                end,
            }
        end,
    }
    hs.inspect = inspect
    hs.processInfo = { frameworksPath = ctl.frameworksPath, bundlePath = '/Applications/Hammerspoon.app' }
    hs.configdir = '/Users/tester/.hammerspoon'

    -- Returns log messages at `level` (e.g. 'e', 'w') joined with newlines.
    function ctl.logText(level)
        local lines = {}
        for _, entry in ipairs(ctl.logs) do
            if not level or entry.level == level then lines[#lines + 1] = entry.msg end
        end
        return table.concat(lines, '\n')
    end

    -- hs.ipc: only localPort is used; ctl.send() plays the role of the `hs` CLI talking to a port.
    package.preload['hs.ipc'] = function()
        ctl.ipcLoaded = true
        return {
            localPort = function(name, fn)
                assert(not (ctl.ports[name] and ctl.ports[name].valid), 'port name already in use: ' .. name)
                local port = { portName = name, fn = fn, valid = true }
                function port:delete() self.valid = false end
                function port:isValid() return self.valid end
                function port:name() return self.portName end
                ctl.ports[name] = port
                return port
            end,
        }
    end
    package.loaded['hs.ipc'] = nil

    -- Sends `data` with `msgID` to the local port `name`; returns the reply (nil if the port is gone).
    function ctl.send(name, msgID, data)
        local port = ctl.ports[name]
        if not port or not port.valid then return nil end
        return tostring(port.fn(port, msgID, data))
    end

    -- Simulates `hs -m <name> -c <command>` in legacy mode, as the stackline signal actions run it.
    function ctl.cli(name, command)
        if ctl.send(name, 900, '1 + 1') == nil then return false end
        ctl.send(name, 0, 'x' .. command)
        ctl.send(name, 0, 'x') -- the CLI also sends its (empty) stdin
        return true
    end

    _G.hs = hs
    ctl.hs = hs
    return ctl
end

M.inspect = inspect
return M
