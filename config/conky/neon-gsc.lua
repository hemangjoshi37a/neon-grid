-- Neon-Grid Search Console board: draws ~/.cache/neon-grid/gsc-<days>.txt (by neon-gsc.py).
-- Two views: OVERVIEW (totals, sites, queries; the hovered row opens up) and COMPARE (one
-- chart per measure sharing the date axis, one line per site).
--
-- How it stays smooth: each view is drawn once into a cached surface and only redrawn while
-- something moves or changes; pointer read-outs are painted on top. The frame rate follows
-- what is happening (FAST while moving or hovered, IDLE otherwise), see the end of conky_gsc().
require 'cairo'
pcall(require, 'cairo_xlib')

local CACHE = os.getenv('HOME') .. '/.cache/neon-grid/'
local RANGES = {28, 60, 90, 365}
local WEEKLY = 120          -- longer ranges are drawn per week
local GAP_X, GAP_Y = 22, 24 -- gap_x and gap_y of neon-gsc.conf (for the glass)
local GLASS_TINT = 0.58     -- how much of the background colour lies over the glass
local FAST, IDLE = 1 / 75, 1 / 25   -- seconds per frame; IDLE is also the longest wait to notice a hover
local PAD = 18              -- space between the outer frame and the content
local RELOAD_S = 20         -- look for new data this often
local MOVE_S = 0.38         -- seconds for sections to open and close
local XS, XQ, EA, EQ, SQ = 314, 220, 150, 152, 44   -- opened site / query height, growth of cards
local MAX_LINES = 8         -- sites drawn in colour on the comparison charts

local CYAN    = {0.00, 0.94, 1.00}
local MAGENTA = {1.00, 0.17, 0.84}
local GREEN   = {0.16, 1.00, 0.64}
local YELLOW  = {0.98, 0.97, 0.44}
local RED     = {1.00, 0.47, 0.54}
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
    GREEN = GREEN, YELLOW = YELLOW})
    or function() end
do  -- the glass lets bright wallpaper through: quiet text is lifted towards the normal text colour
    local plain = refresh_palette
    refresh_palette = function()
        plain()
        for i = 1, 3 do DIM[i] = DIM[i] + (TEXT[i] - DIM[i]) * 0.45 end
    end
end
refresh_palette()

local mx, my = -1, -1       -- pointer in content coordinates, or -1
local inside_board = false
local last_move = 0         -- time of the latest pointer event
local data = nil
local dirty = true          -- cached view needs redrawing
local GA = 1                -- global alpha, used for fades

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

-- section inside the frame; hot = 0..1 how lit up it is
local function card(cr, x, y, w, h, title, c, right, hot)
    hot = hot or 0
    rrect(cr, x, y, w, h, 10)
    col(cr, hot > 0.5 and c or WHITE, 0.022 + 0.02 * hot); cairo_fill(cr)
    if hot > 0.02 then
        for i = 3, 1, -1 do
            rrect(cr, x, y, w, h, 10)
            cairo_set_line_width(cr, 1 + i * 2.5); col(cr, c, 0.05 * hot); cairo_stroke(cr)
        end
        corners(cr, x - 3, y - 3, w + 6, h + 6, 12, c, hot, 2)
    end
    rrect(cr, x, y, w, h, 10)
    cairo_set_line_width(cr, 1 + 0.4 * hot); col(cr, c, 0.30 + 0.6 * hot); cairo_stroke(cr)
    cairo_set_line_width(cr, 3); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, c, 1)
    seg(cr, x + 16, y + 17, x + 16, y + 29)
    text(cr, title, x + 26, y + 28, DISPLAY, 11, true, hot > 0.5 and WHITE or c, 1, 'l')
    if right then text(cr, right, x + w - 16, y + 28, MONO, 10, false, DIM, 1, 'r') end
    cairo_set_line_width(cr, 1); col(cr, c, 0.18)
    seg(cr, x + 16, y + 40, x + w - 16, y + 40)
end

local function badge(cr, xr, y, label, value, c)
    local vw = width_of(cr, value, DISPLAY, 10, true)
    local lw = width_of(cr, label, DISPLAY, 10, false)
    local w = lw + vw + 34
    local x = xr - w
    rrect(cr, x, y, w, 24, 12)
    col(cr, c, 0.14); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, 0.7); cairo_stroke(cr)
    text(cr, label, x + 12, y + 16, DISPLAY, 10, false, DIM, 1, 'l')
    text(cr, value, x + 12 + lw + 10, y + 16, DISPLAY, 10, true, c, 1, 'l')
    return x - 10
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

-- daily counts as thin columns centred on the same x positions as line()
local function columns(cr, x, y, w, h, s, hi, c)
    local n = #s
    if n < 2 then return end
    hi = math.max(hi or 0, 0.0001)
    local bw = math.max(2, w / n * 0.5)
    col(cr, c, 0.9)
    for i = 1, n do
        local bh = clamp(s[i] / hi, 0, 1) * h
        if bh > 0.5 then
            local bx, r = x + (i - 1) * w / (n - 1) - bw / 2, math.min(3, bw / 2, bh)
            cairo_new_path(cr)
            cairo_move_to(cr, bx, y + h); cairo_line_to(cr, bx, y + h - bh + r)
            cairo_arc(cr, bx + r, y + h - bh + r, r, math.pi, 1.5 * math.pi)
            cairo_arc(cr, bx + bw - r, y + h - bh + r, r, 1.5 * math.pi, 2 * math.pi)
            cairo_line_to(cr, bx + bw, y + h); cairo_close_path(cr); cairo_fill(cr)
        end
    end
end

-- position in the results: 0 = not shown that day (gap); better (smaller) is higher up
local function posline(cr, x, y, w, h, s, hi, c, width)
    local n = #s
    if n < 2 then return end
    local function px(i) return x + (i - 1) * w / (n - 1) end
    local function py(v) return y + clamp((v - 1) / math.max(hi - 1, 1), 0, 1) * h end
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    local pen = false
    cairo_new_path(cr)
    for i = 1, n do
        if s[i] > 0 then
            if pen then cairo_line_to(cr, px(i), py(s[i])) else cairo_move_to(cr, px(i), py(s[i])) end
            pen = true
        else pen = false end
    end
    cairo_set_line_width(cr, width or 1.6); col(cr, c, 1); cairo_stroke(cr)
    for i = 1, n do
        if s[i] > 0 and (s[i - 1] or 0) == 0 and (s[i + 1] or 0) == 0 then
            dot(cr, px(i), py(s[i]), 2, c, 1)
        end
    end
end

-- small label box; kept inside x0..x1
local function tooltip(cr, parts, cx, y, x0, x1, c)
    local total = 14
    for _, p in ipairs(parts) do total = total + width_of(cr, p[1], MONO, 10, true) end
    local lx = math.max(x0, math.min(x1 - total, cx - total / 2))
    rrect(cr, lx, y, total, 20, 5); col(cr, BG, 0.96); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, 0.9); cairo_stroke(cr)
    local tx = lx + 7
    for _, p in ipairs(parts) do tx = tx + text(cr, p[1], tx, y + 14, MONO, 10, true, p[2], 1, 'l') end
end

local function commas(v)
    local s = string.format('%d', math.floor(v + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- returns label, colour for a change from prev to cur
local function delta(cur, prev)
    if prev < 0 then return '', DIM end      -- no complete previous period
    if prev <= 0 then
        if cur > 0 then return 'new', CYAN end
        return '', DIM
    end
    local p = (cur - prev) / prev * 100
    if math.abs(p) < 0.5 then return '0%', DIM end
    local s = math.abs(p) > 999 and '>999%' or string.format('%d%%', math.floor(math.abs(p) + 0.5))
    if p > 0 then return '+' .. s, GREEN end
    return '-' .. s, RED
end

local function maxof(t) local m = 0; for _, v in ipairs(t) do if v > m then m = v end end; return m end

local function nums(t, from)
    local o = {}
    for i = from or 1, #t do o[#o + 1] = tonumber(t[i]) or 0 end
    return o
end

local function csv(s)
    local o = {}
    for v in (s or ''):gmatch('[^,]+') do o[#o + 1] = tonumber(v) or 0 end
    return o
end

-- the domain comes with the data, so nothing about it is written in here
local function esc(t) return (t:gsub('%W', '%%%0')) end
local function domain() return data and data.domain or '' end
local function short(host) -- 'blog.example.com' -> 'blog'
    local sub = host:gsub('%.?' .. esc(domain()) .. '$', '')
    return sub == '' and domain() or sub
end
local function short_url(u) return (u:gsub('^([%w%-]*)%.?' .. esc(domain()), function(p)
    return p == '' and domain() or p end)) end

local function delta_ok() return data and data.has_prev end
local DETAIL = {ap = 1, ac = 1, ad = 1, sq = 1, sp = 1, sc = 1, sd = 1, qp = 1, qc = 1, qd = 1}
local function load_data(days)
    local f = io.open(CACHE .. 'gsc-' .. days .. '.txt', 'r')
    if not f then return nil end
    local d = {site = {}, query = {}, op = {}, det = {}}
    for l in f:lines() do
        local p = {}
        for x in (l .. '\t'):gmatch('(.-)\t') do p[#p + 1] = x end
        local k = table.remove(p, 1)
        if k == 'site' then
            local n = function(i) return tonumber(p[i]) or 0 end
            table.insert(d.site, {host = p[1], c = n(2), i = n(3), ctr = n(4), pos = n(5), pc = n(6),
                pi = n(7), impr = csv(p[8]), clicks = csv(p[9]), posd = csv(p[10]), ppos = n(11)})
        elseif k == 'query' then
            local n = function(i) return tonumber(p[i]) or 0 end
            table.insert(d.query, {q = p[1], c = n(2), i = n(3), pos = n(4), pc = n(5), pi = n(6),
                ppos = n(7), impr = csv(p[8]), clicks = csv(p[9]), posd = csv(p[10])})
        elseif k == 'op' then table.insert(d.op, {q = p[1], c = tonumber(p[2]) or 0,
            i = tonumber(p[3]) or 0, pos = tonumber(p[4]) or 0, page = p[5] or ''})
        elseif DETAIL[k] then
            d.det[k] = d.det[k] or {}
            d.det[k][p[1]] = d.det[k][p[1]] or {}
            table.insert(d.det[k][p[1]], {label = p[2], c = tonumber(p[3]) or 0,
                i = tonumber(p[4]) or 0, pos = tonumber(p[5]) or 0, share = tonumber(p[6]) or 0})
        elseif k then d[k] = p end
    end
    f:close()
    if not d.meta or not d.tot then return nil end
    d.days, d.has_prev, d.step = tonumber(d.meta[4]) or 28, d.meta[5] ~= '0', 1
    d.domain = d.meta[6] or ''
    d.by_host = {}
    for _, s in ipairs(d.site) do d.by_host[s.host] = s end
    d.h_impr, d.h_clicks, d.h_pos = nums(d.h_impr or {}), nums(d.h_clicks or {}), nums(d.h_pos or {})
    d.tot = nums(d.tot)
    if d.days > WEEKLY then            -- long ranges: one point per week, whole weeks up to the last day
        d.step = 7
        local n = #d.h_impr
        d.skip = n % 7
        local function weeks(im, ck, po)
            local a, b, c = {}, {}, {}
            for i = d.skip + 1, n, 7 do
                local x, y, z, w = 0, 0, 0, 0
                for j = i, math.min(n, i + 6) do
                    x, y = x + (im[j] or 0), y + (ck[j] or 0)
                    z, w = z + (po[j] or 0) * (im[j] or 0), w + ((po[j] or 0) > 0 and (im[j] or 0) or 0)
                end
                a[#a + 1], b[#b + 1], c[#c + 1] = x, y, w > 0 and z / w or 0
            end
            return a, b, c
        end
        d.h_impr, d.h_clicks, d.h_pos = weeks(d.h_impr, d.h_clicks, d.h_pos)
        for _, l in ipairs({d.site, d.query}) do
            for _, s in ipairs(l) do s.impr, s.clicks, s.posd = weeks(s.impr, s.clicks, s.posd) end
        end
    end
    d.per = d.step == 7 and 'WEEK' or 'DAY'
    -- growth: against the previous period, or second half against first half when there is none
    for _, s in ipairs(d.site) do
        if d.has_prev then s.gi, s.gc, s.oi, s.oc = s.i - s.pi, s.c - s.pc, s.pi, s.pc; s.ni, s.nc = s.i, s.c
        else
            local h, a, b, c, e = #s.impr // 2, 0, 0, 0, 0
            for i, v in ipairs(s.impr) do if i <= h then a = a + v else b = b + v end end
            for i, v in ipairs(s.clicks) do if i <= h then c = c + v else e = e + v end end
            s.gi, s.gc, s.oi, s.oc, s.ni, s.nc = b - a, e - c, a, c, b, e
        end
    end
    return d
end
local function det(kind, id) return data.det[kind] and data.det[kind][id] or {} end

local function day_time(s, offset)
    local y, m, dd = s:match('(%d+)-(%d+)-(%d+)')
    if not y then return os.time() end
    return os.time({year = y, month = m, day = dd, hour = 12}) + (offset or 0) * 86400
end

local function at_day(i)              -- date of point i (0 = first) of the current data
    if not data or data.step == 1 then return i or 0 end
    return (data.skip or 0) + (i or 0) * 7
end
local function nice_date(s, offset) return os.date('%d %b', day_time(s, offset)) end
local function point_date(i) return os.date(data.step == 7 and '%b %Y' or '%d %b', day_time(data.meta[1], at_day(i))) end

local function long_date(i)
    if data.step == 1 then return os.date('%a %d %b', day_time(data.meta[1], i)) end
    local a = day_time(data.meta[1], at_day(i))
    return os.date('%d %b', a) .. ' - ' .. os.date('%d %b %Y', a + 6 * 86400)
end

-- ===== state =====
local view = {x = 0, goal = 0, want = 0}             -- 0 overview, 1 compare
local hide = dofile(os.getenv('HOME') .. '/.config/conky/neon-hide.lua')
local vis, vis_moving, HIDDEN = 1, false, 0.1
local focus, pinned = nil, nil                    -- {k = 'A'|'S'|'Q', i = n}
local panel = 0                                   -- hovered comparison chart
local sprA, sprS, sprQ, sprP = {}, {}, {}, {}
local regions, plots = {{}, {}}, {{}, {}}         -- clickable areas / charts per view
local cur = 1                                     -- view being drawn (index into the two above)
local W, H = 1000, 1508
local GAP = 12
local want_since, shown_panel = nil, 0

local range_i, range_pos, fade = 1, {x = 1, goal = 1}, {x = 1, goal = 1}
local cmp = {avg = false, scale = 'REAL', sel = {}, slot = {}, alpha = {}, rev = 0,
    morph = {x = 1, goal = 1}, key = nil, hover = nil}

local function region(x, y, w, h, fn, r, c)
    regions[cur][#regions[cur] + 1] = {x = x, y = y, w = w, h = h, fn = fn, r = r or 6, c = c or CYAN}
end
local function button(cr, label, x, y, w, on, c, fn)
    rrect(cr, x, y, w, 22, 11)
    col(cr, c, on and 0.85 or 0.10); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, on and 1 or 0.45); cairo_stroke(cr)
    text(cr, label, x + w / 2, y + 15, DISPLAY, 8.5, true, on and BG or TEXT, 1, 'c')
    if GA > 0.9 then region(x, y, w, 22, fn, 11, c) end
end

local function open_url(u)
    if u:match("^https://[%w%.%-_/%%%?=&:!+~]+$") then
        os.execute("xdg-open '" .. u .. "' >/dev/null 2>&1 &")
    end
end
local function enc(s) return (s:gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end)) end
local GSC = 'https://search.google.com/search-console/performance/search-analytics?resource_id=sc-domain%3A'

-- ===== overview layout =====
-- The opened row takes a fixed height and the others share the rest, so the pointer is always
-- still inside the row it opened and nothing flickers.
local function n_rows()
    local base = H - (52 + 290 + GAP) - GAP - (76 + math.min(#data.query, 20) * 26) - 1 - 76
    return math.min(#data.site, math.max(1, math.floor(base / 28))), math.min(#data.query, 20)
end

local function layout(eA, eS, eQ)
    local nS, nQ = n_rows()
    local sS, sQ = 0, 0
    for i = 1, nS do sS = sS + (eS[i] or 0) end
    for i = 1, nQ do sQ = sQ + (eQ[i] or 0) end
    local g = {nS = nS, nQ = nQ, y1 = 52, h1 = 290 + eA * EA, sS = sS, sQ = sQ}
    g.y2 = g.y1 + g.h1 + GAP
    local areaQ = nQ * 26 + sQ * EQ - sS * SQ
    g.hq = 76 + areaQ
    g.y3 = H - 1 - g.hq
    local room = g.y3 - GAP - g.y2 - 76
    local areaS = math.min(room, nS * 33 + sS * (XS - 33))
    g.h2 = 76 + areaS
    if areaS < room - 1 then g.y3 = g.y2 + g.h2 + GAP end
    local function rows(n, e, sum, big, area, top)
        local base = n > sum and (area - sum * big) / (n - sum) or 0
        local ys, hs, y = {}, {}, top
        for i = 1, n do
            local h = base + (e[i] or 0) * (big - base)
            ys[i], hs[i] = y, h
            y = y + h
        end
        return ys, hs
    end
    g.sy, g.sh = rows(nS, eS, sS, XS, areaS, g.y2 + 70)
    g.qy, g.qh = rows(nQ, eQ, sQ, XQ, areaQ, g.y3 + 68)
    return g
end

local function layout_for(f)
    local eS, eQ = {}, {}
    if f and f.k == 'S' then eS[f.i] = 1 elseif f and f.k == 'Q' then eQ[f.i] = 1 end
    return layout(f and f.k == 'A' and 1 or 0, eS, eQ)
end

local function item_at(g, x, y)
    if x < 0 or x > W then return nil end
    if y >= g.y1 and y <= g.y1 + g.h1 then return {k = 'A', i = 1} end
    for i = 1, g.nS do if y >= g.sy[i] and y < g.sy[i] + g.sh[i] then return {k = 'S', i = i} end end
    for i = 1, g.nQ do if y >= g.qy[i] and y < g.qy[i] + g.qh[i] then return {k = 'Q', i = i} end end
end
local function same(a, b) return (a == nil and b == nil) or (a and b and a.k == b.k and a.i == b.i) end

-- ===== comparison layout =====
local PANELS = {'IMPRESSIONS', 'CLICKS', 'CLICK-THROUGH RATE', 'POSITION IN RESULTS'}
local function live_sites()
    local o = {}
    for _, s in ipairs(data.site) do if s.i > 0 then o[#o + 1] = s end end
    return o
end
local function cmp_layout(e)
    local rows = math.ceil(#live_sites() / 5)
    local g = {ty = 52, th = 84 + rows * 27 + 8}
    g.ih = 112
    g.iy = H - 1 - g.ih
    local top = g.ty + g.th + GAP
    local area = g.iy - GAP - top - 3 * 8
    local sum = e[1] + e[2] + e[3] + e[4]
    g.py, g.ph = {}, {}
    local y = top
    for i = 1, 4 do
        g.ph[i] = area / 4 * (1 + e[i] * 0.6 - (sum - e[i]) * 0.2)
        g.py[i] = y
        y = y + g.ph[i] + 8
    end
    return g
end

-- ===== pointer =====
local function retarget()
    if view.want == 1 then
        local e = {0, 0, 0, 0}
        if panel > 0 then e[panel] = 1 end
        local g = cmp_layout(e)
        local hit = 0
        for i = 1, 4 do
            if my >= g.py[i] and my < g.py[i] + g.ph[i] + 8 and mx >= 0 then hit = i end
        end
        panel = hit
        return
    end
    local f = focus
    for _ = 1, 4 do
        local hit = item_at(layout_for(f), mx, my)
        if same(hit, f) then break end
        f = hit
        if hit == nil then break end
    end
    if not same(f, focus) then focus = f end
end

local OTHER_BUTTON = {right = true, middle = true, back = true, forward = true, ['2'] = true, ['3'] = true,
    ['273'] = true, ['274'] = true}
function conky_gsc_mouse(event)
    if vis < 0.5 and event.type ~= 'mouse_leave' then return false end
    local t = event.type
    last_move = T or 0
    if t == 'mouse_move' or t == 'mouse_enter' then
        mx, my = (event.x or -1) - PAD, (event.y or -1) - PAD
        if not inside_board then want_since = T or 0 end
        inside_board = true
        if data and T and want_since and T - want_since > 0.09 then retarget() end
    elseif t == 'mouse_leave' then
        mx, my = -1, -1
        inside_board, focus, panel = false, nil, 0
        cmp.hover = nil
    elseif t == 'button_down' and data and not OTHER_BUTTON[tostring(event.button)] then
        mx, my = (event.x or -1) - PAD, (event.y or -1) - PAD
        local list = regions[view.want + 1]
        for i = #list, 1, -1 do
            local r = list[i]
            if inside(r.x, r.y, r.w, r.h) then r.fn(); dirty = true; return true end
        end
        if view.want == 0 and focus then   -- click keeps a section open after the pointer leaves
            if same(focus, pinned) then pinned = nil else pinned = {k = focus.k, i = focus.i} end
            dirty = true
        end
        return true
    end
    return false
end

-- ===== small building blocks =====
local function share_rows(cr, x, y, w, title, rows, n, c, step)
    text(cr, title, x, y, DISPLAY, 8, true, DIM, 1, 'l')
    local top = 0
    for i = 1, math.min(n, #rows) do top = math.max(top, rows[i].share) end
    for i = 1, math.min(n, #rows) do
        local r, yy = rows[i], y + 5 + i * step
        text(cr, fit(cr, r.label, MONO, 10, false, 76), x, yy, MONO, 10, false, TEXT, 1, 'l')
        local bx, bw = x + 82, w - 82 - 38
        rrect(cr, bx, yy - 6, bw, 5, 2.5); col(cr, c, 0.13); cairo_fill(cr)
        rrect(cr, bx, yy - 6, math.max(5, bw * r.share / math.max(top, 1)), 5, 2.5); col(cr, c, 1); cairo_fill(cr)
        text(cr, string.format('%.0f%%', r.share), x + w, yy, MONO, 10, false, TEXT, 1, 'r')
    end
    if #rows == 0 then text(cr, 'not itemised by Google', x, y + 5 + step, MONO, 9, false, DIM, 1, 'l') end
end

local function list_rows(cr, x, y, w, title, rows, n, c, step, label)
    text(cr, title, x, y, DISPLAY, 8, true, DIM, 1, 'l')
    text(cr, 'CLICKS', x + w - 96, y, DISPLAY, 8, true, DIM, 1, 'r')
    text(cr, 'IMPR', x + w - 40, y, DISPLAY, 8, true, DIM, 1, 'r')
    text(cr, 'POS', x + w, y, DISPLAY, 8, true, DIM, 1, 'r')
    local top = 0.001
    for i = 1, math.min(n, #rows) do top = math.max(top, rows[i].i) end
    for i = 1, math.min(n, #rows) do
        local r, yy = rows[i], y + 5 + i * step
        rrect(cr, x - 5, yy - 11, 8 + (w - 148) * r.i / top, 15, 4); col(cr, c, 0.16); cairo_fill(cr)
        text(cr, fit(cr, label and label(r.label) or r.label, MONO, 10, false, w - 150), x, yy, MONO, 10, false, TEXT, 1, 'l')
        text(cr, commas(r.c), x + w - 96, yy, MONO, 10, true, r.c > 0 and TEXT or DIM, 1, 'r')
        text(cr, commas(r.i), x + w - 40, yy, MONO, 10, false, TEXT, 1, 'r')
        text(cr, string.format('%.1f', r.pos), x + w, yy, MONO, 10, false, DIM, 1, 'r')
    end
    if #rows == 0 then text(cr, 'none itemised by Google', x, y + 5 + step, MONO, 9, false, DIM, 1, 'l') end
end

local function strip_title(cr, x, y, w, label, note, c)
    rrect(cr, x, y - 7, 8, 8, 2); col(cr, c, 1); cairo_fill(cr)
    text(cr, label, x + 14, y, DISPLAY, 8, true, DIM, 1, 'l')
    text(cr, note, x + w, y, MONO, 9, false, DIM, 1, 'r')
end
local function baseline(cr, x, y, w) cairo_set_line_width(cr, 1); col(cr, DIM, 0.25); seg(cr, x, y, x + w, y) end

-- registers a chart group for the crosshair
local function plot(p) if GA > 0.9 then plots[cur][#plots[cur] + 1] = p end end

local function sum(t) local s = 0; for _, v in ipairs(t) do s = s + v end; return s end
local function worst(t) local m = 1; for _, v in ipairs(t) do if v > m then m = v end end; return m end

-- ===== overview =====
local X = {name = 34, sp = 318, spw = 232, cl = 650, cld = 712, im = 812, imd = 874, ctr = 936}
local DX, DW = 34, 540            -- opened charts: left edge and width
local RX, RW = 606, 378           -- opened lists

local function header_numbers(cr, s, by)
    X.pos = W - 16
    local live = s.i > 0
    text(cr, commas(s.c), X.cl, by, MONO, 11, true, s.c > 0 and CYAN or DIM, 1, 'r')
    local dl, dc = delta(s.c, s.pc)
    text(cr, dl, X.cld, by, MONO, 9, false, dc, 1, 'r')
    text(cr, commas(s.i), X.im, by, MONO, 11, true, live and TEXT or DIM, 1, 'r')
    dl, dc = delta(s.i, s.pi)
    text(cr, dl, X.imd, by, MONO, 9, false, dc, 1, 'r')
    local ctr = s.ctr or (s.i > 0 and 100 * s.c / s.i or 0)
    text(cr, live and string.format('%.1f%%', ctr) or '-', X.ctr, by, MONO, 11, false,
        live and TEXT or DIM, 1, 'r')
    text(cr, live and string.format('%.1f', s.pos) or '-', X.pos, by, MONO, 11, false,
        live and YELLOW or DIM, 1, 'r')
end

local set_sites            -- defined with the comparison view

-- frame of an opened row
local function row_frame(cr, y, h, e, c, odd, pin)
    if e > 0.01 then
        rrect(cr, 8.5, y + 1, W - 17, h - 2, 8); col(cr, c, 0.035 + 0.045 * e); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1 + 0.3 * e); col(cr, c, 0.75 * e); cairo_stroke(cr)
        corners(cr, 7, y - 0.5, W - 14, h + 1, 10, c, e, 2)
        if pin then
            local bx = c == GREEN and 446 or 514
            rrect(cr, bx, y + (c == GREEN and 4 or 7), 66, 22, 11); col(cr, c, 0.85 * e); cairo_fill(cr)
            text(cr, 'PINNED', bx + 33, y + (c == GREEN and 19 or 22), DISPLAY, 8.5, true, BG, e, 'c')
        end
    elseif odd then
        rrect(cr, 8.5, y, W - 17, h, 6); col(cr, CYAN, 0.035); cairo_fill(cr)
    end
end

-- charts and lists of an opened site or query. rects given as offsets from y
local function opened(cr, d, s, y, e, kind, id)
    local a = smooth((e - 0.35) / 0.6)
    if a <= 0 then return end
    local old = GA
    GA = GA * a
    local n = #s.impr
    local big = kind == 'S'
    local ch = big and {158, 48} or {140, 44}
    strip_title(cr, DX, y + ch[1] - 8, DW, 'CLICKS / ' .. d.per, 'peak ' .. commas(maxof(s.clicks)), CYAN)
    columns(cr, DX, y + ch[1], DW, ch[2], s.clicks, math.max(1, maxof(s.clicks)), CYAN)
    baseline(cr, DX, y + ch[1] + ch[2], DW)
    local bottom = ch[1] + ch[2]
    if big then
        local pmax = worst(s.posd)
        strip_title(cr, DX, y + 226, DW, 'POSITION (higher is better)', string.format('worst %.0f', pmax), YELLOW)
        posline(cr, DX, y + 234, DW, 44, s.posd, pmax, YELLOW)
        baseline(cr, DX, y + 280, DW)
        bottom = 280
    end
    for _, k in ipairs({0, 0.25, 0.5, 0.75, 1}) do
        local i = math.floor((n - 1) * k + 0.5)
        text(cr, point_date(i), DX + DW * k, y + bottom + 14, MONO, 9, false, DIM, 1,
            k == 0 and 'l' or (k == 1 and 'r' or 'c'))
    end
    if big then
        list_rows(cr, RX, y + 48, RW, 'TOP SEARCHES', det('sq', id), 5, MAGENTA, 17)
        list_rows(cr, RX, y + 160, RW, 'TOP PAGES', det('sp', id), 4, CYAN, 17)
        share_rows(cr, RX, y + 252, 180, 'COUNTRIES (share of views)', det('sc', id), 3, GREEN, 14)
        share_rows(cr, RX + 198, y + 252, 180, 'DEVICES', det('sd', id), 3, GREEN, 14)
        button(cr, 'OPEN SITE', 330, y + 7, 84, false, MAGENTA, function()
            if s.host:match('^[%w%.%-]+$') then open_url('https://' .. s.host .. '/') end end)
        button(cr, 'COMPARE', 422, y + 7, 84, false, CYAN, function()
            set_sites({s.host}, true); view.want = 1 end)
    else
        list_rows(cr, RX, y + 48, RW, 'PAGES SHOWN', det('qp', id), 3, GREEN, 16, short_url)
        share_rows(cr, RX, y + 122, 180, 'COUNTRIES (share)', det('qc', id), 4, GREEN, 14)
        share_rows(cr, RX + 198, y + 122, 180, 'DEVICES', det('qd', id), 3, GREEN, 14)
        local px = s.ppos > 0 and string.format('%.1f', s.ppos) or '-'
        text(cr, d.has_prev and string.format('previous %d days: %s clicks, %s views, position %s', d.days,
            commas(s.pc), commas(s.pi), px) or 'no complete previous period', RX, y + 206, MONO, 9, false, DIM, 1, 'l')
        button(cr, 'SEARCH CONSOLE', 322, y + 4, 116, false, GREEN, function()
            open_url(GSC .. enc(domain()) .. '&query=!' .. enc(s.q)) end)
    end
    if e > 0.98 then
        local strips = {
            {s.impr, big and y + 52 or y + 48, big and 82 or 70, math.max(1, maxof(s.impr) * 1.08), big and MAGENTA or GREEN},
            {s.clicks, y + ch[1], ch[2], math.max(1, maxof(s.clicks)), CYAN}}
        if big then strips[3] = {s.posd, y + 234, 44, worst(s.posd), YELLOW, true} end
        plot({x = DX, y = y + 40, w = DW, h = bottom - 34, n = n, t0 = d.meta[1], strips = strips,
            impr = s.impr, clicks = s.clicks, pos = s.posd, c = big and MAGENTA or GREEN, ty = y + (big and 31 or 28)})
    end
    GA = old
end

-- the small graph of a row, growing into the opened chart
local function grow_graph(cr, s, y, h, e, x0, w0, c, yo, ho)
    local p = 6 * math.min(1, h / 31)
    local gx, gw = mix(x0, DX, e), mix(w0, DW, e)
    local gy, gh = mix(y + p, y + yo, e), mix(math.min(h, 31) - 2 * p, ho, e)
    local top = maxof(s.impr) * mix(1, 1.08, e)
    if e > 0.3 then
        local old = GA; GA = GA * smooth((e - 0.3) / 0.6)
        cairo_set_line_width(cr, 1)
        for k = 0, 3 do col(cr, DIM, k == 3 and 0.25 or 0.12); seg(cr, gx, gy + gh * k / 3, gx + gw, gy + gh * k / 3) end
        strip_title(cr, gx, gy - 6, gw, 'IMPRESSIONS / ' .. data.per, string.format('peak %s   average %s',
            commas(maxof(s.impr)), commas(sum(s.impr) / math.max(1, #s.impr))), c)
        GA = old
    end
    line(cr, gx, gy, gw, gh, s.impr, top, c, true, mix(1.3, 2, e))
end

local function draw_overview(cr, d, g)
    -- ----- totals -----
    local eA = sprA.x or 0
    local y1, h1 = g.y1, g.h1
    card(cr, 0.5, y1, W - 1, h1, 'ALL SITES', CYAN, d.has_prev and 'change vs previous ' .. d.days .. ' days' or 'Google keeps no full previous year to compare with', eA)
    local t = d.tot
    local cl, cc = delta(t[1], t[5])
    local il, ic = delta(t[2], t[6])
    local rl, rc = delta(t[3], t[7])
    local pd = t[4] - t[8]                        -- position: lower is better
    local tiles = {
        {'CLICKS', commas(t[1]), CYAN, cl, cc},
        {'IMPRESSIONS', commas(t[2]), MAGENTA, il, ic},
        {'CLICK-THROUGH', string.format('%.2f%%', t[3]), GREEN, rl, rc},
        {'AVG POSITION', string.format('%.1f', t[4]), YELLOW,
            not d.has_prev and '' or (math.abs(pd) < 0.05 and '0.0' or string.format('%+.1f', pd)),
            math.abs(pd) < 0.05 and DIM or (pd < 0 and GREEN or RED)},
    }
    local tw = (W - 32) / 4
    for i, tl in ipairs(tiles) do
        local tx = 16.5 + (i - 1) * tw
        text(cr, tl[1], tx, y1 + 64, DISPLAY, 9, true, DIM, 1, 'l')
        local adv = text(cr, tl[2], tx, y1 + 102, DISPLAY, 27, true, tl[3], 1, 'l')
        text(cr, tl[4], tx + adv + 10, y1 + 102, MONO, 11, true, tl[5], 1, 'l')
    end
    local hi, hc, hp = d.h_impr, d.h_clicks, d.h_pos
    local gx, gw = 16.5, mix(W - 33, DW + 16, eA)
    local iy, ih = y1 + mix(132, 146, eA), mix(128, 100, eA)
    local cy, chh = y1 + mix(132, 278, eA), mix(128, 60, eA)
    cairo_set_line_width(cr, 1)
    for i = 0, 3 do col(cr, DIM, 0.14); seg(cr, gx, iy + ih * i / 3, gx + gw, iy + ih * i / 3) end
    local imax, cmax = maxof(hi) * 1.1, maxof(hc) * 1.1
    line(cr, gx, iy, gw, ih, hi, imax, MAGENTA, true, 1.8)
    line(cr, gx, cy, gw, chh, hc, cmax, CYAN, eA > 0.5, 1.8)
    local fin = smooth((eA - 0.35) / 0.6)
    local ly = y1 + h1 - 10
    if fin > 0 then
        GA = fin
        strip_title(cr, gx, iy - 7, gw, 'IMPRESSIONS / ' .. d.per, 'peak ' .. commas(maxof(hi)), MAGENTA)
        strip_title(cr, gx, cy - 8, gw, 'CLICKS / ' .. d.per, 'peak ' .. commas(maxof(hc)), CYAN)
        baseline(cr, gx, cy + chh, gw)
        local pmax = worst(hp)
        strip_title(cr, gx, y1 + 360, gw, 'POSITION (higher is better)', string.format('worst %.1f', pmax), YELLOW)
        posline(cr, gx, y1 + 368, gw, 44, hp, pmax, YELLOW)
        baseline(cr, gx, y1 + 414, gw)
        list_rows(cr, RX, y1 + 138, RW, 'TOP PAGES', det('ap', 'all'), 6, MAGENTA, 18, short_url)
        share_rows(cr, RX, y1 + 278, 180, 'COUNTRIES (share of views)', det('ac', 'all'), 6, GREEN, 18)
        share_rows(cr, RX + 198, y1 + 278, 180, 'DEVICES', det('ad', 'all'), 3, GREEN, 18)
        GA = 1
        if eA > 0.98 then
            plot({x = gx, y = y1 + 126, w = gw, h = 290, n = #hi, t0 = d.meta[1], impr = hi, clicks = hc,
                pos = hp, c = CYAN, ty = y1 + 116, strips = {{hi, iy, ih, imax, MAGENTA}, {hc, cy, chh, cmax, CYAN},
                {hp, y1 + 368, 44, pmax, YELLOW, true}}})
        end
    end
    text(cr, nice_date(d.meta[1]), gx, ly, MONO, 9, false, DIM, 1, 'l')
    text(cr, nice_date(d.meta[2]), gx + gw, ly, MONO, 9, false, DIM, 1, 'r')
    if eA < 0.6 then
        GA = 1 - smooth(eA / 0.6)
        local lx = W / 2 - 150
        rrect(cr, lx - 13, ly - 7, 8, 8, 2); col(cr, MAGENTA, 1); cairo_fill(cr)
        lx = lx + text(cr, string.format('impressions (peak %s/%s)', commas(maxof(hi)), d.per:lower()), lx, ly, MONO, 9, false, DIM, 1, 'l') + 30
        rrect(cr, lx - 13, ly - 7, 8, 8, 2); col(cr, CYAN, 1); cairo_fill(cr)
        text(cr, string.format('clicks (peak %s/%s)', commas(maxof(hc)), d.per:lower()), lx, ly, MONO, 9, false, DIM, 1, 'l')
        GA = 1
    end

    -- ----- sites -----
    X.pos = W - 16
    local y2 = g.y2
    card(cr, 0.5, y2, W - 1, g.h2, 'SITES', MAGENTA,
        string.format('%d sites, sorted by impressions', #d.site), clamp(g.sS, 0, 1) * 0.6)
    local hy = y2 + 60
    text(cr, 'SITE', X.name, hy, DISPLAY, 8, true, DIM, 1, 'l')
    text(cr, 'IMPRESSIONS / ' .. d.per, X.sp, hy, DISPLAY, 8, true, DIM, 1 - clamp(g.sS, 0, 1), 'l')
    for _, k in ipairs({{'CLICKS', X.cl}, {'IMPR', X.im}, {'CTR', X.ctr}, {'POS', X.pos}}) do
        text(cr, k[1], k[2], hy, DISPLAY, 8, true, DIM, 1, 'r')
    end
    for r = 1, g.nS do
        local s, yy, h = d.site[r], g.sy[r], g.sh[r]
        local e = sprS[r] and sprS[r].x or 0
        local live = s.i > 0
        row_frame(cr, yy, h, e, MAGENTA, r % 2 == 0, pinned and pinned.k == 'S' and pinned.i == r)
        local by = yy + mix(math.min(h, 31) / 2 + 4, 23, e)
        dot(cr, 22, by - 4, 3 + e, live and (s.c > 0 and GREEN or YELLOW) or DIM, live and 1 or 0.5)
        local sub = s.host:gsub('%.?' .. esc(domain()) .. '$', '')
        local ncol = e > 0.4 and WHITE or (live and TEXT or DIM)
        local size = e > 0.001 and mix(11, 15, e) or 11
        size = math.floor(size * 4 + 0.5) / 4
        if sub == '' then
            text(cr, domain(), X.name, by, MONO, size, true, ncol, 1, 'l')
        else
            local adv = text(cr, sub, X.name, by, MONO, size, true, ncol, 1, 'l')
            text(cr, '.' .. domain(), X.name + adv, by, MONO, size, false, DIM, 0.75 + 0.25 * e, 'l')
        end
        if live or e > 0.01 then grow_graph(cr, s, yy, h, e, X.sp, X.spw, MAGENTA, 52, 82)
        else baseline(cr, X.sp, yy + h - 7, X.spw) end
        header_numbers(cr, s, by)
        if e > 0.3 then
            cairo_save(cr); cairo_rectangle(cr, 0, yy, W, h); cairo_clip(cr)
            opened(cr, d, s, yy, e, 'S', s.host)
            cairo_restore(cr)
        end
    end

    -- ----- top queries -----
    local y3 = g.y3
    card(cr, 0.5, y3, W - 1, g.hq, 'TOP SEARCH QUERIES', GREEN, 'by clicks', clamp(g.sQ, 0, 1) * 0.6)
    hy = y3 + 60
    text(cr, 'QUERY', 34, hy, DISPLAY, 8, true, DIM, 1, 'l')
    for _, k in ipairs({{'CLICKS', X.cl}, {'IMPR', X.im}, {'CTR', X.ctr}, {'POS', X.pos}}) do
        text(cr, k[1], k[2], hy, DISPLAY, 8, true, DIM, 1, 'r')
    end
    local qmax = 0.0001
    for r = 1, g.nQ do qmax = math.max(qmax, d.query[r].c) end
    for r = 1, g.nQ do
        local q, yy, h = d.query[r], g.qy[r], g.qh[r]
        local e = sprQ[r] and sprQ[r].x or 0
        row_frame(cr, yy, h, e, GREEN, r % 2 == 0, pinned and pinned.k == 'Q' and pinned.i == r)
        local by = yy + mix(math.min(h, 26) / 2 + 4, 20, e)
        text(cr, tostring(r), 16.5, by, DISPLAY, 8, true, GREEN, 0.7, 'l')
        local size = math.floor(mix(11, 14, e) * 4 + 0.5) / 4
        text(cr, fit(cr, q.q, MONO, size, e > 0.5, 280), 34, by, MONO, size, e > 0.5, e > 0.4 and WHITE or TEXT, 1, 'l')
        if e < 0.95 then
            local old = GA; GA = GA * (1 - e)
            local bx = mix(450, DX, 0)
            rrect(cr, bx, by - 8, 130, 5, 2.5); col(cr, GREEN, 0.13); cairo_fill(cr)
            rrect(cr, bx, by - 8, math.max(5, 130 * q.c / qmax), 5, 2.5); col(cr, GREEN, 1); cairo_fill(cr)
            GA = old
        end
        grow_graph(cr, q, yy, math.min(h, 26) + e * (h - 26), e, 330, 100, GREEN, 48, 70)
        header_numbers(cr, q, by)
        if e > 0.3 then
            cairo_save(cr); cairo_rectangle(cr, 0, yy, W, h); cairo_clip(cr)
            opened(cr, d, q, yy, e, 'Q', tostring(r))
            cairo_restore(cr)
        end
    end
end

-- ===== comparison =====
-- validated dark-surface categorical order; a site keeps its colour while it stays selected
local HUES = {}
for i, h in ipairs({'3987e5', 'd95926', '199e70', 'c98500', 'd55181', '0ca30c', '9085e9', 'e66767'}) do
    HUES[i] = {tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255}
end
local GREY = {0.62, 0.62, 0.6}

local function is_sel(h) for _, x in ipairs(cmp.sel) do if x == h then return true end end return false end
local function free_slot()
    local used = {}
    for _, h in ipairs(cmp.sel) do if cmp.slot[h] then used[cmp.slot[h]] = true end end
    for i = 1, MAX_LINES do if not used[i] then return i end end
    return 1
end
local function bump() cmp.rev = cmp.rev + 1; dirty = true end
local function remove_site(h)
    for i, x in ipairs(cmp.sel) do if x == h then table.remove(cmp.sel, i) break end end
end
local function add_site(h)
    if is_sel(h) then return end
    if #cmp.sel >= MAX_LINES then table.remove(cmp.sel, 1) end
    cmp.slot[h] = free_slot()
    cmp.sel[#cmp.sel + 1] = h
end
set_sites = function(list, keep_context)
    local want = {}
    for i = 1, math.min(#list, MAX_LINES) do want[list[i]] = true end
    for i = #cmp.sel, 1, -1 do if not want[cmp.sel[i]] then table.remove(cmp.sel, i) end end
    for i = 1, math.min(#list, MAX_LINES) do add_site(list[i]) end
    if keep_context then   -- one site on its own says little: add the three biggest for scale
        for _, s in ipairs(live_sites()) do if #cmp.sel < 4 then add_site(s.host) end end
    end
    bump()
end
local function preset(key, n)
    local l = live_sites()
    if key == 'impr' then table.sort(l, function(a, b) return a.i > b.i end)
    elseif key == 'clicks' then table.sort(l, function(a, b) return a.c > b.c end)
    elseif key == 'rise' then table.sort(l, function(a, b) return a.gi > b.gi end)
    else table.sort(l, function(a, b) return a.gi < b.gi end) end
    local o = {}
    for i = 1, math.min(n, #l) do o[i] = l[i].host end
    set_sites(o)
end
local function colour_of(h) return is_sel(h) and HUES[cmp.slot[h] or 1] or GREY end

-- series for every live site under the current settings; false = no value that day
local cache = {}
local function build_series()
    local key = data.days .. tostring(cmp.avg) .. data.meta[3]
    if cache.key == key then return cache end
    cache = {key = key, s = {}}
    for _, site in ipairs(live_sites()) do
        local L = {impr = site.impr, clicks = site.clicks, pos = site.posd}
        if #L.impr > 0 then
            local N = #L.impr
            local out = {{}, {}, {}, {}}
            local n = N
            for k = 1, n do
                local j = N - n + k
                local from = cmp.avg and math.max(1, j - (data.step == 7 and 3 or 6)) or j
                local im, ck, pw = 0, 0, 0
                for m = from, j do
                    im, ck, pw = im + L.impr[m], ck + L.clicks[m], pw + L.pos[m] * L.impr[m]
                end
                local cnt = j - from + 1
                out[1][k], out[2][k] = im / cnt, ck / cnt
                out[3][k] = im > 0 and 100 * ck / im or false
                out[4][k] = im > 0 and pw / im or false
            end
            local a = {0, 0, 0}
            for j = N - n + 1, N do
                a[1], a[2], a[3] = a[1] + L.impr[j], a[2] + L.clicks[j], a[3] + L.pos[j] * L.impr[j]
            end
            cache.s[site.host] = {out = out, n = n, tot = {a[1], a[2], a[1] > 0 and 100 * a[2] / a[1] or false,
                a[1] > 0 and a[3] / a[1] or false}}
            cache.n = n
        end
    end
    return cache
end

local function nice_top(v)
    if v <= 0 then return 1 end
    local p = 10 ^ math.floor(math.log(v, 10))
    for _, m in ipairs({1, 1.5, 2, 3, 4, 5, 6, 8, 10}) do if m * p >= v then return m * p end end
    return 10 * p
end

-- normalised 0..1 lines (1 = top of the chart) plus the axis top of each panel
local norm = {}
local function build_norm()
    local S = build_series()
    local key = S.key .. cmp.scale .. cmp.rev
    if norm.key == key then return norm end
    local old = norm
    norm = {key = key, top = {}, v = {}, n = S.n}
    for p = 1, 4 do
        local top = 0
        for _, h in ipairs(cmp.sel) do
            local s = S.s[h]
            if s then for _, v in ipairs(s.out[p]) do if v and v > top then top = v end end end
        end
        if p == 3 then top = math.min(top, 100) end
        if p == 4 then top = math.min(math.max(top, 10), 80) end
        norm.top[p] = nice_top(top)
    end
    for h, s in pairs(S.s) do
        norm.v[h] = {}
        for p = 1, 4 do
            local o, peak = {}, 0
            for _, v in ipairs(s.out[p]) do if v and v > peak then peak = v end end
            for k, v in ipairs(s.out[p]) do
                if not v then o[k] = false
                elseif p == 4 then o[k] = 1 - (v - 1) / math.max(norm.top[4] - 1, 1)
                elseif p <= 2 and cmp.scale == '% OF PEAK' then o[k] = peak > 0 and v / peak or 0
                elseif p <= 2 and cmp.scale == 'LOG' then
                    o[k] = math.log(1 + v) / math.log(1 + norm.top[p])
                else o[k] = v / norm.top[p] end
            end
            -- start the morph from what is on screen now
            local from = old.v and old.v[h] and old.v[h][p]
            if from and #from.to > 1 and #o > 1 then
                local m = cmp.morph.x
                local st = {}
                for k = 1, #o do
                    local q = 1 + (k - 1) * (#from.to - 1) / (#o - 1)
                    local i = math.floor(q + 0.5)
                    local a, b = from.st[i], from.to[i]
                    st[k] = (a and b) and mix(a, b, m) or b or a or false
                end
                norm.v[h][p] = {st = st, to = o}
            else
                norm.v[h][p] = {st = o, to = o}
            end
        end
    end
    cmp.morph.x, cmp.morph.from, cmp.morph.goal, cmp.morph.t = 0, 0, 1, 0
    return norm
end

local function norm_at(h, p, k)
    local v = norm.v[h] and norm.v[h][p]
    if not v then return false end
    local a, b = v.st[k], v.to[k]
    if a and b then return mix(a, b, cmp.morph.x) end
    return b
end

local function fmt(p, v)
    if not v then return '-' end
    if p == 1 then return v >= 10 and commas(v) or (v == math.floor(v) and commas(v) or string.format('%.1f', v)) end
    if p == 2 then return v == math.floor(v) and commas(v) or string.format('%.1f', v) end
    if p == 3 then return string.format('%.1f%%', v) end
    return string.format('%.1f', v)
end

-- plot rectangle of a panel
local CX, CW = 58, 0
local function panel_rect(g, p)
    CW = W - 58 - 236
    return CX, g.py[p] + 38, CW, g.ph[p] - 38 - 22
end

local function draw_line_norm(cr, h, p, x, y, w, hh, n, c, a, width)
    local pen, drew = false, false
    cairo_new_path(cr)
    for k = 1, n do
        local v = norm_at(h, p, k)
        if v then
            local px, py = x + (k - 1) * w / (n - 1), y + hh - clamp(v, 0, 1) * hh
            if pen then cairo_line_to(cr, px, py) else cairo_move_to(cr, px, py) end
            pen, drew = true, true
        else pen = false end
    end
    if drew then cairo_set_line_width(cr, width); col(cr, c, a); cairo_stroke(cr) end
end

local function insights(d)
    if d.ins then return d.ins end
    local up, down, spike
    for _, s in ipairs(live_sites()) do
        if not up or s.gc > up.gc then up = s end
        if not down or s.gc < down.gc then down = s end
        local sorted = {}
        for k, v in ipairs(s.impr) do sorted[k] = v end
        table.sort(sorted)
        local med = sorted[math.max(1, #sorted // 2)] or 0
        for k, v in ipairs(s.impr) do
            local score = v - med
            local rel = v / math.max(med, 8)
            if v >= 30 and (not spike or score * rel > spike.score) then
                spike = {s = s, k = k, v = v, med = med, score = score * rel}
            end
        end
    end
    local o = {}
    if up then o[#o + 1] = {'RISING FASTEST', short(up.host), string.format('%s > %s clicks', commas(up.oc), commas(up.nc)),
        string.format('views %s > %s%s', commas(up.oi), commas(up.ni), d.has_prev and '' or ' (1st > 2nd half)'), GREEN, up.host} end
    if down and down.gc >= 0 then o[#o + 1] = {'FALLING MOST', 'none', 'no site lost clicks', 'in this period', GREEN, nil}
    elseif down then o[#o + 1] = {'FALLING MOST', short(down.host), string.format('%s > %s clicks', commas(down.oc), commas(down.nc)),
        string.format('views %s > %s%s', commas(down.oi), commas(down.ni), d.has_prev and '' or ' (1st > 2nd half)'), RED, down.host} end
    if d.op[1] then
        local q = d.op[1]
        o[#o + 1] = {'BEST OPPORTUNITY', q.q, string.format('%s views, only %s click%s', commas(q.i), commas(q.c), q.c == 1 and '' or 's'),
            string.format('position %.1f  %s', q.pos, short_url(q.page)), CYAN, q.page:match('^[^/]+')}
    end
    if spike then o[#o + 1] = {'BIGGEST SPIKE', short(spike.s.host), string.format('%s views on %s', commas(spike.v),
        (d.step == 7 and 'the week of ' or '') .. nice_date(d.meta[1], at_day(spike.k - 1))), string.format('a normal ' .. d.per:lower() .. ': %s', commas(spike.med)), YELLOW, spike.s.host} end
    d.ins = o
    return o
end

local function draw_compare(cr, d, g)
    local S = build_series()
    build_norm()
    -- ----- toolbar and legend -----
    card(cr, 0.5, g.ty, W - 1, g.th, 'COMPARE SITES', CYAN, nil, 0)
    local x = W - 16
    local function group(opts)
        for i = #opts, 1, -1 do
            local o = opts[i]
            local w = width_of(cr, o[1], DISPLAY, 8.5, true) + 22
            x = x - w
            button(cr, o[1], x, g.ty + 9, w, o[2], CYAN, o[3])
            x = x - 5
        end
        x = x - 14
    end
    local function scale_opt(n) return {n, cmp.scale == n, function() cmp.scale = n; bump() end} end
    group({scale_opt('REAL'), scale_opt('% OF PEAK'), scale_opt('LOG')})
    group({{d.step == 7 and 'WEEKLY' or 'DAILY', not cmp.avg, function() cmp.avg = false; bump() end},
        {d.step == 7 and '4-WEEK AVG' or '7-DAY AVG', cmp.avg, function() cmp.avg = true; bump() end}})
    x = 16
    for _, o in ipairs({{'TOP 5 BY VIEWS', function() preset('impr', 5) end},
        {'TOP 5 BY CLICKS', function() preset('clicks', 5) end}, {'RISING 5', function() preset('rise', 5) end},
        {'FALLING 5', function() preset('fall', 5) end}, {'CLEAR', function() set_sites({}) end}}) do
        local w = width_of(cr, o[1], DISPLAY, 8.5, true) + 22
        button(cr, o[1], x, g.ty + 49, w, false, MAGENTA, o[2])
        x = x + w + 6
    end
    text(cr, string.format('click a site to show or hide it (%d of %d)', #cmp.sel, MAX_LINES), W - 16, g.ty + 64,
        MONO, 10, false, DIM, 1, 'r')
    local cw = (W - 32) / 5
    for i, s in ipairs(live_sites()) do
        local cx, cy = 16 + ((i - 1) % 5) * cw, g.ty + 82 + ((i - 1) // 5) * 27
        local on = is_sel(s.host)
        local c = colour_of(s.host)
        rrect(cr, cx, cy, cw - 6, 22, 6); col(cr, on and c or WHITE, on and 0.16 or 0.03); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1); col(cr, on and c or DIM, on and 0.8 or 0.25); cairo_stroke(cr)
        rrect(cr, cx + 8, cy + 7, 8, 8, 2); col(cr, c, on and 1 or 0.35); cairo_fill(cr)
        text(cr, fit(cr, short(s.host), MONO, 10, on, cw - 84), cx + 22, cy + 15, MONO, 10, on, on and WHITE or DIM, 1, 'l')
        text(cr, commas(s.i), cx + cw - 14, cy + 15, MONO, 9, false, DIM, 1, 'r')
        region(cx, cy, cw - 6, 22, function()
            if is_sel(s.host) then remove_site(s.host) else add_site(s.host) end
            bump()
        end, 6, c)
        regions[cur][#regions[cur]].host = s.host
    end

    -- ----- charts -----
    local n = S.n or 0
    for p = 1, 4 do
        local y, h = g.py[p], g.ph[p]
        local e = sprP[p] and sprP[p].x or 0
        local c = ({MAGENTA, CYAN, GREEN, YELLOW})[p]
        rrect(cr, 0.5, y, W - 1, h, 10); col(cr, WHITE, 0.022 + 0.012 * e); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1); col(cr, c, 0.28 + 0.5 * e); cairo_stroke(cr)
        if e > 0.02 then corners(cr, -2.5, y - 3, W + 5, h + 6, 12, c, e, 2) end
        cairo_set_line_width(cr, 3); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, c, 1)
        seg(cr, 16, y + 13, 16, y + 24)
        local adv = text(cr, PANELS[p], 26, y + 23, DISPLAY, 10, true, e > 0.5 and WHITE or c, 1, 'l')
        local note = p == 4 and 'higher on the chart is better'
            or (p <= 2 and (cmp.scale == '% OF PEAK' and "% of each site's own best day"
            or (cmp.scale == 'LOG' and 'log scale' or 'per ' .. d.per:lower())) or 'clicks / impressions')
        if cmp.avg then note = note .. (d.step == 7 and ', 4-week average' or ', 7-day average') end
        text(cr, note, 26 + adv + 12, y + 23, MONO, 9, false, DIM, 1, 'l')
        local px, py, pw, ph = panel_rect(g, p)
        local steps = e > 0.5 and 4 or 2
        for k = 0, steps do
            local f = k / steps
            local yy = py + ph * (1 - f)
            cairo_set_line_width(cr, 1); col(cr, DIM, k == 0 and 0.3 or 0.12); seg(cr, px, yy, px + pw, yy)
            local lab
            if p == 4 then lab = string.format('%.0f', norm.top[4] - f * (norm.top[4] - 1))
            elseif p <= 2 and cmp.scale == '% OF PEAK' then lab = string.format('%d%%', f * 100)
            elseif p <= 2 and cmp.scale == 'LOG' then
                lab = fmt(p, math.floor((1 + norm.top[p]) ^ f - 1 + 0.5))
            else lab = fmt(p, norm.top[p] * f) end
            text(cr, lab, px - 8, yy + 3, MONO, 9, false, DIM, 1, 'r')
        end
        cairo_save(cr)
        cairo_rectangle(cr, px - 2, py - 3, pw + 4, ph + 6); cairo_clip(cr)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        if n > 1 then
            for _, s in ipairs(live_sites()) do      -- unselected sites as quiet context
                if not is_sel(s.host) and p <= 2 then draw_line_norm(cr, s.host, p, px, py, pw, ph, n, GREY, 0.24, 1) end
            end
            for _, hst in ipairs(cmp.sel) do
                local quiet = cmp.hover and cmp.hover ~= hst
                if not quiet then draw_line_norm(cr, hst, p, px, py, pw, ph, n, colour_of(hst), 0.18, 6) end
                draw_line_norm(cr, hst, p, px, py, pw, ph, n, colour_of(hst), quiet and 0.22 or 1,
                    cmp.hover == hst and 2.8 or 2)
            end
            if cmp.hover and not is_sel(cmp.hover) then
                draw_line_norm(cr, cmp.hover, p, px, py, pw, ph, n, WHITE, 0.9, 2)
            end
        end
        cairo_restore(cr)
        cairo_new_path(cr)
        if n > 1 then
            for k = 0, 4 do
                local i = math.floor((n - 1) * k / 4 + 0.5)
                text(cr, point_date(i), px + pw * i / (n - 1), y + h - 7, MONO, 9, false, DIM, 1,
                    k == 0 and 'l' or (k == 4 and 'r' or 'c'))
            end
        end
    end

    -- ----- insights -----
    local ins = insights(d)
    local iw = (W - 3 * 10) / 4
    for i, o in ipairs(ins) do
        local ix = (i - 1) * (iw + 10)
        local c = o[5]
        rrect(cr, ix + 0.5, g.iy, iw - 1, g.ih, 10); col(cr, c, 0.05); cairo_fill_preserve(cr)
        cairo_set_line_width(cr, 1); col(cr, c, 0.35); cairo_stroke(cr)
        cairo_set_line_width(cr, 3); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, c, 1)
        seg(cr, ix + 14, g.iy + 14, ix + 14, g.iy + 25)
        text(cr, o[1], ix + 23, g.iy + 24, DISPLAY, 8.5, true, c, 1, 'l')
        text(cr, fit(cr, o[2], MONO, 14, true, iw - 28), ix + 14, g.iy + 52, MONO, 14, true, WHITE, 1, 'l')
        text(cr, fit(cr, o[3], MONO, 10, false, iw - 28), ix + 14, g.iy + 75, MONO, 10, false, TEXT, 1, 'l')
        text(cr, fit(cr, o[4], MONO, 10, false, iw - 28), ix + 14, g.iy + 94, MONO, 10, false, DIM, 1, 'l')
        region(ix, g.iy, iw, g.ih, function() if o[6] and d.by_host[o[6]] then set_sites({o[6]}, true) end end, 10, c)
    end
end

-- ===== things drawn on top every frame =====
local cross = {x = nil, v = 0}

local function value_list(cr, g, p, k)
    local S = build_series()
    local x1 = W - 16
    local x0 = W - 218
    local y = g.py[p] + 23
    text(cr, k and long_date(k - 1) or (p <= 2 and 'TOTAL' or 'AVERAGE'), x1, y, MONO, 9, true, k and WHITE or DIM, 1, 'r')
    local rows = {}
    local function add(h)
        local s = S.s[h]
        if s then rows[#rows + 1] = {h, k and s.out[p][k] or (not k and s.tot[p]) or false} end
    end
    for _, h in ipairs(cmp.sel) do add(h) end
    if cmp.hover and not is_sel(cmp.hover) then add(cmp.hover) end
    table.sort(rows, function(a, b)
        if (a[2] and true or false) ~= (b[2] and true or false) then return a[2] and true or false end
        if not a[2] or a[2] == b[2] then return a[1] < b[1] end
        if p == 4 then return a[2] < b[2] end
        return a[2] > b[2]
    end)
    local room = math.floor((g.ph[p] - 40) / 17)
    for i = 1, math.min(#rows, room) do
        local h, v = rows[i][1], rows[i][2]
        local yy = y + 6 + i * 17
        local hot = cmp.hover == h
        local c = is_sel(h) and colour_of(h) or WHITE
        if hot then rrect(cr, x0 - 6, yy - 12, x1 - x0 + 12, 16, 4); col(cr, c, 0.22); cairo_fill(cr) end
        rrect(cr, x0, yy - 8, 8, 8, 2); col(cr, c, 1); cairo_fill(cr)
        text(cr, fit(cr, short(h), MONO, 10, hot, 116), x0 + 14, yy, MONO, 10, hot, hot and WHITE or TEXT, 1, 'l')
        text(cr, fmt(p, v), x1, yy, MONO, 10, true, v and TEXT or DIM, 1, 'r')
    end
    if #rows > room then
        text(cr, string.format('+%d more', #rows - room), x0 + 14, y + 6 + (room + 1) * 17 - 4, MONO, 9, false, DIM, 1, 'l')
    end
end

-- which site the pointer is on: legend chip, value list row or nearest line
local function find_hover(g)
    for _, r in ipairs(regions[2]) do if r.host and inside(r.x, r.y, r.w, r.h) then return r.host end end
    if panel == 0 then return nil end
    local px, py, pw, ph = panel_rect(g, panel)
    local n = norm.n or 0
    if n < 2 or not inside(px - 4, py - 4, pw + 8, ph + 8) then return nil end
    local f = clamp((mx - px) / pw, 0, 1) * (n - 1) + 1
    local a = math.min(n - 1, math.floor(f))
    local best, bd = nil, 13
    local function try(h, bias)
        local u, v = norm_at(h, panel, a), norm_at(h, panel, a + 1)
        if u and v then
            local yy = py + ph - clamp(mix(u, v, f - a), 0, 1) * ph
            local dd = math.abs(yy - my) + bias
            if dd < bd then best, bd = h, dd end
        end
    end
    for _, h in ipairs(cmp.sel) do try(h, 0) end
    if panel <= 2 then for _, s in ipairs(live_sites()) do if not is_sel(s.host) then try(s.host, 7) end end end
    return best
end

local function glide(target, dt)
    if not cross.x or math.abs(cross.x - target) > 400 then cross.x, cross.v = target, 0 end
    return follow(cross, target, dt, 48)
end

local function lerp_at(s, f)
    local a = math.floor(f)
    local u, v = s[a], s[math.min(#s, a + 1)]
    if not u or not v then return u or v end
    return mix(u, v, f - a)
end

local function draw_overlay(cr, d, dt, g, gc)
    local used = false
    if view.want == 0 then
        for _, p in ipairs(plots[1]) do
            if inside(p.x - 6, p.y, p.w + 12, p.h) and p.n > 1 then
                used = true
                local k = clamp(math.floor((mx - p.x) / (p.w / (p.n - 1)) + 0.5) + 1, 1, p.n)
                local cx = glide(p.x + (k - 1) * p.w / (p.n - 1), dt)
                local f = clamp((cx - p.x) / p.w, 0, 1) * (p.n - 1) + 1
                local last = p.strips[#p.strips]
                cairo_set_line_width(cr, 1); col(cr, WHITE, 0.4)
                seg(cr, cx, p.strips[1][2], cx, last[2] + last[3])
                for _, s in ipairs(p.strips) do
                    local v = s[6] and s[1][k] or lerp_at(s[1], f)
                    if v and not (s[6] and v == 0) then
                        local yy = s[6] and s[2] + clamp((v - 1) / math.max(s[4] - 1, 1), 0, 1) * s[3]
                            or s[2] + s[3] * (1 - clamp(v / s[4], 0, 1))
                        dot(cr, cx, yy, 7, s[5], 0.25); dot(cr, cx, yy, 3.4, WHITE, 1)
                    end
                end
                local i, c, po = p.impr[k] or 0, p.clicks[k] or 0, p.pos[k] or 0
                tooltip(cr, {{long_date(k - 1) .. '   ', WHITE}, {commas(i) .. ' views   ', TEXT},
                    {commas(c) .. ' clicks   ', TEXT}, {i > 0 and string.format('%.1f%% CTR   ', 100 * c / i) or '- CTR   ', TEXT},
                    {po > 0 and string.format('position %.1f', po) or 'not shown', TEXT}}, cx, p.ty, p.x, p.x + p.w, p.c)
            end
        end
    else
        local S = build_series()
        local k, cx
        if panel > 0 and (S.n or 0) > 1 then
            local px, _, pw = panel_rect(gc, panel)
            if mx >= px - 6 and mx <= px + pw + 6 then
                k = clamp(math.floor((mx - px) / (pw / (S.n - 1)) + 0.5) + 1, 1, S.n)
                cx = glide(px + (k - 1) * pw / (S.n - 1), dt)
                used = true
            end
        end
        for p = 1, 4 do
            local px, py, pw, ph = panel_rect(gc, p)
            if cx then
                cairo_set_line_width(cr, 1); col(cr, WHITE, p == panel and 0.5 or 0.28); seg(cr, cx, py, cx, py + ph)
                local f = clamp((cx - px) / pw, 0, 1) * (S.n - 1) + 1
                local a = math.min(S.n - 1, math.floor(f))
                for _, h in ipairs(cmp.sel) do
                    local u, v = norm_at(h, p, a), norm_at(h, p, a + 1)
                    local q = (u and v) and mix(u, v, f - a) or norm_at(h, p, k)
                    if q and not (cmp.hover and cmp.hover ~= h) then
                        local yy = py + ph - clamp(q, 0, 1) * ph
                        dot(cr, cx, yy, 5.5, BG, 1); dot(cr, cx, yy, 4, colour_of(h), 1)
                    end
                end
            end
            value_list(cr, gc, p, k)
        end
        local hv = inside_board and find_hover(gc) or nil
        if hv ~= cmp.hover then cmp.hover = hv; dirty = true end
    end
    if not used then cross.x = nil end
    -- buttons light up under the pointer
    for _, r in ipairs(regions[view.want + 1]) do
        if inside(r.x, r.y, r.w, r.h) then
            rrect(cr, r.x, r.y, r.w, r.h, r.r); col(cr, r.c, 0.16); cairo_fill_preserve(cr)
            cairo_set_line_width(cr, 1.5); col(cr, r.c, 1); cairo_stroke(cr)
        end
    end
end

-- ===== frame, header, main =====
local next_load, switch = 0, false
local glass_img, screen, glass_stamp
local function load_glass(head)
    local f = io.open(CACHE .. 'screens.txt', 'r')     -- xrandr --listmonitors, written by start.sh
    if f then
        for l in f:lines() do
            local n, w, h, x, y = l:match('^%s*(%d+):%s+%S+%s+(%d+)/%d+x(%d+)/%d+%+(%d+)%+(%d+)')
            if n and tonumber(n) == head then screen = {w = tonumber(w), h = tonumber(h), x = tonumber(x), y = tonumber(y)} end
        end
        f:close()
    end
    f = io.open(CACHE .. 'glass.png', 'rb')
    local size = f and f:seek('end') or 0
    if f then f:close() end
    if size == glass_stamp then return false end
    glass_stamp = size
    if glass_img then cairo_surface_destroy(glass_img) end
    glass_img = size > 0 and cairo_image_surface_create_from_png(CACHE .. 'glass.png') or nil
    return true
end
local function draw_frame(cr, FW, FH)
    local tint = 0.84
    if glass_img and cairo_surface_status(glass_img) == CAIRO_STATUS_SUCCESS and screen then
        -- the blurred wallpaper, placed exactly where the sharp one lies behind this window
        local iw, ih = cairo_image_surface_get_width(glass_img), cairo_image_surface_get_height(glass_img)
        local k = math.max(screen.w / iw, screen.h / ih)
        cairo_save(cr)
        rrect(cr, 1, 1, FW - 2, FH - 2, 16); cairo_clip(cr)
        cairo_translate(cr, (screen.w - iw * k) / 2 - GAP_X, (screen.h - ih * k) / 2 - GAP_Y)
        cairo_scale(cr, k, k)
        cairo_set_source_surface(cr, glass_img, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
        tint = GLASS_TINT
    end
    rrect(cr, 1, 1, FW - 2, FH - 2, 16)
    col(cr, BG, tint); cairo_fill(cr)
    local sheen = cairo_pattern_create_linear(0, 0, FW * 0.5, FH)   -- light falling on the glass
    cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.055)
    cairo_pattern_add_color_stop_rgba(sheen, 0.35, 1, 1, 1, 0.012)
    cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0)
    rrect(cr, 1, 1, FW - 2, FH - 2, 16)
    cairo_set_source(cr, sheen); cairo_fill_preserve(cr); cairo_pattern_destroy(sheen)
    cairo_set_line_width(cr, 1); col(cr, CYAN, 0.45); cairo_stroke(cr)
    corners(cr, 5, 5, FW - 10, FH - 10, 26, CYAN, 0.14, 6)
    corners(cr, 5, 5, FW - 10, FH - 10, 26, CYAN, 0.95, 2)
    cairo_set_line_width(cr, 2); col(cr, MAGENTA, 0.9)
    seg(cr, FW / 2 - 36, 5, FW / 2 + 36, 5); seg(cr, FW / 2 - 36, FH - 5, FW / 2 + 36, FH - 5)
end

local range_names = {'28 DAYS', '60', '90', '365'}
local function range_rect(cr, i)
    local x = 404
    for k = 1, i - 1 do x = x + width_of(cr, range_names[k], DISPLAY, 9, true) + 22 end
    return x, 7, width_of(cr, range_names[i], DISPLAY, 9, true) + 20, 24
end

local TAB = {{'OVERVIEW', 0}, {'COMPARE', 1}}
local function tab_rect(cr, i)
    local x = 186
    for k = 1, i - 1 do x = x + width_of(cr, TAB[k][1], DISPLAY, 9, true) + 26 end
    return x, 7, width_of(cr, TAB[i][1], DISPLAY, 9, true) + 24, 24
end

local function draw_header(cr, d)
    text(cr, 'SEARCH CONSOLE', 6, 25, DISPLAY, 15, true, CYAN, 1, 'l')
    local lg = cairo_pattern_create_linear(0, 0, W, 0)
    for _, s in ipairs({{0, CYAN}, {0.5, MAGENTA}, {1, CYAN}}) do
        cairo_pattern_add_color_stop_rgba(lg, s[1], s[2][1], s[2][2], s[2][3], 0.9)
    end
    cairo_set_source(cr, lg); cairo_set_line_width(cr, 1); seg(cr, 0, 40, W, 40)
    cairo_pattern_destroy(lg)
    if not d then
        badge(cr, W - 2, 6, 'DATA', 'NOT LOADED YET', RED)
        return
    end
    badge(cr, W - 2, 6, nice_date(d.meta[1]) .. ' -', os.date(d.days > 300 and '%d %b %Y' or '%d %b', day_time(d.meta[2])), CYAN)
end

-- "SYNCED 12m 05s AGO", counted live
local function draw_synced(cr, d)
    local dv = os.date(d.days > 300 and '%d %b %Y' or '%d %b', day_time(d.meta[2]))
    local x = W - 2 - (width_of(cr, dv, DISPLAY, 10, true) + width_of(cr, nice_date(d.meta[1]) .. ' -', DISPLAY, 10, false) + 34) - 10
    local age = math.max(0, os.time() - (tonumber(d.meta[3]) or 0))
    local h, m, sec = age // 3600, age % 3600 // 60, age % 60
    local v = h > 0 and string.format('%dh %02dm %02ds', h, m, sec) or (m > 0 and string.format('%dm %02ds', m, sec) or sec .. 's')
    local c = age > 6 * 3600 and RED or (age > 2 * 3600 and YELLOW or GREEN)
    -- fixed width, so the badge does not twitch every second
    local lw, aw = width_of(cr, 'SYNCED', DISPLAY, 9, false), width_of(cr, 'AGO', DISPLAY, 9, false)
    local vw = width_of(cr, h > 0 and '0h 00m 00s' or '00m 00s', MONO, 11, true)
    local w = lw + vw + aw + 52
    x = x - w
    rrect(cr, x, 6, w, 24, 12); col(cr, c, 0.14); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, 0.7); cairo_stroke(cr)
    local pulse = 0.5 + 0.5 * math.sin(T * 2.2)
    dot(cr, x + 13, 18, 4 + 3 * pulse, c, 0.10 + 0.14 * (1 - pulse))
    dot(cr, x + 13, 18, 3, c, 1)
    text(cr, 'SYNCED', x + 23, 22, DISPLAY, 9, false, DIM, 1, 'l')
    text(cr, v, x + 30 + lw + vw, 22, MONO, 11, true, c, 1, 'r')
    text(cr, 'AGO', x + 37 + lw + vw, 22, DISPLAY, 9, false, DIM, 1, 'l')
end

-- cached drawing surfaces
local layer, LW, LH = {}, 0, 0
local function layer_begin(cs, name)
    if not layer[name] then
        layer[name] = cairo_surface_create_similar(cs, CAIRO_CONTENT_COLOR_ALPHA, LW, LH)
    end
    local c = cairo_create(layer[name])
    cairo_set_operator(c, CAIRO_OPERATOR_CLEAR); cairo_paint(c)
    cairo_set_operator(c, CAIRO_OPERATOR_OVER)
    return c
end
local function layer_paint(cr, name, a)
    if not layer[name] or a < 0.004 then return end
    cairo_set_source_surface(cr, layer[name], 0, 0)
    if a >= 0.996 then cairo_paint(cr) else cairo_paint_with_alpha(cr, a) end
end

local next_pal, pal_key, drawn = 0, '', {}
local store = {}                    -- days -> data, so switching back is instant
local function palette_check()
    if T < next_pal then return end
    next_pal = T + 2
    refresh_palette()
    if load_glass(1) then drawn.frame = nil end
    local k = ''
    for _, c in ipairs({CYAN, MAGENTA, TEXT, DIM, BG, GREEN, YELLOW}) do k = k .. c[1] .. c[2] .. c[3] end
    if k ~= pal_key then pal_key = k; dirty = true; drawn.frame = nil end
end
local function data_check()
    if T < next_load then return end
    next_load = T + RELOAD_S
    local days = RANGES[range_i]
    local f = io.open(CACHE .. 'gsc-' .. days .. '.txt', 'r')
    local first = f and f:read('l') or ''
    if f then f:close() end
    local d = store[days]
    if not d or d.first ~= first then
        local new = load_data(days)
        if new then new.first = first; store[days] = new; d = new end
    end
    if not d or d == data then return end
    local fresh = data == nil
    if switch and not fresh then            -- keep the old picture and fade it out
        local name = view.want == 1 and 'comp' or 'over'
        if layer.old then cairo_surface_destroy(layer.old) end
        layer.old, layer[name] = layer[name], nil
        fade.x, fade.from, fade.goal, fade.t = 0, 0, 1, 0
        focus, panel, cross.x = nil, 0, nil
    end
    switch = false
    data = d
    dirty, drawn.frame, drawn.over, drawn.comp = true, nil, nil, nil
    for i = #cmp.sel, 1, -1 do if not d.by_host[cmp.sel[i]] then table.remove(cmp.sel, i) end end
    if fresh then preset('impr', 5) end
    if pinned and pinned.i > (pinned.k == 'Q' and #d.query or #d.site) then pinned = nil end
end

function conky_gsc()
    if conky_window == nil then return end
    local dt = tick()
    vis, vis_moving = hide(dt)
    if vis <= 0 then
        if T_step ~= HIDDEN then T_step = HIDDEN; conky_set_update_interval(HIDDEN) end
        return
    end
    moving = false
    palette_check()
    data_check()
    local FW, FH = conky_window.width, conky_window.height
    if FW ~= LW or FH ~= LH then
        for _, s in pairs(layer) do cairo_surface_destroy(s) end
        layer, LW, LH, dirty, drawn = {}, FW, FH, true, {}
        fade.x, fade.goal = 1, 1
    end
    W, H = FW - 2 * PAD, FH - 2 * PAD
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, FW, FH)
    local cr = cairo_create(cs)
    if vis < 1 then cairo_translate(cr, 0, 18 * (1 - vis)) end
    local d = data

    -- resting pointer: opening waits a moment so crossing the board does not set everything off
    if inside_board and d and want_since and T - want_since > 0.09 then retarget() end

    local tabs_v = tween(view, view.want, dt, 0.46, BETWEEN)
    local range_v = tween(range_pos, range_i, dt, 0.42, BETWEEN)
    local fresh_v = tween(fade, 1, dt, 0.42, BETWEEN)
    if not drawn.frame then
        local c = layer_begin(cs, 'frame')
        GA = 1
        draw_frame(c, FW, FH); cairo_translate(c, PAD, PAD); draw_header(c, d)
        cairo_destroy(c)
        drawn.frame = true
    end
    layer_paint(cr, 'frame', 1)

    local g, gc
    if d then
        local was = moving
        moving = false
        local f = (view.want == 0) and (focus or pinned) or nil
        tween(sprA, f and f.k == 'A' and 1 or 0, dt)
        local nS, nQ = n_rows()
        local eS, eQ = {}, {}
        for i = 1, nS do
            sprS[i] = sprS[i] or {}
            eS[i] = tween(sprS[i], f and f.k == 'S' and f.i == i and 1 or 0, dt)
        end
        for i = 1, nQ do
            sprQ[i] = sprQ[i] or {}
            eQ[i] = tween(sprQ[i], f and f.k == 'Q' and f.i == i and 1 or 0, dt)
        end
        g = layout(clamp(sprA.x, 0, 1), eS, eQ)
        local moveO = moving
        moving = false
        local eP = {}
        for i = 1, 4 do
            sprP[i] = sprP[i] or {}
            eP[i] = tween(sprP[i], view.want == 1 and panel == i and 1 or 0, dt)
        end
        tween(cmp.morph, 1, dt, 0.55, BETWEEN)
        gc = cmp_layout(eP)
        local moveC = moving
        moving = was or moveO or moveC
        if tabs_v < 0.996 and (moveO or dirty or not drawn.over) then
            local c = layer_begin(cs, 'over')
            cairo_translate(c, PAD, PAD)
            cur, regions[1], plots[1], GA = 1, {}, {}, 1
            draw_overview(c, d, g)
            cairo_destroy(c)
            drawn.over = true
        end
        if tabs_v > 0.004 and (moveC or dirty or not drawn.comp) then
            local c = layer_begin(cs, 'comp')
            cairo_translate(c, PAD, PAD)
            cur, regions[2], plots[2], GA = 2, {}, {}, 1
            draw_compare(c, d, gc)
            cairo_destroy(c)
            drawn.comp = true
        end
        if dirty then       -- the hidden view catches up when it is next shown
            if tabs_v >= 0.996 then drawn.over = nil end
            if tabs_v <= 0.004 then drawn.comp = nil end
        end
        dirty = false
        local s = tabs_v
        cairo_save(cr); cairo_translate(cr, -60 * s, 0); layer_paint(cr, 'over', (1 - s) * fresh_v); cairo_restore(cr)
        cairo_save(cr); cairo_translate(cr, 60 * (1 - s), 0); layer_paint(cr, 'comp', s * fresh_v); cairo_restore(cr)
        if fresh_v < 1 then layer_paint(cr, 'old', 1 - fresh_v)
        elseif layer.old then cairo_surface_destroy(layer.old); layer.old = nil end
    end

    -- moving highlight along the top edge
    GA = 1
    local span, run = 150, FW - 120
    local sx = 60 - span + (run + span) * curve(SWEEP, (T % 7) / 7)
    local sg = cairo_pattern_create_linear(sx, 0, sx + span, 0)
    cairo_pattern_add_color_stop_rgba(sg, 0, CYAN[1], CYAN[2], CYAN[3], 0)
    cairo_pattern_add_color_stop_rgba(sg, 0.8, 0.5 + CYAN[1] / 2, 0.5 + CYAN[2] / 2, 0.5 + CYAN[3] / 2, 0.95)
    cairo_pattern_add_color_stop_rgba(sg, 1, CYAN[1], CYAN[2], CYAN[3], 0)
    cairo_set_source(cr, sg); cairo_set_line_width(cr, 2)
    seg(cr, math.max(30, sx), 1.5, math.min(sx + span, FW - 30), 1.5)
    cairo_pattern_destroy(sg)

    cairo_translate(cr, PAD, PAD)
    -- tabs: the filled pill slides between them
    local x1, ty, w1, th = tab_rect(cr, 1)
    local x2, _, w2 = tab_rect(cr, 2)
    local tx, tw = mix(x1, x2, tabs_v), mix(w1, w2, tabs_v)
    rrect(cr, x1 - 3, ty - 3, x2 + w2 - x1 + 6, th + 6, 15); col(cr, WHITE, 0.04); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, CYAN, 0.3); cairo_stroke(cr)
    rrect(cr, tx, ty, tw, th, 12); col(cr, CYAN, 0.9); cairo_fill(cr)
    for i = 1, 2 do
        local x, y, w, h = tab_rect(cr, i)
        local on = math.abs(tabs_v - TAB[i][2]) < 0.5
        local hot = inside(x, y, w, h)
        text(cr, TAB[i][1], x + w / 2, y + 16, DISPLAY, 9, true, on and BG or (hot and WHITE or TEXT), 1, 'c')
    end
    local a1, _, _, _ = range_rect(cr, 1)
    local a4, _, w4 = range_rect(cr, 4)
    local lo = math.max(1, math.min(3, math.floor(range_v)))
    local xa, _, wa = range_rect(cr, lo)
    local xb, _, wb = range_rect(cr, lo + 1)
    rrect(cr, a1 - 3, 4, a4 + w4 - a1 + 6, 30, 15); col(cr, WHITE, 0.04); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, MAGENTA, 0.3); cairo_stroke(cr)
    rrect(cr, mix(xa, xb, range_v - lo), 7, mix(wa, wb, range_v - lo), 24, 12); col(cr, MAGENTA, 0.9); cairo_fill(cr)
    for i = 1, 4 do
        local x, y, w, h = range_rect(cr, i)
        text(cr, range_names[i], x + w / 2, y + 16, DISPLAY, 9, true, math.abs(range_v - i) < 0.5 and BG
            or (inside(x, y, w, h) and WHITE or TEXT), 1, 'c')
    end
    for v = 1, 2 do
        if not regions[v].tabs then
            regions[v].tabs = true
            for i = 1, 4 do
                local x, y, w, h = range_rect(cr, i)
                table.insert(regions[v], {x = x, y = y, w = w, h = h, r = 12, c = MAGENTA, fn = function()
                    if i ~= range_i then range_i, next_load = i, 0; switch = true end
                end})
            end
            for i = 1, 2 do
                local x, y, w, h = tab_rect(cr, i)
                table.insert(regions[v], {x = x, y = y, w = w, h = h, r = 12, c = CYAN, fn = function()
                    if view.want ~= TAB[i][2] then view.want = TAB[i][2]; focus, panel, cmp.hover = nil, 0, nil end
                end})
            end
        end
    end
    if d then draw_synced(cr, d) end
    if d then draw_overlay(cr, d, dt, g, gc) end

    if vis < 1 then                          -- being hidden or shown
        cairo_identity_matrix(cr); cairo_reset_clip(cr)
        cairo_set_source_rgba(cr, 0, 0, 0, vis)      -- (the last used colour must not decide how visible all is)
        cairo_set_operator(cr, CAIRO_OPERATOR_DEST_IN); cairo_paint(cr)
    end
    cairo_destroy(cr)
    cairo_surface_destroy(cs)

    -- frame rate follows what is happening
    local step = (vis_moving or moving or dirty or (inside_board and T - last_move < 1.5)) and FAST or IDLE
    if step ~= T_step then
        T_step = step
        conky_set_update_interval(step)
    end
end
