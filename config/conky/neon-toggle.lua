-- Neon-Grid: the button that hides and shows the widgets on both screens.
require 'cairo'
pcall(require, 'cairo_xlib')
local HOME = os.getenv('HOME')
local FILE = HOME .. '/.cache/neon-grid/widgets-hidden'
local CYAN, TEXT, BG = {0, 0.94, 1}, {0.84, 0.96, 1}, {0.02, 0.03, 0.07}
local recolour = dofile(HOME .. '/.config/conky/neon-palette.lua')({CYAN = CYAN, TEXT = TEXT, BG = BG})
local hover, over, lid, T, step, press = 0, false, nil, 0, 0.04, 0

local function hidden()
    local f = io.open(FILE, 'r')
    if f then f:close() end
    return f ~= nil
end

function conky_toggle_mouse(e)
    if e.type == 'mouse_enter' or e.type == 'mouse_move' then over = true
    elseif e.type == 'mouse_leave' then over = false
    elseif e.type == 'button_down' and (e.button == 'left' or e.button == 1 or e.button == nil) then
        press = 1
        if hidden() then os.remove(FILE) else
            local f = io.open(FILE, 'w')
            if f then f:close() end
        end
        -- clicks go through to the desktop while the widgets are hidden
        os.execute('"' .. HOME .. '/.config/conky/neon-widgets" apply >/dev/null 2>&1 &')
        return true
    end
    return false
end

local n = 0
function conky_toggle()
    if conky_window == nil then return end
    T = T + step
    n = n + 1
    if n % 60 == 1 then recolour() end
    local shut = hidden() and 1 or 0
    lid = lid or shut
    local k = 1 - math.exp(-step * 13)
    hover = hover + ((over and 1 or 0) - hover) * k
    lid = lid + (shut - lid) * k
    press = press * math.exp(-step * 9)
    local W, H = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, W, H)
    local cr = cairo_create(cs)
    local x, y, r = W / 2, H / 2, 17.5 + 2.5 * hover - 2 * press
    local show = 0.55 + 0.45 * math.max(hover, 1 - lid)            -- quiet while the widgets are hidden
    cairo_new_path(cr); cairo_arc(cr, x, y, r, 0, 2 * math.pi)
    cairo_set_source_rgba(cr, BG[1], BG[2], BG[3], 0.60 * show); cairo_fill_preserve(cr)
    cairo_set_source_rgba(cr, CYAN[1], CYAN[2], CYAN[3], 0.10 * hover + 0.20 * press); cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1.2); cairo_set_source_rgba(cr, CYAN[1], CYAN[2], CYAN[3], (0.35 + 0.5 * hover) * show); cairo_stroke(cr)
    -- an eye; its lid closes when the widgets are hidden
    local w, up = 9.5, 6.5 * (1 - lid) - 4.5 * lid
    local c = over and TEXT or CYAN
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_width(cr, 1.8)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], 0.95 * show)
    cairo_new_path(cr); cairo_move_to(cr, x - w, y); cairo_curve_to(cr, x - w / 2, y + 6.5, x + w / 2, y + 6.5, x + w, y); cairo_stroke(cr)
    cairo_new_path(cr); cairo_move_to(cr, x - w, y); cairo_curve_to(cr, x - w / 2, y - up, x + w / 2, y - up, x + w, y); cairo_stroke(cr)
    if lid < 0.9 then
        cairo_new_path(cr); cairo_arc(cr, x, y, 3, 0, 2 * math.pi)
        cairo_set_source_rgba(cr, c[1], c[2], c[3], 0.95 * show * (1 - lid / 0.9)); cairo_fill(cr)
    end
    if lid > 0.1 then                                              -- lashes
        cairo_set_source_rgba(cr, c[1], c[2], c[3], 0.95 * show * lid)
        for i = -1, 1 do
            cairo_new_path(cr); cairo_move_to(cr, x + i * 4.6, y + 4.6 - 0.9 * math.abs(i)); cairo_line_to(cr, x + i * 6.2, y + 8 - 1.2 * math.abs(i)); cairo_stroke(cr)
        end
    end
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
    local busy = math.abs(hover - (over and 1 or 0)) > 0.004 or math.abs(lid - shut) > 0.004 or press > 0.01
    local want = busy and 1 / 120 or (over and 0.04 or 0.06)
    if want ~= step then step = want; conky_set_update_interval(step) end
end
