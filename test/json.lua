-- Minimal JSON decoder backing the hs.json mock. Like hs.json it rejects invalid input (inf, nan).
local json = {}

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

-- Raises a decoding error that reports the byte position.
local function fail(pos, msg)
    error(('json: %s at byte %d'):format(msg, pos), 0)
end

-- Returns the position of the next non-whitespace character at or after `pos`.
local function skip(str, pos)
    return str:find('[^ \t\r\n]', pos) or (#str + 1)
end

local parseValue

-- Returns the decoded string starting at the opening quote `pos`, and the position after it.
local function parseString(str, pos)
    local out, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == '' then fail(i, 'unterminated string') end
        if c == '"' then return table.concat(out), i + 1 end
        if c == '\\' then
            local e = str:sub(i + 1, i + 1)
            if e == 'u' then
                local hex = str:sub(i + 2, i + 5)
                if not hex:match('^%x%x%x%x$') then fail(i, 'bad unicode escape') end
                out[#out + 1] = utf8.char(tonumber(hex, 16))
                i = i + 6
            elseif ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]
                i = i + 2
            else
                fail(i, 'bad escape')
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

-- Returns the number starting at `pos` and the position after it.
local function parseNumber(str, pos)
    local text = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    if not text then fail(pos, 'bad number') end
    local n = tonumber(text)
    if not n then fail(pos, 'bad number') end
    if not text:find('[.eE]') then n = math.tointeger(n) or n end
    return n, pos + #text
end

-- Returns the array starting at `pos` and the position after it.
local function parseArray(str, pos)
    local list = {}
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == ']' then return list, pos + 1 end
    while true do
        local value
        value, pos = parseValue(str, pos)
        list[#list + 1] = value
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then return list, pos + 1 end
        if c ~= ',' then fail(pos, "expected ',' or ']'") end
        pos = skip(str, pos + 1)
    end
end

-- Returns the object starting at `pos` and the position after it.
local function parseObject(str, pos)
    local obj = {}
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
        if str:sub(pos, pos) ~= '"' then fail(pos, 'expected key') end
        local key
        key, pos = parseString(str, pos)
        pos = skip(str, pos)
        if str:sub(pos, pos) ~= ':' then fail(pos, "expected ':'") end
        local value
        value, pos = parseValue(str, skip(str, pos + 1))
        obj[key] = value
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then return obj, pos + 1 end
        if c ~= ',' then fail(pos, "expected ',' or '}'") end
        pos = skip(str, pos + 1)
    end
end

-- Returns the value starting at `pos` and the position after it.
function parseValue(str, pos)
    pos = skip(str, pos)
    local c = str:sub(pos, pos)
    if c == '{' then return parseObject(str, pos) end
    if c == '[' then return parseArray(str, pos) end
    if c == '"' then return parseString(str, pos) end
    if c == '-' or c:match('%d') then return parseNumber(str, pos) end
    if str:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
    if str:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
    if str:sub(pos, pos + 3) == 'null' then return nil, pos + 4 end
    fail(pos, 'unexpected character ' .. (c == '' and 'EOF' or c))
end

-- Returns the Lua value for JSON text `str`; raises on invalid input.
function json.decode(str)
    local value, pos = parseValue(str, 1)
    pos = skip(str, pos)
    if pos <= #str then fail(pos, 'trailing characters') end
    return value
end

-- Returns `str` as a JSON string literal.
local function encodeString(str)
    return '"' .. str:gsub('[%c"\\]', function(c)
        local named = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return named[c] or ('\\u%04x'):format(c:byte())
    end) .. '"'
end

-- Returns JSON text for `value` (tables with a [1] entry are arrays); used to build fixtures.
function json.encode(value)
    local t = type(value)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(value) end
    if t == 'number' then
        if math.type(value) == 'integer' then return tostring(value) end
        return ('%.4f'):format(value)
    end
    if t == 'string' then return encodeString(value) end
    if t == 'table' then
        if value[1] ~= nil or next(value) == nil then
            local parts = {}
            for i, v in ipairs(value) do parts[i] = json.encode(v) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = encodeString(k) .. ':' .. json.encode(value[k]) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    error('json: cannot encode ' .. t)
end

return json
