-- Small, dependency-free helpers shared by stackline modules.
local util = {}

-- Returns a deep copy of `value`; non-table values are returned as-is.
function util.deepCopy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = util.deepCopy(v)
    end
    return copy
end

-- Returns `x` rounded to the nearest integer.
function util.round(x)
    return math.floor(x + 0.5)
end

-- Returns true when `x` is a number that is neither NaN nor infinite.
function util.isFinite(x)
    return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge
end

-- Returns `s` wrapped in single quotes so `sh` treats it as one literal word.
function util.shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Returns `s` without leading and trailing whitespace.
function util.trim(s)
    return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Returns the Levenshtein edit distance between strings `a` and `b` (case-insensitive).
function util.editDistance(a, b)
    a, b = a:lower(), b:lower()
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local curr = { [0] = i }
        for j = 1, #b do
            local cost = (a:byte(i) == b:byte(j)) and 0 or 1
            curr[j] = math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = curr
    end
    return prev[#b]
end

-- Returns the candidate closest to `word` by edit distance, or nil when nothing is reasonably close.
function util.closest(word, candidates)
    local best, bestDistance
    for _, candidate in ipairs(candidates) do
        local d = util.editDistance(word, candidate)
        if not bestDistance or d < bestDistance then
            best, bestDistance = candidate, d
        end
    end
    -- Suggest only when fewer than half the characters differ; otherwise the guess is noise.
    if best and bestDistance <= math.max(2, #word // 2) then return best end
    return nil
end

return util
