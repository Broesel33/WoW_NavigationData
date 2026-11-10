"""A trigger target whose pre-point only another action reaches (DemoAddon, 10.11.2026). Lua 5.1 via lupa, REAL DemoAddon files, a synthetic zone.

The room of portal 702 (Wizard Sanctum, Stormwind) is a part of the network of its own: the mesh joins it to the city only through portal 704 (the
teleport down from the tower).  Portals are parts of a route (chapter 02 rule 11), but the route to a trigger used to be foot only
(WowVisionNavigationLayerTargetStart), so the core found no way to 702 (or a wrong one far away).  Now:
  * the route to the trigger goes through the other action: its first leg ends at the pre-point of that action and the core starts the action there,
    not the activation of the trigger,
  * the activation of the trigger travels with the rest of the route: after the action (WowVisionNavigationActionArrival) the leg ends on the node of
    the trigger and the activation begins there (the pre-point is announced),
  * a control: with the old foot-only rule there is no route.

Synthetic zone: S (0, 0, 5) - P (40, 0, 5) on the ground, the action X from P to E (40, 0, 60); E - T (60, 0, 60) up there, T the pre-point of the
trigger G (capture circle 1 yd around (62, 0, 60)).

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_trigger_after_action.py
(exit code 0 = all green)
"""

import os
import sys
from pathlib import Path

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

BOX = (-1000, 1000, -1000, 1000)
POINTS = [(0.0, 0.0, 5.0), (40.0, 0.0, 5.0), (40.0, 0.0, 60.0), (60.0, 0.0, 60.0)]      # S, P, E, T
LINKS = [(0, 1), (2, 3)]
ACTION = {
    "id": "portal:x", "kind": "portal", "from": 1, "to": nid(2), "toZone": 37, "toMapId": 0, "cost": 20,
    "conditions": {"status": "unconditional", "proof": "fixture"},
    "activation": {"mode": "walk_into_volume", "verified": True, "proof": "fixture"},
    "arrival": {"mode": "same_map_distinct_volume", "proof": "fixture"},
    "timing": {"timeout_seconds": 30},
    "sourceVolume": {"type": "sphere", "x": 42, "y": 0, "z": 5, "radius": 2},
    "arrivalVolume": {"type": "sphere", "x": 40, "y": 0, "z": 60, "radius": 2},
}
TRIGGER = dict(id="portal:g", type="transit_facility", facilityRole="entrance", facilityKind="portal", nameDe="Portal G", nameEn="Portal G",
               category=["transit", "portal"], searchAliases=[], nativeMapId=0, x=62.0, y=0.0, z=60.0, nodeId=nid(3), reachable=True,
               activationMode="walk_into_trigger", activationCaptureRadius=1.0, activationPreX=60.0, activationPreY=0.0, activationPreZ=60.0)

LUA = """
function Entry(id)
  local list = WowVisionNavigationTargetList(NavData, function(t) return t.id == id end, true)
  return list[1]
end
function FootOnlyRoute(startNode, endNode)
  local r = WowVisionNavigationNavNetwork.RouteIds(startNode, endNode, nil, true)
  return r ~= nil
end
"""


def world():
    nodes = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in POINTS]
    sources = C.lua_world(nodes, LINKS, box=BOX, maps=(37,))
    sources[1] = F.zone_text(37, nodes, LINKS, actions=[ACTION])
    L = start_runtime(sources, player=(0.0, 0.0))
    C.install_helpers(L)
    L.execute("UnitPosition = function() return playerX, playerY, 0, 0 end")
    L.execute("Z = {}")
    table = L.globals().Z
    for key, value in TRIGGER.items():
        table[key] = L.table_from(list(value)) if isinstance(value, list) else value
    L.execute("InstallSyntheticInteraction(Z)")
    L.execute(LUA)
    return L


def walk(L, T, frames=200):
    """The player steps onto the current waypoint of the active route, one waypoint per frame, until the route stops or the trigger's pre-point is announced."""
    for _ in range(frames):
        if not T.Navigation.active or T.Navigation.activationPrepointAnnounced:
            return
        wx, wy, _z = T.NodePosition(T.Navigation.path[int(T.Navigation.pathIndex)])
        L.globals().playerX, L.globals().playerY = wx, wy
        tick(L, 0.3)


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    print("A trigger behind another action:")
    L = world()
    T = L.globals().__T
    check("control: on foot the pre-point of the trigger is not reachable", not L.eval("FootOnlyRoute")(nid(0), nid(3)))
    entry = L.eval("Entry")("portal:g")
    check("the list resolves the trigger to its node", entry is not None and int(entry.nodeId) == nid(3), str(entry and entry.nodeId))
    T.Navigation.manualStartNode = nid(0)
    started = L.eval("WowVisionNavigationLayerTargetStart")(entry)
    check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
    path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)] if T.Navigation.path else []
    pending = T.Navigation.pendingAction
    check("its first leg ends at the pre-point of the other action", bool(path) and path[-1] == nid(1), str(path))
    check("the action and the activation of the trigger travel with the rest of the route",
          pending is not None and str(pending.actionId) == "portal:x" and str(pending.activationTargetId) == "portal:g")
    check("the first leg carries no activation of the trigger", T.Navigation.activationTarget is None and T.Navigation.activationTargetId is None)
    walk(L, T)
    actions = L.globals().WowVisionNavigationActionNavigation
    check("at the end of the first leg the core starts the action", not T.Navigation.active and actions.current is not None
          and str(actions.current.action.id) == "portal:x" and T.Navigation.actionContinuation is not None, str(texts(L)[-2:]))
    # the game carries the player through the portal: he stands at its exit, the action module reports the action complete
    action = actions.current.action
    L.globals().playerX, L.globals().playerY = 40.0, 0.0
    actions.Cancel(actions, None)
    continued = L.eval("WowVisionNavigationActionArrival")(action)
    check("after the action the route goes on", bool(continued) and T.Navigation.active, str(texts(L)[-2:]))
    path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)] if T.Navigation.path else []
    check("the leg after the action ends on the node of the trigger", bool(path) and path[-1] == nid(3), str(path))
    check("and carries its activation", T.Navigation.activationTargetId == "portal:g" and T.Navigation.activationTarget is not None)
    walk(L, T)
    check("the activation begins on the trigger's own node (pre-point announced, the navigation stays active)",
          T.Navigation.active and bool(T.Navigation.activationPrepointAnnounced), str(texts(L)[-2:]))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All trigger-after-action tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
