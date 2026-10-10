-- Tiny test framework: describe/it registration, assertions, and a fresh mocked environment.
local mock = require 'test.mock_hs'

local helper = { registered = {} }
local suite = {}

-- Groups the tests registered inside `fn` under `name`.
function helper.describe(name, fn)
    suite[#suite + 1] = name
    fn()
    suite[#suite] = nil
end

-- Registers test `fn` called `name` in the current group.
function helper.it(name, fn)
    local parts = {}
    for i, s in ipairs(suite) do parts[i] = s end
    parts[#parts + 1] = name
    helper.registered[#helper.registered + 1] = { name = table.concat(parts, ' > '), fn = fn }
end

-- Unloads every stackline module and installs a new hs mock; returns the mock controller.
function helper.fresh()
    for name in pairs(package.loaded) do
        if name == 'stackline' or name:match('^stackline%.') then package.loaded[name] = nil end
    end
    _G.stackline = nil
    return mock.install()
end

-- Returns true when `a` and `b` are deeply equal.
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
helper.deepEqual = deepEqual

-- Fails unless `actual` deeply equals `expected`.
function helper.eq(actual, expected, msg)
    if not deepEqual(actual, expected) then
        error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', mock.inspect(expected), mock.inspect(actual)), 2)
    end
end

-- Fails unless `a` and `b` differ by less than `eps` (default 1e-6); `eps` may be omitted for `msg`.
function helper.near(a, b, eps, msg)
    if type(eps) == 'string' then eps, msg = nil, eps end
    if type(a) ~= 'number' or math.abs(a - b) > (eps or 1e-6) then
        error(('%sexpected %s ≈ %s'):format(msg and (msg .. ': ') or '', tostring(a), tostring(b)), 2)
    end
end

-- Fails unless `value` is truthy.
function helper.truthy(value, msg)
    if not value then error(msg or 'expected a truthy value', 2) end
end

-- Fails unless `value` is falsy.
function helper.falsy(value, msg)
    if value then error((msg or 'expected a falsy value') .. ', got ' .. mock.inspect(value), 2) end
end

-- Fails unless string `haystack` contains `needle` (plain match).
function helper.contains(haystack, needle, msg)
    if type(haystack) ~= 'string' or not haystack:find(needle, 1, true) then
        error(('%sexpected %q to contain %q'):format(msg and (msg .. ': ') or '', tostring(haystack), needle), 2)
    end
end

-- Fails if string `haystack` contains `needle` (plain match).
function helper.excludes(haystack, needle, msg)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        error(('%sexpected %q not to contain %q'):format(msg and (msg .. ': ') or '', haystack, needle), 2)
    end
end

-- Returns the number of entries in `t`.
function helper.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

return helper
