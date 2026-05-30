// sidecar.j — WC3 Orc Bot game-state observer (JASS version)
//
// Embedded in war3map.j by create_sidecar_map.py.
// Called via InitSidecar() from the main() function.
//
// Output file (macOS):
//   ~/Documents/Warcraft III/CustomMapData/wc3_orc_sidecar/sidecar.pld
//
// Format: pipe-delimited single line, overwritten every INTERVAL seconds.
//   T:<time>|G:<gold>|L:<lumber>|FU:<food_used>|FC:<food_cap>
//   |U:<id>:<x>:<y>:<hp%>       (own unit)
//   |B:<id>:<x>:<y>:<hp%>       (own building; hp% = construction progress)
//   |E:<id>:<x>:<y>:<hp%>       (visible enemy unit, fog-of-war respected)
//
// INV-001 compliance: enemy units filtered through IsUnitVisible(u, HUMAN)

globals
    player  g_HUMAN    = null
    player  g_AI       = null
    string  g_OUT_PATH = "CustomMapData\\wc3_orc_sidecar\\sidecar"
    real    g_INTERVAL = 0.1
endglobals

// ── helpers ──────────────────────────────────────────────────────────────────

function SC_AppendInt takes string base, string sep, string key, integer val returns string
    return base + sep + key + I2S(val)
endfunction

function SC_AppendReal takes string base, string sep, string key, real val returns string
    local integer whole = R2I(val)
    local integer frac  = R2I((val - I2R(whole)) * 10.0 + 0.5)
    if frac >= 10 then
        set whole = whole + 1
        set frac  = 0
    endif
    return base + sep + key + I2S(whole) + "." + I2S(frac)
endfunction

// ── unit serialization ───────────────────────────────────────────────────────

function SC_AppendUnit takes string line, string tag, unit u returns string
    local real    maxhp = GetUnitState(u, UNIT_STATE_MAX_LIFE)
    local integer hp    = 0
    local integer x     = R2I(GetUnitX(u))
    local integer y     = R2I(GetUnitY(u))
    if maxhp > 0.0 then
        set hp = R2I(GetUnitState(u, UNIT_STATE_LIFE) / maxhp * 100.0 + 0.5)
    endif
    return line + "|" + tag + ":" + I2FourCC(GetUnitTypeId(u)) + ":" + I2S(x) + ":" + I2S(y) + ":" + I2S(hp)
endfunction

// ── unit collection ──────────────────────────────────────────────────────────

function SC_CollectOwn takes string line returns string
    local group g = CreateGroup()
    local unit  u
    call GroupEnumUnitsOfPlayer(g, g_HUMAN, null)
    loop
        set u = FirstOfGroup(g)
        exitwhen u == null
        call GroupRemoveUnit(g, u)
        if not IsUnitDead(u) then
            if IsUnitType(u, UNIT_TYPE_STRUCTURE) then
                set line = SC_AppendUnit(line, "B", u)
            else
                set line = SC_AppendUnit(line, "U", u)
            endif
        endif
    endloop
    call DestroyGroup(g)
    set g = null
    return line
endfunction

function SC_CollectEnemies takes string line returns string
    local group g = CreateGroup()
    local unit  u
    call GroupEnumUnitsInRect(g, GetPlayableMapRect(), null)
    loop
        set u = FirstOfGroup(g)
        exitwhen u == null
        call GroupRemoveUnit(g, u)
        if GetOwningPlayer(u) == g_AI and not IsUnitDead(u) and IsUnitVisible(u, g_HUMAN) then
            set line = SC_AppendUnit(line, "E", u)
        endif
    endloop
    call DestroyGroup(g)
    set g = null
    return line
endfunction

// ── tick ─────────────────────────────────────────────────────────────────────

function SC_Tick takes nothing returns nothing
    local real    t  = GetGameTimeElapsed()
    local integer g  = GetPlayerState(g_HUMAN, PLAYER_STATE_RESOURCE_GOLD)
    local integer l  = GetPlayerState(g_HUMAN, PLAYER_STATE_RESOURCE_LUMBER)
    local integer fu = GetPlayerState(g_HUMAN, PLAYER_STATE_RESOURCE_FOOD_USED)
    local integer fc = GetPlayerState(g_HUMAN, PLAYER_STATE_RESOURCE_FOOD_CAP)
    local string  line

    set line = SC_AppendReal("", "", "T:", t)
    set line = SC_AppendInt(line, "|", "G:", g)
    set line = SC_AppendInt(line, "|", "L:", l)
    set line = SC_AppendInt(line, "|", "FU:", fu)
    set line = SC_AppendInt(line, "|", "FC:", fc)
    set line = SC_CollectOwn(line)
    set line = SC_CollectEnemies(line)

    call PreloadGenClear()
    call PreloadGenStart()
    call Preload(line)
    call PreloadGenEnd(g_OUT_PATH)
endfunction

// ── initialization ────────────────────────────────────────────────────────────

function InitSidecar takes nothing returns nothing
    local timer t = CreateTimer()
    set g_HUMAN = Player(0)
    set g_AI    = Player(1)

    call PreloadGenClear()
    call PreloadGenStart()
    call Preload("INIT:sidecar_v1")
    call PreloadGenEnd(g_OUT_PATH)

    call TimerStart(t, g_INTERVAL, true, function SC_Tick)
    set t = null
endfunction
