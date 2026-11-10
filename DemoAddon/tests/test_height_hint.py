"""Tests of the general height hint (DemoAddon): "Target is above/below, about N yards" at the route start and at the arrival.
Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones; harness shared with test_floor_arrival.py. Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_height_hint.py
(exit code 0 = all green)
"""

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent / "WowVisionNavigation"
TOOLS = Path(os.environ.get("WOWNAV_TOOLS", r"C:\Users\Manu\projects\WowNav\tools"))
os.environ["WOW_addon_dir"] = str(ADDON)
sys.path.insert(0, str(TOOLS))

import schema7_fixture as F  # noqa: E402
from core_fixtures import lua_world, nid, start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-100, 100, -100, 100)
NODES = [F.node(0, 0, 5.0, area="FINE", radius=0.5), F.node(20, 0, 5.0, area="FINE", radius=0.5)]
LINKS = [(0, 1)]


def world():
    L = start_runtime(lua_world(NODES, LINKS, box=BOX), player=(0, 0))
    L.globals().__T.SetHeightAnchor(5.0, 0, 0)
    return L


def start(L, source, result=None):
    """Starts the route to node 1, then lets the core compute the hint for the given target source (as the start does)."""
    g = L.globals()
    T = g.__T
    T.StartNavigationToNode(nid(1), "Gnomish Tome")
    assert T.Navigation.active, texts(L)
    lua = L.eval("function(s, r) return WowVisionNavigationComputeHeightHint(s, r) end")
    return lua(L.table_from(source) if source is not None else None, L.table_from(result) if result is not None else None)


def walk(L):
    T = L.globals().__T
    for _ in range(40):
        if not T.Navigation.active:
            break
        waypoint = T.Navigation.path[int(T.Navigation.pathIndex)]
        wx, wy, _z = T.NodePosition(waypoint)
        L.globals().playerX, L.globals().playerY = wx, wy
        tick(L, 0.3)
    return T.Navigation


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    print("Guidance.HeightHint:")
    L = world()
    G = L.eval("WowVisionNavigationGuidance")
    h = G.HeightHint(16.5, 5.0)
    check("above by 11.5 yd: 'above', 12 yards (rounded)", h and h.direction == "above" and h.yards == 12)
    h = G.HeightHint(-6.0, 5.0)
    check("below by 11 yd: 'below'", h and h.direction == "below" and h.yards == 11)
    check("difference inside the tolerance (3 yd): no hint", G.HeightHint(8.0, 5.0) is None and G.HeightHint(2.0, 5.0) is None)
    check("just above the tolerance: hint", G.HeightHint(8.2, 5.0) is not None)
    check("target without height: no hint", G.HeightHint(None, 5.0) is None)
    check("route end without height: no hint", G.HeightHint(10.0, None) is None)
    L.execute("WowVisionNavigationDB.targetTolerance = 6")
    check("the threshold follows the player tolerance /vn tolerance", G.HeightHint(10.0, 5.0) is None
          and G.HeightHint(12.0, 5.0) is not None)

    print("Route start:")
    L = world()
    text = start(L, {"z": 16.5})
    check("target 11.5 yd above the route end: German hint", text == "Ziel liegt erhöht, etwa 12 Yards.", str(text))
    L = world()
    text = start(L, {"z": -7.0})
    check("target 12 yd below: German hint", text == "Ziel liegt tiefer, etwa 12 Yards.", str(text))
    L = world()
    L.execute("WowVisionNavigationDB.language = 'en'")
    text = start(L, {"z": 16.5})
    check("English: 'Target is above, about 12 yards.'", text == "Target is above, about 12 yards.", str(text))
    L = world()
    L.execute("WowVisionNavigationDB.language = 'en'")
    text = start(L, {"z": -7.0})
    check("English below", text == "Target is below, about 12 yards.", str(text))
    L = world()
    check("inside the tolerance: no announcement", start(L, {"z": 7.5}) is None)
    L = world()
    check("target without height and without level: no announcement", start(L, {}, {"zUnknown": True}) is None)
    L = world()
    text = start(L, {}, {"queryZ": 16.5})
    check("level choice: the height of the chosen level counts (queryZ)", text == "Ziel liegt erhöht, etwa 12 Yards.", str(text))
    L = world()
    text = start(L, {"z": 16.5}, {"queryZ": 5.0})
    check("source height wins over the level", text is not None)
    L = world()
    check("water target: no announcement", start(L, {"z": 16.5}, {"endpointSurface": "water"}) is None)
    L = world()
    check("no source (plain node route): no announcement", start(L, None) is None)

    print("Arrival at the route end:")
    L = world()
    start(L, {"z": 16.5})
    nav = walk(L)
    check("arrival names the target and the height hint", not nav.active
          and any("erreicht" in t and "Ziel liegt erhöht, etwa 12 Yards." in t for t in texts(L)), str(texts(L)[-2:]))
    check("the hint is cleared with the route", nav.heightHint is None)
    L = world()
    start(L, {"z": 7.5})
    nav = walk(L)
    check("inside the tolerance: arrival without a hint", not nav.active and any("erreicht" in t for t in texts(L))
          and not any("Ziel liegt" in t for t in texts(L)))
    L = world()
    L.execute("WowVisionNavigationDB.heightAwareArrival = true")
    start(L, {"z": -7.0})
    nav = walk(L)
    check("with /vn floor on (no second level here): hint unchanged, arrival as before", not nav.active
          and any("erreicht" in t and "Ziel liegt tiefer, etwa 12 Yards." in t for t in texts(L)))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All height-hint tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
