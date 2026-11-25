-- Neon-Grid command panel (laptop screen): header, then a 4-column grid: processor, memory,
-- graphics, temperature / apps, network, storage / Claude usage, cooling, power.
-- Hover opens a card, a click pins it, buttons act through neon-act. Data comes from
-- neon-deck.txt and neon-apps.json, written by neon-deck.py.
--
-- Everything is drawn into a cached surface that is redrawn only when the data or the clock
-- changes or something moves; pointer effects are painted on top at full speed.
require 'cairo'
pcall(require, 'cairo_xlib')

local RUN = os.getenv('XDG_RUNTIME_DIR') or '/run/user/1000'
local PATH = RUN .. '/neon-deck.txt'
local HISTORY = 150
local SAMPLE_S = 2          -- seconds between collector samples
local FAST, IDLE = 1 / 120, 1 / 25  -- seconds per frame; IDLE is also the longest wait to notice a hover
local MOVE_S = 0.40         -- seconds for cards to open and close

local CYAN    = {0.00, 0.94, 1.00}
local MAGENTA = {1.00, 0.17, 0.84}
local GREEN   = {0.16, 1.00, 0.64}
local YELLOW  = {0.98, 0.97, 0.44}
local RED     = {1.00, 0.47, 0.54}
local ORANGE  = {1.00, 0.55, 0.26}
local TEXT    = {0.84, 0.96, 1.00}
local DIM     = {0.48, 0.53, 0.66}
local BG      = {0.031, 0.039, 0.078}
local WHITE   = {1, 1, 1}
local MONO, DISPLAY = 'JetBrains Mono', 'Orbitron'
-- one shared object: conky never frees these, so making one per text draw leaks GiBs a day
local EXT = cairo_text_extents_t:create()

-- wallpaper colours (neon-palette); without it the colours above are used
local ok_pal, make_pal = pcall(dofile, os.getenv('HOME') .. '/.config/conky/neon-palette.lua')
local refresh_palette = ok_pal and make_pal({CYAN = CYAN, MAGENTA = MAGENTA, TEXT = TEXT, DIM = DIM, BG = BG,
    GREEN = GREEN, YELLOW = YELLOW, ORANGE = ORANGE})
    or function() end
do  -- the glass lets bright wallpaper through: quiet text is lifted towards the normal text colour
    local plain = refresh_palette
    refresh_palette = function()
        plain()
        for i = 1, 3 do DIM[i] = DIM[i] + (TEXT[i] - DIM[i]) * 0.45 end
    end
end
refresh_palette()

local mx, my = -1, -1       -- pointer position inside the panel, or -1
local inside_panel = false
local last_move = 0         -- time of the latest pointer event
local GA = 1                -- global alpha, used for fades
local dirty = true
local frame_dt = 0.01
local OTHER_BUTTON = {right = true, middle = true, back = true, forward = true, ['2'] = true, ['3'] = true,
    ['273'] = true, ['274'] = true}

local function inside(x, y, w, h) return mx >= x and mx <= x + w and my >= y and my <= y + h end
local function col(cr, c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], (a or 1) * GA) end
local function mix(a, b, t) return a + (b - a) * t end
local function clamp(v, a, b) return v < a and a or (v > b and b or v) end

-- ===== movement: cubic bezier curves (x1, y1, x2, y2 as in CSS) =====
local function bezier_table(x1, y1, x2, y2)
    local function at(a, b, u) return 3 * a * u * (1 - u) ^ 2 + 3 * b * u * u * (1 - u) + u ^ 3 end
    local out = {}
    for i = 0, 256 do
        local lo, hi = 0, 1
        for _ = 1, 22 do
            local m = (lo + hi) / 2
            if at(x1, x2, m) < i / 256 then lo = m else hi = m end
        end
        out[i] = at(y1, y2, (lo + hi) / 2)
    end
    return out
end
local OPENING = bezier_table(0.10, 0.80, 0.15, 1.00)   -- quick start, long soft landing
local BETWEEN = bezier_table(0.30, 0.00, 0.10, 1.00)   -- from one place to another
local SWEEP = bezier_table(0.45, 0.00, 0.25, 1.00)
local function curve(tbl, t)
    t = clamp(t, 0, 1) * 256
    local i = math.min(255, math.floor(t))
    return tbl[i] + (tbl[i + 1] - tbl[i]) * (t - i)
end
local function smooth(t) return curve(BETWEEN, t) end

-- moves o.x to a target along a curve; a new target starts from where it is now
local moving = false
local function tween(o, target, dt, secs, tbl)
    if o.x == nil then o.x, o.goal = target == 0 and 0 or 0, 0 end
    if target ~= o.goal then o.from, o.goal, o.t = o.x, target, 0 end
    if o.x == o.goal then return o.x end
    o.t = (o.t or 0) + dt / (secs or MOVE_S)
    if o.t >= 1 then o.x = o.goal else
        o.x = o.from + (o.goal - o.from) * curve(tbl or OPENING, o.t)
        moving = true
    end
    return o.x
end
-- follows the pointer (critically damped, so it never jumps when the aim changes mid-way)
local function follow(o, target, dt, w)
    o.x, o.v = o.x or 0, o.v or 0
    if o.x == target and o.v == 0 then return o.x end
    local d, ex = o.x - target, math.exp(-w * dt)
    local tmp = (o.v + w * d) * dt
    o.x, o.v = target + (d + tmp) * ex, (o.v - w * tmp) * ex
    if math.abs(o.x - target) < 0.0015 and math.abs(o.v) < 0.02 then o.x, o.v = target, 0
    else moving = true end
    return o.x
end

-- ===== clock: smooth seconds from /proc/uptime (10 ms steps) =====
local T, T_step = nil, IDLE
local function uptime()
    local f = io.open('/proc/uptime')
    if not f then return os.time() end
    local v = tonumber((f:read('l') or ''):match('%S+')) or 0
    f:close()
    return v
end
-- /proc/uptime only knows 10 ms steps, so the length of a frame is the average of the last ones; the clock
-- follows the real frame rate, whatever it is, and never jumps.
local tick
do
local ring, ring_n, ring_step = {}, 0, nil
function tick()
    local up = uptime()
    if not T or up - T > 0.25 or T - up > 0.12 or ring_step ~= T_step then
        local dt = T and clamp(up - T, 0.001, 0.02) or FAST
        if not T or math.abs(up - T) > 0.25 then T = up else T = T + dt end
        ring, ring_n, ring_step = {up}, 1, T_step
        return dt
    end
    ring_n = ring_n + 1
    ring[ring_n] = up
    local from = math.max(1, ring_n - 14)
    local est = ring_n > 6 and (up - ring[from]) / (ring_n - from) or T_step
    if ring_n > 400 then
        local keep = {}
        for i = ring_n - 15, ring_n do keep[#keep + 1] = ring[i] end
        ring, ring_n = keep, #keep
    end
    est = clamp(est, 0.003, 0.06)
    local dt = clamp(est + clamp((up - T) * 0.08, -0.25 * est, 0.25 * est), 0.001, 0.06)
    T = T + dt
    return dt
end
end

-- ===== text (sizes are remembered: measuring is the slow part) =====
local widths, fits, n_memo = {}, {}, 0
local function width_of(cr, s, face, size, bold)
    local k = face .. size .. (bold and 'b' or 'n') .. s
    local w = widths[k]
    if w then return w end
    cairo_select_font_face(cr, face, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    cairo_text_extents(cr, s, EXT)
    w = EXT.x_advance
    n_memo = n_memo + 1
    if n_memo > 5000 then widths, fits, n_memo = {}, {}, 0 end
    widths[k] = w
    return w
end

-- draws text; returns its advance width. align: 'l', 'r', 'c'
local function text(cr, s, x, y, face, size, bold, c, a, align)
    local adv = width_of(cr, s, face, size, bold)
    if (a or 1) * GA < 0.01 then return adv end
    cairo_select_font_face(cr, face, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    if align == 'r' then x = x - adv elseif align == 'c' then x = x - adv / 2 end
    cairo_new_path(cr)
    cairo_move_to(cr, x, y)
    col(cr, c, a)
    cairo_show_text(cr, s)
    cairo_new_path(cr)
    return adv
end

-- shortens a label to fit a width
local function fit(cr, s, face, size, bold, maxw)
    local k = size .. (bold and 'b' or 'n') .. math.floor(maxw) .. face .. s
    if fits[k] then return fits[k] end
    local out = s
    if width_of(cr, s, face, size, bold) > maxw then
        local n = utf8.len(s)
        local lo, hi = 0, n or #s
        while lo < hi do
            local m = (lo + hi + 1) // 2
            local cut = n and s:sub(1, (utf8.offset(s, m + 1) or #s + 1) - 1) or s:sub(1, m)
            if width_of(cr, cut .. '..', face, size, bold) <= maxw then lo = m else hi = m - 1 end
        end
        out = (n and s:sub(1, (utf8.offset(s, lo + 1) or #s + 1) - 1) or s:sub(1, lo)) .. '..'
    end
    fits[k] = out
    return out
end

local function rrect(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function seg(cr, x1, y1, x2, y2)
    cairo_new_path(cr); cairo_move_to(cr, x1, y1); cairo_line_to(cr, x2, y2); cairo_stroke(cr)
end

local function corners(cr, x, y, w, h, L, c, a, width)
    cairo_set_line_width(cr, width); cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE); col(cr, c, a)
    for _, p in ipairs({
        {x, y + L, x, y, x + L, y}, {x + w - L, y, x + w, y, x + w, y + L},
        {x + w, y + h - L, x + w, y + h, x + w - L, y + h}, {x + L, y + h, x, y + h, x, y + h - L},
    }) do
        cairo_new_path(cr)
        cairo_move_to(cr, p[1], p[2]); cairo_line_to(cr, p[3], p[4]); cairo_line_to(cr, p[5], p[6])
        cairo_stroke(cr)
    end
end

local function dot(cr, x, y, r, c, a)
    cairo_new_path(cr); cairo_arc(cr, x, y, r, 0, 2 * math.pi); col(cr, c, a); cairo_fill(cr)
end

local function line(cr, x, y, w, h, s, hi, c, fill, width)
    local n = #s
    if n < 2 then return end
    hi = math.max(hi or 0, 0.0001)
    local function px(i) return x + (i - 1) * w / (n - 1) end
    local function py(v) return y + h - math.max(0, math.min(1, v / hi)) * h end
    if fill then
        cairo_new_path(cr)
        cairo_move_to(cr, px(1), y + h)
        for i = 1, n do cairo_line_to(cr, px(i), py(s[i])) end
        cairo_line_to(cr, px(n), y + h); cairo_close_path(cr)
        local g = cairo_pattern_create_linear(0, y, 0, y + h)
        cairo_pattern_add_color_stop_rgba(g, 0, c[1], c[2], c[3], 0.30 * GA)
        cairo_pattern_add_color_stop_rgba(g, 1, c[1], c[2], c[3], 0.0)
        cairo_set_source(cr, g); cairo_fill(cr); cairo_pattern_destroy(g)
    end
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for pass = 1, 2 do
        cairo_new_path(cr)
        cairo_move_to(cr, px(1), py(s[1]))
        for i = 2, n do cairo_line_to(cr, px(i), py(s[i])) end
        cairo_set_line_width(cr, pass == 1 and width + 3.5 or width)
        col(cr, c, pass == 1 and 0.15 or 1)
        cairo_stroke(cr)
    end
end

local function commas(v)
    local s = string.format('%d', math.floor(v + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

local function read_first(path)
    local f = io.open(path, 'r')
    if not f then return '' end
    local s = f:read('*l') or ''
    f:close()
    return s
end

local KERNEL = read_first('/proc/sys/kernel/osrelease')
local HOST = read_first('/proc/sys/kernel/hostname')

local GCACHE = os.getenv('HOME') .. '/.cache/neon-grid/'
local GAP_Y, GLASS_TINT = 22, 0.58   -- gap_y of neon-panel.conf; background colour over the glass
local glass_img, screen, glass_stamp
local function load_glass(head)
    local f = io.open(GCACHE .. 'screens.txt', 'r')     -- xrandr --listmonitors, written by start.sh
    if f then
        for l in f:lines() do
            local n, w, h, x, y = l:match('^%s*(%d+):%s+%S+%s+(%d+)/%d+x(%d+)/%d+%+(%d+)%+(%d+)')
            if n and tonumber(n) == head then screen = {w = tonumber(w), h = tonumber(h), x = tonumber(x), y = tonumber(y)} end
        end
        f:close()
    end
    f = io.open(GCACHE .. 'glass.png', 'rb')
    local size = f and f:seek('end') or 0
    if f then f:close() end
    if size == glass_stamp then return false end
    glass_stamp = size
    if glass_img then cairo_surface_destroy(glass_img) end
    glass_img = size > 0 and cairo_image_surface_create_from_png(GCACHE .. 'glass.png') or nil
    return true
end

-- ===== state =====
local raw, d, n = nil, nil, nil            -- file text, parsed rows, numbers
local hide = dofile(os.getenv('HOME') .. '/.config/conky/neon-hide.lua')
local vis, vis_moving, HIDDEN = 1, false, 0.1
local focus, pinned = nil, nil             -- name of the hovered / pinned card
local spr = {}                             -- card -> tween
local regions, plots = {}, {}
local sort_by, selected, confirm = 'cpu', nil, nil
local order = {}                           -- app ids in the order shown
local rowpos, meter = {}, {}               -- tweens for app rows and bars
local toast, toast_at, toast_tw = nil, 0, {}
local next_look = 0
local W, H = 1770, 996
local PAD, GAP = 18, 12
local TOP = 136                            -- where the cards start, below the header
local FOOT = 34
local want_since = nil

-- The grid: four equal columns, three rows. An opened card takes room from its neighbours in
-- the same row and from the other rows, so it stays under the pointer and nothing is covered.
local GRID = {
    {h = 236, open = 112, {'cpu', 1, 1.50}, {'mem', 1, 1.50}, {'gpu', 1, 1.50}, {'temp', 1, 1.50}},
    {h = 352, open = 92, {'apps', 2, 1.16}, {'net', 1, 1.46}, {'disk', 1, 1.46}},
    {h = 200, open = 124, {'claude', 2, 1.14}, {'cool', 1, 1.40}, {'power', 1, 1.40}},
}
local ROW_OF = {}
for r, row in ipairs(GRID) do for _, c in ipairs(row) do ROW_OF[c[1]] = r end end

local function layout(e)                   -- e: card -> 0..1
    local out = {}
    local iw, ih = W - 2 * PAD, H - TOP - FOOT - (#GRID - 1) * GAP
    local sumh, er = 0, {}
    for r, row in ipairs(GRID) do
        sumh = sumh + row.h
        er[r] = 0
        for _, c in ipairs(row) do er[r] = er[r] + (e[c[1]] or 0) end
    end
    local hs = {}
    for r, row in ipairs(GRID) do
        local v = row.h * ih / sumh + er[r] * row.open
        for q, other in ipairs(GRID) do
            if q ~= r then v = v - er[q] * other.open * row.h / (sumh - other.h) end
        end
        hs[r] = v
    end
    local y = TOP
    for r, row in ipairs(GRID) do
        local unit = (iw - 3 * GAP) / 4
        local base, total = {}, 0
        for i, c in ipairs(row) do
            base[i] = unit * c[2] + GAP * (c[2] - 1)
            total = total + base[i]
        end
        local x = PAD
        for i, c in ipairs(row) do
            local w = base[i] + (e[c[1]] or 0) * base[i] * (c[3] - 1)
            for q, o in ipairs(row) do
                if q ~= i then w = w - (e[o[1]] or 0) * base[q] * (o[3] - 1) * base[i] / (total - base[q]) end
            end
            out[c[1]] = {x = x, y = y, w = w, h = hs[r]}
            x = x + w + GAP
        end
        y = y + hs[r] + GAP
    end
    return out
end
local function at(g, x, y)
    for k, c in pairs(g) do
        if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then return k end
    end
end
local function retarget()
    local f = focus
    for _ = 1, 4 do
        local hit = at(layout(f and {[f] = 1} or {}), mx, my)
        if hit == f then break end
        if hit == nil then             -- in a gap: stay as we are unless outside the grid
            if my >= TOP and my <= H - FOOT and mx >= PAD and mx <= W - PAD then return end
            f = nil
            break
        end
        f = hit
    end
    if f ~= focus then focus = f; dirty = true end
end

-- ===== actions =====
local ACT = os.getenv('HOME') .. '/.config/conky/neon-act'
local function act(what, arg)
    if what:match('^[%a]+$') and arg:match('^[%w_%-]+$') then
        os.execute("'" .. ACT .. "' " .. what .. ' ' .. arg .. ' >/dev/null 2>&1 &')
        next_look = 0
    end
end
local function region(x, y, w, h, fn, r, c)
    regions[#regions + 1] = {x = x, y = y, w = w, h = h, fn = fn, r = r or 6, c = c or CYAN}
end
local function button(cr, label, x, y, w, on, c, fn, h)
    h = h or 22
    rrect(cr, x, y, w, h, h / 2)
    col(cr, c, on and 0.85 or 0.11); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, on and 1 or 0.45); cairo_stroke(cr)
    text(cr, label, x + w / 2, y + h / 2 + 3.5, DISPLAY, 8.5, true, on and BG or TEXT, 1, 'c')
    if GA > 0.85 then region(x, y, w, h, fn, h / 2, c) end
end
local function bwidth(cr, label) return width_of(cr, label, DISPLAY, 8.5, true) + 24 end

function conky_mouse(event)
    if vis < 0.5 and event.type ~= 'mouse_leave' then return false end
    local t = event.type
    last_move = T or 0
    if t == 'mouse_move' or t == 'mouse_enter' then
        mx, my = event.x or -1, event.y or -1
        if not inside_panel then want_since = T or 0 end
        inside_panel = true
        if d and T and want_since and T - want_since > 0.09 then retarget() end
    elseif t == 'mouse_leave' then
        mx, my = -1, -1
        inside_panel, focus = false, nil
    elseif t == 'button_down' and d and not OTHER_BUTTON[tostring(event.button)] then
        mx, my = event.x or -1, event.y or -1
        for i = #regions, 1, -1 do
            local r = regions[i]
            if inside(r.x, r.y, r.w, r.h) then r.fn(); dirty = true; return true end
        end
        if focus then pinned = pinned ~= focus and focus or nil; dirty = true end
        return true
    end
    return false
end

-- ===== pieces =====
local function card(cr, g, title, c, right, e, name)
    local x, y, w, h = g.x, g.y, g.w, g.h
    rrect(cr, x, y, w, h, 12); col(cr, e > 0.5 and c or WHITE, 0.025 + 0.02 * e); cairo_fill(cr)
    if e > 0.02 then
        for i = 3, 1, -1 do
            rrect(cr, x, y, w, h, 12)
            cairo_set_line_width(cr, 1 + i * 2.5); col(cr, c, 0.05 * e); cairo_stroke(cr)
        end
        local o = 3 + 7 * (1 - e)
        corners(cr, x - o, y - o, w + 2 * o, h + 2 * o, 12, c, e, 2)
    end
    rrect(cr, x, y, w, h, 12)
    cairo_set_line_width(cr, 1 + 0.4 * e); col(cr, c, 0.30 + 0.6 * e); cairo_stroke(cr)
    cairo_set_line_width(cr, 3); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, c, 1)
    seg(cr, x + 15, y + 15, x + 15, y + 26)
    local adv = text(cr, title, x + 24, y + 25, DISPLAY, 10.5, true, e > 0.5 and WHITE or c, 1, 'l')
    if pinned == name then
        rrect(cr, x + 34 + adv, y + 13, 50, 15, 7.5); col(cr, c, 0.85); cairo_fill(cr)
        text(cr, 'PINNED', x + 59 + adv, y + 24, DISPLAY, 7, true, BG, 1, 'c')
    end
    if right then text(cr, right, x + w - 15, y + 25, MONO, 10.5, true, TEXT, 1, 'r') end
end

-- remembers a bar or ring value and moves it smoothly while somebody is looking
local draws = 0
local function moved(key, v)
    local o = meter[key]
    if not o then o = {x = v, goal = v}; meter[key] = o end
    o.seen = draws
    if not inside_panel then o.x, o.goal = v, v; return v end
    return tween(o, v, frame_dt, 0.55, BETWEEN)
end

local function bar(cr, x, y, w, h, frac, c, mark)
    frac = clamp(frac, 0, 1)
    rrect(cr, x, y, w, h, h / 2); col(cr, c, 0.15); cairo_fill(cr)
    if frac > 0.004 then rrect(cr, x, y, math.max(h, w * frac), h, h / 2); col(cr, c, 1); cairo_fill(cr) end
    if mark then
        cairo_set_line_width(cr, 2); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, WHITE, 0.9)
        seg(cr, x + w * clamp(mark, 0, 1), y - 4, x + w * clamp(mark, 0, 1), y + h + 4)
    end
end

local function ring(cr, cx, cy, r, w, pct, c, value, sub, e)
    local a0, a1 = math.rad(135), math.rad(405)
    local ae = a0 + (a1 - a0) * clamp(pct, 0, 100) / 100
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, w); col(cr, c, 0.15)
    cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, a1); cairo_stroke(cr)
    if pct > 0.5 then
        for i = 4, 1, -1 do
            cairo_set_line_width(cr, w + i * 3.2); col(cr, c, 0.045 + 0.02 * e)
            cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, ae); cairo_stroke(cr)
        end
        cairo_set_line_width(cr, w); col(cr, c, 1)
        cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, ae); cairo_stroke(cr)
        cairo_set_line_width(cr, w * 0.45); col(cr, WHITE, 0.9)
        cairo_new_path(cr); cairo_arc(cr, cx, cy, r, ae - 0.02, ae); cairo_stroke(cr)
    end
    text(cr, value, cx, cy + r * 0.17, DISPLAY, math.floor(r * 0.44), true, TEXT, 1, 'c')
    if sub then text(cr, sub, cx, cy + r * 0.80, DISPLAY, 7, true, DIM, 1, 'c') end
end

-- history chart over the last five minutes, newest on the right
local function chart(cr, x, y, w, h, series, lo, hi, e, opts)
    opts = opts or {}
    cairo_set_line_width(cr, 1)
    local steps = h > 70 and 4 or 2
    for k = 0, steps do
        col(cr, DIM, k == 0 and 0.30 or 0.13); seg(cr, x, y + h - h * k / steps, x + w, y + h - h * k / steps)
        if opts.fmt and e > 0.4 and h > 60 then
            text(cr, opts.fmt(lo + (hi - lo) * k / steps), x + 3, y + h - h * k / steps + (k == steps and 10 or -3), MONO, 8, false, DIM, smooth((e - 0.4) / 0.5) * 0.9, 'l')
        end
    end
    local step = w / (HISTORY - 1)
    local function py(v) return y + h - clamp((v - lo) / math.max(hi - lo, 0.001), 0, 1) * h end
    for _, s in ipairs(series) do
        local v, c = s[1], s[2]
        local m = #v
        if m > 1 then
            local function px(i) return x + w - (m - i) * step end
            cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
            if s.fill then
                cairo_new_path(cr); cairo_move_to(cr, px(1), y + h)
                for i = 1, m do cairo_line_to(cr, px(i), py(v[i])) end
                cairo_line_to(cr, px(m), y + h); cairo_close_path(cr)
                local g = cairo_pattern_create_linear(0, y, 0, y + h)
                cairo_pattern_add_color_stop_rgba(g, 0, c[1], c[2], c[3], 0.34 * GA)
                cairo_pattern_add_color_stop_rgba(g, 1, c[1], c[2], c[3], 0)
                cairo_set_source(cr, g); cairo_fill(cr); cairo_pattern_destroy(g)
            end
            for pass = 1, 2 do
                cairo_new_path(cr); cairo_move_to(cr, px(1), py(v[1]))
                for i = 2, m do cairo_line_to(cr, px(i), py(v[i])) end
                cairo_set_line_width(cr, pass == 1 and 5 or 1.8); col(cr, c, pass == 1 and 0.15 or 1); cairo_stroke(cr)
            end
            dot(cr, px(m), py(v[m]), 3, c, 1)
        end
    end
    if opts.name and e > 0.97 then
        plots[#plots + 1] = {x = x, y = y, w = w, h = h, s = series, lo = lo, hi = hi, fmt = opts.read or opts.fmt,
            who = opts.who, c = series[1][2]}
    end
end

local function head(cr, label, x, y) text(cr, label, x, y, DISPLAY, 7.5, true, DIM, 1, 'l') end
local function fact(cr, label, value, x, y, w, c)
    text(cr, label, x, y, MONO, 10, false, DIM, 1, 'l')
    text(cr, fit(cr, value, MONO, 10.5, true, w - width_of(cr, label, MONO, 10, false) - 8), x + w, y, MONO, 10.5, true, c or TEXT, 1, 'r')
end
local function bars_list(cr, x, y, w, items, n_max, c, f, top, step)
    step = step or 19
    for i = 1, math.min(n_max, #items) do
        local it = items[i]
        local yy = y + (i - 1) * step
        local cc = it[3] or c
        text(cr, fit(cr, it[1], MONO, 10, false, w * 0.46), x, yy, MONO, 10, false, TEXT, 1, 'l')
        bar(cr, x + w * 0.49, yy - 6, w * 0.51 - 62, 5, it[2] / math.max(top, 0.001), cc)
        text(cr, f(it[2]), x + w, yy, MONO, 10, true, TEXT, 1, 'r')
    end
end

local function mib(v) return v >= 1024 and string.format('%.1f GiB', v / 1024) or string.format('%.0f MiB', v) end
local function rate(k) return k >= 1024 and string.format('%.1f MiB/s', k / 1024) or string.format('%.0f KiB/s', k) end
local function gib(v) return string.format('%.1f GiB', v) end
local function pct(v) return string.format('%.0f%%', v) end
local function span(s)
    s = math.max(0, math.floor(s))
    if s >= 86400 then return string.format('%dd %dh', s // 86400, s % 86400 // 3600) end
    if s >= 3600 then return string.format('%dh %02dm', s // 3600, s % 3600 // 60) end
    return string.format('%dm', s // 60)
end
local function stats(t)
    local lo, hi, s = math.huge, -math.huge, 0
    for _, v in ipairs(t) do lo, hi, s = math.min(lo, v), math.max(hi, v), s + v end
    if #t == 0 then return 0, 0, 0 end
    return lo, hi, s / #t
end
local function heat(v, base) return v >= 88 and RED or (v >= 75 and YELLOW or base) end
local function pairs_of(t)
    local o = {}
    for i = 1, #(t or {}) - 1, 2 do o[#o + 1] = {t[i], tonumber(t[i + 1]) or 0} end
    return o
end

-- ===== row 1: the four vital signs share one frame =====
local function vital(cr, name, g, e, o)
    card(cr, g, o.title, o.c, o.right, e, name)
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    local zone = mix(clamp(h * 0.44, 72, 104), 156, e)           -- ring and facts
    local r = clamp(zone * 0.40, 27, 46)
    local cx, cy = x + r + 8, y + 42 + r + 4
    ring(cr, cx, cy, r, clamp(r * 0.16, 5, 8), moved(name, o.pct), o.ring or o.c, o.value, o.sub, e)
    local lw = mix(w, math.min(w, 318), e)
    local fx, fw = x + 2 * r + 34, lw - 2 * r - 34
    local rows = math.min(#o.facts, math.max(3, math.floor((zone - 8) / 19)))
    for i = 1, rows do fact(cr, o.facts[i][1], o.facts[i][2], fx, y + 58 + (i - 1) * 19, fw, o.facts[i][3]) end
    local cty = y + 44 + zone
    local cth = h - 44 - zone - 22
    chart(cr, x, cty, w, cth, o.series, o.lo, o.hi, e, {fmt = o.fmt, name = name, who = o.who, read = o.read})
    text(cr, '5 min ago', x, y + h - 7, MONO, 8.5, false, DIM, 1, 'l')
    text(cr, o.note, x + w / 2, y + h - 7, MONO, 8.5, false, DIM, 1, 'c')
    text(cr, 'now', x + w, y + h - 7, MONO, 8.5, false, DIM, 1, 'r')
    local a = smooth((e - 0.35) / 0.6)
    if a > 0 then
        local old = GA; GA = GA * a
        cairo_save(cr); cairo_rectangle(cr, g.x, g.y, g.w, g.h); cairo_clip(cr)
        o.detail(x + 342, y + 46, w - 342)
        cairo_restore(cr)
        GA = old
    end
end

local function draw_vitals(cr, G, E)
    local lo, hi, av = stats(n.h_cpu)
    local L = n.load
    vital(cr, 'cpu', G.cpu, E.cpu, {title = 'PROCESSOR', c = CYAN, pct = n.cpu[1], value = pct(n.cpu[1]), sub = 'BUSY',
        right = string.format('%.1f GHz', L[4] or 0), ring = heat(n.cpu[1], CYAN),
        facts = {{'busiest', (d.topcpu or {'-'})[1]},
            {'queue', string.format('%.1f of %d threads', L[1] or 0, n.cpu[2] or 0), (L[1] or 0) > (n.cpu[2] or 16) and RED or nil},
            {'programs', string.format('%d', L[6] or 0)}, {'threads', commas(L[7] or 0)},
            {'15-min queue', string.format('%.1f', L[3] or 0)}, {'top speed', string.format('%.1f GHz', L[5] or 0)},
            {'last 5 min', string.format('%.0f - %.0f%%', lo, hi)}},
        series = {{n.h_cpu, CYAN, fill = true}}, lo = 0, hi = 100, fmt = pct, who = d.who_cpu,
        note = string.format('average %.0f%%   peak %.0f%%', av, hi),
        detail = function(x, y, w)
            head(cr, 'EVERY THREAD', x, y + 4)
            local cw = (w + 4) / math.max(1, #n.cores)
            for i, v in ipairs(n.cores) do
                local bx, bh = x + (i - 1) * cw, 44
                rrect(cr, bx, y + 12, cw - 4, bh, 3); col(cr, CYAN, 0.12); cairo_fill(cr)
                local fh = math.max(3, bh * v / 100)
                rrect(cr, bx, y + 12 + bh - fh, cw - 4, fh, math.min(3, fh / 2)); col(cr, heat(v, CYAN), 1); cairo_fill(cr)
            end
            head(cr, 'BUSIEST NOW  (100% = one thread)', x, y + 76)
            local t = pairs_of(d.topcpu)
            bars_list(cr, x, y + 94, w, t, 4, CYAN, pct, t[1] and t[1][2] or 1, 17)
        end})

    local M = n.memx
    local swap_full = (M[5] or 0) > 0 and (M[4] or 0) / M[5] or 0
    lo, hi, av = stats(n.h_mem)
    vital(cr, 'mem', G.mem, E.mem, {title = 'MEMORY', c = MAGENTA, pct = n.mem[1], value = pct(n.mem[1]), sub = 'USED',
        right = string.format('%.1f / %.1f GiB', n.mem[2] or 0, n.mem[3] or 0), ring = heat(n.mem[1], MAGENTA),
        facts = {{'biggest', (d.topmem or {'-'})[1]}, {'available', gib(M[3] or 0), (M[3] or 9) < 2 and RED or nil},
            {'swap', swap_full > 0.97 and 'FULL  ' .. gib(M[5]) or string.format('%.1f of %.1f GiB', M[4] or 0, M[5] or 0),
                swap_full > 0.97 and RED or (swap_full > 0.75 and YELLOW or nil)},
            {'file cache', gib(M[2] or 0)}, {'apps', gib(M[1] or 0)}, {'installed', gib(n.mem[3] or 0)},
            {'last 5 min', string.format('%.0f - %.0f%%', lo, hi)}},
        series = {{n.h_mem, MAGENTA, fill = true}}, lo = 0, hi = 100, fmt = pct, who = d.who_mem, read = pct,
        note = string.format('average %.0f%%   peak %.0f%%', av, hi),
        detail = function(x, y, w)
            head(cr, 'WHERE IT GOES', x, y + 4)
            local total = math.max(n.mem[3] or 1, 0.1)
            local parts = {{M[1] or 0, MAGENTA, 'apps'}, {math.max(0, math.min(M[2] or 0, total - (M[1] or 0))), CYAN, 'cache'}}
            rrect(cr, x, y + 12, w, 14, 7); col(cr, DIM, 0.2); cairo_fill(cr)
            local bx = x
            for _, p in ipairs(parts) do
                local pw = w * p[1] / total
                if pw > 4 then rrect(cr, bx, y + 12, pw - 2, 14, math.min(7, (pw - 2) / 2)); col(cr, p[2], 0.95); cairo_fill(cr) end
                bx = bx + pw
            end
            local lx = x
            for _, p in ipairs({{MAGENTA, 'apps ' .. gib(M[1] or 0)}, {CYAN, 'cache ' .. gib(M[2] or 0)}, {DIM, 'free'}}) do
                rrect(cr, lx, y + 35, 8, 8, 2); col(cr, p[1], 1); cairo_fill(cr)
                lx = lx + 13 + text(cr, p[2], lx + 13, y + 43, MONO, 9, false, TEXT, 1, 'l') + 14
            end
            head(cr, 'BIGGEST APPS', x, y + 66)
            local t = pairs_of(d.topmem)
            bars_list(cr, x, y + 84, w, t, 5, MAGENTA, mib, t[1] and t[1][2] or 1, 17)
        end})

    local X = n.gpux
    lo, hi, av = stats(n.h_gpu)
    local idle = (X[2] or 0) > 0 and (X[3] or 0) > 0 and X[2] / X[3] < 0.25
    vital(cr, 'gpu', G.gpu, E.gpu, {title = 'GRAPHICS', c = GREEN, pct = n.gpu[1], value = pct(n.gpu[1]), sub = 'NVIDIA',
        right = string.format('%.0f W', X[1] or 0), ring = heat(n.gpu[1], GREEN),
        facts = {{'clock', string.format('%.0f MHz%s', X[2] or 0, idle and ' (idling)' or '')},
            {'VRAM', string.format('%s of %s', mib(n.gpu[2] or 0), mib(n.gpu[3] or 0)), (n.gpu[2] or 0) / math.max(1, n.gpu[3] or 1) > 0.9 and RED or nil},
            {'Radeon 780M', pct(X[5] or 0)}, {'temperature', string.format('%.0f°', n.temp[2] or 0)},
            {'power state', (d.gpux or {})[4] or '?'}, {'top clock', string.format('%.0f MHz', X[3] or 0)},
            {'last 5 min', string.format('%.0f - %.0f%%', lo, hi)}},
        series = {{n.h_gpu, GREEN, fill = true, 'NVIDIA'}, {n.h_rgpu, YELLOW, 'Radeon'}}, lo = 0, hi = 100, fmt = pct,
        note = 'NVIDIA filled, Radeon line',
        detail = function(x, y, w)
            head(cr, 'GRAPHICS MEMORY', x, y + 4)
            fact(cr, 'NVIDIA', mib(n.gpu[2] or 0) .. ' / ' .. mib(n.gpu[3] or 0), x, y + 22, w)
            bar(cr, x, y + 28, w, 5, (n.gpu[2] or 0) / math.max(1, n.gpu[3] or 1), GREEN)
            fact(cr, 'Radeon', mib(X[6] or 0) .. ' / ' .. mib(X[7] or 1), x, y + 52, w)
            bar(cr, x, y + 58, w, 5, (X[6] or 0) / math.max(1, X[7] or 1), YELLOW)
            head(cr, 'NVIDIA MEMORY BY APP', x, y + 86)
            local t = pairs_of(d.topgpu)
            bars_list(cr, x, y + 104, w, t, 2, GREEN, mib, t[1] and t[1][2] or 1, 17)
            if #t == 0 then text(cr, 'nothing is using it', x, y + 104, MONO, 10, false, DIM, 1, 'l') end
            local bw = bwidth(cr, 'OPEN NVTOP')
            button(cr, 'OPEN NVTOP', x + w - bw, y + 130, bw, false, GREEN, function() act('open', 'gpu') end)
        end})

    local S = pairs_of(d.sens)
    table.sort(S, function(a, b) return a[2] > b[2] end)
    lo, hi, av = stats(n.h_ctemp)
    local hot = 0
    for _, v in ipairs(n.h_ctemp) do if v >= 85 then hot = hot + SAMPLE_S end end
    local ssd = 0
    for _, s in ipairs(S) do if s[1]:match('^SSD') then ssd = math.max(ssd, s[2]) end end
    vital(cr, 'temp', G.temp, E.temp, {title = 'TEMPERATURE', c = YELLOW, pct = n.temp[1], value = string.format('%.0f°', n.temp[1] or 0),
        sub = 'CPU', right = string.format('peak %.0f°', hi), ring = (n.temp[1] or 0) >= 88 and RED or ((n.temp[1] or 0) >= 75 and YELLOW or GREEN),
        facts = {{'GPU', string.format('%.0f°', n.temp[2] or 0)}, {'hottest SSD', string.format('%.0f°', ssd), ssd >= 70 and RED or nil},
            {'above 85°', hot == 0 and 'not in 5 min' or string.format('%d s of last 5 min', hot), hot > 60 and RED or nil},
            {'average', string.format('%.0f°', av)}, {'fans', d.fan and d.fan[5] or '?'},
            {'fan speed', string.format('%.0f rpm', n.fan[1] or 0)}, {'lowest', string.format('%.0f°', lo)}},
        series = {{n.h_ctemp, YELLOW, fill = true, 'CPU'}, {n.h_gtemp, GREEN, 'GPU'}}, lo = 30, hi = 100,
        fmt = function(v) return string.format('%.0f°', v) end, note = 'CPU filled, GPU line',
        detail = function(x, y, w)
            head(cr, 'EVERY SENSOR', x, y + 4)
            local t = {}
            for i, s in ipairs(S) do t[i] = {s[1], s[2], s[2] >= 85 and RED or (s[2] >= 70 and YELLOW or GREEN)} end
            bars_list(cr, x, y + 22, w, t, 7, GREEN, function(v) return string.format('%.0f°', v) end, 100, 19)
        end})
end

-- ===== apps =====
local function apps_now()
    local list, by = {}, {}
    for _, a in ipairs(d.app or {}) do
        local it = {id = a[1], name = a[2], cpu = tonumber(a[3]) or 0, ram = tonumber(a[4]) or 0, io = tonumber(a[5]) or 0,
            n = tonumber(a[6]) or 0, thr = tonumber(a[7]) or 0, vram = tonumber(a[8]) or 0, age = tonumber(a[9]) or 0,
            can = a[10], spark = {}, rd = tonumber(a[12]) or 0, wr = tonumber(a[13]) or 0, down = tonumber(a[14]) or 0,
            up = tonumber(a[15]) or 0, conns = tonumber(a[16]) or 0}
        it.net = it.down + it.up
        for v in (a[11] or ''):gmatch('[^,]+') do it.spark[#it.spark + 1] = tonumber(v) or 0 end
        list[#list + 1], by[it.id] = it, it
    end
    -- while the pointer is on the table the order is frozen, so nothing slips away under a click
    if focus == 'apps' and #order > 0 then
        local out, seen = {}, {}
        for _, id in ipairs(order) do if by[id] then out[#out + 1] = by[id]; seen[id] = true end end
        for _, it in ipairs(list) do if not seen[it.id] then out[#out + 1] = it; order[#order + 1] = it.id end end
        return out
    end
    table.sort(list, function(a, b)
        if sort_by == 'name' then return a.name:lower() < b.name:lower() end
        if a[sort_by] == b[sort_by] then return a.ram > b.ram end
        return a[sort_by] > b[sort_by]
    end)
    order = {}
    for i, it in ipairs(list) do order[i] = it.id end
    return list
end

local function draw_apps(cr, g, e)
    card(cr, g, 'APPS', CYAN, nil, e, 'apps')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    local hint = 'sorted by ' .. ({cpu = 'processor', ram = 'memory', io = 'disk', net = 'network', rd = 'disk reads', wr = 'disk writes',
        down = 'download', up = 'upload', age = 'age', name = 'name'})[sort_by]
    if e < 0.9 then text(cr, hint, x + w, y + 25, MONO, 9.5, false, DIM, 1 - e, 'r') end
    if e > 0.4 then
        local old = GA; GA = GA * smooth((e - 0.4) / 0.5)
        local bw = bwidth(cr, 'SYSTEM MONITOR')
        button(cr, 'SYSTEM MONITOR', x + w - bw, y + 9, bw, false, CYAN, function() act('open', 'monitor') end)
        text(cr, 'click a row for actions, a heading to sort', x + w - bw - 14, y + 25, MONO, 9.5, false, DIM, 1, 'r')
        GA = old
    end
    local list = apps_now()
    -- columns
    local big = e
    -- closed: PROCESSOR MEMORY DISK NETWORK; open: disk and network split in two, then PROCS and RUNNING
    local split = smooth((big - 0.5) * 2)
    local c_age = x + w
    local c_n = c_age - 78 * big
    local c_up = c_age - 128 * big
    local c_net = c_age - mix(0, 204, big)
    local c_wr = c_age - mix(76, 280, big)
    local c_io = c_age - mix(76, 356, big)
    local c_ram = c_age - mix(152, 442, big)
    local c_cpu = c_age - mix(238, 530, big)
    local sx, sw = x + 206, math.max(40, c_cpu - 74 - (x + 206))
    local hy = y + 54
    local function column(label, key, cx, al)
        local on = sort_by == key
        local lw = width_of(cr, label, DISPLAY, 8, true)
        text(cr, label, cx, hy, DISPLAY, 8, true, on and CYAN or DIM, 1, al)
        local bx = al == 'r' and cx - lw or cx
        if on then cairo_set_line_width(cr, 1.5); col(cr, CYAN, 0.9); seg(cr, bx, hy + 4, bx + lw, hy + 4) end
        region(bx - 8, hy - 14, lw + 16, 22, function() sort_by = key; order = {} local f = focus; focus = nil; apps_now(); focus = f end, 6, CYAN)
    end
    column('APP', 'name', x + 4, 'l')
    text(cr, 'LAST 80 S', sx, hy, DISPLAY, 8, true, DIM, 1, 'l')
    column('PROCESSOR', 'cpu', c_cpu, 'r'); column('MEMORY', 'ram', c_ram, 'r')
    if split < 1 then
        local old = GA; GA = GA * (1 - split)
        column('DISK', 'io', c_io, 'r'); column('NETWORK', 'net', c_net, 'r')
        GA = old
    end
    if split > 0 then
        local old = GA; GA = GA * split
        column('READ', 'rd', c_io, 'r'); column('WRITE', 'wr', c_wr, 'r')
        column('DOWN', 'down', c_net, 'r'); column('UP', 'up', c_up, 'r')
        text(cr, 'PROCS', c_n, hy, DISPLAY, 8, true, DIM, 1, 'r'); column('RUNNING', 'age', c_age, 'r')
        GA = old
    end
    local top, room = y + 64, h - 64 - 8
    local rowh = clamp(room / math.max(1, math.floor(room / 25)), 22, 30)
    local count = math.min(#list, math.floor(room / rowh))
    local mcpu, mram = 1, 1
    for _, a in ipairs(list) do mcpu, mram = math.max(mcpu, a.cpu), math.max(mram, a.ram) end
    cairo_save(cr); cairo_rectangle(cr, g.x, top, g.w, room + 4); cairo_clip(cr)
    local shown = {}
    for i = 1, count do
        local a = list[i]
        shown[a.id] = true
        -- rows move between slots, so they always travel with their card
        local goal = i - 1
        local o = rowpos[a.id]
        if not o then o = {x = goal, goal = goal}; rowpos[a.id] = o end
        if inside_panel then tween(o, goal, frame_dt, 0.5, BETWEEN) else o.x, o.goal = goal, goal end
        local yy = top + o.x * rowh
        local by = yy + rowh / 2 + 4
        local sel = selected == a.id
        if sel then
            rrect(cr, g.x + 8, yy + 1, g.w - 16, rowh - 2, 7); col(cr, CYAN, 0.16); cairo_fill_preserve(cr)
            cairo_set_line_width(cr, 1); col(cr, CYAN, 0.8); cairo_stroke(cr)
        elseif i % 2 == 0 then
            rrect(cr, g.x + 8, yy + 1, g.w - 16, rowh - 2, 7); col(cr, CYAN, 0.035); cairo_fill(cr)
        end
        local cc = a.cpu >= 200 and RED or (a.cpu >= 80 and YELLOW or CYAN)
        dot(cr, x + 4, by - 4, 3, a.cpu >= 5 and cc or DIM, a.cpu >= 5 and 1 or 0.5)
        text(cr, fit(cr, a.name, MONO, 11, true, 180), x + 14, by, MONO, 11, true, sel and WHITE or TEXT, 1, 'l')
        region(g.x + 8, yy, g.w - 16, rowh, function()
            selected = selected ~= a.id and a.id or nil
            confirm = nil
        end, 7, CYAN)
        if sel then
            local bx = sx
            local function pill(label, c, fn)
                local bw = bwidth(cr, label)
                button(cr, label, bx, yy + rowh / 2 - 10, bw, confirm and confirm.id == a.id and confirm.label == label, c, fn, 20)
                bx = bx + bw + 6
            end
            if a.can == '-' then
                text(cr, 'part of the system: no actions', bx, by, MONO, 9.5, false, DIM, 1, 'l')
            else
                local sure = confirm and confirm.id == a.id and T < confirm.till
                local verb = a.can == 'restart' and 'RESTART' or 'END APP'
                local label = sure and 'SURE? CLICK AGAIN' or verb
                pill(label, a.can == 'restart' and YELLOW or RED, function()
                    if confirm and confirm.id == a.id and T < confirm.till then
                        act(a.can, a.id); confirm, selected = nil, nil
                    else confirm = {id = a.id, till = T + 4, label = 'SURE? CLICK AGAIN'} end
                end)
                if bx + 110 < c_cpu - 60 and not sure then
                    pill('GIVE WAY', CYAN, function() act('nice', a.id); selected = nil end)
                end
            end
        elseif #a.spark > 1 then
            local pk = 1
            for _, v in ipairs(a.spark) do pk = math.max(pk, v) end
            line(cr, sx, yy + 5, sw, rowh - 10, a.spark, math.max(pk, 8), cc, true, 1.3)
        end
        text(cr, a.cpu >= 0.05 and string.format('%.1f%%', a.cpu) or '0%', c_cpu, by, MONO, 11, true, a.cpu >= 5 and cc or DIM, 1, 'r')
        bar(cr, c_cpu - 108 + 52, yy + rowh - 4, 56, 2, moved('c' .. a.id, a.cpu) / mcpu, cc)
        text(cr, mib(a.ram), c_ram, by, MONO, 11, true, a.ram >= 2048 and MAGENTA or TEXT, 1, 'r')
        bar(cr, c_ram - 56, yy + rowh - 4, 56, 2, moved('m' .. a.id, a.ram) / mram, MAGENTA)
        local function cell(v, cx, hot)
            text(cr, v >= 1 and rate(v) or '-', cx, by, MONO, 10, false, v >= 1024 and hot or (v >= 1 and TEXT or DIM), 1, 'r')
        end
        if split < 1 then
            local old = GA; GA = GA * (1 - split)
            cell(a.io, c_io, YELLOW); cell(a.net, c_net, GREEN)
            GA = old
        end
        if split > 0 then
            local old = GA; GA = GA * split
            cell(a.rd, c_io, YELLOW); cell(a.wr, c_wr, YELLOW); cell(a.down, c_net, GREEN); cell(a.up, c_up, GREEN)
            text(cr, string.format('%d', a.n), c_n, by, MONO, 10, false, TEXT, 1, 'r')
            text(cr, span(a.age), c_age, by, MONO, 10, false, TEXT, 1, 'r')
            GA = old
        end
    end
    cairo_restore(cr)
    for id in pairs(rowpos) do if not shown[id] then rowpos[id] = nil end end
end

-- ===== apps as the network and the disk see them =====
-- rows: {id, name, values...}; cols: {label, right edge, index, format, colour, alpha}. A click shows the app in the table.
local function app_list(cr, x, y, w, title, rows, cols, count, extra, a, key)
    head(cr, title, x, y)
    for _, c in ipairs(cols) do
        if (c[6] or 1) > 0.01 then text(cr, c[1], c[2], y, DISPLAY, 7.5, true, DIM, c[6] or 1, 'r') end
    end
    local left = cols[1][2]
    for _, c in ipairs(cols) do if (c[6] or 1) > 0.5 then left = math.min(left, c[2]) end end
    for i = 1, math.min(#rows, count + extra) do
        local row, yy = rows[i], y + i * 18
        local old = GA
        if i > count then GA = GA * a end
        if GA > 0.01 then
            local busy = (row.rate or 0) >= 1
            text(cr, fit(cr, row.name, MONO, 10, busy, left - 74 - x), x, yy, MONO, 10, busy, row.id and TEXT or DIM, busy and 1 or 0.8, 'l')
            for _, c in ipairs(cols) do
                local v = row[c[3]] or 0
                if (c[6] or 1) > 0.01 then
                    text(cr, v >= (c.min or 1) and c[4](v) or '-', c[2], yy, MONO, 10, false, v >= (c.min or 1) and (c.plain and TEXT or c[5]) or DIM, c[6] or 1, 'r')
                end
            end
            if row.id and GA > 0.85 then
                region(x - 6, yy - 13, w + 12, 18, function() sort_by, selected, order, confirm = key, row.id, {}, nil end, 6, cols[1][5])
            end
        end
        GA = old
    end
    if #rows == 0 then text(cr, 'quiet', x, y + 18, MONO, 10, false, DIM, 1, 'l') end
end

-- ===== network =====
local function draw_net(cr, g, e)
    card(cr, g, 'NETWORK', GREEN, (d.net or {})[3], e, 'net')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    local half = (w - 12) / 2
    for i, k in ipairs({{'DOWN', n.net[1] or 0, GREEN}, {'UP', n.net[2] or 0, CYAN}}) do
        local bx = x + (i - 1) * (half + 12)
        head(cr, k[1], bx, y + 50)
        text(cr, rate(k[2]), bx, y + 72, DISPLAY, 15, true, k[3], 1, 'l')
    end
    local extra = mix(0, 104, e)
    local cy, ch = y + 86, h - 86 - 52 - 76 - extra
    local top = math.max(40, (select(2, stats(n.h_down))), (select(2, stats(n.h_up)))) * 1.1
    -- down above the line, up below it
    local up = ch * 0.4
    chart(cr, x, cy, w, ch - up, {{n.h_down, GREEN, fill = true, 'down'}}, 0, top, e, {fmt = rate, name = 'net'})
    local flipped = {}
    for i, v in ipairs(n.h_up) do flipped[i] = v end
    cairo_save(cr); cairo_translate(cr, 0, 2 * (cy + ch - up)); cairo_scale(cr, 1, -1)
    chart(cr, x, cy + ch - up - up, w, up, {{flipped, CYAN, fill = true}}, 0, top, 0)
    cairo_restore(cr)
    if e > 0.97 then plots[#plots].also = {y = cy + ch - up, h = up, s = n.h_up, c = CYAN, name = 'up'} end
    local ny = cy + ch + 18
    local N = d.netx or {}
    local sig = tonumber(N[2]) or 0
    text(cr, fit(cr, N[1] ~= '' and N[1] or 'wired or offline', MONO, 10, true, w - 96), x, ny, MONO, 10, true, TEXT, 1, 'l')
    for i = 1, 4 do
        local bh = 4 + i * 3
        rrect(cr, x + w - 62 + i * 8, ny - bh + 1, 5, bh, 1.5); col(cr, GREEN, sig >= i * 25 - 20 and 1 or 0.2); cairo_fill(cr)
    end
    text(cr, sig > 0 and pct(sig) or '', x + w, ny, MONO, 10, false, DIM, 1, 'r')
    text(cr, fit(cr, string.format('since boot: %s down, %s up', gib(tonumber(N[5]) or 0), gib(tonumber(N[6]) or 0)), MONO, 9, false, w), x, ny + 18,
        MONO, 9, false, DIM, 1, 'l')
    local a = smooth((e - 0.4) / 0.55)
    -- who is using it: the three busiest, six when open
    local rows = {}
    for _, p in ipairs(d.napp or {}) do
        local it = {id = p[1], name = p[2], tonumber(p[3]) or 0, tonumber(p[4]) or 0, tonumber(p[5]) or 0}
        it[4] = (tonumber(p[6]) or 0) + (tonumber(p[7]) or 0)
        it.rate = it[1] + it[2]
        if p[2] == 'other users' then it.id = nil end
        rows[#rows + 1] = it
    end
    local un = n.netu or {}
    if (un[1] or 0) + (un[2] or 0) >= 1 then
        rows[#rows + 1] = {name = 'not per app (QUIC, calls, DNS)', un[1] or 0, un[2] or 0, 0, 0, rate = (un[1] or 0) + (un[2] or 0)}
        table.sort(rows, function(p, q) if p.rate ~= q.rate then return p.rate > q.rate end return (p[4] or 0) > (q[4] or 0) end)
    end
    local ly = ny + 40
    app_list(cr, x, ly, w, 'BY APP', rows, {
        {'UP', x + w, 2, rate, CYAN}, {'DOWN', x + w - 84, 1, rate, GREEN},
        {'SINCE START', x + w - 176, 4, mib, TEXT, a, plain = true},
        {'OPEN', x + w - 262, 3, function(v) return string.format('%.0f', v) end, TEXT, a, plain = true},
    }, 3, 3, a, 'net')
    if a > 0 then
        local old = GA; GA = GA * a
        local dy = ly + 7 * 18 + 8
        local half2 = (w - 16) / 2
        fact(cr, 'address', N[4] or '-', x, dy, half2); fact(cr, 'link', N[3] or '-', x, dy + 18, half2)
        button(cr, 'NETWORK SETTINGS', x + half2 + 16, dy - 12, half2, false, GREEN, function() act('open', 'network') end)
        GA = old
    end
end

-- ===== storage =====
local function draw_disk(cr, g, e)
    local used = n.disk[1] or 0
    local c = used >= 95 and RED or (used >= 88 and YELLOW or CYAN)
    card(cr, g, 'STORAGE', c, string.format('%.0f%% full', used), e, 'disk')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    local adv = text(cr, string.format('%.1f', n.disk[2] or 0), x, y + 74, DISPLAY, 26, true, TEXT, 1, 'l')
    text(cr, 'GiB free', x + adv + 8, y + 74, MONO, 10.5, false, DIM, 1, 'l')
    text(cr, string.format('of %.0f', n.disk[3] or 0), x + w, y + 74, MONO, 10.5, false, DIM, 1, 'r')
    bar(cr, x, y + 86, w, 8, moved('disk', used) / 100, c)
    local ch24 = tonumber((d.diskx or {})[3] or '')
    local hrs = tonumber((d.diskx or {})[4] or '')
    local note = 'learning how fast it fills'
    local nc = DIM
    if ch24 and hrs and hrs > 1 then
        local perday = ch24 / hrs * 24
        note = string.format('%s%.1f GiB in the last %.0f h', ch24 >= 0 and '+' or '', ch24, hrs)
        if perday < -0.5 then note = note .. string.format(', full in %d days', math.floor((n.disk[2] or 0) / -perday)); nc = YELLOW end
    end
    text(cr, fit(cr, note, MONO, 9.5, false, w), x, y + 112, MONO, 9.5, false, nc, 1, 'l')
    local extra = mix(0, 100, e)
    local cy, chh = y + 144, h - 144 - 24 - 80 - extra
    local top = math.max(1024, (select(2, stats(n.h_read))), (select(2, stats(n.h_write)))) * 1.1
    text(cr, 'read ' .. rate((n.diskx or {})[1] or 0), x, y + 134, MONO, 9.5, true, CYAN, 1, 'l')
    text(cr, 'write ' .. rate((n.diskx or {})[2] or 0), x + w, y + 134, MONO, 9.5, true, MAGENTA, 1, 'r')
    if chh > 24 then
        chart(cr, x, cy, w, chh, {{n.h_read, CYAN, fill = true, 'read'}, {n.h_write, MAGENTA, 'write'}}, 0, top, e, {fmt = rate, name = 'disk'})
    end
    text(cr, '5 min ago', x, cy + chh + 15, MONO, 8.5, false, DIM, 1, 'l'); text(cr, 'now', x + w, cy + chh + 15, MONO, 8.5, false, DIM, 1, 'r')
    local a = smooth((e - 0.4) / 0.55)
    local rows = {}
    for _, p in ipairs(d.dapp or {}) do
        local it = {id = p[1], name = p[2], tonumber(p[3]) or 0, tonumber(p[4]) or 0, tonumber(p[5]) or 0, tonumber(p[6]) or 0}
        it.rate = it[1] + it[2]
        rows[#rows + 1] = it
    end
    local dy = cy + chh + 38
    app_list(cr, x, dy, w, 'BY APP', rows, {
        {'WRITE', x + w, 2, rate, MAGENTA}, {'READ', x + w - 84, 1, rate, CYAN},
        {'WRITTEN', x + w - 176, 4, mib, TEXT, a, plain = true}, {'READ IN ALL', x + w - 262, 3, mib, TEXT, a, plain = true},
    }, 3, 3, a, 'io')
    if a > 0 then
        local old = GA; GA = GA * a
        local bw = (w - 8) / 2
        local by2 = dy + 6 * 18 + 14
        button(cr, 'FILES', x, by2, bw, false, CYAN, function() act('open', 'files') end)
        button(cr, 'WHAT FILLS IT', x + bw + 8, by2, bw, false, c, function() act('open', 'disk') end)
        GA = old
    end
end

-- ===== Claude usage, with pace =====
local function limit(cr, x, y, w, label, p, reset, window, fmtd)
    p, reset = tonumber(p) or -1, tonumber(reset) or 0
    local now = os.time()
    local gone = reset > 0 and reset <= now
    if gone then p = 0 end
    local cc = p >= 90 and RED or (p >= 70 and YELLOW or CYAN)
    head(cr, label, x, y)
    local adv = text(cr, p < 0 and '--' or pct(p), x, y + 34, DISPLAY, 25, true, cc, 1, 'l')
    text(cr, 'used', x + adv + 8, y + 34, MONO, 10, false, DIM, 1, 'l')
    local right, say, sc = 'no reset time', '', DIM
    local mark
    if gone then right = 'window has reset'
    elseif reset > now then
        right = 'resets in ' .. span(reset - now)
        local f = clamp(1 - (reset - now) / window, 0.001, 1)
        mark = f
        if p > 1 and f > 0.03 then
            local proj = p / f
            if proj > 100 then
                local left = (100 - p) / (p / (f * window))
                say, sc = 'at this pace it runs out in ' .. span(left), RED
            else say, sc = string.format('on course for %.0f%% at the reset', proj), proj > 85 and YELLOW or GREEN end
        end
    end
    text(cr, right, x + w, y + 18, MONO, 10.5, true, TEXT, 1, 'r')
    if reset > now then text(cr, os.date(fmtd, reset), x + w, y + 34, MONO, 9.5, false, DIM, 1, 'r') end
    bar(cr, x, y + 48, w, 8, moved('cl' .. label, math.max(0, p)) / 100, cc, mark)
    text(cr, fit(cr, say, MONO, 9.5, false, w), x, y + 75, MONO, 9.5, false, sc, 1, 'l')
end

local function draw_claude(cr, g, e)
    local c = d.claude
    card(cr, g, 'CLAUDE USAGE', ORANGE, c and c[5] or nil, e, 'claude')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    if not c then
        text(cr, 'waiting for a Claude Code session to report usage', x, y + 70, MONO, 11, false, DIM, 1, 'l')
        return
    end
    local cw = (w - 2 * 26) / 3
    limit(cr, x, y + 56, cw, '5-HOUR SESSION', c[1], c[2], 5 * 3600, 'at %H:%M')
    limit(cr, x + cw + 26, y + 56, cw, 'WEEK, ALL MODELS', c[3], c[4], 7 * 86400, '%a %d %b, %H:%M')
    local x3 = x + 2 * (cw + 26)
    head(cr, 'THIS SESSION', x3, y + 56)
    local ctx = tonumber(c[6]) or 0
    fact(cr, 'context used', pct(ctx), x3, y + 78, cw, ctx >= 80 and YELLOW or MAGENTA)
    bar(cr, x3, y + 86, cw, 5, moved('ctx', ctx) / 100, MAGENTA)
    fact(cr, 'cost at API rates', string.format('$%.2f', tonumber(c[7]) or 0), x3, y + 112, cw, GREEN)
    local age = os.time() - (tonumber(c[8]) or os.time())
    fact(cr, 'reported', age < 90 and 'live' or span(age) .. ' ago', x3, y + 131, cw, age > 3600 and YELLOW or nil)
    local a = math.max(smooth((e - 0.4) / 0.55), smooth((g.h - 236) / 60))
    local by = y + 148
    if h > 176 then
        local old = GA; GA = GA * (1 - a * 0.999)
        text(cr, 'white mark = where an even pace would be', x, y + h - 14, MONO, 9, false, DIM, 1, 'l')
        GA = old
    end
    if a > 0 then
        local old = GA; GA = GA * a
        local bw = bwidth(cr, 'OPEN USAGE PAGE')
        button(cr, 'OPEN USAGE PAGE', x + w - bw, by + 4, bw, false, ORANGE, function() act('open', 'usage') end)
        head(cr, 'LAST 24 HOURS', x, by + 16)
        rrect(cr, x + 112, by + 8, 8, 8, 2); col(cr, GREEN, 1); cairo_fill(cr)
        local ad = text(cr, '5-hour', x + 125, by + 16, MONO, 9, false, TEXT, 1, 'l')
        rrect(cr, x + 138 + ad, by + 8, 8, 8, 2); col(cr, ORANGE, 1); cairo_fill(cr)
        text(cr, 'week', x + 151 + ad, by + 16, MONO, 9, false, TEXT, 1, 'l')
        local cy, ch = by + 34, h - (by - y) - 34 - 22
        local tt, a5, aw = n.cl_t or {}, n.cl_5 or {}, n.cl_w or {}
        if #tt > 2 and ch > 20 then
            local t0, t1 = tt[1], tt[#tt]
            for k = 0, 2 do cairo_set_line_width(cr, 1); col(cr, DIM, 0.15); seg(cr, x, cy + ch * k / 2, x + w, cy + ch * k / 2) end
            for _, s in ipairs({{aw, ORANGE}, {a5, GREEN}}) do
                cairo_new_path(cr)
                for i, t in ipairs(tt) do
                    local px, py = x + w * (t - t0) / math.max(1, t1 - t0), cy + ch - ch * clamp((s[1][i] or 0) / 100, 0, 1)
                    if i == 1 then cairo_move_to(cr, px, py) else cairo_line_to(cr, px, py) end
                end
                cairo_set_line_width(cr, 2); col(cr, s[2], 1); cairo_stroke(cr)
            end
            text(cr, os.date('%a %H:%M', math.floor(t0)), x, y + h - 8, MONO, 8.5, false, DIM, 1, 'l')
            text(cr, 'now', x + w, y + h - 8, MONO, 8.5, false, DIM, 1, 'r')
        else
            text(cr, 'the history starts building now and shows here after a few minutes', x, cy + 22, MONO, 10, false, DIM, 1, 'l')
        end
        GA = old
    end
end

-- ===== cooling =====
local fans_at = {}
local function draw_cool(cr, g, e)
    local mode = d.fan and d.fan[5] or '?'
    card(cr, g, 'COOLING', MAGENTA, mode:lower():gsub('_', ' '), e, 'cool')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    local r = clamp(h * 0.145, 24, 34)
    fans_at = {}
    local half = w / 2
    for i = 1, 2 do
        local cx, cy = x + (i - 1) * half + r + 4, y + 46 + r
        local rpm, top = n.fan[i] or 0, math.max(n.fan[i + 2] or 6000, 1)
        local c = i == 1 and MAGENTA or YELLOW
        cairo_set_line_width(cr, 4); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, c, 0.15)
        cairo_new_path(cr); cairo_arc(cr, cx, cy, r, 0, 2 * math.pi); cairo_stroke(cr)
        col(cr, c, 1); cairo_new_path(cr)
        cairo_arc(cr, cx, cy, r, -math.pi / 2, -math.pi / 2 + 2 * math.pi * clamp(moved('fan' .. i, rpm) / top, 0, 0.999)); cairo_stroke(cr)
        fans_at[i] = {cx, cy, r - 7, rpm, c}
        head(cr, 'FAN ' .. i, cx + r + 12, cy - 10)
        text(cr, string.format('%.0f', rpm), cx + r + 12, cy + 8, DISPLAY, 14, true, TEXT, 1, 'l')
        text(cr, string.format('%.0f%% of max', 100 * rpm / top), cx + r + 12, cy + 24, MONO, 9, false, DIM, 1, 'l')
    end
    local by = y + 46 + 2 * r + 16
    local modes = {{'AUTO', 'AUTO'}, {'SMART', 'BETTER_AUTO'}, {'MAX', 'MAX'}}
    local bw = (w - 16) / 3
    for i, m in ipairs(modes) do
        button(cr, m[1], x + (i - 1) * (bw + 8), by, bw, mode == m[2], MAGENTA, function() act('fan', m[2]) end, 24)
    end
    local fy = by + 46
    if fy < y + h - 4 then
        text(cr, fit(cr, string.format('CPU %.0f°   GPU %.0f°   keyboard %s', n.temp[1] or 0, n.temp[2] or 0,
            ((d.kbd or {'-'})[1] or '-'):lower()), MONO, 9.5, false, w), x, fy, MONO, 9.5, false, DIM, 1, 'l')
    end
    local a = math.max(smooth((e - 0.4) / 0.55), smooth((g.h - 236) / 60))
    if a > 0 then
        local old = GA; GA = GA * a
        local cy, ch = fy + 14, y + h - 24 - (fy + 14)
        if ch > 24 then
            local top = math.max(n.fan[3] or 6000, n.fan[4] or 6000) * 1.05
            chart(cr, x, cy, w, ch, {{n.h_fan1, MAGENTA, fill = true, 'fan 1'}, {n.h_fan2, YELLOW, 'fan 2'}}, 0, top, e,
                {fmt = function(v) return string.format('%.0f rpm', v) end, name = 'cool'})
            text(cr, '5 min ago', x, y + h - 8, MONO, 8.5, false, DIM, 1, 'l'); text(cr, 'now', x + w, y + h - 8, MONO, 8.5, false, DIM, 1, 'r')
        end
        GA = old
    end
end

-- ===== power =====
local function draw_power(cr, g, e)
    local b = d.bat or {}
    local p = tonumber(b[1]) or 0
    local state = b[2] or '?'
    local c = p <= 15 and RED or (p <= 35 and YELLOW or GREEN)
    card(cr, g, 'POWER', GREEN, state:lower() == 'full' and 'plugged in, full' or state:lower(), e, 'power')
    local x, y, w, h = g.x + 15, g.y, g.w - 30, g.h
    -- the battery itself
    local bw, bh = 92, clamp(h * 0.19, 34, 46)
    local by = y + 46
    rrect(cr, x, by, bw, bh, 8); cairo_set_line_width(cr, 2); col(cr, c, 0.8); cairo_stroke(cr)
    rrect(cr, x + bw + 3, by + bh * 0.3, 5, bh * 0.4, 2); col(cr, c, 0.8); cairo_fill(cr)
    rrect(cr, x + 4, by + 4, math.max(8, (bw - 8) * moved('bat', p) / 100), bh - 8, 5); col(cr, c, 0.55); cairo_fill(cr)
    text(cr, pct(p), x + bw / 2, by + bh / 2 + 5, DISPLAY, 14, true, TEXT, 1, 'c')
    local fx, fw = x + bw + 26, w - bw - 26
    local watts = tonumber(b[3]) or 0
    if state == 'Discharging' and watts > 0.5 then
        fact(cr, 'lasts', span((tonumber(b[6]) or 0) / watts * 3600), fx, by + 14, fw)
        fact(cr, 'drawing', string.format('%.1f W', watts), fx, by + 33, fw)
    else
        fact(cr, 'battery health', pct(tonumber(b[4]) or 0), fx, by + 14, fw)
        fact(cr, 'NVIDIA draws', string.format('%.0f W', (n.gpux or {})[1] or 0), fx, by + 33, fw)
    end
    local prof = (d.prof or {})[1] or '?'
    local py = by + bh + 22
    local opts = {{'SAVER', 'power-saver'}, {'BALANCED', 'balanced'}, {'FULL', 'performance'}}
    local ow = (w - 16) / 3
    for i, o in ipairs(opts) do
        button(cr, o[1], x + (i - 1) * (ow + 8), py, ow, prof == o[2], GREEN, function() act('profile', o[2]) end, 24)
    end
    if py + 46 < y + h - 4 then
        text(cr, fit(cr, 'power profile: ' .. prof, MONO, 9.5, false, w), x, py + 46, MONO, 9.5, false, DIM, 1, 'l')
    end
    local a = math.max(smooth((e - 0.4) / 0.55), smooth((g.h - 236) / 60))
    if a > 0 then
        local old = GA; GA = GA * a
        local dy = py + 74
        fact(cr, 'charge cycles', string.format('%.0f', tonumber(b[5]) or 0), x, dy, w)
        fact(cr, 'energy stored', string.format('%.0f of %.0f Wh', tonumber(b[6]) or 0, tonumber(b[7]) or 0), x, dy + 19, w)
        fact(cr, 'battery health', pct(tonumber(b[4]) or 0), x, dy + 38, w)
        fact(cr, 'processor clock', string.format('%.1f of %.1f GHz', n.load[4] or 0, n.load[5] or 0), x, dy + 57, w)
        local bw2 = bwidth(cr, 'POWER SETTINGS')
        button(cr, 'POWER SETTINGS', x + w - bw2, dy + 70, bw2, false, GREEN, function() act('open', 'power') end)
        GA = old
    end
end

-- ===== header (unchanged) and footer =====
local pulse_at, hour_at
local function draw_content(cr)
    regions, plots = {}, {}
    draws = draws + 1
    local now = os.time()
    -- ===== frame =====
    local tint = 0.84
    if glass_img and cairo_surface_status(glass_img) == CAIRO_STATUS_SUCCESS and screen then
        -- the blurred wallpaper, placed exactly where the sharp one lies behind this window
        local iw, ih = cairo_image_surface_get_width(glass_img), cairo_image_surface_get_height(glass_img)
        local k = math.max(screen.w / iw, screen.h / ih)
        cairo_save(cr)
        rrect(cr, 1, 1, W - 2, H - 2, 16); cairo_clip(cr)
        cairo_translate(cr, (screen.w - iw * k) / 2 - (screen.w - W) / 2, (screen.h - ih * k) / 2 - GAP_Y)
        cairo_scale(cr, k, k)
        cairo_set_source_surface(cr, glass_img, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
        tint = GLASS_TINT
    end
    rrect(cr, 1, 1, W - 2, H - 2, 16)
    col(cr, BG, tint); cairo_fill(cr)
    local sheen = cairo_pattern_create_linear(0, 0, W * 0.5, H)   -- light falling on the glass
    cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.055)
    cairo_pattern_add_color_stop_rgba(sheen, 0.35, 1, 1, 1, 0.012)
    cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0)
    rrect(cr, 1, 1, W - 2, H - 2, 16)
    cairo_set_source(cr, sheen); cairo_fill_preserve(cr); cairo_pattern_destroy(sheen)
    cairo_set_line_width(cr, 1); col(cr, CYAN, 0.45); cairo_stroke(cr)
    corners(cr, 5, 5, W - 10, H - 10, 26, CYAN, 0.14, 6)
    corners(cr, 5, 5, W - 10, H - 10, 26, CYAN, 0.95, 2)
    cairo_set_line_width(cr, 2); col(cr, MAGENTA, 0.9)
    seg(cr, W / 2 - 36, 5, W / 2 + 36, 5); seg(cr, W / 2 - 36, H - 5, W / 2 + 36, H - 5)
    local pad, gap = 18, 12
    local x0, iw = pad, W - 2 * pad
    -- ===== header: day / clock / uptime =====
    local hy, hh = pad, 100
    text(cr, string.format('//  WEEK %s  /  DAY %s', os.date('%V'), os.date('%j')), x0 + 8, hy + 20,
        DISPLAY, 9, true, MAGENTA, 1, 'l')
    local day = os.date('%A'):upper()
    text(cr, day, x0 + 10, hy + 68, DISPLAY, 42, true, MAGENTA, 0.85, 'l')
    text(cr, day, x0 + 8, hy + 66, DISPLAY, 42, true, CYAN, 1, 'l')
    text(cr, os.date('%d %B %Y'):upper(), x0 + 9, hy + 92, DISPLAY, 12, false, TEXT, 1, 'l')

    local clock = os.date('%H:%M')
    local cadv = text(cr, clock, W / 2, hy + 74, DISPLAY, 54, true, CYAN, 1, 'c')
    text(cr, os.date('%S'), W / 2 + cadv / 2 + 8, hy + 74, DISPLAY, 18, false, MAGENTA, 1, 'l')
    text(cr, 'LOCAL TIME', W / 2, hy + 94, DISPLAY, 8, true, DIM, 1, 'c')

    local up = tonumber(read_first('/proc/uptime'):match('^(%S+)')) or 0
    local ud, uh, um = math.floor(up / 86400), math.floor(up % 86400 / 3600),
        math.floor(up % 3600 / 60)
    local tw, th = 66, 56
    local tx = x0 + iw - 3 * tw - 2 * 8
    for i, t in ipairs({{ud, 'DAYS', CYAN}, {uh, 'HOURS', CYAN}, {um, 'MINUTES', MAGENTA}}) do
        local bx, by = tx + (i - 1) * (tw + 8), hy + 30
        region(bx, by, tw, th, function() end, 8, t[3])
        rrect(cr, bx, by, tw, th, 8); col(cr, t[3], 0.05); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1.2); col(cr, t[3], 0.9); cairo_stroke(cr)
        text(cr, string.format('%02d', t[1]), bx + tw / 2, by + 30, DISPLAY, 21, true, TEXT, 1, 'c')
        text(cr, t[2], bx + tw / 2, by + th - 7, DISPLAY, 7, true, t[3], 1, 'c')
    end
    text(cr, 'UPTIME', tx, hy + 20, DISPLAY, 9, true, DIM, 1, 'l')
    local ox = tx - 250
    pulse_at = {ox + 6, hy + 40}
    text(cr, 'SYSTEM ONLINE', ox + 22, hy + 44, DISPLAY, 10, true, GREEN, 1, 'l')
    text(cr, 'up since ' .. os.date('%a %d %b, %H:%M', now - math.floor(up)), ox, hy + 64, MONO,
        10.5, false, TEXT, 1, 'l')
    local lit = math.floor(up % 86400 / 3600)
    for i = 0, 23 do
        rrect(cr, ox + i * 9.2, hy + 74, 6.6, 6, 1.5)
        if i < lit then col(cr, CYAN, 1) elseif i == lit then col(cr, MAGENTA, 0.3); hour_at = {ox + i * 9.2, hy + 74}
        else col(cr, DIM, 0.3) end
        cairo_fill(cr)
    end

    local ly = hy + hh + 6
    local lg = cairo_pattern_create_linear(x0, 0, x0 + iw, 0)
    cairo_pattern_add_color_stop_rgba(lg, 0, CYAN[1], CYAN[2], CYAN[3], 0.9)
    cairo_pattern_add_color_stop_rgba(lg, 0.5, MAGENTA[1], MAGENTA[2], MAGENTA[3], 0.9)
    cairo_pattern_add_color_stop_rgba(lg, 1, CYAN[1], CYAN[2], CYAN[3], 0.9)
    cairo_set_source(cr, lg); cairo_set_line_width(cr, 1); seg(cr, x0, ly, x0 + iw, ly)
    cairo_pattern_destroy(lg)


    local fresh = d and d.stamp and (now - (tonumber(d.stamp[1]) or 0) < 20)
    if not fresh then
        text(cr, 'TELEMETRY COLLECTOR OFFLINE', W / 2, H / 2, DISPLAY, 16, true, RED, 1, 'c')
        text(cr, 'systemctl --user start neon-deck', W / 2, H / 2 + 26, MONO, 11, false, DIM, 1, 'c')
        return
    end
    local E = {}
    for k in pairs(ROW_OF) do E[k] = spr[k] and spr[k].x or 0 end
    local G = layout(E)
    draw_vitals(cr, G, E)
    draw_apps(cr, G.apps, E.apps); draw_net(cr, G.net, E.net); draw_disk(cr, G.disk, E.disk)
    draw_claude(cr, G.claude, E.claude); draw_cool(cr, G.cool, E.cool); draw_power(cr, G.power, E.power)

    -- footer: facts on the left, shortcuts on the right
    local fy = H - 16
    local fx = x0 + 6
    for _, f in ipairs({{'KERNEL', KERNEL}, {'COMPUTER', HOST}}) do
        fx = fx + text(cr, f[1] .. ' ', fx, fy, DISPLAY, 8, false, DIM, 1, 'l')
        fx = fx + text(cr, f[2], fx, fy, DISPLAY, 8, true, TEXT, 1, 'l') + 24
    end
    local bx = x0 + iw
    for _, b in ipairs({{'LOCK', 'lock'}, {'SETTINGS', 'settings'}, {'FILES', 'files'}, {'SYSTEM MONITOR', 'monitor'}}) do
        local bw = bwidth(cr, b[1])
        bx = bx - bw
        button(cr, b[1], bx, fy - 14, bw, false, CYAN, function() act('open', b[2]) end, 20)
        bx = bx - 8
    end
end

-- ===== painted on top every frame =====
local cross = {}
local function crosshair(cr, p, dt)
    local s1 = p.s[1][1]
    local m = #s1
    if m < 2 then return false end
    local step = p.w / (HISTORY - 1)
    local i = clamp(m - math.floor((p.x + p.w - mx) / step + 0.5), 1, m)
    local key = p.y * 10000 + p.x
    local target = p.x + p.w - (m - i) * step
    if not cross.x or cross.on ~= key then cross.x, cross.v, cross.on = target, 0, key end
    local gx = follow(cross, target, dt, 55)
    local q = clamp(m - (p.x + p.w - gx) / step, 1, m)
    local function at_q(t)
        local a = math.floor(q)
        local u, v = t[a] or t[#t] or 0, t[math.min(#t, a + 1)] or 0
        return u + (v - u) * (q - a)
    end
    cairo_set_line_width(cr, 1); col(cr, WHITE, 0.45)
    seg(cr, gx, p.y, gx, p.also and p.also.y + p.also.h or p.y + p.h)
    local parts = {{i == m and 'now   ' or string.format('%d s ago   ', (m - i) * SAMPLE_S), WHITE}}
    for _, s in ipairs(p.s) do
        local v = at_q(s[1])
        local yy = p.y + p.h - clamp((v - p.lo) / math.max(p.hi - p.lo, 0.001), 0, 1) * p.h
        dot(cr, gx, yy, 7, s[2], 0.25); dot(cr, gx, yy, 3.4, WHITE, 1)
        parts[#parts + 1] = {(s[3] and s[3] .. ' ' or '') .. p.fmt(s[1][i] or 0) .. '   ', s[2]}
    end
    if p.also then
        local v = at_q(p.also.s)
        dot(cr, gx, p.also.y + clamp(v / p.hi, 0, 1) * p.also.h, 3.4, WHITE, 1)
        parts[#parts + 1] = {p.also.name .. ' ' .. p.fmt(p.also.s[i] or 0) .. '   ', p.also.c}
    end
    if p.who and p.who[i] then
        local nm, v = p.who[i]:match('^(.-)|(.*)$')
        if nm then parts[#parts + 1] = {'most: ' .. nm, TEXT} end
    end
    local total = 14
    for _, t in ipairs(parts) do total = total + width_of(cr, t[1], MONO, 10, true) end
    local lx = clamp(gx - total / 2, p.x, math.max(p.x, p.x + p.w - total))
    local ly = p.y - 24
    rrect(cr, lx, ly, total, 20, 6); col(cr, BG, 0.96); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, p.c, 0.9); cairo_stroke(cr)
    local tx = lx + 7
    for _, t in ipairs(parts) do tx = tx + text(cr, t[1], tx, ly + 14, MONO, 10, true, t[2], 1, 'l') end
    return true
end

local hl = {y = {}, a = {}}
local function draw_hover(cr, dt)
    -- the topmost thing under the pointer lights up; inside a list the light glides
    local hit
    for i = #regions, 1, -1 do
        local r = regions[i]
        if inside(r.x, r.y, r.w, r.h) then hit = r; break end
    end
    if hit then
        local same_list = hl.x == hit.x and hl.w == hit.w
        if not same_list or (hl.a.x or 0) < 0.05 then hl.y.x, hl.y.goal = hit.y, hit.y end
        if not same_list then hl.a.x, hl.a.goal = 0.3, 0.3 end
        hl.x, hl.w, hl.h, hl.r, hl.c = hit.x, hit.w, hit.h, hit.r, hit.c
        tween(hl.y, hit.y, dt, 0.22)
    end
    local e = tween(hl.a, hit and 1 or 0, dt, 0.24)
    if e > 0.01 and hl.c then
        rrect(cr, hl.x, hl.y.x, hl.w, hl.h, hl.r); col(cr, hl.c, 0.13 * e); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1.3); col(cr, hl.c, 0.85 * e); cairo_stroke(cr)
    end
    local used = false
    if not moving then
        for _, p in ipairs(plots) do
            if inside(p.x, p.y - 4, p.w, p.h + (p.also and p.also.h or 0) + 8) then used = crosshair(cr, p, dt) or used end
        end
    end
    if not used then cross.x = nil end
end

local spin = {0, 0}
local function draw_fans(cr, dt)
    for i, f in ipairs(fans_at) do
        spin[i] = (spin[i] + dt * f[4] / 6000 * 7) % (2 * math.pi)
        local cx, cy, r = f[1], f[2], f[3]
        col(cr, f[5], 0.75)
        for k = 0, 6 do
            local a = spin[i] + k * 2 * math.pi / 7
            cairo_new_path(cr)
            cairo_move_to(cr, cx + 4 * math.cos(a), cy + 4 * math.sin(a))
            cairo_curve_to(cr, cx + r * 0.6 * math.cos(a + 0.15), cy + r * 0.6 * math.sin(a + 0.15),
                cx + r * 0.95 * math.cos(a + 0.25), cy + r * 0.95 * math.sin(a + 0.25), cx + r * math.cos(a + 0.62), cy + r * math.sin(a + 0.62))
            cairo_curve_to(cr, cx + r * 0.7 * math.cos(a + 0.75), cy + r * 0.7 * math.sin(a + 0.75),
                cx + r * 0.4 * math.cos(a + 0.7), cy + r * 0.4 * math.sin(a + 0.7), cx + 4 * math.cos(a + 0.7), cy + 4 * math.sin(a + 0.7))
            cairo_close_path(cr); cairo_fill(cr)
        end
        dot(cr, cx, cy, 4.5, f[5], 1)
    end
end

local function draw_toast(cr, dt)
    local on = toast and os.time() - toast_at < 4
    local e = tween(toast_tw, on and 1 or 0, dt, 0.4, OPENING)
    if e < 0.01 or not toast then return end
    local w = width_of(cr, toast, MONO, 12, true) + 48
    local y = 96 + 20 * e
    GA = e
    rrect(cr, W / 2 - w / 2, y, w, 34, 17); col(cr, BG, 0.95); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1.4); col(cr, CYAN, 0.9); cairo_stroke(cr)
    dot(cr, W / 2 - w / 2 + 18, y + 17, 4, CYAN, 1)
    text(cr, toast, W / 2 + 8, y + 21, MONO, 12, true, WHITE, 1, 'c')
    GA = 1
end

-- ===== data =====
local function parse(txt)
    local t = {app = {}, napp = {}, dapp = {}}
    for l in (txt or ''):gmatch('[^\n]+') do
        local p = {}
        for x in (l .. '\t'):gmatch('(.-)\t') do p[#p + 1] = x end
        local k = table.remove(p, 1)
        if k == 'app' or k == 'napp' or k == 'dapp' then t[k][#t[k] + 1] = p elseif k then t[k] = p end
    end
    local m = {}
    for k, v in pairs(t) do
        if k ~= 'app' and k ~= 'napp' and k ~= 'dapp' then
            local o = {}
            for i, x in ipairs(v) do o[i] = tonumber(x) or 0 end
            m[k] = o
        end
    end
    setmetatable(m, {__index = function() return {} end})
    return t, m
end

local layer, LW, LH = nil, 0, 0
local was_moving = false
local next_pal, second, pal_key, act_stamp = 0, 0, '', nil
local function look()
    if T >= next_pal then
        next_pal = T + 2
        refresh_palette()
        if load_glass(0) then dirty = true end
        local k = ''
        for _, c in ipairs({CYAN, MAGENTA, TEXT, DIM, BG, GREEN, YELLOW, ORANGE}) do k = k .. c[1] .. c[2] .. c[3] end
        if k ~= pal_key then pal_key, dirty = k, true end
    end
    if T >= next_look then
        next_look = T + 0.25
        local f = io.open(PATH, 'r')
        local txt = f and f:read('a') or nil
        if f then f:close() end
        if txt and txt ~= raw then raw = txt; d, n = parse(txt); dirty = true end
        f = io.open(RUN .. '/neon-act.txt', 'r')
        local l = f and f:read('l') or nil
        if f then f:close() end
        if l and l ~= act_stamp then
            local t, msg = l:match('^(%d+)\t(.*)$')
            if act_stamp ~= nil or (t and os.time() - tonumber(t) < 4) then toast, toast_at = msg, tonumber(t) or os.time() end
            act_stamp = l
        elseif not l then act_stamp = act_stamp or '' end
    end
    if os.time() ~= second then second, dirty = os.time(), true end
    if confirm and T > confirm.till then confirm, dirty = nil, true end
end

function conky_panel()
    if conky_window == nil then return end
    local dt = tick()
    vis, vis_moving = hide(dt)
    if vis <= 0 then
        if T_step ~= HIDDEN then T_step = HIDDEN; conky_set_update_interval(HIDDEN) end
        return
    end
    frame_dt = dt
    moving = false
    look()
    W, H = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, W, H)
    local cr = cairo_create(cs)
    if vis < 1 then cairo_translate(cr, 0, 18 * (1 - vis)) end
    if not layer or W ~= LW or H ~= LH then
        if layer then cairo_surface_destroy(layer) end
        layer = cairo_surface_create_similar(cs, CAIRO_CONTENT_COLOR_ALPHA, W, H)
        LW, LH, dirty = W, H, true
    end
    GA = 1
    if inside_panel and d and want_since and T - want_since > 0.09 then retarget() end
    local f = focus or pinned
    for k in pairs(ROW_OF) do
        spr[k] = spr[k] or {}
        tween(spr[k], f == k and 1 or 0, dt, MOVE_S)
    end
    for k, o in pairs(meter) do
        if o.seen ~= draws then meter[k] = nil elseif o.x ~= o.goal then moving = true end
    end
    for _, o in pairs(rowpos) do if o.x ~= o.goal then moving = true end end
    if dirty or moving or was_moving then
        dirty = false
        was_moving = moving
        local c = cairo_create(layer)
        cairo_set_operator(c, CAIRO_OPERATOR_CLEAR); cairo_paint(c)
        cairo_set_operator(c, CAIRO_OPERATOR_OVER)
        pulse_at, hour_at = nil, nil
        draw_content(c)
        cairo_destroy(c)
    end
    cairo_set_source_surface(cr, layer, 0, 0); cairo_paint(cr)

    -- travelling highlight along the top edge
    local span, run = 170, W - 120
    local sx = 60 - span + (run + span) * curve(SWEEP, (T % 8) / 8)
    local sg = cairo_pattern_create_linear(sx, 0, sx + span, 0)
    cairo_pattern_add_color_stop_rgba(sg, 0, CYAN[1], CYAN[2], CYAN[3], 0)
    cairo_pattern_add_color_stop_rgba(sg, 0.8, 0.5 + CYAN[1] / 2, 0.5 + CYAN[2] / 2, 0.5 + CYAN[3] / 2, 0.95)
    cairo_pattern_add_color_stop_rgba(sg, 1, CYAN[1], CYAN[2], CYAN[3], 0)
    cairo_set_source(cr, sg); cairo_set_line_width(cr, 2)
    seg(cr, math.max(30, sx), 1.5, math.min(sx + span, W - 30), 1.5)
    cairo_pattern_destroy(sg)
    local pulse = 0.5 + 0.5 * math.sin(T * 2.2)
    if pulse_at then
        cairo_new_path(cr); cairo_arc(cr, pulse_at[1], pulse_at[2], 6 + 4 * pulse, 0, 2 * math.pi)
        col(cr, GREEN, 0.10 + 0.14 * (1 - pulse)); cairo_fill(cr)
        cairo_new_path(cr); cairo_arc(cr, pulse_at[1], pulse_at[2], 4, 0, 2 * math.pi); col(cr, GREEN, 1)
        cairo_fill(cr)
    end
    if hour_at then
        rrect(cr, hour_at[1], hour_at[2], 6.6, 6, 1.5); col(cr, MAGENTA, 0.2 + 0.7 * pulse); cairo_fill(cr)
    end
    if d then
        draw_fans(cr, dt)
        draw_hover(cr, dt)
        draw_toast(cr, dt)
    end

    if vis < 1 then                          -- being hidden or shown
        cairo_identity_matrix(cr); cairo_reset_clip(cr)
        cairo_set_source_rgba(cr, 0, 0, 0, vis)      -- (the last used colour must not decide how visible all is)
        cairo_set_operator(cr, CAIRO_OPERATOR_DEST_IN); cairo_paint(cr)
    end
    cairo_destroy(cr)
    cairo_surface_destroy(cs)

    -- frame rate follows what is happening
    local step = (vis_moving or moving or was_moving or (inside_panel and T - last_move < 1.5)) and FAST or IDLE
    if step ~= T_step then
        T_step = step
        conky_set_update_interval(step)
    end
end
