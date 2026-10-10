-- yabai client: finds the binary, runs commands asynchronously through hs.task, and decodes the
-- JSON that yabai prints.
local log  = require 'stackline.log'
local util = require 'stackline.util'

local yabai = {}

-- Only what stackline needs: fewer properties means less work for yabai and smaller JSON for us.
yabai.WINDOW_PROPERTIES = 'id,pid,app,space,frame,stack-index,has-focus,is-visible'

local state = {
    path = nil,          -- resolved binary
    version = nil,       -- { major, minor, patch } once probed
    selectProps = true,  -- `query --windows <props>` needs yabai >= 7.0.3
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

-- Runs `<yabai> <args...>` asynchronously and calls `cb(ok, stdout, stderr, exitCode)` exactly once.
-- `timeout` (seconds, default 3) terminates a hung process. Returns the hs.task, or nil.
function yabai.exec(args, cb, timeout)
    cb = cb or function() end
    if not state.path then
        cb(false, '', 'yabai binary not found', -1)
        return nil
    end
    return yabai.spawn(state.path, args, cb, timeout)
end

-- Runs `path` with `args` like yabai.exec (also used for /bin/sh scripts). Returns the hs.task, or nil.
function yabai.spawn(path, args, cb, timeout)
    local finished, timer = false, nil
    local function finish(ok, out, err, code)
        if finished then return end
        finished = true
        if timer then timer:stop() end
        cb(ok, out or '', err or '', code)
    end

    local task = hs.task.new(path, function(code, out, err)
        finish(code == 0, out, err, code)
    end, args)
    if not task or not task:start() then
        finish(false, '', 'could not launch ' .. path, -1)
        return nil
    end

    timer = hs.timer.doAfter(timeout or 3, function()
        if finished then return end
        -- Report first: terminating fires the task callback, which must not win with an empty error.
        finish(false, '', ('timed out: %s %s'):format(path, table.concat(args, ' ')), -1)
        if task:isRunning() then task:terminate() end
    end)
    return task
end

-- Returns the Lua value decoded from yabai's JSON output, or nil plus an error message.
function yabai.decode(text)
    if type(text) ~= 'string' or not text:find('%S') then return nil, 'empty output from yabai' end
    -- yabai prints frames with printf("%.4f"), which yields bare inf/nan for degenerate windows:
    -- not valid JSON, so replace those numbers with 0 before decoding.
    local clean = text:gsub('([:%[,]%s*)%-?inf', '%10'):gsub('([:%[,]%s*)%-?nan', '%10')
    local ok, value = pcall(hs.json.decode, clean)
    if not ok or value == nil then return nil, 'could not parse yabai output as JSON' end
    return value
end

-- Reads the yabai version (once per yabai start) and calls `cb(version)`; version may be nil.
function yabai.probe(cb)
    yabai.exec({ '--version' }, function(ok, out)
        state.version = ok and yabai.parseVersion(out) or nil
        state.selectProps = yabai.supportsPropertySelection(state.version)
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
