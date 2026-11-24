-- Neon-Grid HUD: cairo ring gauges + corner brackets
require 'cairo'
pcall(require, 'cairo_xlib')

local CYAN    = {0.00, 0.94, 1.00}
local MAGENTA = {1.00, 0.17, 0.84}
local GREEN   = {0.16, 1.00, 0.64}
local YELLOW  = {0.98, 0.97, 0.44}
local TEXT    = {0.84, 0.96, 1.00}
local DIM     = {0.48, 0.53, 0.66}

local function col(cr, c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a) end

local function centered(cr, text, cx, y, face, size, bold, c, a)
    cairo_select_font_face(cr, face, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local e = cairo_text_extents_t:create()
    cairo_text_extents(cr, text, e)
    cairo_move_to(cr, cx - (e.width / 2 + e.x_bearing), y)
    col(cr, c, a)
    cairo_show_text(cr, text)
end

local function ring(cr, cx, cy, r, w, pct, c, label, value)
    pct = math.max(0, math.min(100, pct or 0))
    local a0, a1 = math.rad(135), math.rad(405)
    local ae = a0 + (a1 - a0) * pct / 100
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)

    -- track
    cairo_set_line_width(cr, w)
    col(cr, c, 0.14)
    cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, a1)
    cairo_stroke(cr)

    -- outer tick marks
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    cairo_set_line_width(cr, 1)
    for i = 0, 27 do
        local a = a0 + (a1 - a0) * i / 27
        local lit = (a <= ae + 0.001)
        col(cr, lit and c or DIM, lit and 0.9 or 0.35)
        local r1, r2 = r + w / 2 + 4, r + w / 2 + ((i % 9 == 0) and 10 or 7)
        cairo_move_to(cr, cx + r1 * math.cos(a), cy + r1 * math.sin(a))
        cairo_line_to(cr, cx + r2 * math.cos(a), cy + r2 * math.sin(a))
        cairo_stroke(cr)
    end
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)

    if pct > 0.5 then
        -- glow
        for i = 4, 1, -1 do
            cairo_set_line_width(cr, w + i * 3.5)
            col(cr, c, 0.055)
            cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, ae)
            cairo_stroke(cr)
        end
        -- value arc
        cairo_set_line_width(cr, w)
        col(cr, c, 1)
        cairo_new_path(cr); cairo_arc(cr, cx, cy, r, a0, ae)
        cairo_stroke(cr)
        -- bright head
        cairo_set_line_width(cr, w * 0.45)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.9)
        cairo_new_path(cr); cairo_arc(cr, cx, cy, r, ae - 0.02, ae)
        cairo_stroke(cr)
    end

    -- inner thin ring
    cairo_set_line_width(cr, 1)
    col(cr, c, 0.25)
    cairo_new_path(cr); cairo_arc(cr, cx, cy, r - w / 2 - 6, 0, 2 * math.pi)
    cairo_stroke(cr)

    centered(cr, value, cx, cy + 7, 'Orbitron', 19, true, TEXT, 1)
    centered(cr, label, cx, cy + r - 6, 'Orbitron', 8.5, true, c, 1)
end

local function brackets(cr, w, h)
    local L, m = 22, 5
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE)
    for pass = 1, 2 do
        cairo_set_line_width(cr, pass == 1 and 6 or 2)
        col(cr, CYAN, pass == 1 and 0.12 or 0.95)
        local pts = {
            {m, m + L, m, m, m + L, m},
            {w - m - L, m, w - m, m, w - m, m + L},
            {w - m, h - m - L, w - m, h - m, w - m - L, h - m},
            {m + L, h - m, m, h - m, m, h - m - L},
        }
        for _, p in ipairs(pts) do
            cairo_move_to(cr, p[1], p[2])
            cairo_line_to(cr, p[3], p[4])
            cairo_line_to(cr, p[5], p[6])
            cairo_stroke(cr)
        end
    end
    -- magenta accent notches
    cairo_set_line_width(cr, 2)
    col(cr, MAGENTA, 0.9)
    cairo_move_to(cr, w / 2 - 28, m); cairo_line_to(cr, w / 2 + 28, m); cairo_stroke(cr)
    cairo_move_to(cr, w / 2 - 28, h - m); cairo_line_to(cr, w / 2 + 28, h - m); cairo_stroke(cr)
end

local function num(s) return tonumber((conky_parse(s) or ''):match('%-?%d+%.?%d*')) or 0 end

function conky_main()
    if conky_window == nil then return end
    local w, h = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
        conky_window.visual, w, h)
    local cr = cairo_create(cs)

    brackets(cr, w, h)

    local s = conky_parse('${execi 4 ~/.config/conky/neon-sensors.sh}') or ''
    local gpu, ctemp = s:match('(%d+)%s+(%d+)')
    gpu, ctemp = tonumber(gpu) or 0, tonumber(ctemp) or 0
    local cpu, mem = num('${cpu cpu0}'), num('${memperc}')

    local x1, x2 = w * 0.27, w * 0.73
    local y1, y2 = 182, 318
    ring(cr, x1, y1, 46, 7, cpu, CYAN, 'CPU', string.format('%d%%', cpu))
    ring(cr, x2, y1, 46, 7, mem, MAGENTA, 'RAM', string.format('%d%%', mem))
    ring(cr, x1, y2, 46, 7, gpu, GREEN, 'GPU', string.format('%d%%', gpu))
    ring(cr, x2, y2, 46, 7, ctemp, YELLOW, 'TEMP', string.format('%d°', ctemp))

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
