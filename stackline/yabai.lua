-- yabai client: finds the binary, runs commands asynchronously through hs.task, and decodes the
-- JSON that yabai prints.
local log  = require 'stackline.log'
local util = require 'stackline.util'

local yabai = {}

-- Only what stackline needs: fewer properties means less work for yabai and smaller JSON for us.
yabai.WINDOW_PROPERTIES = 'id,pid,app,space,frame,stack-index,has-focus,is-visible,has-parent-zoom,has-fullscreen-zoom'

-- hs.task reads a pipe only after the process exits, so output larger than the pipe buffer
-- (a few hundred windows) would block yabai forever. Commands therefore write stdout to a file:
--   /bin/sh -c '<CAPTURE_SCRIPT>' stackline-yabai <file> <yabai> <args...>
local CAPTURE_SCRIPT = 'out=$1; shift; exec "$@" >"$out"'
local CAPTURE_TAG = 'stackline-yabai'

local state = {
    path = nil,          -- resolved binary
    version = nil,       -- { major, minor, patch } once probed (informational)
    selectProps = true,  -- `query --windows <props>` needs yabai >= 7.0.3; cleared when yabai rejects it
    captures = 0,        -- counter for unique capture file names
}

-- Returns the attribute `mode` of `path` ('file', 'directory', ...) or nil when it does not exist.
local function mode(path)
    return path and hs.fs.attributes(path, 'mode') or nil
end

-- Returns the user name used by yabai to name its socket.
local function userName()
    return os.getenv('USER') or os.getenv('LOGNAME') or (os.getenv('HOME') or ''):match('([^/]+)$') or ''
end

-- Returns the first usable yabai binary (the configured one first), or nil plus the paths tried.
-- `configured` may be 'auto', a binary, or a directory such as a Homebrew prefix (/opt/homebrew/opt/yabai).
function yabai.resolve(configured)
    local tried, seen = {}, {}
    local function candidate(path)
        if not path or path == '' or seen[path] then return nil end
        seen[path] = true
        tried[#tried + 1] = path
        if mode(path) == 'file' then return path end
    end

    local custom = configured and configured ~= 'auto' and util.trim(configured) or nil
    if custom and custom ~= '' then
        custom = custom:gsub('^~', function() return os.getenv('HOME') or '~' end)
        local found = (mode(custom) == 'directory')
            and (candidate(custom .. '/bin/yabai') or candidate(custom .. '/yabai'))
            or candidate(custom)
        if found then return found end
        log.w(('paths.yabai "%s" is not an executable; looking for yabai elsewhere'):format(custom))
    end

    local home, user = os.getenv('HOME'), userName()
    local defaults = {
        '/opt/homebrew/bin/yabai',                       -- Homebrew on Apple Silicon
        '/usr/local/bin/yabai',                          -- Homebrew on Intel / manual installs
        home and (home .. '/.nix-profile/bin/yabai'),    -- Nix profiles
        user ~= '' and ('/etc/profiles/per-user/' .. user .. '/bin/yabai') or nil,
        '/run/current-system/sw/bin/yabai',              -- nix-darwin
    }
    for i = 1, 5 do
        local found = candidate(defaults[i])
        if found then return found end
    end

    -- Hammerspoon inherits launchd's minimal PATH, but honour it in case the user extended it.
    for dir in (os.getenv('PATH') or ''):gmatch('[^:]+') do
        local found = candidate(dir .. '/yabai')
        if found then return found end
    end
    return nil, tried
end

-- Sets the binary used by every other function.
function yabai.setPath(path)
    state.path = path
end

-- Returns the binary in use, or nil.
function yabai.path()
    return state.path
end

-- Returns the path of the socket yabai listens on (its presence means yabai is running).
function yabai.socketPath()
    return '/tmp/yabai_' .. userName() .. '.socket'
end

-- Returns the parsed version table, or nil when unknown.
function yabai.version()
    return state.version
end

-- Returns { major, minor, patch } parsed from `yabai --version` output, or nil.
function yabai.parseVersion(text)
    local major, minor, patch = tostring(text or ''):match('(%d+)%.(%d+)%.(%d+)')
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

-- Returns true when `version` supports `query --windows <properties>` (added in yabai 7.0.3).
function yabai.supportsPropertySelection(version)
    if not version then return true end -- unknown: try it; queryWindows falls back on error
    local a, b, c = version[1], version[2], version[3]
    return a > 7 or (a == 7 and (b > 0 or c >= 3))
end

-- Returns a fresh path for capturing one command's stdout.
local function captureFile()
    state.captures = state.captures + 1
    local dir = (hs.fs.temporaryDirectory and hs.fs.temporaryDirectory()) or '/tmp/'
    if dir:sub(-1) ~= '/' then dir = dir .. '/' end
    return dir .. ('stackline-%d.out'):format(state.captures)
end

-- Returns the content of file `path` ('' when it does not exist) and deletes the file.
local function slurp(path)
    local content = ''
    local f = io.open(path, 'rb')
    if f then
        content = f:read('a') or ''
        f:close()
    end
    os.remove(path)
    return content
end

-- Runs `<yabai> <args...>` asynchronously and calls `cb(ok, stdout, stderr, exitCode)` exactly once.
-- `timeout` (seconds, default 3) terminates a hung process. Returns the hs.task, or nil.
function yabai.exec(args, cb, timeout)
    cb = cb or function() end
    if not state.path then
        cb(false, '', 'yabai binary not found', -1)
        return nil
    end

    local out = captureFile()
    local argv = { '-c', CAPTURE_SCRIPT, CAPTURE_TAG, out, state.path }
    for _, arg in ipairs(args) do argv[#argv + 1] = arg end

    -- Hammerspoon keeps hs.task and hs.timer callbacks in its registry until the object itself is
    -- collected. These callbacks reach each other's objects through the `task`/`timer` upvalues,
    -- so finish() clears them; otherwise neither object could ever be freed.
    local finished, task, timer = false, nil, nil
    local function finish(ok, stdout, err, code)
        finished = true
        if timer then timer:stop() end
        task, timer = nil, nil
        cb(ok, stdout, err or '', code)
    end

    task = hs.task.new('/bin/sh', function(code, _, err)
        -- A late callback after a timeout only cleans up whatever the killed process left behind.
        if finished then return os.remove(out) end
        finish(code == 0, slurp(out), err, code)
    end, argv)
    if not task or not task:start() then
        os.remove(out)
        finish(false, '', 'could not launch ' .. state.path, -1)
        return nil
    end
    local started = task

    timer = hs.timer.doAfter(timeout or 3, function()
        if finished then return end
        local running = task
        -- Report first: terminating fires the task callback, which must not win with an empty error.
        finish(false, '', ('timed out: %s %s'):format(state.path, table.concat(args, ' ')), -1)
        os.remove(out)
        if running and running:isRunning() then running:terminate() end
    end)
    return started
end

-- Runs `path` with `args` and calls `cb(ok, stdout, stderr, exitCode)` exactly once, reading stdout
-- from a pipe: only for commands with little output, such as /bin/sh scripts. Returns the hs.task, or nil.
function yabai.spawn(path, args, cb, timeout)
    -- See yabai.exec for why finish() clears the task/timer upvalues.
    local finished, task, timer = false, nil, nil
    local function finish(ok, out, err, code)
        if finished then return end
        finished = true
        if timer then timer:stop() end
        task, timer = nil, nil
        cb(ok, out or '', err or '', code)
    end

    task = hs.task.new(path, function(code, out, err)
        finish(code == 0, out, err, code)
    end, args)
    if not task or not task:start() then
        finish(false, '', 'could not launch ' .. path, -1)
        return nil
    end
    local started = task

    timer = hs.timer.doAfter(timeout or 3, function()
        if finished then return end
        local running = task
        -- Report first: terminating fires the task callback, which must not win with an empty error.
        finish(false, '', ('timed out: %s %s'):format(path, table.concat(args, ' ')), -1)
        if running and running:isRunning() then running:terminate() end
    end)
    return started
end

-- Returns the Lua value decoded from yabai's JSON output, or nil plus an error message.
function yabai.decode(text)
    if type(text) ~= 'string' or not text:find('%S') then return nil, 'empty output from yabai' end
    -- yabai prints frames with printf("%.4f"), which yields bare inf/nan for degenerate windows:
    -- not valid JSON, so turn those numbers into null (nil in Lua) before decoding.
    local clean = text:gsub('([:%[,]%s*)%-?inf', '%1null'):gsub('([:%[,]%s*)%-?nan', '%1null')
    local ok, value = pcall(hs.json.decode, clean)
    if not ok or value == nil then return nil, 'could not parse yabai output as JSON' end
    return value
end

-- Reads the yabai version (once per yabai start) and calls `cb(version)`; version may be nil.
-- The version is informational only: `yabai --version` reports the binary, and after an upgrade
-- the running daemon may be older, so queryWindows learns what the daemon accepts from its errors.
function yabai.probe(cb)
    yabai.exec({ '--version' }, function(ok, out)
        state.version = ok and yabai.parseVersion(out) or nil
        if not state.version then log.w('could not determine the yabai version') end
        if cb then cb(state.version) end
    end)
end

-- Queries every window and calls `cb(windows)` on success or `cb(nil, err)` on failure.
function yabai.queryWindows(cb)
    local args = { '-m', 'query', '--windows' }
    if state.selectProps then args[#args + 1] = yabai.WINDOW_PROPERTIES end

    yabai.exec(args, function(ok, out, err)
        if not ok then
            -- yabai < 7.0.3 rejects the property list: remember and retry with a full query.
            if state.selectProps and (err:find('not a valid property', 1, true) or err:find('unknown option', 1, true)) then
                state.selectProps = false
                return yabai.queryWindows(cb)
            end
            return cb(nil, util.trim(err) ~= '' and util.trim(err) or 'yabai query failed')
        end
        local windows, decodeErr = yabai.decode(out)
        if type(windows) ~= 'table' then return cb(nil, decodeErr or 'unexpected yabai output') end
        cb(windows)
    end)
end

-- Focuses the window with `id`; calls `cb(ok, err)`.
function yabai.focusWindow(id, cb)
    yabai.exec({ '-m', 'window', '--focus', tostring(id) }, function(ok, _, err)
        if cb then cb(ok, util.trim(err)) end
    end)
end

-- Lists registered signals; calls `cb(signals)` or `cb(nil, err)`.
function yabai.listSignals(cb)
    yabai.exec({ '-m', 'signal', '--list' }, function(ok, out, err)
        if not ok then return cb(nil, util.trim(err)) end
        local list, decodeErr = yabai.decode(out)
        if type(list) ~= 'table' then return cb(nil, decodeErr) end
        cb(list)
    end)
end

-- Returns true when `err` means the yabai server could not be reached.
function yabai.isConnectionError(err)
    err = tostring(err or '')
    return err:find('failed to connect', 1, true) ~= nil
        or err:find('failed to open socket', 1, true) ~= nil
        or err:find('binary not found', 1, true) ~= nil
end

-- Forgets the probed version (call when yabai restarts or the binary changes).
function yabai.reset()
    state.version = nil
    state.selectProps = true
end

return yabai
