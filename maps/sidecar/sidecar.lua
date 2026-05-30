-- sidecar.lua — WC3 Orc Bot game-state observer  (v2 — comprehensive)
--
-- Paste this entire file into the World Editor Trigger Editor as a
-- Lua "Custom Script" action on a "Map Initialization" event.
--
-- Output file (macOS):
--   ~/Documents/Warcraft III/CustomMapData/wc3_orc_sidecar/sidecar.pld
--
-- Format: pipe-delimited single line, overwritten every INTERVAL seconds.
-- The same line is also pinned in _G.WC3BOT_STATE for memory-scan reads.
--
-- ── Header fields ──────────────────────────────────────────────────────────
--   T:<time>|G:<gold>|L:<lumber>|FU:<food_used>|FC:<food_cap>
--   |GH:<x>:<y>
--   |CAM:<tx>:<ty>:<tz>:<aoa_rad>:<fov_rad>:<dist>:<rot_rad>
--
-- ── Own units ──────────────────────────────────────────────────────────────
--   |U:<id>:<x>:<y>:<hp%>:<z>:<order>          regular unit  (order = integer order ID)
--   |H:<id>:<x>:<y>:<hp%>:<z>:<order>:<mana>:<maxmana>:<lvl>:<xp>:<sp>
--                                               hero (sp = available skill points)
--   |HI:<slot>:<id>:<charges>                  hero item, follows H; slot 1-indexed
--
-- ── Own buildings ──────────────────────────────────────────────────────────
--   |B:<id>:<x>:<y>:<hp%>:<z>:<queueid>:<rp_x>:<rp_y>
--                                               building; queueid = FourCC of unit
--                                               being trained/researched, "0000" if idle
--                                               rp_x/rp_y = rally-point world coords
--
-- ── Enemy units (fog-of-war compliant) ─────────────────────────────────────
--   |E:<id>:<x>:<y>:<hp%>:<z>                  visible enemy unit
--
-- ── Neutral structures/units ────────────────────────────────────────────────
--   |N:<id>:<x>:<y>:<hp%>:<z>:<gold>:<workers>  neutral; gold = GetResourceAmount(),
--                                               workers = peons currently inside mine
--
-- ── World data (camera-local) ──────────────────────────────────────────────
--   |D:<id>:<x>:<y>:<hp%>                      destructible (trees, rocks) near camera
--   |TK:<x>:<y>:<lvl>                          terrain cliff level sample (0-15)
--
-- ── Selection ──────────────────────────────────────────────────────────────
--   |SEL:<id1>,<id2>,...                        own unit type IDs currently selected
--
-- INV-001 compliance: enemy units filtered through IsUnitVisible(u, HUMAN).
-- No map-hack or fog bypass used.

-- ── Native aliases (captured before any map code can override them) ──────────
local _GetPlayerState          = GetPlayerState
local _CreateGroup             = CreateGroup
local _GroupEnumUnitsInRect    = GroupEnumUnitsInRect
local _GroupEnumUnitsOfPlayer  = GroupEnumUnitsOfPlayer
local _GetPlayableMapRect      = GetPlayableMapRect
local _GetPlayerStartLocation  = GetPlayerStartLocation
local _GetStartLocationX       = GetStartLocationX
local _GetStartLocationY       = GetStartLocationY
local _GetOwningPlayer         = GetOwningPlayer
local _GetUnitState            = GetUnitState
local _IsUnitVisible           = IsUnitVisible
local _FirstOfGroup            = FirstOfGroup
local _GroupRemoveUnit         = GroupRemoveUnit
local _DestroyGroup            = DestroyGroup
local _GetUnitTypeId           = GetUnitTypeId
local _GetWidgetX              = GetWidgetX
local _GetWidgetY              = GetWidgetY
local _BlzGetUnitMaxHP         = BlzGetUnitMaxHP
local _BlzGetTerrainHeight     = BlzGetTerrainHeight
local _IsUnitType              = IsUnitType
local _Player                  = Player
local _CreateTimer             = CreateTimer
local _TimerStart              = TimerStart
local _TimerGetElapsed         = TimerGetElapsed
local _PreloadGenClear         = PreloadGenClear
local _PreloadGenStart         = PreloadGenStart
local _Preload                 = Preload
local _PreloadGenEnd           = PreloadGenEnd
local _DisplayTextToPlayer     = DisplayTextToPlayer
-- Extended natives (comprehensive state)
local _GetUnitCurrentOrder     = GetUnitCurrentOrder
local _GetHeroLevel            = GetHeroLevel
local _GetHeroXP               = GetHeroXP
local _GetHeroSkillPoints      = GetHeroSkillPoints
local _UnitInventorySize       = UnitInventorySize
local _UnitItemInSlot          = UnitItemInSlot
local _GetItemTypeId           = GetItemTypeId
local _GetItemCharges          = GetItemCharges
local _GetResourceAmount       = GetResourceAmount
-- GetUnitCargoCount returns 0 for WC3 gold mines (mines do NOT use the cargo
-- transport system).  Worker count is derived instead via proximity tracking.
local _BlzGetUnitOrderTarget   = BlzGetUnitOrderTarget  -- Reforged: order target unit; nil if not available
local _GetUnitRallyPoint       = GetUnitRallyPoint  -- may be nil on older patches
local _GetLocationX            = GetLocationX
local _GetLocationY            = GetLocationY
local _RemoveLocation          = RemoveLocation
local _IsUnitSelected          = IsUnitSelected
local _GetTerrainCliffLevel    = GetTerrainCliffLevel
local _EnumDestructablesInRect = EnumDestructablesInRect
local _GetEnumDestructable     = GetEnumDestructable
local _GetDestructableX        = GetDestructableX
local _GetDestructableY        = GetDestructableY
local _GetDestructableTypeId   = GetDestructableTypeId
local _GetDestructableLife     = GetDestructableLife
local _GetDestructableMaxLife  = GetDestructableMaxLife
local _Rect                    = Rect
local _SetRect                 = SetRect

-- ── Configuration ─────────────────────────────────────────────────────────────
-- HUMAN/AI lazy-init on first tick (GetLocalPlayer nil at top-level on some maps).
local HUMAN    = nil
local AI       = nil
local OUT_PATH = "CustomMapData/wc3_orc_sidecar/sidecar"
local INTERVAL = 0.1   -- seconds between ticks

local _DESTR_RANGE = 1500  -- destructible scan radius around camera target (wu)
local _CLIFF_STEP  = 256   -- cliff-level sample grid spacing (wu)
local _CLIFF_HALF  = 3     -- ±n steps  →  (2n+1)² = 49 samples at n=3
local _TICK        = 0     -- incremented each tick; drives periodic tasks

-- ── Game-time tracking ────────────────────────────────────────────────────────
-- GetGameTimeElapsed does not exist in WC3 Reforged Lua; use a dedicated timer
-- with rollover accumulation to prevent float drift.
local _gameTimer    = _CreateTimer()
local _gameTimeSec  = 0.0
local _TIMER_PERIOD = 30.0
_TimerStart(_gameTimer, _TIMER_PERIOD, true, function()
    _gameTimeSec = _gameTimeSec + _TIMER_PERIOD
end)

local function gameTime()
    return _gameTimeSec + _TimerGetElapsed(_gameTimer)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- IsUnitDead replacement: life ≤ 0.405 means dead in WC3.
local function isUnitDead(u)
    return _GetUnitState(u, UNIT_STATE_LIFE) <= 0.405
end

-- Convert WC3 FourCC integer → 4-character ASCII string (e.g. 0x6F70656F → 'opeo').
local function fourcc(id)
    return string.char(
        (id >> 24) & 0xFF,
        (id >> 16) & 0xFF,
        (id >>  8) & 0xFF,
         id        & 0xFF
    )
end

-- Write a single-line state string via the Preload API (overwrites on each call).
local function write_line(line)
    _PreloadGenClear()
    _PreloadGenStart()
    _Preload(line)
    _PreloadGenEnd(OUT_PATH)
end

-- Safe HP% calculation shared by all collectors.
local function hpPct(u)
    local maxhp = _BlzGetUnitMaxHP and _BlzGetUnitMaxHP(u) or nil
    if maxhp == nil or maxhp <= 0 then
        maxhp = _GetUnitState(u, UNIT_STATE_MAX_LIFE)
    end
    return maxhp > 0
        and math.floor(_GetUnitState(u, UNIT_STATE_LIFE) / maxhp * 100 + 0.5)
        or 0
end

-- ── Mine-cycle worker counting ────────────────────────────────────────────────
-- Strategy: order-filter FIRST, then proximity.
--   - Idle peon next to mine:        order=0       → excluded ✓
--   - Peon building near mine:       building order → excluded ✓
--   - Peon attacking creep near mine: attack order  → excluded ✓
--   - Peon walking to mine:          ORDER_smart / ORDER_harvest → included ✓
--   - Peon returning with gold:      ORDER_returnresources variant → included ✓
--
-- Order IDs (empirically observed + standard JASS constants):
--   851971 = ORDER_smart   (right-click resolves to harvest when target is mine)
--   852005 = ORDER_harvest (explicit harvest order)
--   852012 = ORDER_returnresources (standard constant)
--   852017 = observed Orc peon return-resources variant on Last Refuge
-- These are the ONLY orders that indicate a peon is in the mine-harvest cycle.

local _HARVEST_RADIUS_SQ = 640 * 640

local _MINING_ORDERS = {
    [851971] = true,  -- ORDER_smart
    [852005] = true,  -- ORDER_harvest
    [852012] = true,  -- ORDER_returnresources
    [852017] = true,  -- Orc harvest/return variant (empirical)
}

-- Cache of visible own-worker {x, y, order} built once per tick.
local _worker_pos = {}

local function cache_worker_positions()
    for i = #_worker_pos, 1, -1 do _worker_pos[i] = nil end
    local g = _CreateGroup()
    _GroupEnumUnitsOfPlayer(g, HUMAN, nil)
    local u = _FirstOfGroup(g)
    while u ~= nil do
        if not isUnitDead(u) then
            local order  = _GetUnitCurrentOrder and _GetUnitCurrentOrder(u) or 0
            -- BlzGetUnitOrderTarget: unit target of the current order (Reforged native).
            -- For harvest order → points to the mine unit (exact match, same as UI overlay).
            -- For return order  → points to the town hall (not the mine).
            -- nil if native unavailable or order has no unit target.
            local target = _BlzGetUnitOrderTarget and _BlzGetUnitOrderTarget(u) or nil
            table.insert(_worker_pos, {
                x      = _GetWidgetX(u),
                y      = _GetWidgetY(u),
                order  = order,
                target = target,
            })
        end
        _GroupRemoveUnit(g, u)
        u = _FirstOfGroup(g)
    end
    _DestroyGroup(g)
end

-- Count visible own workers in the mine-harvest cycle for mine unit `mine_unit`
-- at world position (mx, my).
--
-- Priority:
--   1. Exact target match: BlzGetUnitOrderTarget(peon) == mine_unit  → exact (same as UI)
--      Counts peons currently walking TO the mine (harvest order target = mine).
--   2. Fallback: order in _MINING_ORDERS + proximity
--      Catches returning peons (their order target = town hall, not mine)
--      and any version of WC3 where BlzGetUnitOrderTarget is unavailable.
--
-- The one peon physically INSIDE the mine is invisible to all enumeration;
-- Python adds +1 via worker_in_mine() inference for the full "X/5" count.
local function count_mine_cycle_workers(mine_unit, mx, my)
    local exact_available = (_BlzGetUnitOrderTarget ~= nil)
    local count = 0
    for _, p in ipairs(_worker_pos) do
        local matched = false
        -- Method 1: exact order-target match (only possible for harvest direction)
        if exact_available and p.target ~= nil and p.target == mine_unit then
            matched = true
        end
        -- Method 2: mining order + proximity (catches return leg + fallback)
        if not matched and _MINING_ORDERS[p.order] then
            local dx = p.x - mx
            local dy = p.y - my
            if dx * dx + dy * dy <= _HARVEST_RADIUS_SQ then
                matched = true
            end
        end
        if matched then count = count + 1 end
    end
    return count
end

-- ── Destructible collection ───────────────────────────────────────────────────
-- Run every _DESTR_FREQ ticks; previous result returned on other ticks.
local _DESTR_FREQ = 5       -- update every 5 ticks (0.5 s)
local _destr_buf  = {}      -- reused buffer
local _destr_rect = nil     -- reused Rect object

local function _destr_action()
    local d    = _GetEnumDestructable()
    local life = _GetDestructableLife(d)
    if life > 0.405 then
        local maxlife = _GetDestructableMaxLife(d)
        local hp  = maxlife > 0 and math.floor(life / maxlife * 100 + 0.5) or 0
        local did = fourcc(_GetDestructableTypeId(d))
        local dx  = math.floor(_GetDestructableX(d))
        local dy  = math.floor(_GetDestructableY(d))
        table.insert(_destr_buf, "D:" .. did .. ":" .. dx .. ":" .. dy .. ":" .. hp)
    end
end

local function collect_destructibles(cx, cy)
    if _TICK % _DESTR_FREQ ~= 1 then return _destr_buf end

    -- Clear buffer (reuse table to avoid GC pressure).
    for i = #_destr_buf, 1, -1 do _destr_buf[i] = nil end

    if _destr_rect == nil then
        _destr_rect = _Rect(cx - _DESTR_RANGE, cy - _DESTR_RANGE,
                            cx + _DESTR_RANGE, cy + _DESTR_RANGE)
    else
        _SetRect(_destr_rect,
                 cx - _DESTR_RANGE, cy - _DESTR_RANGE,
                 cx + _DESTR_RANGE, cy + _DESTR_RANGE)
    end

    _EnumDestructablesInRect(_destr_rect, nil, _destr_action)
    return _destr_buf
end

-- ── Cliff-level sampling ──────────────────────────────────────────────────────
-- Re-sample when camera has moved ≥ half a grid step, or every _CLIFF_FREQ ticks.
local _CLIFF_FREQ = 10      -- full resample every 10 ticks (1 s)
local _cliff_buf  = {}
local _cliff_cx   = nil
local _cliff_cy   = nil
local _HALF_STEP_SQ = (_CLIFF_STEP * 0.5) ^ 2

local function sample_cliffs(cx, cy)
    local resample = (_TICK % _CLIFF_FREQ == 1)
    if not resample and _cliff_cx ~= nil then
        local dx = cx - _cliff_cx
        local dy = cy - _cliff_cy
        resample = (dx * dx + dy * dy) > _HALF_STEP_SQ
    end
    if not resample then return _cliff_buf end

    _cliff_cx = cx
    _cliff_cy = cy
    for i = #_cliff_buf, 1, -1 do _cliff_buf[i] = nil end

    if _GetTerrainCliffLevel then
        for ix = -_CLIFF_HALF, _CLIFF_HALF do
            for iy = -_CLIFF_HALF, _CLIFF_HALF do
                local sx  = math.floor(cx + ix * _CLIFF_STEP)
                local sy  = math.floor(cy + iy * _CLIFF_STEP)
                local lvl = _GetTerrainCliffLevel(sx, sy)
                table.insert(_cliff_buf, "TK:" .. sx .. ":" .. sy .. ":" .. lvl)
            end
        end
    end
    return _cliff_buf
end

-- ── Own-unit / enemy collection ───────────────────────────────────────────────
-- is_enemy = false → own (HUMAN) units and buildings
-- is_enemy = true  → visible enemy (AI) units, fog-of-war compliant

local function collect(is_enemy)
    local parts = {}
    local g = _CreateGroup()
    -- nil filter: enumerate ALL units in rect; owner/visibility filtered below.
    -- (Filter callbacks skip buildings in WC3 Reforged Lua.)
    _GroupEnumUnitsInRect(g, _GetPlayableMapRect(), nil)

    local u = _FirstOfGroup(g)
    while u ~= nil do
        local owner   = _GetOwningPlayer(u)
        local include = false
        if is_enemy then
            include = (owner == AI)
                   and not isUnitDead(u)
                   and _IsUnitVisible(u, HUMAN)
        else
            include = (owner == HUMAN) and not isUnitDead(u)
        end

        if include then
            local uid   = fourcc(_GetUnitTypeId(u))
            local x     = math.floor(_GetWidgetX(u))
            local y     = math.floor(_GetWidgetY(u))
            local hp    = hpPct(u)
            local tz    = _BlzGetTerrainHeight
                          and string.format("%.0f", _BlzGetTerrainHeight(x, y))
                          or "0"
            local order = _GetUnitCurrentOrder and _GetUnitCurrentOrder(u) or 0

            if is_enemy then
                -- E: visible enemy unit (no extra data to preserve privacy boundaries)
                table.insert(parts,
                    "E:" .. uid .. ":" .. x .. ":" .. y .. ":" .. hp .. ":" .. tz)

            elseif _IsUnitType(u, UNIT_TYPE_STRUCTURE) then
                -- B: own building — include training queue and rally-point coords
                local qid  = (order ~= 0) and fourcc(order) or "0000"
                local rp_x = x  -- default: rally at building position
                local rp_y = y
                if _GetUnitRallyPoint then
                    local rp = _GetUnitRallyPoint(u)
                    if rp then
                        rp_x = math.floor(_GetLocationX(rp))
                        rp_y = math.floor(_GetLocationY(rp))
                        _RemoveLocation(rp)
                    end
                end
                table.insert(parts,
                    "B:" .. uid .. ":" .. x .. ":" .. y .. ":" .. hp .. ":" .. tz
                    .. ":" .. qid .. ":" .. rp_x .. ":" .. rp_y)

            elseif _IsUnitType(u, UNIT_TYPE_HERO) then
                -- H: own hero — full stats
                local mana    = math.floor((_GetUnitState(u, UNIT_STATE_MANA) or 0) + 0.5)
                local maxmana = math.floor((_GetUnitState(u, UNIT_STATE_MAX_MANA) or 0) + 0.5)
                local lvl     = _GetHeroLevel    and _GetHeroLevel(u)    or 0
                local xp      = _GetHeroXP       and _GetHeroXP(u)       or 0
                local sp      = _GetHeroSkillPoints and _GetHeroSkillPoints(u) or 0
                table.insert(parts,
                    "H:" .. uid .. ":" .. x .. ":" .. y .. ":" .. hp .. ":" .. tz
                    .. ":" .. order
                    .. ":" .. mana .. ":" .. maxmana
                    .. ":" .. lvl .. ":" .. xp .. ":" .. sp)

                -- HI: hero items (slot 1-indexed, immediately after H entry)
                if _UnitInventorySize and _UnitItemInSlot and _GetItemTypeId then
                    local invSize = _UnitInventorySize(u)
                    for slot = 0, invSize - 1 do
                        local item = _UnitItemInSlot(u, slot)
                        if item ~= nil then
                            local iid     = fourcc(_GetItemTypeId(item))
                            local charges = _GetItemCharges and _GetItemCharges(item) or 0
                            table.insert(parts,
                                "HI:" .. (slot + 1) .. ":" .. iid .. ":" .. charges)
                        end
                    end
                end

            else
                -- U: own regular unit
                table.insert(parts,
                    "U:" .. uid .. ":" .. x .. ":" .. y .. ":" .. hp .. ":" .. tz
                    .. ":" .. order)
            end
        end

        _GroupRemoveUnit(g, u)
        u = _FirstOfGroup(g)
    end

    _DestroyGroup(g)
    return parts
end

-- ── Neutral collection ────────────────────────────────────────────────────────
-- N:<id>:<x>:<y>:<hp%>:<z>:<gold>:<workers>
-- gold = GetResourceAmount() (non-zero for gold mines; 0 for other structures).
-- workers = GetUnitCargoCount() = peons currently inside the mine (0 for non-mines).

local function collect_neutral()
    local parts = {}
    local g = _CreateGroup()
    _GroupEnumUnitsInRect(g, _GetPlayableMapRect(), nil)

    local u = _FirstOfGroup(g)
    while u ~= nil do
        local owner = _GetOwningPlayer(u)
        if not (owner == HUMAN or owner == AI) and not isUnitDead(u) then
            local uid  = fourcc(_GetUnitTypeId(u))
            local x    = math.floor(_GetWidgetX(u))
            local y    = math.floor(_GetWidgetY(u))
            local hp   = hpPct(u)
            local tz   = _BlzGetTerrainHeight
                         and string.format("%.0f", _BlzGetTerrainHeight(x, y))
                         or "0"
            local gold    = _GetResourceAmount and _GetResourceAmount(u) or 0
            -- Visible own workers within HARVEST_RADIUS of this neutral.
            -- For Orc/Human: up to (max_peons - 1) visible here; +1 inside mine
            -- is inferred in Python via peon-count drop.
            local workers = count_mine_cycle_workers(u, x, y)
            table.insert(parts,
                "N:" .. uid .. ":" .. x .. ":" .. y .. ":" .. hp .. ":" .. tz
                .. ":" .. gold .. ":" .. workers)
        end
        _GroupRemoveUnit(g, u)
        u = _FirstOfGroup(g)
    end

    _DestroyGroup(g)
    return parts
end

-- ── Selected-unit collection ──────────────────────────────────────────────────
-- Returns "SEL:<id1>,<id2>,..." or "" if nothing is selected.
-- Only own units are checked (enemy/neutral selection not reported).

local function collect_selected()
    if not _IsUnitSelected then return "" end

    local sel_ids = {}
    local g = _CreateGroup()
    _GroupEnumUnitsOfPlayer(g, HUMAN, nil)

    local u = _FirstOfGroup(g)
    while u ~= nil do
        if _IsUnitSelected(u, HUMAN) and not isUnitDead(u) then
            table.insert(sel_ids, fourcc(_GetUnitTypeId(u)))
        end
        _GroupRemoveUnit(g, u)
        u = _FirstOfGroup(g)
    end

    _DestroyGroup(g)
    if #sel_ids > 0 then
        return "SEL:" .. table.concat(sel_ids, ",")
    end
    return ""
end

-- ── Tick ──────────────────────────────────────────────────────────────────────

local function tick()
    -- Lazy-init: GetLocalPlayer() is nil at top-level on standard melee maps.
    if HUMAN == nil then
        HUMAN = GetLocalPlayer()
        AI    = _Player(HUMAN == _Player(0) and 1 or 0)
    end
    _TICK = _TICK + 1

    -- Resources
    local t  = math.floor(gameTime() * 10 + 0.5) / 10
    local g  = _GetPlayerState(HUMAN, PLAYER_STATE_RESOURCE_GOLD)
    local l  = _GetPlayerState(HUMAN, PLAYER_STATE_RESOURCE_LUMBER)
    local fu = _GetPlayerState(HUMAN, PLAYER_STATE_RESOURCE_FOOD_USED)
    local fc = _GetPlayerState(HUMAN, PLAYER_STATE_RESOURCE_FOOD_CAP)

    -- Great Hall start-location anchor (always available, no unit-enum needed)
    local startLoc = _GetPlayerStartLocation(HUMAN)
    local gh_x = math.floor(_GetStartLocationX(startLoc))
    local gh_y = math.floor(_GetStartLocationY(startLoc))

    -- Camera state (numeric copies needed for cliff/destr sampling)
    local cam_tx_n  = math.floor(GetCameraTargetPositionX() + 0.5)
    local cam_ty_n  = math.floor(GetCameraTargetPositionY() + 0.5)
    local cam_tz    = string.format("%.1f", GetCameraTargetPositionZ())
    -- GetCameraField returns radians; Python converts to degrees.
    local cam_aoa   = string.format("%.4f", GetCameraField(CAMERA_FIELD_ANGLE_OF_ATTACK))
    local cam_fov   = string.format("%.4f", GetCameraField(CAMERA_FIELD_FIELD_OF_VIEW))
    local cam_dist  = string.format("%.2f", GetCameraField(CAMERA_FIELD_TARGET_DISTANCE))
    local cam_rot   = string.format("%.4f", GetCameraField(CAMERA_FIELD_ROTATION))

    local parts = {
        "T:"  .. t,
        "G:"  .. g,
        "L:"  .. l,
        "FU:" .. fu,
        "FC:" .. fc,
        "GH:" .. gh_x .. ":" .. gh_y,
        "CAM:" .. cam_tx_n .. ":" .. cam_ty_n .. ":" .. cam_tz
                .. ":" .. cam_aoa .. ":" .. cam_fov
                .. ":" .. cam_dist .. ":" .. cam_rot,
    }

    -- Own units/heroes/buildings
    for _, v in ipairs(collect(false))    do table.insert(parts, v) end
    -- Visible enemy units (fog-of-war compliant)
    for _, v in ipairs(collect(true))     do table.insert(parts, v) end
    -- Cache own worker positions before neutral collection (used for mine proximity count)
    cache_worker_positions()
    -- Neutral structures (mines, shops, etc.)
    for _, v in ipairs(collect_neutral()) do table.insert(parts, v) end
    -- Destructibles (trees, rocks) within _DESTR_RANGE of camera
    for _, v in ipairs(collect_destructibles(cam_tx_n, cam_ty_n)) do
        table.insert(parts, v)
    end
    -- Terrain cliff levels around camera (high-ground detection)
    for _, v in ipairs(sample_cliffs(cam_tx_n, cam_ty_n)) do
        table.insert(parts, v)
    end
    -- Currently selected own units
    local sel = collect_selected()
    if sel ~= "" then
        table.insert(parts, sel)
    end

    -- Pin string as Lua global so mach_vm_read scans can find _G.WC3BOT_STATE.
    local line = table.concat(parts, "|")
    _G.WC3BOT_STATE = line
    write_line(line)
end

-- ── SaveGameCache channel (disabled) ─────────────────────────────────────────
-- StoreInteger does not exist in WC3 Reforged Lua; channel unused.
local function cache_tick() end  -- luacheck: ignore

-- ── Initialization ────────────────────────────────────────────────────────────
-- Hook into main() so the timer starts AFTER WC3 fully initialises the game.
-- Standard melee maps define main() which WC3 calls after loading. We save the
-- original, override it, call original first, then start our timer.

local _sidecar_orig_main = main

function main()
    if _sidecar_orig_main then _sidecar_orig_main() end

    local _tick_count = 0
    TimerStart(CreateTimer(), INTERVAL, true, function()
        _tick_count = _tick_count + 1
        local ok, err = pcall(tick)
        if not ok then
            DisplayTextToPlayer(GetLocalPlayer(), 0, 0,
                "[sidecar] tick error: " .. tostring(err))
        end
        -- Alive heartbeat every 5 s
        if _tick_count % 50 == 1 then
            DisplayTextToPlayer(GetLocalPlayer(), 0, 0,
                "[sidecar] alive t=" .. string.format("%.1f", gameTime()))
        end
    end)
end
