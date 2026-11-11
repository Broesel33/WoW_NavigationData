"""Route to a dock of the new dock model over a portal (DemoAddon, 11.11.2026). Lua 5.1 via lupa, REAL DemoAddon files, a synthetic zone.

A boat or zeppelin landing of the new model (a dynamic point on its own fixed node, boardingPointId / a point on board "Am Schiff") is an ordinary
target for the route: portals, lifts and teleports are parts of the route to it (Teldrassil: Dolanaar -> portal Darnassus -> dock Rutheran). Still
on foot only: the one checked link from the dock to its point on board, a dock of the old model (manual_wait) and a plain waiting point. The ride of
the vehicle itself (a "board" action) is never a part of a route on foot to a dock.

Synthetic zone: S (0, 0, 5) - P (40, 0, 5) on the ground, the portal X from P to E (40, 0, 60); E - D (60, 0, 60) the dock of the new model,
D - V (76, 0, 60) its point on board, E - W (40, 40, 60) the waiting point of the old model. A "board" action (a ship ride) from D to Q (60, 80, 60)
is the control that the vehicle is no part of the route to a dock.

Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_dock_portal_route.py
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
sys.path.insert(0, str(HERE))

import schema7_fixture as F  # noqa: E402
import core_fixtures as C  # noqa: E402
from core_fixtures import nid, start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402
import test_dock_model as M  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-1000, 1000, -1000, 1000)
FP = M.FP
POINTS = [(0.0, 0.0, 5.0), (40.0, 0.0, 5.0), (40.0, 0.0, 60.0), (60.0, 0.0, 60.0), (76.0, 0.0, 60.0), (40.0, 40.0, 60.0), (60.0, 80.0, 60.0)]
LINKS = [(0, 1), (2, 3), (3, 4), (2, 5)]
S, P, E, D, V, W, Q = range(7)
PORTAL = {
    "id": "portal:x", "kind": "portal", "from": P, "to": nid(E), "toZone": 37, "toMapId": 0, "cost": 20,
    "conditions": {"status": "unconditional", "proof": "fixture"},
    "activation": {"mode": "walk_into_volume", "verified": True, "proof": "fixture"},
    "arrival": {"mode": "same_map_distinct_volume", "proof": "fixture"},
    "timing": {"timeout_seconds": 30},
    "sourceVolume": {"type": "sphere", "x": 42, "y": 0, "z": 5, "radius": 2},
    "arrivalVolume": {"type": "sphere", "x": 40, "y": 0, "z": 60, "radius": 2},
}
RIDE = {
    "id": "ride:d", "kind": "boat", "from": D, "to": nid(Q), "toZone": 37, "toMapId": 0, "cost": 30,
    "conditions": {"status": "unconditional", "proof": "fixture"},
    "activation": {"mode": "board", "verified": True, "proof": "fixture"},
    "arrival": {"mode": "same_map_distinct_volume", "proof": "fixture"},
    "timing": {"timeout_seconds": 60},
    "sourceVolume": {"type": "sphere", "x": 60, "y": 0, "z": 60, "radius": 2},
    "arrivalVolume": {"type": "sphere", "x": 60, "y": 80, "z": 60, "radius": 2},
}
LUA = """
function Entry(id)
  local list = WowVisionNavigationTargetList(NavData, function(t) return t.id == id end, true)
  return list[1]
end
"""


def world(kind="boat"):
    nodes = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in POINTS]
    cells = F.auto_cells(nodes)
    dock = dict(facilityRole="waiting", facilityKind=kind, transportRouteId=M.ROUTE, transportStopId="stop:D")
    rows = [
        M.row("dock:D", POINTS[D], kind, boardingPointId="ship:V", **dock),
        M.row("ship:V", POINTS[V], kind, facilityRole="onboard", facilityKind=kind, dockId="dock:D", transportRouteId=M.ROUTE,
              transportStopId="stop:D", nameKey="on_ship" if kind == "boat" else "on_zeppelin", nameParam="Darnassus"),
    ]
    zone = C.elwynn_zone(C.ZONE, box=BOX, maps=(37,))
    sources = C.World([C.index_for([zone]), F.zone_text(C.ZONE, nodes, LINKS, cells, fingerprint=FP, actions=[PORTAL, RIDE]),
                       F.catalog_text(C.ZONE, "logical", []), M.dyn_text(C.ZONE, rows, FP)])
    sources.box, sources.maps = BOX, (37,)
    L = start_runtime(sources, player=(0.0, 0.0))
    C.install_helpers(L)
    L.execute("UnitPosition = function() return playerX, playerY, 0, 0 end")
    L.execute(LUA)
    return L


def ok(result):
    """lupa returns a Lua multiple result as a tuple."""
    return bool(result[0] if isinstance(result, tuple) else result)


def ids_of(T):
    return [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)] if T.Navigation.path else []


def walk(L, T, frames=200, until=lambda T: False):
    for _ in range(frames):
        if not T.Navigation.active or until(T):
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

    for kind in ("boat", "zeppelin"):
        print(f"Dock of the new model ({kind}) behind a portal:")
        L = world(kind)
        g = L.globals()
        T = g.__T
        T.Navigation.manualStartNode = nid(S)
        started = ok(L.eval("WowVisionNavigationLayerTargetStart")(L.eval("Entry")("dock:D")))
        check("the route to the dock starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
        pending = T.Navigation.pendingAction
        check("its first leg ends at the pre-point of the portal and the portal travels with the route",
              ids_of(T)[-1:] == [nid(P)] and pending is not None and str(pending.actionId) == "portal:x", str(ids_of(T)))
        check("the dock is the target of the route (dockArrivalId) and the route is not foot only", str(T.Navigation.dockArrivalId) == "dock:D"
              and not pending.footOnly and not T.Navigation.footOnly)
        walk(L, T)
        actions = g.WowVisionNavigationActionNavigation
        check("at the end of the first leg the core starts the portal", actions.current is not None and str(actions.current.action.id) == "portal:x",
              str(texts(L)[-2:]))
        action = actions.current.action
        g.playerX, g.playerY = 40.0, 0.0
        actions.Cancel(actions, None)
        continued = L.eval("WowVisionNavigationActionArrival")(action)
        check("after the portal the route goes on and ends on the dock node", bool(continued) and T.Navigation.active and ids_of(T)[-1] == nid(D)
              and str(T.Navigation.dockArrivalId) == "dock:D", str(ids_of(T)))
        check("the ride of the vehicle is no part of it", all(int(p) != nid(Q) for p in ids_of(T)))
        walk(L, T, until=lambda T: T.Navigation.boardingArrivalId is not None)
        out = texts(L)
        check("the dock is reached and the route to the point on board starts by itself", any("Naechster Punkt: Am " in t for t in out) and T.Navigation.active
              and str(T.Navigation.boardingArrivalId) == "ship:V", str(out[-3:]))
        check("the route to the point on board is the one link D-V", ids_of(T)[:2] == [nid(D), nid(V)] and nid(Q) not in ids_of(T), str(ids_of(T)))
        # the point on board alone, from before the portal, is still walked on foot only: from S there is no route
        L2 = world(kind)
        T2 = L2.globals().__T
        T2.Navigation.manualStartNode = nid(S)
        started = ok(L2.eval("WowVisionNavigationLayerTargetStart")(L2.eval("Entry")("ship:V")))
        check("control: the point on board is foot only (no route from S, the portal is not used)", not started and not T2.Navigation.active, str((started, T2.Navigation.active, texts(L2)[-1:])))

    print("Old model (manual_wait) behind the same portal stays foot only:")
    L = world()
    g = L.globals()
    T = g.__T
    x, y, z = POINTS[W]
    values = dict(id="wait:old", type="transit_facility", facilityRole="waiting", facilityKind="boat", nameDe="Alter Anleger", nameEn="Old dock",
                  category=["transit", "boat"], searchAliases=[], nativeMapId=0, x=x, y=y, z=z, nodeId=nid(W), reachable=True,
                  waitpointProofId="proof:old", transportRouteId="route:old", transportStopId="stop:old", interactionMode="manual_wait", waitingRadius=2.0,
                  boardingHintStatus="certified", boardingDirX=1.0, boardingDirY=0.0, boardingPreviewDistance=5.0)
    L.execute("Z = {}")
    table = g.Z
    for key, value in values.items():
        table[key] = L.table_from(list(value)) if isinstance(value, list) else value
    L.execute("InstallSyntheticInteraction(Z)")
    T.Navigation.manualStartNode = nid(S)
    started = ok(L.eval("WowVisionNavigationLayerTargetStart")(L.eval("Entry")("wait:old")))
    check("no route to the old waiting point from S (the portal is not used)", not started and not T.Navigation.active, str((started, T.Navigation.active, texts(L)[-1:])))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All dock-portal tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
