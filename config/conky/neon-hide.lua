-- Neon-Grid: hides and shows the widgets. Usage: local hide = dofile('.../neon-hide.lua')
-- hide(dt) returns how visible the widget is (0..1) and whether that is changing.
local FILE = os.getenv('HOME') .. '/.cache/neon-grid/widgets-hidden'
local OUT, IN = 0.30, 0.42          -- seconds
local a, since, hidden

-- cubic bezier through (0.2, 0) and (0, 1)
local function ease(x)
    local lo, hi = 0, 1
    for _ = 1, 16 do
        local t = (lo + hi) / 2
        local at = 3 * 0.2 * t * (1 - t) * (1 - t) + t * t * t
        if at < x then lo = t else hi = t end
    end
    return 3 * lo * lo * (1 - lo) + lo * lo * lo
end

return function(dt)
    since = (since or 1) + dt
    if since > 0.08 then
        since = 0
        local f = io.open(FILE, 'r')
        hidden = f ~= nil
        if f then f:close() end
    end
    if not a then a = hidden and 0 or 1 end
    local goal = hidden and 0 or 1
    if a < goal then a = math.min(1, a + dt / IN) elseif a > goal then a = math.max(0, a - dt / OUT) end
    if a == goal then return goal, false end      -- exactly 1 or 0 at rest
    return ease(a), true
end
