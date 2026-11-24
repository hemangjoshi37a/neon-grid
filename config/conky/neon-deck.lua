-- Neon-Grid telemetry deck: draws the state file written by neon-deck.py
require 'cairo'
pcall(require, 'cairo_xlib')

local PATH = (os.getenv('XDG_RUNTIME_DIR') or '/run/user/1000') .. '/neon-deck.txt'
local HISTORY = 150

local CYAN    = {0.00, 0.94, 1.00}
local MAGENTA = {1.00, 0.17, 0.84}
local GREEN   = {0.16, 1.00, 0.64}
local YELLOW  = {0.98, 0.97, 0.44}
local RED     = {1.00, 0.23, 0.42}
local ORANGE  = {1.00, 0.55, 0.26}
local TEXT    = {0.84, 0.96, 1.00}
local DIM     = {0.48, 0.53, 0.66}
local BG      = {0.031, 0.039, 0.078}

local MONO, DISPLAY = 'JetBrains Mono', 'Orbitron'

local function col(cr, c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1) end

-- align: 'l', 'r' or 'c' relative to x
local function text(cr, s, x, y, face, size, bold, c, a, align)
    cairo_select_font_face(cr, face, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    if align == 'r' or align == 'c' then
        local e = cairo_text_extents_t:create()
        cairo_text_extents(cr, s, e)
        local adv = e.width + e.x_bearing
        x = x - (align == 'r' and adv or adv / 2)
    end
    cairo_new_path(cr)
    cairo_move_to(cr, x, y)
    col(cr, c, a)
    cairo_show_text(cr, s)
    cairo_new_path(cr)
end

local function rrect(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function card(cr, x, y, w, h, title, c, right)
    rrect(cr, x, y, w, h, 10)
    col(cr, BG, 0.80)
    cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1)
    col(cr, c, 0.45)
    cairo_stroke(cr)
    -- accent bar + title
    cairo_set_line_width(cr, 3)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    col(cr, c, 1)
    cairo_move_to(cr, x + 16, y + 17); cairo_line_to(cr, x + 16, y + 29); cairo_stroke(cr)
    text(cr, title, x + 26, y + 28, DISPLAY, 11, true, c, 1, 'l')
    if right then text(cr, right, x + w - 16, y + 28, DISPLAY, 11, true, TEXT, 1, 'r') end
    cairo_set_line_width(cr, 1)
    col(cr, c, 0.18)
    cairo_move_to(cr, x + 16, y + 40); cairo_line_to(cr, x + w - 16, y + 40); cairo_stroke(cr)
end

local function badge(cr, xr, y, label, value, c)
    cairo_select_font_face(cr, DISPLAY, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 10)
    local e = cairo_text_extents_t:create()
    cairo_text_extents(cr, value, e)
    local vw = e.width + e.x_bearing
    cairo_text_extents(cr, label, e)
    local lw = e.width + e.x_bearing
    local w = lw + vw + 34
    local x = xr - w
    rrect(cr, x, y, w, 24, 12)
    col(cr, c, 0.14); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, c, 0.7); cairo_stroke(cr)
    text(cr, label, x + 12, y + 16, DISPLAY, 10, false, DIM, 1, 'l')
    text(cr, value, x + 12 + lw + 10, y + 16, DISPLAY, 10, true, c, 1, 'l')
    return x - 10
end

-- series: array of numbers (oldest first); newest sample sits at the right edge
local function graph(cr, x, y, w, h, series, lo, hi, c, fill)
    local n = #series
    if n < 2 then return end
    local step = w / (HISTORY - 1)
    local function px(i) return x + w - (n - i) * step end
    local function py(v)
        local t = (v - lo) / (hi - lo)
        t = math.max(0, math.min(1, t))
        return y + h - t * h
    end
    if fill then
        cairo_new_path(cr)
        cairo_move_to(cr, px(1), y + h)
        for i = 1, n do cairo_line_to(cr, px(i), py(series[i])) end
        cairo_line_to(cr, px(n), y + h)
        cairo_close_path(cr)
        local g = cairo_pattern_create_linear(0, y, 0, y + h)
        cairo_pattern_add_color_stop_rgba(g, 0, c[1], c[2], c[3], 0.30)
        cairo_pattern_add_color_stop_rgba(g, 1, c[1], c[2], c[3], 0.0)
        cairo_set_source(cr, g)
        cairo_fill(cr)
        cairo_pattern_destroy(g)
    end
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for pass = 1, 2 do
        cairo_new_path(cr)
        cairo_move_to(cr, px(1), py(series[1]))
        for i = 2, n do cairo_line_to(cr, px(i), py(series[i])) end
        cairo_set_line_width(cr, pass == 1 and 5 or 1.8)
        col(cr, c, pass == 1 and 0.16 or 1)
        cairo_stroke(cr)
    end
    -- head dot
    cairo_new_path(cr)
    cairo_arc(cr, px(n), py(series[n]), 3, 0, 2 * math.pi)
    col(cr, c, 1); cairo_fill(cr)
end

local function grid(cr, x, y, w, h, lo, hi, ticks, fmt)
    cairo_set_line_width(cr, 1)
    for _, v in ipairs(ticks) do
        local gy = y + h - (v - lo) / (hi - lo) * h
        col(cr, DIM, 0.18)
        cairo_new_path(cr)
        cairo_move_to(cr, x, gy); cairo_line_to(cr, x + w, gy); cairo_stroke(cr)
        text(cr, string.format(fmt, v), x - 8, gy + 4, MONO, 9, false, DIM, 1, 'r')
    end
end

local function bar(cr, x, y, w, h, frac, c)
    frac = math.max(0, math.min(1, frac))
    rrect(cr, x, y, w, h, h / 2); col(cr, c, 0.13); cairo_fill(cr)
    if frac > 0.01 then
        rrect(cr, x, y, math.max(h, w * frac), h, h / 2); col(cr, c, 1); cairo_fill(cr)
    end
end

local function list(cr, x, y, w, rows, items, fmt, c, rowh)
    local maxv = 0.0001
    for i = 2, #items, 2 do maxv = math.max(maxv, tonumber(items[i]) or 0) end
    local r = 0
    for i = 1, #items - 1, 2 do
        if r >= rows then break end
        local name, v = items[i], tonumber(items[i + 1]) or 0
        local yy = y + r * rowh
        text(cr, string.format('%d', r + 1), x, yy + 12, DISPLAY, 8, true, c, 0.7, 'l')
        text(cr, name, x + 18, yy + 12, MONO, 11, false, TEXT, 1, 'l')
        text(cr, fmt(v), x + w, yy + 12, MONO, 11, true, c, 1, 'r')
        bar(cr, x + 18, yy + 19, w - 18, 4, v / maxv, c)
        r = r + 1
    end
    if r == 0 then text(cr, 'no data', x + 18, y + 12, MONO, 10, false, DIM, 1, 'l') end
end

local function load()
    local f = io.open(PATH, 'r')
    if not f then return nil end
    local d = {}
    for line in f:lines() do
        local parts = {}
        for p in (line .. '\t'):gmatch('(.-)\t') do parts[#parts + 1] = p end
        local key = table.remove(parts, 1)
        if key then d[key] = parts end
    end
    f:close()
    return d
end

local function nums(t)
    local o = {}
    for i, v in ipairs(t or {}) do o[i] = tonumber(v) or 0 end
    return o
end

local function fmt_mem(v)
    if v >= 1024 then return string.format('%.2f GiB', v / 1024) end
    return string.format('%.0f MiB', v)
end

local function temp_col(t)
    if t >= 85 then return RED elseif t >= 70 then return YELLOW end
    return nil
end

function conky_deck()
    if conky_window == nil then return end
    local W, H = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
        conky_window.visual, W, H)
    local cr = cairo_create(cs)
    W = W - 1

    local d = load()
    local fresh = d and d.stamp and (os.time() - (tonumber(d.stamp[1]) or 0) < 15)

    -- header
    -- header strip, so the title stays readable on any wallpaper
    rrect(cr, 0.5, 0.5, W - 0.5, 35, 10)
    col(cr, BG, 0.82); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, CYAN, 0.45); cairo_stroke(cr)
    text(cr, 'VICTUS', 16, 25, DISPLAY, 17, true, CYAN, 1, 'l')
    text(cr, '//  TELEMETRY DECK', 116, 25, DISPLAY, 11, false, MAGENTA, 1, 'l')
    if not fresh then
        badge(cr, W - 8, 6, 'COLLECTOR', 'OFFLINE', RED)
        cairo_destroy(cr); cairo_surface_destroy(cs)
        return
    end

    local cpu, mem, gpu = nums(d.cpu), nums(d.mem), nums(d.gpu)
    local temp, fan = nums(d.temp), nums(d.fan)
    local mode = (d.fan and d.fan[5]) or 'N/A'
    local kbd = (d.kbd and d.kbd[1]) or 'N/A'

    local bx = badge(cr, W - 8, 6, 'FAN MODE', mode, mode == 'MAX' and MAGENTA or CYAN)
    badge(cr, bx, 6, 'KEYBOARD', (kbd:match('^%S+') or kbd), GREEN)

    local gap = 12
    local cw = (W - 2 * gap) / 3
    local y1, h1 = 44, 286
    local y2 = y1 + h1 + gap
    local h2 = 258
    local y3 = y2 + h2 + gap
    local h3 = H - y3 - 1

    -- top CPU apps
    local x = 0.5
    card(cr, x, y1, cw, h1, 'TOP CPU', CYAN, string.format('%.0f%%', cpu[1] or 0))
    graph(cr, x + 16, y1 + 46, cw - 32, 30, nums(d.h_cpu), 0, 100, CYAN, true)
    list(cr, x + 16, y1 + 88, cw - 32, 6, d.topcpu or {},
        function(v) return string.format('%.1f%%', v) end, CYAN, 32)

    -- top RAM apps
    x = x + cw + gap
    card(cr, x, y1, cw, h1, 'TOP RAM', MAGENTA,
        string.format('%.1f / %.1f GiB', mem[2] or 0, mem[3] or 0))
    graph(cr, x + 16, y1 + 46, cw - 32, 30, nums(d.h_mem), 0, 100, MAGENTA, true)
    list(cr, x + 16, y1 + 88, cw - 32, 6, d.topmem or {}, fmt_mem, MAGENTA, 32)

    -- GPU
    x = x + cw + gap
    card(cr, x, y1, cw, h1, 'GPU', GREEN, string.format('%.0f%%', gpu[1] or 0))
    graph(cr, x + 16, y1 + 46, cw - 32, 62, nums(d.h_gpu), 0, 100, GREEN, true)
    local vfrac = (gpu[2] or 0) / math.max(1, gpu[3] or 1)
    text(cr, 'VRAM', x + 16, y1 + 132, DISPLAY, 9, true, YELLOW, 1, 'l')
    text(cr, string.format('%.0f / %.0f MiB', gpu[2] or 0, gpu[3] or 0),
        x + cw - 16, y1 + 132, MONO, 11, true, TEXT, 1, 'r')
    bar(cr, x + 16, y1 + 140, cw - 32, 6, vfrac, YELLOW)
    graph(cr, x + 16, y1 + 152, cw - 32, 22, nums(d.h_vram), 0, 100, YELLOW, true)
    text(cr, 'VRAM BY APP', x + 16, y1 + 196, DISPLAY, 8, true, DIM, 1, 'l')
    list(cr, x + 16, y1 + 206, cw - 32, 2, d.topgpu or {}, fmt_mem, YELLOW, 32)

    -- temperature history
    local w2 = (W - gap) / 2
    local gx, gw = 52, w2 - 52 - 18
    x = 0.5
    card(cr, x, y2, w2, h2, 'TEMPERATURE', CYAN, nil)
    local ct, gt = temp[1] or 0, temp[2] or 0
    text(cr, string.format('GPU %.0f°C', gt), x + w2 - 16, y2 + 28, DISPLAY, 11, true,
        temp_col(gt) or GREEN, 1, 'r')
    text(cr, string.format('CPU %.0f°C', ct), x + w2 - 120, y2 + 28, DISPLAY, 11, true,
        temp_col(ct) or CYAN, 1, 'r')
    local gy, gh = y2 + 54, h2 - 54 - 26
    grid(cr, x + gx, gy, gw, gh, 30, 100, {40, 60, 80, 100}, '%d°')
    graph(cr, x + gx, gy, gw, gh, nums(d.h_gtemp), 30, 100, GREEN, false)
    graph(cr, x + gx, gy, gw, gh, nums(d.h_ctemp), 30, 100, CYAN, true)
    text(cr, '5 min', x + gx, y2 + h2 - 9, MONO, 9, false, DIM, 1, 'l')
    text(cr, 'now', x + gx + gw, y2 + h2 - 9, MONO, 9, false, DIM, 1, 'r')

    -- fan history
    x = x + w2 + gap
    card(cr, x, y2, w2, h2, 'FANS', MAGENTA, nil)
    text(cr, string.format('FAN2 %.0f', fan[2] or 0), x + w2 - 16, y2 + 28, DISPLAY, 11, true,
        YELLOW, 1, 'r')
    text(cr, string.format('FAN1 %.0f', fan[1] or 0), x + w2 - 130, y2 + 28, DISPLAY, 11, true,
        MAGENTA, 1, 'r')
    local fmaxv = math.max(fan[3] or 6000, fan[4] or 6000, 1000)
    local ftop = math.ceil(fmaxv / 1000) * 1000
    local ticks = {}
    for v = 2000, ftop, 2000 do ticks[#ticks + 1] = v end
    grid(cr, x + gx, gy, gw, gh, 0, ftop, ticks, '%d')
    graph(cr, x + gx, gy, gw, gh, nums(d.h_fan2), 0, ftop, YELLOW, false)
    graph(cr, x + gx, gy, gw, gh, nums(d.h_fan1), 0, ftop, MAGENTA, true)
    text(cr, 'rpm', x + gx, y2 + h2 - 9, MONO, 9, false, DIM, 1, 'l')
    text(cr, 'now', x + gx + gw, y2 + h2 - 9, MONO, 9, false, DIM, 1, 'r')

    -- Claude plan usage
    card(cr, 0.5, y3, W - 0.5, h3, 'CLAUDE USAGE', ORANGE, nil)
    local c = d.claude
    if not c then
        text(cr, 'waiting for a Claude Code session to report usage', 26, y3 + 84, MONO, 11,
            false, DIM, 1, 'l')
    else
        local now = os.time()
        local colw = (W - 32 - 2 * 36) / 3
        text(cr, c[5] or '?', W - 16, y3 + 28, DISPLAY, 11, true, TEXT, 1, 'r')

        local function limit(x, label, pct, reset, datefmt)
            pct, reset = tonumber(pct) or -1, tonumber(reset) or 0
            local expired = reset > 0 and reset <= now
            if expired then pct = 0 end
            local cc = (pct >= 90 and RED) or (pct >= 70 and YELLOW) or CYAN
            text(cr, label, x, y3 + 62, DISPLAY, 9, true, DIM, 1, 'l')
            text(cr, pct < 0 and '--' or string.format('%.0f%%', pct), x, y3 + 98, DISPLAY, 26,
                true, cc, 1, 'l')
            text(cr, 'used', x + 92, y3 + 98, MONO, 10, false, DIM, 1, 'l')
            local left
            if expired then left = 'window has reset'
            elseif reset == 0 then left = 'no reset time'
            else
                local s = reset - now
                local dd, hh, mm = math.floor(s / 86400), math.floor(s % 86400 / 3600),
                    math.floor(s % 3600 / 60)
                left = dd > 0 and string.format('resets in %dd %dh', dd, hh)
                    or string.format('resets in %dh %02dm', hh, mm)
            end
            text(cr, left, x + colw, y3 + 84, MONO, 11, true, TEXT, 1, 'r')
            if reset > now then
                text(cr, os.date(datefmt, reset), x + colw, y3 + 100, MONO, 10, false, DIM, 1, 'r')
            end
            bar(cr, x, y3 + 112, colw, 7, math.max(0, pct) / 100, cc)
        end

        limit(16.5, '5-HOUR SESSION', c[1], c[2], 'at %H:%M')
        limit(16.5 + colw + 36, 'WEEKLY  /  ALL MODELS', c[3], c[4], '%a %d %b, %H:%M')

        local x3 = 16.5 + 2 * (colw + 36)
        local ctx = tonumber(c[6]) or 0
        text(cr, 'THIS SESSION', x3, y3 + 62, DISPLAY, 9, true, DIM, 1, 'l')
        text(cr, 'context', x3, y3 + 84, MONO, 11, false, TEXT, 1, 'l')
        text(cr, string.format('%.0f%%', ctx), x3 + colw, y3 + 84, MONO, 11, true, MAGENTA, 1, 'r')
        text(cr, 'cost (API rates)', x3, y3 + 100, MONO, 11, false, TEXT, 1, 'l')
        text(cr, string.format('$%.2f', tonumber(c[7]) or 0), x3 + colw, y3 + 100, MONO, 11, true,
            GREEN, 1, 'r')
        bar(cr, x3, y3 + 112, colw, 7, ctx / 100, MAGENTA)
        local age = now - (tonumber(c[8]) or now)
        local ages = age < 90 and 'live' or (age < 5400 and string.format('updated %dm ago',
            math.floor(age / 60)) or string.format('updated %dh ago', math.floor(age / 3600)))
        text(cr, ages, W - 150, y3 + 28, MONO, 9, false, DIM, 1, 'r')
    end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
