-- Zooming Mandelbrot set visualizer for cliamp.
-- Cycles through 4 zoom targets; fast zoom-out transition when interior goes solid.
--
-- Renders entirely in Unicode braille (U+2800–U+28FF).
-- Each cell's escape-time iteration count maps to a fill level (0–8 dots):
-- empty far exterior → sparse dots → dense dots near boundary → full ⣿ interior.
--
-- Performance stack:
--   1. Cardioid/period-2 bulb pre-check — skips iteration for provably in-set points
--   2. Direct column coordinates        — multiply per cell, no float drift at deep zoom
--   3. Two-phase Brent cycle detection  — interior exits early, exterior exits fast
--   4. Precomputed braille strings      — zero hot-path allocation (30×256 at init)
--   5. Reused row buffer               — no per-row table allocation; less GC pressure
--   6. Geometry cache                  — iter/period grid reused across frames; only
--                                        recomputed when zoom drifts >1.5% or every
--                                        MAX_CACHE_FRAMES frames. Color (coffset) is
--                                        reapplied every frame from the cached grid,
--                                        so music reactivity is never stale.

local p = plugin.register({ name = "Mandelbrot", type = "visualizer" })

-- Cache globals: local lookups skip the global table chain in Lua 5.1's VM.
local m_min   = math.min
local m_max   = math.max
local m_floor = math.floor

-- ── Zoom targets — cycles to next when screen goes solid ─────────────────────
local TARGETS = {
    { x = -0.7436438870371587, y =  0.1318259042053119 },  -- Sea Horse Valley
    { x = -0.7269054119,       y =  0.1889141542        },  -- Elephant Valley
    { x = -0.7454294967,       y =  0.1130543653        },  -- Seahorse spiral arm
    { x = -1.769383179,        y = -0.004236848          },  -- Antenna mini-brot
}

-- ── Tuning ───────────────────────────────────────────────────────────────────
local MIN_ZOOM        = 1.0
local MAX_ZOOM        = 1e6
local ZOOM_SPEED      = 0.12
local RESET_SPEED     = 3.0
local ROTATION_SPEED  = 0.004
local BASE_ITER       = 80
local MAX_ITER_CAP    = 128
local BASS_COLOR_KICK = 15
local BASS_FLASH_THR  = 0.55
local COLOR_FLOW      = 2.0
local ASPECT          = 2.0
local SILENCE_THRESH  = 0.02
local IDLE_AFTER      = 20
local SOLID_TRIGGER   = 0.99
-- Geometry cache: recompute Mandelbrot grid only when zoom drifts by this
-- fraction, or when MAX_CACHE_FRAMES is reached. Color is re-applied every
-- frame so music reactivity is instant regardless of cache state.
local GEOM_THRESHOLD   = 0.015   -- 1.5% zoom change triggers recompute
local MAX_CACHE_FRAMES = 8       -- force recompute at least every N frames
-- ─────────────────────────────────────────────────────────────────────────────

local ESC   = string.char(27)
local RESET = ESC .. "[0m"

local PALETTE = {
    196, 202, 208, 214, 220, 226,
    190, 154, 118,  82,  46,
     47,  48,  49,  50,  51,
     45,  39,  33,  27,  21,
     57,  93, 129, 165, 201,
    200, 199, 198, 197,
}
local PAL = #PALETTE  -- 30

-- ── Braille halftone tables ──────────────────────────────────────────────────
-- Nine Unicode braille masks representing 0–8 lit dots, chosen so dots spread
-- evenly across the 2×4 character grid at each density level:
--
--   2×4 dot grid layout (Unicode braille bit positions):
--     dot1=1   dot4=8
--     dot2=2   dot5=16
--     dot3=4   dot6=32
--     dot7=64  dot8=128
--
--   level 0: ⠀ mask=0    (empty)
--   level 1: ⠁ mask=1    (dot1 — top-left)
--   level 2: ⠉ mask=9    (dots 1,4 — top row)
--   level 3: ⡉ mask=73   (dots 1,4,7 — top row + bottom-left)
--   level 4: ⣉ mask=201  (dots 1,4,7,8 — four corners)
--   level 5: ⣋ mask=203  (corners + dot2)
--   level 6: ⣛ mask=219  (corners + dot2 + dot5 — corners + middle row)
--   level 7: ⣻ mask=251  (all except dot3)
--   level 8: ⣿ mask=255  (all 8 dots — full)
local FILL_MASKS = {0, 1, 9, 73, 201, 203, 219, 251, 255}

-- BRAILE[i][mask]   = dim    colour + braille char + reset  (palette entry i, mask 0..255)
-- BRAILE_B[i][mask] = bright colour + braille char + reset
local BRAILE   = {}
local BRAILE_B = {}
for i = 1, PAL do
    local dc = ESC .. "[2;38;5;" .. PALETTE[i] .. "m"
    local bc = ESC .. "[38;5;"   .. PALETTE[i] .. "m"
    local td = {}; local tb = {}
    for mask = 0, 255 do
        local br = string.char(0xE2, 0xA0 + math.floor(mask / 64), 0x80 + mask % 64)
        td[mask] = dc .. br .. RESET
        tb[mask] = bc .. br .. RESET
    end
    BRAILE[i]   = td
    BRAILE_B[i] = tb
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function p:init()
    self.zoom          = MIN_ZOOM
    self.zoom_dir      = 1
    self.zoom_log      = 0.0
    self.cos_t         = 1.0
    self.sin_t         = 0.0
    self.color_phase   = 0.0
    self.last_clock    = os.clock()
    self.silent_frames = 0
    self.target_idx    = 1
    self.center_x      = TARGETS[1].x
    self.center_y      = TARGETS[1].y
    self.resetting     = false
    self.row_buffer    = {}   -- reused every frame to avoid per-row allocation
    -- Geometry cache: flat arrays indexed (r-1)*cols + c
    self.iter_grid     = {}   -- raw iteration counts per cell
    self.period_grid   = {}   -- Brent period estimates per cell
    self.grid_zoom     = 0    -- zoom at last recompute (0 = invalid/never)
    self.grid_rows     = 0
    self.grid_cols     = 0
    self.grid_max_iter = 0
    self.cache_age     = MAX_CACHE_FRAMES  -- force recompute on first frame
end

function p:render(bands, frame, rows, cols)
    if cols < 20 or rows < 5 then return "Expand Window" end
    bands = bands or {}

    local now = os.clock()
    local dt  = now - (self.last_clock or now)
    self.last_clock = now
    if dt < 0 then dt = 0 elseif dt > 0.3 then dt = 0.3 end

    local any_sound = false
    for i = 1, #bands do
        if (bands[i] or 0) > SILENCE_THRESH then any_sound = true; break end
    end
    if any_sound then self.silent_frames = 0
    else self.silent_frames = (self.silent_frames or 0) + 1 end
    local idle = (self.silent_frames or 0) >= IDLE_AFTER

    if not idle then
        if self.resetting then
            local factor = 1.0 - RESET_SPEED * dt
            if factor < 0.1 then factor = 0.1 end
            self.zoom     = (self.zoom or 1) * factor
            self.zoom_log = m_max(0, (self.zoom_log or 0) - RESET_SPEED * dt)
            if self.zoom <= MIN_ZOOM then
                self.zoom = MIN_ZOOM; self.zoom_log = 0
                self.resetting = false; self.zoom_dir = 1
                self.target_idx = (self.target_idx % #TARGETS) + 1
                local t = TARGETS[self.target_idx]
                self.center_x = t.x; self.center_y = t.y
            end
        else
            local zd  = self.zoom_dir or 1
            local dzl = ZOOM_SPEED * dt * zd
            self.zoom     = (self.zoom or MIN_ZOOM) * (1.0 + dzl)
            self.zoom_log = m_max(0, (self.zoom_log or 0) + dzl)
            if self.zoom >= MAX_ZOOM then
                self.zoom = MAX_ZOOM; self.zoom_dir = -1
            elseif self.zoom <= MIN_ZOOM then
                self.zoom = MIN_ZOOM; self.zoom_dir = 1; self.zoom_log = 0
            end
        end

        local delta = ROTATION_SPEED * dt
        local c0, s0 = self.cos_t or 1.0, self.sin_t or 0.0
        local nc, ns = c0 - s0*delta, s0 + c0*delta
        local inv = 1.5 - 0.5*(nc*nc + ns*ns)
        self.cos_t = nc * inv; self.sin_t = ns * inv
        self.color_phase = (self.color_phase or 0) + COLOR_FLOW * dt
    end

    -- ── Per-frame constants ──────────────────────────────────────────────────
    local dyn_max_iter = m_min(MAX_ITER_CAP,
                             BASE_ITER + m_floor((self.zoom_log or 0) * 20))
    local t95 = m_floor(dyn_max_iter * 0.95)
    local t85 = m_floor(dyn_max_iter * 0.85)
    local t65 = m_floor(dyn_max_iter * 0.65)
    local t40 = m_floor(dyn_max_iter * 0.40)
    local t20 = m_floor(dyn_max_iter * 0.20)
    local t10 = m_floor(dyn_max_iter * 0.10)
    local t04 = m_floor(dyn_max_iter * 0.04)

    local bass    = m_max(bands[1] or 0, bands[2] or 0)
    local coffset = (m_floor(self.color_phase or 0)
                     + m_floor(bass * BASS_COLOR_KICK)) % PAL
    local cidx  = coffset + 1
    local int_brl = (bass > BASS_FLASH_THR) and BRAILE_B or BRAILE

    local zoom  = self.zoom or MIN_ZOOM
    local cos_t = self.cos_t or 1.0
    local sin_t = self.sin_t or 0.0
    local cx    = self.center_x or TARGETS[1].x
    local cy    = self.center_y or TARGETS[1].y

    -- ── Geometry cache decision ───────────────────────────────────────────────
    -- Recompute the iter/period grid only when the view has changed enough to
    -- matter visually. Color (coffset) is derived from music and always fresh.
    local cache_age  = (self.cache_age or MAX_CACHE_FRAMES) + 1
    local grid_zoom  = self.grid_zoom or 0
    local zoom_ratio = (grid_zoom > 0) and (zoom / grid_zoom) or 0
    local needs_recompute = (
        self.grid_rows     ~= rows          or
        self.grid_cols     ~= cols          or
        self.grid_max_iter ~= dyn_max_iter  or
        cache_age          >= MAX_CACHE_FRAMES or
        zoom_ratio         <  (1 - GEOM_THRESHOLD) or
        zoom_ratio         >  (1 + GEOM_THRESHOLD)
    )
    if needs_recompute then
        self.grid_zoom     = zoom
        self.grid_rows     = rows
        self.grid_cols     = cols
        self.grid_max_iter = dyn_max_iter
        self.cache_age     = 0
    else
        self.cache_age     = cache_age
    end

    -- ── Coordinate setup ─────────────────────────────────────────────────────
    local scale     = 4.0 / (zoom * cols)
    local d_pcr     = scale * cos_t
    local d_pci     = scale * sin_t
    local scale_asp = scale * ASPECT
    local mid_c     = (cols + 1) * 0.5
    local mid_r     = (rows + 1) * 0.5
    local pcr_base  = cx + (0.0 - mid_c) * d_pcr
    local pci_base  = cy + (0.0 - mid_c) * d_pci

    local brl_b = BRAILE_B
    local fm    = FILL_MASKS
    local pal   = PAL

    -- Per-frame color lookup: iter → precomputed braille string for current coffset.
    -- Rebuilt every frame (cheap: ~128 iterations) so music color is always live
    -- even when geometry is served from cache.
    local brl_for_iter   = {}
    local brl_for_iter_d = {}
    for i = 0, dyn_max_iter - 1 do
        local fill
        if     i > t95 then fill = 7
        elseif i > t85 then fill = 6
        elseif i > t65 then fill = 5
        elseif i > t40 then fill = 4
        elseif i > t20 then fill = 3
        elseif i > t10 then fill = 2
        elseif i > t04 then fill = 1
        else   fill = 0 end
        local ci = (i + coffset) % pal + 1
        local m  = fm[fill + 1]
        brl_for_iter[i] = (m == 0) and " " or brl_b[ci][m]
        local md = fm[m_min(fill + 1, 8) + 1]
        brl_for_iter_d[i] = (md == 0) and " " or brl_b[ci][md]
    end

    local in_set_count = 0
    local out = {}
    if not self.row_buffer  then self.row_buffer  = {} end
    if not self.iter_grid   then self.iter_grid   = {} end
    if not self.period_grid then self.period_grid = {} end
    local row_buffer  = self.row_buffer
    local iter_grid   = self.iter_grid
    local period_grid = self.period_grid

    for r = 1, rows do
        local rdither = r % 2
        local dy      = (r - mid_r) * scale_asp
        local r_pcr   = pcr_base - dy * sin_t
        local r_pci   = pci_base + dy * cos_t
        local base_idx = (r - 1) * cols  -- flat-array row offset

        for c = 1, cols do
            local iter, period
            local idx = base_idx + c

            if needs_recompute then
                -- ── Full Mandelbrot computation ──────────────────────────────
                local pcr = r_pcr + c * d_pcr
                local pci = r_pci + c * d_pci

                local pci2 = pci * pci
                local q_x  = pcr - 0.25
                local q    = q_x * q_x + pci2
                iter   = dyn_max_iter
                period = 0

                if not (q * (q + q_x) < 0.25 * pci2) then
                    local p1 = pcr + 1.0
                    if not (p1 * p1 + pci2 < 0.0625) then

                        local zr, zi   = 0.0, 0.0
                        local zr2, zi2 = 0.0, 0.0
                        iter = 0
                        while iter < 20 and zr2 + zi2 < 4.0 do
                            zi   = 2.0 * zr * zi + pci
                            zr   = zr2 - zi2 + pcr
                            zr2  = zr * zr
                            zi2  = zi * zi
                            iter = iter + 1
                        end

                        if iter == 20 and zr2 + zi2 < 4.0 then
                            local bz_r, bz_i = zr, zi
                            local bmax, blen = 2, 0
                            while iter < dyn_max_iter and zr2 + zi2 < 4.0 do
                                zi   = 2.0 * zr * zi + pci
                                zr   = zr2 - zi2 + pcr
                                zr2  = zr * zr
                                zi2  = zi * zi
                                iter = iter + 1
                                blen = blen + 1
                                if blen == bmax then
                                    bz_r = zr; bz_i = zi; bmax = bmax + bmax; blen = 0
                                else
                                    local dr = zr - bz_r
                                    local di = zi - bz_i
                                    if dr*dr + di*di < 1e-12 then
                                        period = bmax
                                        iter = dyn_max_iter; break
                                    end
                                end
                            end
                        end

                    end
                end

                -- Store in cache
                iter_grid[idx]   = iter
                period_grid[idx] = period
            else
                -- ── Read from geometry cache ─────────────────────────────────
                iter   = iter_grid[idx]
                period = period_grid[idx]
            end

            -- ── Map iter → output (always, every frame) ──────────────────────
            if iter >= dyn_max_iter then
                local int_cidx = (period > 0) and ((coffset + period) % pal + 1) or cidx
                row_buffer[c] = int_brl[int_cidx][255]
                in_set_count  = in_set_count + 1
            else
                if (rdither + c) % 2 == 0 then
                    row_buffer[c] = brl_for_iter[iter]
                else
                    row_buffer[c] = brl_for_iter_d[iter]
                end
            end
        end
        out[r] = table.concat(row_buffer, "", 1, cols)
    end

    if not self.resetting and in_set_count >= rows * cols * SOLID_TRIGGER then
        self.resetting = true
    end

    return table.concat(out, "\n")
end
