-- Test runner: `lua test/run.lua [pattern]` (from the repo root, or via `make test`).
local root = (arg and arg[0] or ''):match('^(.*)/test/run%.lua$') or '.'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
_G.STACKLINE_ROOT = root

local helper = require 'test.helper'

local SPECS = {
    'test.util_spec',
    'test.config_spec',
    'test.scheduler_spec',
    'test.yabai_spec',
    'test.model_spec',
    'test.layout_spec',
    'test.render_spec',
    'test.signals_spec',
    'test.core_spec',
    'test.leak_spec',
}

for _, spec in ipairs(SPECS) do
    local file = io.open(root .. '/' .. spec:gsub('%.', '/') .. '.lua')
    if file then
        file:close()
        local ok, err = pcall(require, spec)
        if not ok then
            -- Report a spec that fails to load as one failing test instead of aborting the run.
            helper.registered[#helper.registered + 1] = { name = spec .. ' (load)', fn = function() error(err, 0) end }
        end
    else
        io.write('SKIP  ', spec, ' (not written yet)\n')
    end
end

local pattern = arg and arg[1]
local passed, failures = 0, {}
for _, test in ipairs(helper.registered) do
    if not pattern or test.name:find(pattern, 1, true) then
        helper.fresh()
        local ok, err = xpcall(test.fn, debug.traceback)
        if ok then
            passed = passed + 1
        else
            failures[#failures + 1] = { name = test.name, err = err }
            io.write('FAIL  ', test.name, '\n')
        end
    end
end

for _, f in ipairs(failures) do
    io.write('\n[', f.name, ']\n', f.err, '\n')
end
require('test.mock_hs').cleanup()
io.write(('\n%s: %d passed, %d failed (%s)\n'):format(_VERSION, passed, #failures, #failures == 0 and 'ok' or 'FAILED'))
os.exit(#failures == 0 and 0 or 1)
