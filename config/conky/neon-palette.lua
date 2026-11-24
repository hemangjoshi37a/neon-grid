-- Neon-Grid: lets neon-palette recolour the widgets while they run.
-- Usage: local refresh = dofile('.../neon-palette.lua')({CYAN = CYAN, ...}); refresh()
-- The tables are changed in place; names missing from the overlay go back to their defaults.
local FILE = os.getenv('HOME') .. '/.config/neon-grid/palette.lua'

return function(themed)
    local defaults = {}
    for name, c in pairs(themed) do defaults[name] = {c[1], c[2], c[3]} end
    return function()
        local chunk = loadfile(FILE)
        local ok, p = false, nil
        if chunk then ok, p = pcall(chunk) end
        if not ok or type(p) ~= 'table' then p = {} end
        for name, c in pairs(themed) do
            local src = p[name] or defaults[name]
            for i = 1, 3 do c[i] = tonumber(src[i]) or defaults[name][i] end
        end
    end
end
