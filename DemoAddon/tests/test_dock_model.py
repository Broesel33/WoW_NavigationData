"""Tests of the dock model (user decision 10.11.2026; DemoAddon). Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones.

A boat or zeppelin landing is an ordinary dynamic point on its own fixed node (no waiting circle, no waiting proof, no boarding straight). The route
ends on that node and the arrival is the normal one. The dock then says "Next point: On the ship to ..." and the route to the point on board (a row
of its own, one ordinary link away from the dock node) starts by itself. After the arrival there the context "dock reached" is set again, so that the
passive mode (choose the counterpart dock of the same route) works.

Synthetic zone (node 0 S the start, 1 B a cheaper attachment of the cell of the dock, 2 X a corner, 3 D the dock, 4 V the point on board - linked ONLY
to D -, 5 D2 the counterpart dock, 6 W the waiting point of the old model behind D2). The dyn catalog carries navFingerprint (the fingerprint of the navdata).

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_dock_model.py
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
from layered_runtime_contract import digest, lua_literal  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-1000, 1000, -1000, 1000)
FP = "AB" * 32
POINTS = [(0.0, 0.0, 5.0), (30.0, 0.0, 5.0), (0.0, 40.0, 5.0), (40.0, 40.0, 5.0), (56.0, 40.0, 5.0), (0.0, 80.0, 5.0), (0.0, 120.0, 5.0)]
LINKS = [(0, 1), (0, 2), (2, 3), (3, 4), (2, 5), (5, 6)]
S, B, X, D, V, D2, W = range(7)
ROUTE = "route:1"


def cells_for(nodes, target_node, extra):
    """The automatic cells; the cell of target_node gets the extra attachments (the cheaper one: the cells alone would end beside the dock)."""
    cells = F.auto_cells(nodes)
    point = nodes[target_node]
    for cell in cells:
        size = F.CELL_SIZE[cell["area"]]
        if (cell["gx"], cell["gy"]) == (int(point["x"] // size), int(point["y"] // size)) \
                and any(a.get("node") == target_node for a in cell["attachments"]):
            cell["attachments"] = cell["attachments"] + extra
            return cells
    raise AssertionError("the cell of the target node was not found")


def dyn_text(zone_id, rows, nav_fingerprint):
    """The dyn catalog file with the head field navFingerprint (schema7_fixture.catalog_text has no head parameter)."""
    value = {"schema": 1, "layer": "dyn", "zoneId": zone_id, "coordinateSpace": "world", "sourceSha256": "0" * 64, "converterSha256": "0" * 64}
    if nav_fingerprint is not None:
        value["navFingerprint"] = nav_fingerprint
    value["targets"] = rows
    value["payloadSha256"] = digest(value)
    header = {k: v for k, v in value.items() if k != "targets"}
    lines = ["local DynTargets = " + lua_literal(header), "DynTargets.targets = {"]
    lines += ["  " + lua_literal(row) + "," for row in rows]
    lines += ["}", "WVN7Dyn = WVN7Dyn or {}", f"WVN7Dyn[{zone_id}] = DynTargets", ""]
    return "\n".join(lines)


def row(rid, point, kind="boat", **extra):
    x, y, z = point
    value = {"id": rid, "kind": "transit_facility", "type": "transit_facility", "nameDe": "Anleger " + rid, "nameEn": "Dock " + rid,
             "category": ["transit", kind], "searchAliases": [], "nativeMapId": 0, "coordinateSpace": "world", "x": x, "y": y, "z": z,
             "zStatus": "known", "availability": "static", "source": {"provider": "test", "record": rid}}
    value.update(extra)
    return value


def dyn_rows(kind):
    ship_key = "on_ship" if kind == "boat" else "on_zeppelin"
    dock = dict(facilityRole="waiting", facilityKind=kind, transportRouteId=ROUTE, transportStopId="stop:D")
    return [
        row("dock:D", POINTS[D], kind, boardingPointId="ship:V", **dock),
        row("ship:V", POINTS[V], kind, facilityRole="onboard", facilityKind=kind, dockId="dock:D", transportRouteId=ROUTE,
            transportStopId="stop:D", nameKey=ship_key, nameParam="Darnassus"),
        row("dock:D2", POINTS[D2], kind, facilityRole="waiting", facilityKind=kind, transportRouteId=ROUTE, transportStopId="stop:D2"),
        # shifted coordinates: the coordinate rule does not find the node, n does
        row("dock:shift", (POINTS[D][0] + 3.0, POINTS[D][1], POINTS[D][2]), kind, n=D, **dict(dock, transportStopId="stop:shift")),
        # a dyn point without a node of its own (a fishing spot): the cells bind it, no "nearest node"
        {**row("spot:1", (20.0, 22.0, 5.0), "fishing"), "kind": "fishing_spot", "type": "fishing_spot", "category": ["fishing"]},
    ]


LUA = """
function Entry(id)
  local list = WowVisionNavigationTargetList(NavData, function(t) return t.id == id end, true)
  return list[1]
end
WACALLS = 0
local Dock = WowVisionNavigationDockNavigation
local original = Dock.WaitAreaReached
Dock.WaitAreaReached = function(...) WACALLS = WACALLS + 1; return original(...) end
function Resolved(id, startNode, legacy)
  local entry = Entry(id)
  if legacy then entry.dynNode, entry.navFingerprint, entry.targetNode = nil, nil, nil end
  local context = WowVisionNavigationLayerTargetContext(true, startNode)
  local r = WowVisionNavigationTargetResolver:Resolve(NavData, entry, context)
  return r.endNodeId or -1, tostring(r.quality), tostring(r.targetNode)
end
function TryActivate(mode)
  local copy = {}
  for k, v in pairs(WVN7Dyn[37]) do copy[k] = v end
  if mode == "empty" then copy.navFingerprint = ""
  elseif mode == "number" then copy.navFingerprint = 5
  elseif mode == "negative" or mode == "fraction" then
    local rows = {}
    for i, r in ipairs(copy.targets) do local c = {}; for k, v in pairs(r) do c[k] = v end; rows[i] = c end
    rows[1].n = mode == "negative" and -1 or 1.5
    copy.targets = rows
  end
  local ok, why = WowVisionNavigationTargetCatalog:ActivateZones(NavData, {{zoneId = 37, logical = WVN7Logical[37], dynamic = copy}})
  return tostring(ok) .. " " .. tostring(why)
end
function OtherRoute()
  local e = Entry("dock:D2")
  e.transportRouteId = "route:other"
  return WowVisionNavigationDockNavigation:ChoosePassive(e, NavData, "0")
end
function ListIds()
  local out = {}
  for _, e in ipairs(__T.Navigation.SearchTargets("")) do out[#out + 1] = e.id end
  return table.concat(out, ",")
end
"""


def world(kind="boat", nav_fingerprint=FP):
    nodes = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in POINTS]
    cells = cells_for(nodes, D, [{"node": B, "mask": 0xFFFF}])
    zone = C.elwynn_zone(C.ZONE, box=BOX, maps=(37,))
    sources = C.World([C.index_for([zone]), F.zone_text(C.ZONE, nodes, LINKS, cells, fingerprint=FP), F.catalog_text(C.ZONE, "logical", []),
                       dyn_text(C.ZONE, dyn_rows(kind), nav_fingerprint)])
    sources.box, sources.maps = BOX, (37,)
    L = start_runtime(sources, player=(0.0, 0.0))
    C.install_helpers(L)
    L.execute("UnitPosition = function() return playerX, playerY, 0, 0 end")
    L.execute(LUA)
    return L


def walk(L, stop, seen_wait, limit=120):
    """The player walks the waypoints of the route (as in test_wait_target_end.py) until stop(T) is true."""
    g = L.globals()
    T = g.__T
    for _ in range(limit):
        if stop(T):
            return True
        if T.Navigation.waitTargetId is not None:
            seen_wait.append(str(T.Navigation.waitTargetId))
        if T.Navigation.active and T.Navigation.path:
            wx, wy, _z = T.NodePosition(T.Navigation.path[int(T.Navigation.pathIndex)])
            g.playerX, g.playerY = wx, wy
        tick(L, 0.3)
    return stop(T)


def path_of(T):
    return [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)]


def physical(T):
    """The path without the virtual end point of the logical target."""
    if T.Navigation.path is None:
        return []
    ids = path_of(T)
    return ids[:-1] if T.Navigation.logicalTarget is not None else ids


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    print("Resolution of a dock of the new model:")
    L = world()
    resolved = L.eval("Resolved")
    end, quality, how = resolved("dock:D", nid(S))
    check("the route ends on the node of the dock (exact, node at the coordinates)", (end, quality, how) == (nid(D), "exact", "target_node"), str((end, quality, how)))
    end, quality, how = resolved("dock:D", nid(S), True)
    check("control: without the fixed node the cells decide and the route ends beside the dock", end != nid(D), str(end))
    end, quality, how = resolved("dock:shift", nid(S))
    check("a row with n and shifted coordinates is bound by n", (end, quality, how) == (nid(D), "exact", "target_node_id"), str((end, quality, how)))
    end, quality, how = resolved("ship:V", nid(S))
    check("the point on board resolves to its own node", (end, quality, how) == (nid(V), "exact", "target_node"), str((end, quality, how)))
    end, quality, how = resolved("spot:1", nid(S))
    check("a dyn row without a node is bound over the cells (no nearest node)", end != -1 and how == "nil" and quality == "approximate", str((end, quality, how)))
    entry = L.eval("Entry")("dock:D")
    check("the stored row is marked", bool(entry.dynNode) and entry.navFingerprint == FP, str((entry.dynNode, entry.navFingerprint)))

    print("Route to the dock, normal arrival, the next point:")
    g = L.globals()
    T = g.__T
    dock = g.WowVisionNavigationDockNavigation
    seen_wait = []
    started = L.eval("WowVisionNavigationLayerTargetStart")(L.eval("Entry")("dock:D"))
    check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
    check("the dock is announced as the arrival target of the route", str(T.Navigation.dockArrivalId) == "dock:D" and T.Navigation.waitTargetId is None)
    ids = physical(T)
    check("the last physical node of the route is the dock", ids[-1] == nid(D), str(ids))
    # fix2 (route regression gate, sw475a): the route of a row with its fixed node ends ON that node, no virtual end point behind it
    check("the route itself ends on the dock node (no logical end point)", T.Navigation.logicalTarget is None and path_of(T)[-1] == nid(D), str(path_of(T)))
    walk(L, lambda T: T.Navigation.boardingArrivalId is not None or not T.Navigation.active, seen_wait)
    out = texts(L)
    check("the normal target arrival was announced", any("'Anleger dock:D' erreicht!" in t for t in out), str(out[-4:]))
    check("the dock text and the next point were announced", any("Anleger 'Anleger dock:D' erreicht" in t and "das Schiff" in t and "Naechster Punkt: Am Schiff nach Darnassus" in t for t in out), str(out[-3:]))
    check("no waiting circle: waitTargetId was never set, WaitAreaReached never asked", not seen_wait and int(g.WACALLS) == 0, f"{seen_wait} {g.WACALLS}")
    check("the route to the point on board is active", bool(T.Navigation.active) and str(T.Navigation.boardingArrivalId) == "ship:V")
    ids = physical(T)
    check("it starts on the dock node and runs over the one link D-V", ids == [nid(D), nid(V)], str(ids))
    check("its last physical node is the point on board", ids[-1] == nid(V))
    check("the route to the point on board ends on its node (no logical end point)", T.Navigation.logicalTarget is None and path_of(T)[-1] == nid(V), str(path_of(T)))

    print("Arrival on board, the context of the dock, the passive mode:")
    walk(L, lambda T: not T.Navigation.active, seen_wait)
    check("the arrival on board is a normal arrival", any("'Am Schiff nach Darnassus' erreicht!" in t for t in texts(L)), str(texts(L)[-2:]))
    for _ in range(5):          # the beacon runs in OnUpdate: a dock of the new model keeps its context and gives no tone
        tick(L, 0.3)
    reached = dock.reached
    check("the context 'dock reached' is set again with the id of the dock", reached is not None and str(reached.id) == "dock:D", str(reached and reached.id))
    check("no straight, no direction tone (AlignmentTarget gives nothing)", dock.AlignmentTarget(dock, g.playerX, g.playerY, g.NavData) is None)
    check("still no waiting circle", not seen_wait and int(g.WACALLS) == 0)
    ids = str(L.eval("ListIds")())
    check("the point on board is a normal list entry", "ship:V" in ids.split(","), ids)
    check("there is no synthetic dock-boarding entry", "dock-boarding" not in ids, ids)
    check("a dock of another route is no counterpart", not L.eval("OtherRoute")() and dock.passive is None and dock.reached is not None)
    selected = L.eval("WowVisionNavigationSelectListEntry")(L.eval("Entry")("dock:D2"))
    check("choosing the counterpart dock sets the passive mode", bool(selected) and dock.passive is not None and str(dock.passive.id) == "dock:D2"
          and str(dock.passive.transportRouteId) == ROUTE and dock.reached is None, str(texts(L)[-1:]))
    check("the passive mode starts no route", not T.Navigation.active)

    print("Zeppelin:")
    L = world("zeppelin")
    g = L.globals()
    T = g.__T
    ship = L.eval("Entry")("ship:V")
    name = str(g.WowVisionNavigationTargetName(ship))
    check("the point on board is named over on_zeppelin", name == "Am Zeppelin nach Darnassus", name)
    L.eval("WowVisionNavigationLayerTargetStart")(L.eval("Entry")("dock:D"))
    walk(L, lambda T: T.Navigation.boardingArrivalId is not None or not T.Navigation.active, [])
    out = texts(L)
    check("the dock text names the zeppelin and the next point", any("den Zeppelin" in t and "Naechster Punkt: Am Zeppelin nach Darnassus" in t for t in out), str(out[-3:]))
    check("the route to the point on board runs", bool(T.Navigation.active) and physical(T) == [nid(D), nid(V)])

    print("A dyn catalog without navFingerprint (an older export):")
    L = world(nav_fingerprint=None)
    entry = L.eval("Entry")("dock:D")
    check("the rows are not marked, the cells bind them as before", not entry.dynNode and entry.layerResolution.targetNode is None, str((entry.dynNode, entry.layerResolution.targetNode)))
    entry = L.eval("Entry")("dock:shift")
    check("n is ignored without navFingerprint", entry.layerResolution.targetNode is None)

    print("A broken catalog is refused:")
    L = world()
    activate = L.eval("TryActivate")
    check("control: the valid catalog is activated", str(activate("ok")).startswith("true"), str(activate("ok")))
    check("navFingerprint empty", str(activate("empty")) == "false invalid navFingerprint", str(activate("empty")))
    check("navFingerprint not a string", str(activate("number")) == "false invalid navFingerprint", str(activate("number")))
    check("n negative", str(activate("negative")) == "false invalid node number", str(activate("negative")))
    check("n not an integer", str(activate("fraction")) == "false invalid node number", str(activate("fraction")))

    print("The old model (manual_wait) in the same runtime:")
    L = world()
    g = L.globals()
    T = g.__T
    dock = g.WowVisionNavigationDockNavigation
    x, y, z = POINTS[W]
    values = dict(id="wait:old", type="transit_facility", facilityRole="waiting", facilityKind="boat", nameDe="Alter Anleger", nameEn="Old dock",
                  category=["transit", "boat"], searchAliases=[], nativeMapId=0, x=x, y=y, z=z, nodeId=nid(W), reachable=True,
                  waitpointProofId="proof:old", transportRouteId="route:old", transportStopId="stop:old", interactionMode="manual_wait", waitingRadius=2.0,
                  boardingHintStatus="certified", boardingDirX=1.0, boardingDirY=0.0, boardingPreviewDistance=5.0)
    L.execute("Z = {}")
    table = L.globals().Z
    for key, value in values.items():
        table[key] = L.table_from(list(value)) if isinstance(value, list) else value
    L.execute("InstallSyntheticInteraction(Z)")
    started = L.eval("WowVisionNavigationLayerTargetStart")(L.eval("Entry")("wait:old"))
    check("the route starts, the waiting circle is the end", bool(started) and str(T.Navigation.waitTargetId) == "wait:old" and T.Navigation.dockArrivalId is None,
          str(texts(L)[-2:]))
    seen = []
    walk(L, lambda T: not T.Navigation.active, seen)
    entry = L.eval("Entry")("wait:old")
    check("the arrival uses the waiting circle and the old texts", dock.reached is not None and str(dock.reached.id) == "wait:old"
          and bool(dock.WaitAreaReached(dock, entry, x, y, g.NavData)) and int(g.WACALLS) > 0 and any("Richtungston" in t for t in texts(L)), str(texts(L)[-1:]))
    check("the old model still has its straight (AlignmentTarget)", dock.AlignmentTarget(dock, x, y, g.NavData) is not None)

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All dock-model tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
