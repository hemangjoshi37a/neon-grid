-- Neon-Grid day display: uptime tiles drawn under the date
require 'cairo'
pcall(require, 'cairo_xlib')

local CYAN    = {0.00, 0.94, 1.00}
local MAGENTA = {1.00, 0.17, 0.84}
local GREEN   = {0.16, 1.00, 0.64}
local TEXT    = {0.84, 0.96, 1.00}
local DIM     = {0.48, 0.53, 0.66}
local BG      = {0.031, 0.039, 0.078}

local function col(cr, c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1) end

local function text(cr, s, x, y, face, size, bold, c, a, align)
    cairo_select_font_face(cr, face, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local e = cairo_text_extents_t:create()
    cairo_text_extents(cr, s, e)
    if align == 'c' then x = x - e.x_advance / 2 end
    cairo_new_path(cr)
    cairo_move_to(cr, x, y)
    col(cr, c, a)
    cairo_show_text(cr, s)
    cairo_new_path(cr)
    return e.x_advance
end

local function rrect(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function tile(cr, x, y, w, h, value, label, c)
    rrect(cr, x, y, w, h, 8)
    col(cr, BG, 0.78); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 5); col(cr, c, 0.10); cairo_stroke_preserve(cr)
    cairo_set_line_width(cr, 1.2); col(cr, c, 0.9); cairo_stroke(cr)
    text(cr, value, x + w / 2, y + h / 2 + 5, 'Orbitron', 23, true, TEXT, 1, 'c')
    text(cr, label, x + w / 2, y + h - 8, 'Orbitron', 7.5, true, c, 1, 'c')
end

local function uptime_seconds()
    local f = io.open('/proc/uptime', 'r')
    if not f then return 0 end
    local s = tonumber((f:read('*l') or ''):match('^(%S+)')) or 0
    f:close()
    return s
end

function conky_day()
    if conky_window == nil then return end
    local W, H = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
        conky_window.visual, W, H)
    local cr = cairo_create(cs)

    -- backing panel, so the text stays readable on any wallpaper
    rrect(cr, 0.5, 0.5, W - 1, H - 1, 12)
    col(cr, BG, 0.80); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1); col(cr, CYAN, 0.45); cairo_stroke(cr)
    cairo_set_line_width(cr, 3); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); col(cr, MAGENTA, 1)
    cairo_new_path(cr); cairo_move_to(cr, 0.5, 18); cairo_line_to(cr, 0.5, H - 18); cairo_stroke(cr)

    local up = uptime_seconds()
    local d, h, m = math.floor(up / 86400), math.floor(up % 86400 / 3600),
        math.floor(up % 3600 / 60)
    local tw, th, gap = 74, 62, 10
    local x, y = 740, H - th - 22

    tile(cr, x, y, tw, th, string.format('%02d', d), 'DAYS', CYAN)
    tile(cr, x + tw + gap, y, tw, th, string.format('%02d', h), 'HOURS', CYAN)
    tile(cr, x + 2 * (tw + gap), y, tw, th, string.format('%02d', m), 'MINUTES', MAGENTA)

    local tx = x + 3 * (tw + gap) + 12
    -- status dot + label
    cairo_new_path(cr); cairo_arc(cr, tx + 5, y + 14, 8, 0, 2 * math.pi)
    col(cr, GREEN, 0.18); cairo_fill(cr)
    cairo_new_path(cr); cairo_arc(cr, tx + 5, y + 14, 4, 0, 2 * math.pi)
    col(cr, GREEN, 1); cairo_fill(cr)
    text(cr, 'SYSTEM ONLINE', tx + 20, y + 18, 'Orbitron', 10, true, GREEN, 1, 'l')
    text(cr, 'up since ' .. os.date('%a %d %b, %H:%M', os.time() - math.floor(up)), tx, y + 38,
        'JetBrains Mono', 10.5, false, TEXT, 1, 'l')
    -- progress through the current day of uptime (24 hour ticks)
    local bw, n = 208, 24
    local seg = bw / n
    local lit = math.floor(up % 86400 / 3600)
    for i = 0, n - 1 do
        rrect(cr, tx + i * seg, y + 48, seg - 2.5, 6, 1.5)
        if i < lit then col(cr, CYAN, 1) elseif i == lit then col(cr, MAGENTA, 1)
        else col(cr, DIM, 0.3) end
        cairo_fill(cr)
    end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
