"""Tests of the end of a route to a certified interaction (DemoAddon, 10.11.2026). Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones.

A waiting point (manual_wait, waiting circle) and an activation area (walk_into_trigger, capture circle) lie exactly on a node of the network. The resolver
used to take the cheapest pair of checked attachments of the target cell for them, like for every ordinary target, and the route ended on another attachment of
the cell (a node 40 yd away, a link point 3 yd before the node): beside the circle, so Dock:WaitAreaReached never became true. Now the route ends in the circle of
the row, on its own node.

Two synthetic zones, each with a target cell that has several checked attachments:
  far:  the waiting point W at the end of the long way, a cheaper attachment B of the same cell on a short branch (the Feralas case)
  near: the waiting point W2 behind W, a link point 3 yd before W2 on the incoming link (the Menethil case)
plus a negative control (the old behaviour, switched on in the test) that proves the zones do show the fault.

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_wait_target_end.py
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
# node 0 S the start, 1 B the short branch (30 yd), 2 X the corner of the long way, 3 W the waiting point (40, 40), 4 W2 behind W (80, 40)
POINTS = [(0.0, 0.0, 5.0), (30.0, 0.0, 5.0), (0.0, 40.0, 5.0), (40.0, 40.0, 5.0), (80.0, 40.0, 5.0)]
LINKS = [(0, 1), (0, 2), (2, 3), (3, 4)]
LINK_T = 237            # 237/256 of a 40 yd link: the link point lies 2.97 yd before the end node


def cells_for(nodes, target_node, extra):
    """The automatic cells; the cell of target_node gets the extra attachments (more checked attachments, full field mask)."""
    cells = F.auto_cells(nodes)
    point = nodes[target_node]
    for cell in cells:
        size = F.CELL_SIZE[cell["area"]]
        if (cell["gx"], cell["gy"]) == (int(point["x"] // size), int(point["y"] // size)) \
                and any(a.get("node") == target_node for a in cell["attachments"]):
            cell["attachments"] = cell["attachments"] + extra
            return cells
    raise AssertionError("the cell of the target node was not found")


def world(case, row):
    nodes = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in POINTS]
    target_node = 3 if case == "far" else 4
    extra = [{"node": 1, "mask": 0xFFFF}] if case == "far" else []
    extra += [{"link": (2, 3) if case == "far" else (3, 4), "t": LINK_T, "mask": 0xFFFF}]
    cells = cells_for(nodes, target_node, extra)
    sources = C.lua_world(nodes, LINKS, cells=cells, box=BOX, maps=(37,))
    L = start_runtime(sources, player=(0.0, 0.0))
    C.install_helpers(L)
    L.execute("UnitPosition = function() return playerX, playerY, 0, 0 end")
    x, y, z = POINTS[target_node]
    values = dict(id="wait:" + case, type="transit_facility", facilityRole="waiting", facilityKind="boat", nameDe="Anleger", nameEn="Dock",
                  category=["transit", "boat"], searchAliases=[], nativeMapId=0, x=x, y=y, z=z, nodeId=nid(target_node), reachable=True,
                  waitpointProofId="proof:" + case, transportRouteId="route", transportStopId="stop", **row)
    L.execute("Z = {}")
    table = L.globals().Z
    for key, value in values.items():
        table[key] = L.table_from(list(value)) if isinstance(value, list) else value
    L.execute("InstallSyntheticInteraction(Z)")
    return L, target_node


WAIT = dict(interactionMode="manual_wait", waitingRadius=2.0, boardingHintStatus="certified", boardingDirX=1.0, boardingDirY=0.0, boardingPreviewDistance=5.0)
TRIGGER = dict(activationMode="walk_into_trigger", activationCaptureRadius=1.0, activationPreX=0.0, activationPreY=0.0, activationPreZ=5.0)

LUA = """
function Entry(id)
  local list = WowVisionNavigationTargetList(NavData, function(t) return t.id == id end, true)
  return list[1]
end
function EndOf(entry, startNode, legacy)
  local R = WowVisionNavigationTargetResolver
  local keep = R.EndRadius
  if legacy then R.EndRadius = function() return nil end end
  local context = WowVisionNavigationLayerTargetContext(true, startNode)
  local r = R:Resolve(NavData, entry, context)
  R.EndRadius = keep
  local x, y = __T.NodePosition(r.endNodeId)
  return r.endNodeId, x, y, r.path and #r.path or 0
end
"""


def end_of(L, entry, legacy=False):
    result = L.eval("EndOf")(entry, nid(0), legacy)
    return int(result[0]), float(result[1]), float(result[2])


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    for case, label in (("far", "the cheaper attachment of the cell is another node (Feralas)"),
                        ("near", "the cheaper attachment is a link point 3 yd before the node (Menethil)")):
        print(f"Waiting point, {label}:")
        L, node = world(case, WAIT)
        L.execute(LUA)
        entry = L.eval("Entry")("wait:" + case)
        check("the list resolves it to its node", entry is not None and int(entry.nodeId) == nid(node), str(entry and entry.nodeId))
        legacy = end_of(L, entry, legacy=True)
        check("control: without the rule the route ends beside the circle", legacy[0] != nid(node), str(legacy))
        end = end_of(L, entry)
        check("the route ends on the node of the waiting point", end[0] == nid(node), str(end))
        check("the end lies in the waiting circle", (end[1] - POINTS[node][0]) ** 2 + (end[2] - POINTS[node][1]) ** 2 <= 4.0, str(end))

        # the whole chain: start, walk, arrival
        L.execute("T = __T")
        started = L.eval("WowVisionNavigationLayerTargetStart")(entry)
        T = L.globals().__T
        check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
        path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)]
        check("its last waypoint is the waiting point", path[-1] == nid(node), str(path))
        for _ in range(60):
            if not T.Navigation.active:
                break
            waypoint = T.Navigation.path[int(T.Navigation.pathIndex)]
            wx, wy, _z = T.NodePosition(waypoint)
            L.globals().playerX, L.globals().playerY = wx, wy
            tick(L, 0.3)
        dock = L.globals().WowVisionNavigationDockNavigation
        check("the arrival at the waiting point is reported", not T.Navigation.active and dock.reached is not None
              and dock.WaitAreaReached(dock, entry, *POINTS[node][:2], L.globals().NavData), str(texts(L)[-2:]))

    print("Activation area (walk_into_trigger):")
    L, node = world("far", TRIGGER)
    L.execute(LUA)
    entry = L.eval("Entry")("wait:far")
    legacy = end_of(L, entry, legacy=True)
    end = end_of(L, entry)
    check("control: without the rule the route ends on another attachment", legacy[0] != nid(node), str(legacy))
    check("the route ends on the node of the area", end[0] == nid(node), str(end))

    print("An ordinary target keeps the cost comparison (the cheapest pair of attachments):")
    L, node = world("far", dict(WAIT))
    L.execute(LUA)
    L.execute("Z2 = {}; for k, v in pairs(Entry('wait:far')) do Z2[k] = v end; Z2.interactionMode, Z2.waitingRadius = nil, nil")
    plain = L.globals().Z2
    end = end_of(L, plain)
    check("without a circle the route still ends on the cheaper attachment", end[0] != nid(node), str(end))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All wait-target tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
