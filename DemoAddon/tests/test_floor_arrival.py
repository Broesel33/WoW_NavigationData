"""Tests of the height-aware arrival (/vn floor, DemoAddon). Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones.

Reuses the harness of the WowNav repo (tools/). Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_floor_arrival.py
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
from core_fixtures import lua_world, nid, start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-100, 100, -100, 100)
# Target column at x=20: lower floor z 5 (node 2), upper floor z 14 (node 3); start column at x=0 (nodes 0 and 1).
# The lonely target at x=60 has only one level (node 4, linked to node 2).
NODES = [F.node(0, 0, 5.0, area="FINE", radius=0.5), F.node(0, 0, 14.0, area="FINE", radius=0.5),
         F.node(20, 0, 5.0, area="FINE", radius=0.5), F.node(20, 0, 14.0, area="FINE", radius=0.5),
         F.node(60, 0, 5.0, area="FINE", radius=0.5)]
LINKS = [(0, 2), (1, 3), (0, 1), (2, 3), (2, 4)]


def world(floor_on):
    L = start_runtime(lua_world(NODES, LINKS, box=BOX), player=(0, 0))
    g = L.globals()
    if floor_on is not None:
        g.WowVisionNavigationDB.heightAwareArrival = floor_on
    return L


def arrive(L, target, estimate, name="Testziel"):
    """Starts a route to the node and steps on every waypoint in turn.  estimate: the height the route state reports
    (a stale value is simulated by replacing Guidance.Height); None keeps the real route interpolation."""
    T = L.globals().__T
    T.SetHeightAnchor(5.0, 0, 0)               # the start is on the lower floor
    T.StartNavigationToNode(nid(target), name)
    assert T.Navigation.active, texts(L)
    if estimate is not None:
        L.execute("WowVisionNavigationGuidance.Height = function() return %r end" % float(estimate))
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

    print("Floor analysis (Guidance.ArrivalFloor):")
    L = world(True)
    G = L.eval("WowVisionNavigationGuidance")
    r = G.ArrivalFloor(20, 0, 14.0, 14.0)
    check("target on the upper floor: floor 'upper', no wrong level", r and r.floor == "upper" and not r.wrongLevel)
    r = G.ArrivalFloor(20, 0, 5.0, None)
    check("target on the lower floor: floor 'lower'", r and r.floor == "lower" and not r.wrongLevel)
    r = G.ArrivalFloor(20, 0, 14.0, 5.0)
    check("estimate clearly on the other level: wrong level", r and r.wrongLevel is True)
    r = G.ArrivalFloor(20, 0, 14.0, None)
    check("unknown estimate: not wrong (behaves as before)", r and r.wrongLevel is False)
    r = G.ArrivalFloor(20, 0, 14.0, 9.5)
    check("estimate between the levels (fits neither): not wrong", r and r.wrongLevel is False)
    check("target without a second level: nil", G.ArrivalFloor(60, 0, 5.0, 14.0) is None)
    check("target z unknown: nil", G.ArrivalFloor(20, 0, None, 5.0) is None)
    L = world(None)
    check("default is OFF: nil even with a second level",
          L.eval("WowVisionNavigationGuidance").ArrivalFloor(20, 0, 14.0, 5.0) is None)

    print("Command /vn floor (German alias stockwerk):")
    L = world(None)
    g = L.globals()
    slash = g.SlashCmdList["WOWVISIONNAVIGATION"]
    check("saved variable is absent/false by default", not g.WowVisionNavigationDB.heightAwareArrival)
    slash("stockwerk")
    check("toggle turns it on and says so (de)", g.WowVisionNavigationDB.heightAwareArrival is True
          and any("Hoehenbewusste Ankunft EINGESCHALTET" in t for t in texts(L)))
    slash("floor off")
    check("/vn floor off turns it off and says so", g.WowVisionNavigationDB.heightAwareArrival is False
          and any("Hoehenbewusste Ankunft AUSGESCHALTET" in t for t in texts(L)))
    slash("floor on")
    check("/vn floor on", g.WowVisionNavigationDB.heightAwareArrival is True)
    slash("stockwerk aus")
    check("/vn stockwerk aus", g.WowVisionNavigationDB.heightAwareArrival is False)
    slash("floor maybe")
    check("unknown value is refused with usage and changes nothing", g.WowVisionNavigationDB.heightAwareArrival is False
          and any("stockwerk an" in t for t in texts(L)))
    slash("status")
    check("/vn status shows the setting", any("Hoehenbewusste Ankunft (" in t and "aus" in t for t in texts(L)))
    slash("hilfe")
    check("/vn help lists the command", any("/vn stockwerk" in t for t in texts(L)))
    L.execute("WowVisionNavigationDB.language = 'en'")
    slash("floor on")
    check("English confirmation", any("Height-aware arrival ON" in t for t in texts(L)))
    slash("floor off")
    check("English confirmation off", any("Height-aware arrival OFF" in t for t in texts(L)))
    slash("help")
    check("English help line", any("/vn floor [on|off]" in t for t in texts(L)))

    print("Arrival in the running navigation:")
    L = world(False)
    nav = arrive(L, 3, 5.0)
    check("off: arrival counts, no floor text", not nav.active and any("erreicht" in t for t in texts(L))
          and not any("Das Ziel liegt" in t for t in texts(L)))
    L = world(True)
    nav = arrive(L, 3, 14.0)
    check("on, estimate on the target level: arrival counts and names the floor",
          not nav.active and any("erreicht" in t and "Das Ziel liegt oben." in t for t in texts(L)), str(texts(L)[-2:]))
    L = world(True)
    nav = arrive(L, 3, 5.0)
    said = [t for t in texts(L) if "Die Ankunft zaehlt noch nicht" in t]
    check("on, estimate on the other level: arrival not counted, route stays active", nav.active is True
          and not any("erreicht" in t for t in texts(L)))
    check("...and the wrong level is announced exactly once with the target floor",
          len(said) == 1 and "oben" in said[0], str(said))
    L.execute("WowVisionNavigationGuidance.Height = function() return 14.0 end")
    tick(L, 0.3)
    check("when the estimate points to the target level the arrival is counted",
          L.globals().__T.Navigation.active is False and any("Das Ziel liegt oben." in t for t in texts(L)))
    L = world(True)
    nav = arrive(L, 3, 9.5)
    check("on, estimate between the levels (unclear): behaves as before", not nav.active
          and any("erreicht" in t for t in texts(L)))
    L = world(True)
    nav = arrive(L, 3, None)
    check("on, real route estimate (no stub): arrival counts and names the floor",
          not nav.active and any("Das Ziel liegt oben." in t for t in texts(L)))
    L = world(True)
    nav = arrive(L, 2, 14.0)
    check("lower target with an estimate on the upper floor: not counted", nav.active is True)
    L = world(True)
    nav = arrive(L, 2, 5.0)
    check("lower target, right estimate: names 'unten'", not nav.active and any("Das Ziel liegt unten." in t for t in texts(L)))
    L = world(True)
    nav = arrive(L, 4, 14.0)
    check("target without a second level: arrival as before, no floor text", not nav.active
          and any("erreicht" in t for t in texts(L)) and not any("Das Ziel liegt" in t for t in texts(L)))
    check("the once-flag is cleared with the route", L.globals().__T.Navigation.floorWrongAnnounced is None)

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All floor-arrival tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
