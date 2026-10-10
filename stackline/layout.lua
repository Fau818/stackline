-- Indicator geometry and styling. Pure functions: no Hammerspoon calls.
-- Positions, colors and shadows reproduce the original stackline look.
local layout = {}

-- Extra room around the indicators so their shadows are not clipped by the canvas edge.
layout.SHADOW_PADDING = 24

-- Returns 'right' when the window sits mostly on the right of its screen, otherwise 'left'.
local function screenSide(frame, screen)
    local threshold = 0.75
    local left = frame.x - screen.x
    local right = left + frame.w
    local percRight = right / screen.w
    local percLeft = (screen.w - left) / screen.w
    return (percRight > threshold and percLeft < threshold) and 'right' or 'left'
end

-- Returns the intersection of rects `a` and `b`, or nil when they do not overlap.
local function intersect(a, b)
    local x1, y1 = math.max(a.x, b.x), math.max(a.y, b.y)
    local x2, y2 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
    if x2 <= x1 or y2 <= y1 then return nil end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Returns the indicator geometry for `stack` in absolute screen coordinates:
-- { side, radius, items = { { id, rect, iconRect } }, bounds, canvasFrame }.
-- `screenFrame` is the full frame of the stack's screen; `a` is the `appearance` config.
function layout.compute(stack, a, screenFrame)
    local width = a.showIcons and a.size or (a.size / a.pillThinness)
    local height = a.size
    local f = stack.frame
    local side = screenSide(f, screenFrame)

    -- Indicators go outside the window edge nearest the screen edge, but never off screen.
    local x
    if side == 'right' then
        x = f.x + f.w + a.offset.x
        if x + width > screenFrame.x + screenFrame.w then x = screenFrame.x + screenFrame.w - width end
    else
        x = f.x - width - a.offset.x
        if x < screenFrame.x then x = screenFrame.x end
    end

    local items = {}
    local step = height * a.vertSpacing
    for i, win in ipairs(stack.windows) do
        local y = f.y + a.offset.y + (i - 1) * step
        items[i] = {
            id = win.id,
            rect = { x = x, y = y, w = width, h = height },
            iconRect = {
                x = x + a.iconPadding,
                y = y + a.iconPadding,
                w = width - a.iconPadding * 2,
                h = height - a.iconPadding * 2,
            },
        }
    end

    local bounds = { x = x, y = f.y + a.offset.y, w = width, h = (#items - 1) * step + height }
    local pad = layout.SHADOW_PADDING
    local padded = { x = bounds.x - pad, y = bounds.y - pad, w = bounds.w + pad * 2, h = bounds.h + pad * 2 }

    return {
        side = side,
        -- `radius` is a divisor for icon indicators (higher → less round) and literal for pills.
        radius = a.showIcons and (width / a.radius) or a.radius,
        items = items,
        bounds = bounds,
        -- Keep shadows on the stack's own screen so they do not bleed onto a neighbouring display.
        canvasFrame = intersect(padded, screenFrame) or bounds,
    }
end

-- Returns the visual state of window `id`: 'focused' / 'inactive' while its stack has focus,
-- 'lastActive' / 'idle' while focus is elsewhere.
function layout.stateFor(stack, id)
    if stack.focusedId then
        return id == stack.focusedId and 'focused' or 'inactive'
    end
    return id == stack.activeId and 'lastActive' or 'idle'
end

-- Returns a copy of color table `color` with its alpha replaced by `alpha`.
local function withAlpha(color, alpha)
    local c = {}
    for k, v in pairs(color) do c[k] = v end
    c.alpha = alpha
    return c
end

-- Returns { fill, iconAlpha, shadow } for an indicator in `state` on the given `side`.
function layout.style(a, state, side)
    local fillAlpha, iconAlpha
    if state == 'focused' then
        fillAlpha, iconAlpha = a.alpha, a.alpha
    elseif state == 'inactive' then
        fillAlpha, iconAlpha = a.alpha / a.dimmer, a.alpha / a.iconDimmer
    elseif state == 'lastActive' then
        -- The last-focused icon stays at full alpha while its stack is unfocused.
        fillAlpha, iconAlpha = a.alpha / (a.dimmer / 1.2), a.alpha
    else
        -- Icons carry idle indicators on their own; pills need a faint background to stay visible.
        fillAlpha = a.showIcons and 0 or 0.2
        iconAlpha = a.alpha / (a.iconDimmer + (a.iconDimmer * 0.70))
    end

    -- Shadows: stronger for the (last) focused indicator, softer without icons, and cast towards
    -- the screen edge as if lit from the screen's center.
    local strong = (state == 'focused' or state == 'lastActive')
    local iconsOff = a.showIcons and 1 or 5
    local direction = (side == 'left') and -1 or 1
    local shadow = {
        blurRadius = (strong and 15.0 or 7.0) / iconsOff,
        color = { alpha = 1 / ((strong and 6 or 7) * iconsOff) },
        offset = {
            h = (strong and 3.0 or 2.0) * -1.0,
            w = ((strong and 7.0 or 6.0) * direction) / iconsOff,
        },
    }

    return { fill = withAlpha(a.color, fillAlpha), iconAlpha = iconAlpha, shadow = shadow }
end

return layout
