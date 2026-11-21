"""Real-data test: every walk-in portal on one native map is a link of the route (DemoAddon, 21.11.2026). Lua 5.1 via lupa, REAL DemoAddon files,
REAL shipped data (Forever folder of the sister repository).

For every action of the data with activation walk_into_volume whose exit lies on the same native map (Stormwind's sanctum 702/704 inside one zone,
Rut'theran 542 -> Darnassus and Darnassus 527 -> Rut'theran into the neighbouring zone), a route is started from a node 20 to 60 yd before the start
node of the action to a node 20 to 60 yd beyond its exit (the first pair whose route has the action as its portal) and walked like a player: one
0.5 yd step a frame towards the current waypoint, and the game teleports him to the centre of the arrival volume the moment he is in the trigger
(the source volume, 3D, at the height of the waypoint he walks to), whatever the core does. No zone event is fired. The checks:
  * the action begins (the player stands in the trigger or on its activation point), with no "go to the pre-point" and no "wait at the pre-point",
  * the game teleports him exactly once,
  * the route goes on from the exit by itself (the zone of the exit is the active one, no time limit ran out) and arrives at the target.

Data: the Forever folder of the sister repository, or a dir in WOWNAV_DATA or the first argument. Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_portal_link_real_data.py [data dir]
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
RING = (20.0, 60.0)

LUA = r"""
local N = WowVisionNavigationNavNetwork

-- the most specific registered UiMap at the player (a city lies inside the box of its zone): the best map of the client
function SimBestMap()
  local best, area
  for id, zone in pairs(WowVisionNavigationZoneLoader.zones) do
    for ui, b in pairs(zone.worldBoxes) do
      if playerX >= b.xmin and playerX <= b.xmax and playerY >= b.ymin and playerY <= b.ymax then
        local a = (b.xmax - b.xmin) * (b.ymax - b.ymin)
        if not area or a < area then best, area = ui, a end
      end
    end
  end
  return best
end

-- the walk-in actions of a zone whose exit lies on the same native map
function WalkInActions(zoneId)
  local zone = N.LoadZone(zoneId)
  local list = {}
  for _, action in ipairs(zone and zone.actions or {}) do
    if type(action.activation) == "table" and action.activation.mode == "walk_into_volume" and action.fromNativeMap == action.toNativeMap then
      list[#list + 1] = action.id
    end
  end
  return list
end

local function Ring(id, low, high, count)
  local zone = N.LoadZone(math.floor(id / N.ZONE_BASE))
  local x, y, z = N.Position(id)
  local found = {}
  for i = 1, zone.n do
    local d = math.sqrt((zone.x[i] - x) ^ 2 + (zone.y[i] - y) ^ 2)
    if zone.area[i] ~= 2 and d >= low and d <= high then found[#found + 1] = { id = zone.base + i - 1, d = d + math.abs(zone.z[i] - z) } end
  end
  table.sort(found, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  local picks = {}
  for k = 1, math.min(count, #found) do picks[k] = found[k].id end
  return picks
end

-- a route over the action (its portal is the pending action of the first leg) -> start node, target node, or nil
function StartOver(actionId, low, high)
  local action = WowVisionNavigationActionNavigation.byId[actionId]
  local nav = __T.Navigation
  for _, startId in ipairs(Ring(action.fromNode, low, high, 8)) do
    for _, targetId in ipairs(Ring(action.toNode, low, high, 8)) do
      __T.StopNavigation(nil)
      playerX, playerY = N.Position(startId)
      nav.manualStartNode = startId
      if __T.StartNavigationToNode(targetId, "Portal test target") and nav.pendingAction and nav.pendingAction.actionId == actionId then
        return startId, targetId
      end
    end
  end
  __T.StopNavigation(nil)
  return nil
end

-- walks the route; the game teleports the player through the action under test the moment he stood in its trigger at the last frame (the server
-- answers the client a moment later, never in the same frame; sphere, 3D). The ground he walks on is the route: his height is the one of the link
-- he walks (inside the action: that of its trigger). Only this trigger teleports (other triggers near the exit, such as the portal back at
-- Darnassus, are not part of this check) -> teleports, the texts since the start, the active zone right after the action, its exit zone, whether
-- the route is still active
function Walk(actionId, maxSteps)
  local A, nav = WowVisionNavigationActionNavigation, __T.Navigation
  local action = A.byId[actionId]
  local v, to = action.sourceVolume, action.arrivalVolume
  local first = #outputs
  local teleports, z, zoneAfter = 0, nil, nil
  for _ = 1, maxSteps do
    if not nav.active and not A.current then break end
    if teleports == 0 and z and (playerX - v.x) ^ 2 + (playerY - v.y) ^ 2 + (z - v.z) ^ 2 <= v.radius ^ 2 then
      playerX, playerY, z = to.x, to.y, to.z
      teleports = teleports + 1
    elseif A.current then
      local s = A.current.action.sourceVolume
      local dx, dy = s.x - playerX, s.y - playerY
      local d = math.sqrt(dx * dx + dy * dy)
      z = s.z
      if d > 0.5 then playerX, playerY = playerX + dx / d * 0.5, playerY + dy / d * 0.5 end
    else
      local wp = nav.path[nav.pathIndex]
      local prev = nav.pathIndex > 1 and nav.path[nav.pathIndex - 1] or nil
      local wx, wy, wz = __T.NodePosition(wp)
      local dx, dy = wx - playerX, wy - playerY
      local d = math.sqrt(dx * dx + dy * dy)
      if d <= 0.5 then playerX, playerY = wx, wy else playerX, playerY = playerX + dx / d * 0.5, playerY + dy / d * 0.5 end
      z = WowVisionNavigationGuidance.Height(prev, wp, playerX, playerY) or wz
    end
    bestMapID = SimBestMap() or bestMapID
    time = time + 0.05
    __T.navFrame.scripts["OnUpdate"](__T.navFrame, 0.05)
    if teleports > 0 and zoneAfter == nil and not A.current then zoneAfter = NavData and NavData.zoneId end
  end
  local said = {}
  for i = first + 1, #outputs do said[#said + 1] = tostring(outputs[i]) end
  return teleports, said, zoneAfter, action.toZoneId, nav.active
end

function Debug()
  local nav = __T.Navigation
  return tostring(nav.active) .. " path " .. tostring(nav.path and #nav.path) .. " pending " .. tostring(nav.pendingAction and nav.pendingAction.actionId)
    .. " zone " .. tostring(NavData and NavData.zoneId) .. " pos " .. tostring(playerX) .. "/" .. tostring(playerY)
end
"""


def zone_id_of(path):
    return int(re.search(r"zoneId=(\d+)", path.read_text(encoding="utf-8", errors="replace")[:600]).group(1))


def portal_zones(data):
    """{continent: [zone dir]} of the zones with a walk-in action on their own map, plus the zones their actions lead into."""
    found = {}
    for continent in sorted(p for p in data.iterdir() if p.is_dir()):
        dirs = {zone_id_of(z / "navdata.lua"): z.name for z in continent.iterdir() if (z / "navdata.lua").is_file()}
        picked = set()
        for zone_id, name in dirs.items():
            text = (continent / name / "navdata.lua").read_text(encoding="utf-8", errors="replace")
            block = text[text.find("actions={"):] if "actions={" in text else ""
            for match in re.finditer(r'\["mode"\]="walk_into_volume".*?\["toMapId"\]=(\d+),\["toZone"\]=(\d+)', block):
                if int(match.group(2)) in dirs:
                    picked.update({name, dirs[int(match.group(2))]})
        if picked:
            found[continent.name] = sorted(picked)
    return found


def main(argv):
    data = Path(os.environ.get("WOWNAV_DATA", DEFAULT_DATA))
    if argv and Path(argv[0]).is_dir():
        data = Path(argv[0])
    if not data.is_dir():
        print(f"No data folder {data}")
        return 1
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    for continent, zones in portal_zones(data).items():
        sources = [H.read(data / continent / "index.lua")]
        ids = []
        for zone in zones:
            ids.append(zone_id_of(data / continent / zone / "navdata.lua"))
            sources += [H.read(data / continent / zone / name) for name in ("navdata.lua", "logical_targets.lua", "dyn_targets.lua")]
        lua = H.new_runtime(data_sources=sources, addon=ADDON)
        keep = " or ".join(f"id == {i}" for i in ids)
        lua.execute("for _, c in pairs(WVN7Index) do for id in pairs(c.zones) do if not (%s) then c.zones[id] = nil end end end" % keep)
        H.fire_addon_loaded(lua)
        lua.execute(LUA)
        # the position stub converts world coordinates with the boxes of the registered UiMaps
        lua.execute("BOXES = {}; for _, z in pairs(WowVisionNavigationZoneLoader.zones) do for ui, b in pairs(z.worldBoxes) do "
                    "BOXES[ui] = {b.xmin, b.xmax, b.ymin, b.ymax} end end")
        lua.execute("UnitPosition = function() return playerX, playerY, 0, %d end" % (1 if continent == "Kalimdor" else 0))
        for zone_id in ids:
            actions = list(lua.eval("WalkInActions")(zone_id).values())
            for action_id in actions:
                # the player stands in the zone of the action; the zone is activated like at the login
                lua.execute(f"""
                  local zone = WowVisionNavigationZoneLoader.zones[{zone_id}]
                  local a = WowVisionNavigationActionNavigation.byId["{action_id}"]
                  playerX, playerY = WowVisionNavigationNavNetwork.Position(a.fromNode)
                  bestMapID = SimBestMap()
                  WowVisionNavigationZoneLoader:LoadZone(zone)
                """)
                start, target = lua.eval("StartOver")(action_id, RING[0], RING[1]) or (None, None)
                label = f"{continent}/{zone_id} {action_id}"
                if start is None:
                    check(f"{label}: a route over the portal exists", False)
                    continue
                teleports, said, active_zone, to_zone, active = lua.eval("Walk")(action_id, 4000)
                said = list(said.values())
                check(f"{label}: no 'go to the pre-point' and no 'wait at the pre-point'",
                      not any("Vorpunkt von" in t or "Warte am Vorpunkt" in t for t in said), str(said[:3]))
                check(f"{label}: the action began before the teleport (walk-in text)", any("Geradeaus weitergehen" in t for t in said), str(said[:2]))
                check(f"{label}: the game teleports through it", int(teleports) == 1, f"{teleports}; at the end: {lua.eval('Debug')()}")
                check(f"{label}: the zone of the exit is active without a zone event", active_zone is not None and int(active_zone) == int(to_zone),
                      f"{active_zone} / {to_zone}")
                check(f"{label}: the route goes on by itself and arrives (no time limit)",
                      not active and any("Route von" in t for t in said) and any("erreicht" in t for t in said)
                      and not any("Zeitueberschreitung" in t for t in said), str(said[-3:]))
    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All walk-in portals of the data are links of the route."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
