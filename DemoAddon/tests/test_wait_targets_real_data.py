"""Real-data test of the end of a route to a certified interaction (DemoAddon, 10.11.2026). Lua 5.1 via lupa, REAL DemoAddon files, REAL shipped data.

Every dyn row of every zone with interactionMode manual_wait (lifts), activationMode walk_into_trigger (tram, portals, entrances) or a boat or zeppelin
landing is routed with the real core from nodes 20 to 120 yd away (the nearest, a middle and the farthest node of that ring, those that have a route):
  * the route ends on the node the row resolves to (target.nodeId): the activation proof asks for exactly that node,
  * the end lies in the circle of the row (waiting circle of a lift, capture circle of the activation area),
  * a waiting point of the old model (lift): Dock:WaitAreaReached is true at the end, and walking the first route arrives (Dock.reached).
A boat or zeppelin landing follows the dock model (user decision 10.11.2026): no circle. The shipped data still carry the OLD model for them, so before the
zone is loaded every such row is rewritten in the Lua state (interactionMode, waitingRadius, waitpointProofId and the boarding fields removed, the head of
the catalog gets navFingerprint = the fingerprint of the zone; the rows then have the head's dynNode mark). A row that already has the new model (an
onboard row with its dockId exists) is taken as it is. The check then is: the route ends EXACTLY on the node at the coordinates of the dock, walking it is
a normal arrival (Dock.reached is set, no waitTargetId, no Dock:WaitAreaReached), and for a dock with a point on board (boardingPointId) the route from
the dock node ends on the node of that row and its arrival sets the context of the dock again.
A row that none of the sampled starts reaches (ring, then 12 nodes over the whole zone) is printed as a NOTE (no route end to check).

Data: the Forever folder of the sister repository, or the maps folder of any addon with the same layout (a dir in WOWNAV_DATA or the first argument that is
a dir). Zones are loaded one at a time (the big continents do not fit into one Lua state). Further arguments name zones (folder names) to test; without,
all zones whose dyn_targets.lua holds such rows. Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_wait_targets_real_data.py [data dir] [Zone ...]
(exit code 0 = all green)
"""

import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent / "WowVisionNavigation"
TOOLS = Path(os.environ.get("WOWNAV_TOOLS", r"C:\Users\Manu\projects\WowNav\tools"))
os.environ["WOW_addon_dir"] = str(ADDON)       # the harness must load the DemoAddon, not addon/
sys.path.insert(0, str(TOOLS))

import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

DEFAULT_DATA = HERE.parent.parent / "Forever"
RING = (20.0, 120.0)          # yd: the start nodes lie this far from the row (the measure of the dock analysis of 10.11.2026)
MARKERS = ("manual_wait", "walk_into_trigger", '["facilityKind"]="boat"', '["facilityKind"]="zeppelin"')

LUA = """
local N = WowVisionNavigationNavNetwork

-- up to three start nodes of the ring around (x, y): the nearest, a middle and the farthest land node
local function Starts(zone, x, y, low, high, count)
  local found = {}
  for i = 1, zone.n do
    if zone.area[i] ~= 2 and not N.NoExit(zone.base + i - 1) then
      local d = math.sqrt((zone.x[i] - x) ^ 2 + (zone.y[i] - y) ^ 2)
      if d >= low and d <= high then found[#found + 1] = { id = zone.base + i - 1, d = d } end
    end
  end
  table.sort(found, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  local picks = {}
  if #found <= count then
    for _, item in ipairs(found) do picks[#picks + 1] = item.id end
  else
    for k = 0, count - 1 do picks[#picks + 1] = found[1 + math.floor(k * (#found - 1) / (count - 1))].id end
  end
  return picks
end

function SimSetup(zoneId)
  local zone = WowVisionNavigationZoneLoader.zones[zoneId]
  -- the position stub converts world coordinates with the boxes of the zone's UiMaps (open-world zones have no native map of their own)
  for ui, box in pairs(zone.worldBoxes) do
    BOXES[ui] = { box.xmin, box.xmax, box.ymin, box.ymax }
    bestMapID = ui
  end
  return WowVisionNavigationZoneLoader:LoadZone(zone)
end

-- The dock model for the shipped rows of the old model (see the head of this file): -> rewritten rows, rows that already had the new model
local OLD_FIELDS = { "interactionMode", "waitingRadius", "waitpointProofId", "boardingHintStatus", "boardingDirX", "boardingDirY", "boardingPreviewDistance" }
function MigrateDockRows(zoneId)
  local catalog, zone = WVN7Dyn and WVN7Dyn[zoneId], WVN7 and WVN7[zoneId]
  if not catalog or not zone then return 0, 0 end
  local migrated, native = 0, 0
  for _, row in ipairs(catalog.targets) do
    if row.type == "transit_facility" and row.facilityRole == "waiting" and (row.facilityKind == "boat" or row.facilityKind == "zeppelin") then
      if row.interactionMode == "manual_wait" then
        for _, key in ipairs(OLD_FIELDS) do row[key] = nil end
        migrated = migrated + 1
      else
        native = native + 1
      end
    end
  end
  if migrated + native > 0 then catalog.navFingerprint = zone.fingerprint end
  return migrated, native
end

-- Dock:WaitAreaReached is counted: a dock of the new model never asks for it
WACALLS = 0
do
  local Dock = WowVisionNavigationDockNavigation
  local original = Dock.WaitAreaReached
  Dock.WaitAreaReached = function(...) WACALLS = WACALLS + 1; return original(...) end
end

-- The player walks to the current waypoint of the active route in steps of half a yard until stop() or the end of the route
local function WalkUntil(stop)
  local nav = __T.Navigation
  for _ = 1, 60000 do          -- 30 000 yd: a route round a bay can be long
    if stop() then return true end
    if not nav.active then return false end
    local nx, ny = __T.NodePosition(nav.path[nav.pathIndex])
    local dx, dy = nx - playerX, ny - playerY
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= 0.5 then playerX, playerY = nx, ny else playerX, playerY = playerX + dx / distance * 0.5, playerY + dy / distance * 0.5 end
    time = time + 0.3
    __T.navFrame.scripts["OnUpdate"](__T.navFrame, 0.3)
  end
  return false
end

-- A route to a dock of the new model is walked: normal arrival (context "reached", no waiting circle), then the route to the point on board
-- -> list of problem texts
local function WalkVessel(entry)
  local Dock, nav = WowVisionNavigationDockNavigation, __T.Navigation
  local problems, calls, seenWait = {}, WACALLS, false
  WalkUntil(function()
    if nav.waitTargetId ~= nil then seenWait = true end
    return nav.boardingArrivalId ~= nil or not nav.active
  end)
  if seenWait then problems[#problems + 1] = "waitTargetId was set (a waiting circle took part)" end
  if WACALLS ~= calls then problems[#problems + 1] = "Dock:WaitAreaReached was asked" end
  if entry.boardingPointId then
    local ship = WowVisionNavigationTargetList(NavData, function(t) return t.id == entry.boardingPointId end, true)[1]
    if not ship or type(ship.nodeId) ~= "number" then
      problems[#problems + 1] = "the point on board " .. tostring(entry.boardingPointId) .. " does not resolve to a node"
    elseif not nav.active or nav.boardingArrivalId ~= entry.boardingPointId then
      problems[#problems + 1] = "the route to the point on board did not start after the arrival at the dock"
    else
      local endNode = nav.logicalPrepoint or nav.path[#nav.path]
      if nav.path[1] ~= entry.nodeId then problems[#problems + 1] = "the route to the point on board does not start on the dock node" end
      if endNode ~= ship.nodeId then problems[#problems + 1] = "the route to the point on board ends on " .. tostring(endNode) .. ", not on the node " .. ship.nodeId .. " of its row" end
      WalkUntil(function() return not nav.active end)
      if nav.active then problems[#problems + 1] = "the arrival on board did not happen" end
    end
  end
  if nav.active or not Dock.reached or Dock.reached.id ~= entry.id then
    local last = outputs and outputs[#outputs] or "-"
    problems[#problems + 1] = "walking the route does not arrive at the dock (context 'reached' of the dock missing; route active: " .. tostring(nav.active)
        .. ", waypoint " .. tostring(nav.pathIndex) .. "/" .. tostring(nav.path and #nav.path) .. ", last message: " .. tostring(last) .. ")"
  end
  return problems
end

function InteractionRows(zoneId)
  local Dock = WowVisionNavigationDockNavigation
  local list = WowVisionNavigationTargetList(NavData, function(t)
    return t.interactionMode == "manual_wait" or t.activationMode == "walk_into_trigger" or Dock:IsVesselDock(t, NavData) end, true)
  local rows = {}
  for _, entry in ipairs(list) do
    if entry.zoneId == zoneId then rows[#rows + 1] = entry end
  end
  return rows
end

-- -> routed starts, list of failure texts for the row (index of the row in InteractionRows)
function CheckRow(zoneId, index, low, high)
  local R, Dock = WowVisionNavigationTargetResolver, WowVisionNavigationDockNavigation
  local entry = InteractionRows(zoneId)[index]
  local zone = N.zones[zoneId]
  local fails, routed = {}, 0
  local wait = entry.interactionMode == "manual_wait"
  local vessel = Dock:IsVesselDock(entry, NavData)         -- the dock model: no circle, the node at the coordinates
  UnitPosition = function() return playerX, playerY, 0, entry.nativeMapId end
  if not entry.layerResolution or entry.layerResolution.quality ~= "exact" or type(entry.nodeId) ~= "number" then
    return 0, { "the row does not resolve exactly to a node (" .. tostring(entry.layerResolution and entry.layerResolution.quality) .. ")" }, entry.id
  end
  local starts = Starts(zone, entry.x, entry.y, low, high, 3)
  -- a row no ring start reaches (a lift in its own part of the network) is tried from further away before it counts as unreachable
  local function reaches(list)
    for _, startId in ipairs(list) do
      local context = WowVisionNavigationLayerTargetContext(true, startId)
      local r = context and R:Resolve(NavData, entry, context)
      if r and r.endNodeId then return true end
    end
    return false
  end
  if not reaches(starts) then
    starts = Starts(zone, entry.x, entry.y, low, 1e9, 12)
  end
  if #starts == 0 then return 0, { "no node between " .. low .. " and " .. high .. " yd" }, entry.id end
  local walked = false
  for _, startId in ipairs(starts) do
    local context = WowVisionNavigationLayerTargetContext(true, startId)
    local r = context and R:Resolve(NavData, entry, context)
    if r and r.endNodeId then
      routed = routed + 1
      local ex, ey = __T.NodePosition(r.endNodeId)
      local d = math.sqrt((ex - entry.x) ^ 2 + (ey - entry.y) ^ 2)
      local radius = R.EndRadius(entry)
      local label = "start " .. startId .. ": "
      if r.endNodeId ~= entry.nodeId then fails[#fails + 1] = label .. "the route ends on " .. r.endNodeId .. ", not on the node " .. entry.nodeId .. " of the row (" .. string.format("%.2f", d) .. " yd from it)" end
      if vessel then
        -- the dock model: the route ends exactly on the node that stands at the coordinates of the row (no circle)
        if d > 0.1 then fails[#fails + 1] = label .. "the end node lies " .. string.format("%.2f", d) .. " yd from the coordinates of the dock" end
        if radius then fails[#fails + 1] = label .. "the dock still asks for a circle (" .. tostring(radius) .. ")" end
      elseif wait then
        -- a waiting point lies on its node: the end is in the waiting circle and the arrival rule of the dock holds there
        if not radius or d > radius then fails[#fails + 1] = label .. "the end lies " .. string.format("%.2f", d) .. " yd from the row, the circle is " .. tostring(radius) end
        if not Dock:WaitAreaReached(entry, ex, ey, NavData) then fails[#fails + 1] = label .. "WaitAreaReached is false at the end" end
      end
      -- the core starts a route to an activation area only for an entrance (TransitActivation:IsActivationTarget); an exit is checked up to the end node
      if not walked and (wait or vessel or entry.facilityRole == "entrance") then
        walked = true
        local sx, sy = __T.NodePosition(startId)
        playerX, playerY = sx, sy
        Dock:Reset(false)
        __T.Navigation.manualStartNode = startId
        local started = WowVisionNavigationSelectListEntry(entry)
        if not started or not __T.Navigation.active then
          fails[#fails + 1] = label .. "the route does not start"
        elseif vessel then
          for _, problem in ipairs(WalkVessel(entry)) do fails[#fails + 1] = label .. problem end
          __T.ExecuteSlashCommand("stop")
        elseif not wait then
          -- an activation area: the route starts (the activation proof asks for the node of the row) and ends on that node
          local path = __T.Navigation.path
          if path[#path] ~= entry.nodeId or not __T.Navigation.activationTarget or __T.Navigation.activationTarget.id ~= entry.id then
            fails[#fails + 1] = label .. "the started route does not end on the node of the activation area"
          end
          __T.ExecuteSlashCommand("stop")
        else
          -- the player walks the straights of the route in steps of half a yard, as a player does (like test_anleger_after_action)
          local prevX, prevY = playerX, playerY
          for i = 1, #__T.Navigation.path do
            local nx, ny = __T.NodePosition(__T.Navigation.path[i])
            local dx, dy = nx - prevX, ny - prevY
            local steps = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) / 0.5))
            for k = 1, steps do
              if not __T.Navigation.active then break end
              playerX, playerY = prevX + dx * k / steps, prevY + dy * k / steps
              time = time + 0.3
              __T.navFrame.scripts["OnUpdate"](__T.navFrame, 0.3)
            end
            prevX, prevY = nx, ny
            if not __T.Navigation.active then break end
          end
          if __T.Navigation.active or not Dock.reached or Dock.reached.id ~= entry.id then
            fails[#fails + 1] = label .. "walking the route does not arrive at the waiting point"
          end
          __T.ExecuteSlashCommand("stop")
        end
      end
    end
  end
  if routed == 0 then fails[#fails + 1] = "no route from any of the " .. #starts .. " start nodes (the ring, then the whole zone)" end
  return routed, fails, entry.id
end
"""


def zones_with_rows(data):
    """[(continent, zone dir)] of the data with an interaction row in its dyn_targets.lua."""
    found = []
    for continent in sorted(p for p in data.iterdir() if p.is_dir()):
        for zone in sorted(p for p in continent.iterdir() if p.is_dir()):
            dyn = zone / "dyn_targets.lua"
            if dyn.is_file() and any(m in dyn.read_text(encoding="utf-8") for m in MARKERS) and (zone / "navdata.lua").is_file():
                found.append((continent.name, zone.name))
    return found


def zone_id_of(data, continent, zone):
    text = (data / continent / zone / "navdata.lua").read_text(encoding="utf-8", errors="replace")[:600]
    return int(re.search(r"zoneId=(\d+)", text).group(1))


def check_zone(data, continent, zone):
    """-> (rows, routed starts, [failure text], [note]) of one zone."""
    zone_id = zone_id_of(data, continent, zone)
    sources = [H.read(data / continent / "index.lua")] + [H.read(data / continent / zone / name) for name in ("navdata.lua", "logical_targets.lua", "dyn_targets.lua")]
    lua = H.new_runtime(data_sources=sources, addon=ADDON)
    # only the zone under test is in the state (the others are not loaded: memory); the index keeps just its entry
    lua.execute("for _, continent in pairs(WVN7Index) do for id in pairs(continent.zones) do if id ~= %d then continent.zones[id] = nil end end end" % zone_id)
    H.fire_addon_loaded(lua)
    lua.execute(LUA)
    migrated, native = lua.eval("MigrateDockRows")(zone_id)       # boat and zeppelin landings -> the dock model, before the zone is loaded
    # the player stands at the first row so that the zone is the one under test
    first = re.search(r'\["x"\]=(-?[\d.]+),\["y"\]=(-?[\d.]+)',
                      "\n".join(line for line in (data / continent / zone / "dyn_targets.lua").read_text(encoding="utf-8").splitlines()
                                if any(m in line for m in MARKERS)))
    H.set_player(lua, float(first.group(1)), float(first.group(2)))
    if not lua.eval("SimSetup")(zone_id):
        return 0, 0, [f"{zone}: the zone does not load"], [], 0, 0
    rows = lua.eval("InteractionRows")(zone_id)
    count = len(rows)
    failures, notes, routed_total = [], [], 0
    for index in range(1, count + 1):
        routed, fails, row_id = lua.eval("CheckRow")(zone_id, index, RING[0], RING[1])
        routed_total += int(routed)
        for text in fails.values():
            # a row that no sampled start reaches has no route end to check: a note about the data (reachability is the target-sight and
            # reach gates' business), not a failure of this test
            (notes if text.startswith("no route from any") else failures).append(f"{zone}: {row_id}: {text}")
    return count, routed_total, failures, notes, int(migrated), int(native)


def main(argv):
    arguments = list(argv)
    data = Path(os.environ.get("WOWNAV_DATA", DEFAULT_DATA))
    if arguments and Path(arguments[0]).is_dir():
        data = Path(arguments.pop(0))
    only = set(arguments)
    if not data.is_dir():
        print(f"No data folder {data}")
        return 1
    zones = [z for z in zones_with_rows(data) if not only or z[1] in only]
    print(f"{len(zones)} zones with interaction rows in {data}")
    failures, rows_total, migrated_total, native_total = [], 0, 0, 0
    for continent, zone in zones:
        count, routed, fails, notes, migrated, native = check_zone(data, continent, zone)
        rows_total += count
        migrated_total += migrated
        native_total += native
        dock_text = f", docks: {migrated} rewritten to the dock model, {native} already in it" if migrated or native else ""
        print(("  OK   " if not fails else "  FAIL ") + f"{continent}/{zone}: {count} rows, {routed} routed starts{dock_text}")
        for text in fails:
            print("         " + text)
        failures.extend(fails)
        for text in notes:
            print("  NOTE " + text)
    print(f"\n{rows_total} interaction rows ({migrated_total} boat/zeppelin docks rewritten to the dock model, {native_total} already in it). "
          + (f"Failed: {len(failures)} finding(s)." if failures else "All routes end in the circle or on the node of their row."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
