"""Arrival after a teleport without a height (DemoAddon, 11.11.2026). Lua 5.1 via lupa, REAL DemoAddon files.

In the game UnitPosition delivers no usable height (none, or a constant 0).  The action module used to prove the arrival of an action only with a
reliable height, so a portal leg never completed by itself: after 30 s the action ran into its time limit and only /vn neu helped.  Now a teleport
(an action record that is walked into or clicked, or that ends on another native map; never a ride, a dive or a wind bridge) is proven in the plane:
  * the player stands on the native map of the target, in x/y inside the arrival volume of the record (no volume: the position of the exit node
    within the arrival radius),
  * on the same native map the player must also have been seen in x/y inside the source volume at an EARLIER observation (the plane of the exit
    may lie inside that of the entrance, as at the Stormwind portals, so standing there is no proof by itself),
  * no confirmation (/vn continue) is needed, and the action completes by itself as soon as the core can start the next leg.
With a reliable height nothing changes.

Part A: the action module alone (the arrival rules).  Part B: the core, the portal leg of a route, with the real OnUpdate.

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_teleport_arrival.py
(exit code 0 = all green)
"""

import os
import sys
from pathlib import Path

import lupa.lua51 as lupa

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent / "WowVisionNavigation"
TOOLS = Path(os.environ.get("WOWNAV_TOOLS", r"C:\Users\Manu\projects\WowNav\tools"))
os.environ["WOW_addon_dir"] = str(ADDON)       # the harness must load the DemoAddon, not addon/
sys.path.insert(0, str(TOOLS))

import schema7_fixture as F  # noqa: E402
import core_fixtures as C  # noqa: E402
from core_fixtures import nid, start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

# ---------------------------------------------------------------------------------------------------------------- part A: the action module

MODULE_SETUP = """
clock = 0
function GetTime() return clock end
announcements, completed = {}, 0
function say(s) table.insert(announcements, s) end
function done(a) completed = completed + 1 end
function NewAction(kind, activation, arrival)
  return {
    id = "a:x", kind = kind, fromNode = 1, toNode = 2, toZoneId = 84, fromNativeMap = 0, toNativeMap = 0, cost = 60,
    conditions = { status = "unconditional", proof = "fixture" },
    activation = { mode = activation, verified = true, proof = "fixture" },
    arrival = { mode = arrival, proof = "fixture" },
    timing = { timeout_seconds = 30 },
    -- the plane of the exit lies partly inside that of the entrance (as at the Stormwind portals)
    sourceVolume = { type = "sphere", x = 14, y = 0, z = 150, radius = 7 },
    arrivalVolume = { type = "sphere", x = 6, y = 0, z = 30, radius = 7 },
  }
end
core_ready = true
function Begin(action, gated)
  local nav = WowVisionNavigationActionNavigation
  nav.exitReady = gated and function() return core_ready end or nil
  core_ready = not gated
  nav.current, completed, clock = nil, 0, 0
  assert(nav:Initialize({ zoneId = 84 }, say, done, false))
  assert(nav:AddActions({ action }))
  assert(nav:Start(action.id))
  assert(nav:ReachedPrepoint())
  return nav
end
function At(nav, x, y, map, extra)
  local o = { nativeMapId = map or 0, position = { x = x, y = y, z = 0 }, zReliable = false, transportStopped = false }
  for k, v in pairs(extra or {}) do o[k] = v end
  return nav:Observe(o)
end
"""


def module_runtime():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute((ADDON / "Localization.lua").read_text(encoding="utf-8"))
    L.execute((ADDON / "ActionNavigation.lua").read_text(encoding="utf-8"))
    L.execute(MODULE_SETUP)
    return L


def part_a(check):
    L = module_runtime()
    new_action, begin, lua_at = L.eval("NewAction"), L.eval("Begin"), L.eval("At")

    def at(nav, x, y, map_id=0, extra=None):
        point = (extra or {}).get("arrivalPoint")
        return lua_at(nav, x, y, map_id, L.table_from({"arrivalPoint": L.table_from(point)}) if point else None)

    print("Part A: the arrival rules without a height")
    # same map, entrance and exit overlap in the plane
    nav = begin(new_action("portal", "walk_into_volume", "same_map_distinct_volume"), False)
    check("standing in the plane of the exit without having been at the source proves nothing", not at(nav, 6, 0))
    check("the first observation in the source volume is no arrival (the arrival is judged after the source was seen)", not at(nav, 12, 0))
    check("a later observation in the plane of the exit proves the arrival of the teleport", at(nav, 6, 0))
    check("... and the action completes by itself (no /vn continue)", nav.current is None and int(L.globals().completed) == 1)

    # no phase and no confirmation needed: the player teleports before he confirmed anything
    nav = begin(new_action("portal", "walk_into_volume", "same_map_distinct_volume"), False)
    check("still in the waiting phase", str(nav.current.phase) == "waiting")
    at(nav, 12, 0)
    check("the teleport is proven in the waiting phase too", at(nav, 6, 0) and int(L.globals().completed) == 1)

    # outside the exit volume: nothing
    nav = begin(new_action("portal", "walk_into_volume", "same_map_distinct_volume"), False)
    at(nav, 12, 0)
    check("a position outside the plane of the exit is no arrival", not at(nav, 40, 0) and nav.current is not None)

    # the core is not ready yet: the arrival is proven, the action waits and completes on the next tick
    nav = begin(new_action("portal", "walk_into_volume", "same_map_distinct_volume"), True)
    at(nav, 12, 0)
    check("proven, but the next leg cannot start yet: the action stays (disembarking)",
          at(nav, 6, 0) and str(nav.current.phase) == "disembarking" and int(L.globals().completed) == 0)
    L.execute("core_ready = true")
    nav.Tick(nav)
    check("the next tick completes it once the core is ready", nav.current is None and int(L.globals().completed) == 1)

    # another native map: the map change and the plane of the exit are enough
    action = new_action("portal", "walk_into_volume", "native_map_volume")
    action["toNativeMap"] = 369
    nav = begin(action, None)
    check("on the old map nothing is proven", not at(nav, 6, 0, 0))
    check("on the new map outside the exit volume nothing is proven", not at(nav, 60, 0, 369))
    check("on the new map in the plane of the exit the arrival is proven", at(nav, 6, 0, 369) and int(L.globals().completed) == 1)

    # a record without an arrival volume: the exit node within the arrival radius
    action = new_action("portal", "walk_into_volume", "native_map_volume")
    action["toNativeMap"], action["arrivalVolume"] = 369, None
    nav = begin(action, None)
    check("no arrival volume and no node position: nothing is proven", not at(nav, 6, 0, 369))
    check("the exit node outside its radius: nothing is proven", not at(nav, 6, 0, 369, {"arrivalPoint": {"x": 20.0, "y": 0.0, "radius": 1.5}}))
    check("the exit node within its radius: the arrival is proven",
          at(nav, 6, 0, 369, {"arrivalPoint": {"x": 6.5, "y": 0.0, "radius": 1.5}}) and int(L.globals().completed) == 1)

    # what is no teleport keeps the old rules
    nav = begin(new_action("dive", "dive", "same_map_distinct_volume"), None)
    at(nav, 12, 0)
    check("a dive (the player swims himself) is not proven in the plane", not at(nav, 6, 0) and nav.current is not None)
    ride = new_action("tram", "board", "transport_stop_volume")
    ride["toNativeMap"] = 369
    nav = begin(ride, None)
    check("a ride is not proven in the plane", not at(nav, 6, 0, 369) and nav.current is not None)

    # with a reliable height nothing changes: the old rules (source left, confirmed, disembark by hand)
    nav = begin(new_action("portal", "walk_into_volume", "same_map_distinct_volume"), False)
    inside_source = {"zReliable": True}
    L.execute("function Reliable(nav, x, y, z) return nav:Observe({ nativeMapId = 0, position = { x = x, y = y, z = z }, zReliable = true }) end")
    reliable = L.eval("Reliable")
    check("reliable height, not confirmed: nothing is proven", not reliable(nav, 6, 0, 30) and nav.current is not None)
    nav.Confirm(nav)
    nav.Confirm(nav)
    reliable(nav, 14, 0, 150)
    reliable(nav, 40, 0, 150)             # left the source
    check("reliable height, confirmed and the source left: the arrival is proven as before", reliable(nav, 6, 0, 30))
    check("... and the player disembarks by hand (as before)", str(nav.current.phase) == "disembarking" and int(L.globals().completed) == 0)
    check("... /vn continue completes it", nav.ReachedExit(nav) and int(L.globals().completed) == 1)
    del inside_source


# ---------------------------------------------------------------------------------------------------------------- part B: the core

BOX = (-1000, 1000, -1000, 1000)
POINTS = [(0.0, 0.0, 5.0), (40.0, 0.0, 5.0), (40.0, 0.0, 60.0), (60.0, 0.0, 60.0)]      # S, P, E, T
LINKS = [(0, 1), (2, 3)]
ACTION = {
    "id": "portal:x", "kind": "portal", "from": 1, "to": nid(2), "toZone": 37, "toMapId": 0, "cost": 20,
    "conditions": {"status": "unconditional", "proof": "fixture"},
    "activation": {"mode": "walk_into_volume", "verified": True, "proof": "fixture"},
    "arrival": {"mode": "same_map_distinct_volume", "proof": "fixture"},
    "timing": {"timeout_seconds": 30},
    "sourceVolume": {"type": "sphere", "x": 43, "y": 0, "z": 5, "radius": 2},
    "arrivalVolume": {"type": "sphere", "x": 40, "y": 0, "z": 60, "radius": 2},          # its plane lies partly inside that of the source
}
TRIGGER = dict(id="portal:g", type="transit_facility", facilityRole="entrance", facilityKind="portal", nameDe="Portal G", nameEn="Portal G",
               category=["transit", "portal"], searchAliases=[], nativeMapId=0, x=62.0, y=0.0, z=60.0, nodeId=nid(3), reachable=True,
               activationMode="walk_into_trigger", activationCaptureRadius=1.0, activationPreX=60.0, activationPreY=0.0, activationPreZ=60.0)


def world(z_value):
    nodes = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in POINTS]
    sources = C.lua_world(nodes, LINKS, box=BOX, maps=(37,))
    sources[1] = F.zone_text(37, nodes, LINKS, actions=[ACTION])
    L = start_runtime(sources, player=(0.0, 0.0))
    C.install_helpers(L)
    # the game: a constant height 0 (z_value 0) or none at all (nil)
    L.execute("UnitPosition = function() return playerX, playerY, %s, 0 end" % ("nil" if z_value is None else repr(z_value)))
    L.execute("Z = {}")
    table = L.globals().Z
    for key, value in TRIGGER.items():
        table[key] = L.table_from(list(value)) if isinstance(value, list) else value
    L.execute("InstallSyntheticInteraction(Z)")
    L.execute("""
function Entry(id)
  local list = WowVisionNavigationTargetList(NavData, function(t) return t.id == id end, true)
  return list[1]
end
""")
    return L


def walk(L, T, frames=200):
    """The player steps onto the current waypoint of the active route, one waypoint per frame, until the route stops or the trigger's pre-point is announced."""
    for _ in range(frames):
        if not T.Navigation.active or T.Navigation.activationPrepointAnnounced:
            return
        wx, wy, _z = T.NodePosition(T.Navigation.path[int(T.Navigation.pathIndex)])
        L.globals().playerX, L.globals().playerY = wx, wy
        tick(L, 0.3)


def part_b(check, z_value, label):
    print(f"\nPart B: the portal leg of a route, UnitPosition height {label}")
    L = world(z_value)
    T = L.globals().__T
    actions = L.globals().WowVisionNavigationActionNavigation
    entry = L.eval("Entry")("portal:g")
    T.Navigation.manualStartNode = nid(0)
    started = L.eval("WowVisionNavigationLayerTargetStart")(entry)
    check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
    walk(L, T)
    check("at the pre-point of the portal the core starts the action", not T.Navigation.active and actions.current is not None
          and str(actions.current.action.id) == "portal:x" and T.Navigation.actionContinuation is not None, str(texts(L)[-2:]))
    check("the player stands in the plane of the exit already (stacked levels) and nothing is proven", str(actions.current.phase) == "waiting")
    tick(L, 0.3)
    check("a frame at the pre-point proves nothing either", actions.current is not None and str(actions.current.phase) == "waiting")
    # he walks into the portal: the source volume (no teleport seen yet), then the game carries him to the exit
    L.globals().playerX, L.globals().playerY = 43.0, 0.0
    tick(L, 0.3)
    check("standing in the source volume proves nothing yet", actions.current is not None and str(actions.current.phase) == "waiting")
    L.globals().playerX, L.globals().playerY = 40.0, 0.0
    tick(L, 0.3)
    check("after the teleport the action is complete by itself (no /vn continue, no timeout)", actions.current is None, str(texts(L)[-3:]))
    check("the next leg starts on its own", T.Navigation.active and T.Navigation.activationTargetId == "portal:g", str(texts(L)[-2:]))
    path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)] if T.Navigation.path else []
    check("the next leg runs from the exit node to the node of the trigger", bool(path) and path[0] == nid(2) and path[-1] == nid(3), str(path))
    walk(L, T)
    check("it ends in the activation of the trigger (pre-point announced)", T.Navigation.active and bool(T.Navigation.activationPrepointAnnounced),
          str(texts(L)[-2:]))
    # time passes: no time limit can cancel anything now
    for _ in range(5):
        L.globals().time = L.globals().time + 20
        tick(L, 0.3)
    check("no timeout cancels the new leg", T.Navigation.active)


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    part_a(check)
    part_b(check, 0, "constant 0")
    part_b(check, None, "missing (nil)")
    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All teleport arrival tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
