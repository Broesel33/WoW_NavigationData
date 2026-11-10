"""Tests of the fixed node of a logical target (Weg B, user decision 10.11.2026; DemoAddon). Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones.

The resolver binds a target of a catalog with navFingerprint to its node: n of the row when the loaded zone has the catalog's fingerprint, else the node at the
target's coordinates (half the export resolution, 0.05 yd, the smallest height difference within the band), else (a target of a target update, p) the nearest
physical node at its height; every other target (an older catalog, live targets) over the cells as before. The coordinate rule is the twin of
tools/wegenetz/target_nodes.py (WowNav), checked here point by point.

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_target_nodes.py
(exit code 0 = all green)
"""

import os
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent / "WowVisionNavigation"
TOOLS = Path(os.environ.get("WOWNAV_TOOLS", r"C:\Users\Manu\projects\WowNav\tools"))
os.environ["WOW_addon_dir"] = str(ADDON)       # the harness must load the DemoAddon, not addon/
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(TOOLS / "wegenetz"))

import schema7_fixture as F  # noqa: E402
import core_fixtures as C  # noqa: E402
from core_fixtures import nid, start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402
import logical_catalog as LC  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-1000, 1000, -1000, 1000)
FP = "AB" * 32
# node 0: the start; node 1: the raw position of "plain" (and of "low" on the floor); node 2: a gallery 2 yd above it; node 3: the access point of
# "wall" (the target stands 3 yd inside the wall); nodes 4/5: the two levels of "stair"; node 6: a plain waypoint near "later" (a target of an update);
# node 7: a water node (the fish 6 yd under its surface)
POINTS = [(0.0, 0.0, 5.0), (20.0, 0.0, 5.0), (20.0, 0.0, 7.0), (40.0, 3.0, 5.0), (60.0, 0.0, 5.0), (60.0, 0.0, 15.0), (80.0, 0.0, 5.0), (100.0, 0.0, 0.0)]
LINKS = [(0, 1), (1, 2), (1, 3), (3, 4), (4, 5), (4, 6), (6, 7)]


def row(tid, x, y, z=None, levels=None, **extra):
    value = {"id": tid, "kind": "npc", "type": "creature", "entry": 7, "nameEn": "Guard " + tid, "nameDe": "Wache " + tid, "category": ["npc"],
             "searchAliases": [], "nativeMapId": 0, "coordinateSpace": "world", "x": x, "y": y, "zStatus": "unknown" if z is None else "known",
             "availability": "static", "source": {"provider": "test", "record": tid}}
    if z is not None:
        value["z"] = z
    if levels:
        value["levels"] = levels
    value.update(extra)
    return value


ROWS = [row("plain", 20.04, -0.03, 5.6), row("gallery", 20.0, 0.0, 6.6), row("wall", 40.0, 0.0, 5.0, n=3), row("stair", 60.0, 0.0, levels=[5.0, 15.0]),
        row("deck", 60.0, 0.0, levels=[5.0, 15.0], n=[False, 5]), row("later", 82.0, 2.0, 5.0, approx=True), row("fish", 100.0, 0.0, -6.0, n=7),
        row("far", 400.0, 0.0, 5.0)]


def world(fingerprint=FP, nav_fingerprint=FP, rows=ROWS, cells=None):
    nodes = [F.node(x, y, z, area="WATER" if i == 7 else "OPEN") for i, (x, y, z) in enumerate(POINTS)]
    zone = C.elwynn_zone(C.ZONE, box=BOX, maps=(37,))
    catalog_rows = [{**r, "n": (None if r["n"] is False else r["n"]) if not isinstance(r.get("n"), list) else [None if v is False else v for v in r["n"]]}
                    if "n" in r else r for r in rows]
    if nav_fingerprint is None:
        catalog_rows = [{k: v for k, v in r.items() if k != "n"} for r in catalog_rows]
    sources = C.World([C.index_for([zone]), F.zone_text(C.ZONE, nodes, LINKS, cells, fingerprint=fingerprint),
                       LC.render(LC.encode(C.ZONE, catalog_rows, 0, "0" * 64, None, nav_fingerprint=nav_fingerprint)), F.catalog_text(C.ZONE, "dyn", [])])
    sources.box, sources.maps = BOX, (37,)
    L = start_runtime(sources, player=(0.0, 0.0))
    L.execute("""
        R, N = WowVisionNavigationTargetResolver, WowVisionNavigationNavNetwork
        ROWS = {}
        for _, t in ipairs(WowVisionNavigationTargetCatalog.ExpandCatalog(WVN7Logical[37])) do t.zoneId = 37; ROWS[t.id] = t end
        function Bind(id, band, refuse)
            local route = function(node) if refuse and refuse[node] then return nil end return {node}, 1 end
            local r = R:Resolve(NavData, ROWS[id], {heightBand = band, route = route})
            return tostring(r.endNodeId and (r.endNodeId - N.ZONE_BASE * 37) or nil) .. " " .. tostring(r.quality) .. " " .. tostring(r.targetNode)
        end
    """)
    return L


def bind(L, target, band=None, refuse=None):
    lua = L.eval("function(id, band, refuse) return Bind(id, band, refuse) end")
    return str(lua(target, band, L.table_from({nid(i): True for i in refuse}) if refuse else None))


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    print("The node of a target (Weg B):")
    L = world()
    check("coordinates: the node within 0.05 yd, the nearest height", bind(L, "plain") == "1 exact target_node", bind(L, "plain"))
    check("coordinates: a gallery 2 yd above the floor is its own level", bind(L, "gallery") == "2 exact target_node", bind(L, "gallery"))
    check("n: the node of a target in the wall", bind(L, "wall") == "3 exact target_node_id", bind(L, "wall"))
    check("levels without n: each level by its coordinates", (bind(L, "stair", 1), bind(L, "stair", 2)) == ("4 exact target_node", "5 exact target_node"),
          str((bind(L, "stair", 1), bind(L, "stair", 2))))
    check("levels with n: false = the coordinates, a number = n", (bind(L, "deck", 1), bind(L, "deck", 2)) == ("4 exact target_node", "5 exact target_node_id"))
    check("a water node holds the fish under its surface", bind(L, "fish") == "7 exact target_node_id", bind(L, "fish"))
    check("p (a target of an update): the nearest node at its height, approximate", bind(L, "later") == "6 approximate nearest_node", bind(L, "later"))
    check("no node within the radius: no target in the network", bind(L, "far").startswith("nil unroutable"), bind(L, "far"))
    check("no route to the node: the nearest nodes one by one", bind(L, "plain", refuse=[1]) == "2 approximate nearest_node", bind(L, "plain", refuse=[1]))
    r = L.eval("R:Resolve(NavData, ROWS['later'], {})")
    plain = str(L.eval("WowVisionNavigationTargetSelection:Describe(ROWS['later'], nil)"))
    described = str(L.eval("WowVisionNavigationTargetSelection:Describe(ROWS['later'], R:Resolve(NavData, ROWS['later'], {}))"))
    check("the fallback says how far the node is (the description of the list)", r.deltaXY is not None and abs(r.deltaXY - 2.828) < 0.01
          and len(described) > len(plain), f"{r.deltaXY} {described!r}")

    print("Another navdata (a partial deploy):")
    L = world(fingerprint="CD" * 32)
    check("n is not used, the coordinates still find the node", bind(L, "plain") == "1 exact target_node", bind(L, "plain"))
    check("the row with n falls back to the cells", bind(L, "wall").split()[2] == "nil", bind(L, "wall"))
    check("no nearest-node fallback for a catalog of another navdata", bind(L, "later").split()[2] == "nil", bind(L, "later"))
    check("noted once in the saved variables", "another navdata" in str(L.eval("WowVisionNavigationDB.targetNodeNote")))

    print("An older catalog (no navFingerprint):")
    L = world(nav_fingerprint=None)
    check("bound over the cells as before", bind(L, "plain").split()[2] == "nil" and bind(L, "plain").split()[0] != "nil", bind(L, "plain"))
    check("the catalog validation refuses a broken n", str(L.eval("""(function()
        local c = {} for k, v in pairs(WVN7Logical[37]) do c[k] = v end
        c.targets = {{"x", 1, 1, 2, 3, n = -1}}; c.expanded, c.classObjects = nil, nil
        local ok, why = WowVisionNavigationTargetCatalog.ValidateCatalog(c) return tostring(ok) .. " " .. tostring(why) end)()""")) == "nil invalid node number")

    print("The coordinate rule equals the pipeline's (tools/wegenetz/target_nodes.py):")
    import target_nodes as TN
    from schema7_codec import decode
    rng = random.Random(10)
    pts = [(round(rng.uniform(-50, 50), 1), round(rng.uniform(-50, 50), 1), round(rng.uniform(0, 12), 1)) for _ in range(300)]
    pts += [(p[0] + 0.1, p[1], p[2] + 1.0) for p in pts[:60]] + [(p[0], p[1], p[2] + 2.5) for p in pts[60:120]]
    nodes = [F.node(x, y, z, area="WATER" if k % 17 == 0 else "OPEN") for k, (x, y, z) in enumerate(pts)]
    text = F.zone_text(C.ZONE, nodes, [(0, 1)], fingerprint=FP)
    index = TN.NodeIndex(decode(text)["nodes"])
    sources = C.World([C.index_for([C.elwynn_zone(C.ZONE, box=BOX, maps=(37,))]), text, F.catalog_text(C.ZONE, "logical", []), F.catalog_text(C.ZONE, "dyn", [])])
    sources.box, sources.maps = BOX, (37,)
    M = start_runtime(sources, player=(0.0, 0.0))
    at = M.eval("function(x, y, z) local zone = WowVisionNavigationNavNetwork.LoadZone(37); local i = WowVisionNavigationNavNetwork.TargetNodeAt(zone, x, y, z, 3.0); return i and (i - 1) or -1 end")
    queries = [(p[0] + rng.choice((-0.05, -0.049, 0.0, 0.03, 0.05, 0.051, 0.07)), p[1] + rng.choice((-0.05, 0.0, 0.049, 0.05)), p[2] + rng.uniform(-4, 4)) for p in pts]
    differ = [(q, index.hit(*q, 3.0), at(*q)) for q in queries if (index.hit(*q, 3.0) if index.hit(*q, 3.0) is not None else -1) != at(*q)]
    hits = sum(1 for q in queries if index.hit(*q, 3.0) is not None)
    check(f"{len(queries)} points, {hits} hits: Lua and Python agree", not differ, str(differ[:3]))

    print("A route to a target with a node, the arrival and the height hint:")
    L = world()
    g = L.globals()
    T = g.__T
    T.SetHeightAnchor(5.0, 0, 0)
    started = L.eval("WowVisionNavigationLayerTargetStart(ROWS['gallery'])")
    check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-3:]))
    path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)]
    check("it ends at the node of the target, then the target itself", nid(2) in path and path[-2] == nid(2), str(path))
    hint = L.eval("WowVisionNavigationComputeHeightHint(ROWS['gallery'], Navigation and Navigation.layerTargetResult or nil)")
    check("the height hint is computed from the node (no error)", True, str(hint))
    for _ in range(40):
        if not T.Navigation.active:
            break
        waypoint = T.Navigation.path[int(T.Navigation.pathIndex)]
        wx, wy, _z = T.NodePosition(waypoint)
        g.playerX, g.playerY = wx, wy
        tick(L, 0.3)
    check("the route arrives", not T.Navigation.active and any("erreicht" in t for t in texts(L)), str(texts(L)[-2:]))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All target-node tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
