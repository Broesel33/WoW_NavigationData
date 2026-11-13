"""Tests of the height question (/vn ebene) over stepped cells (DemoAddon). Lua 5.1 via lupa, REAL DemoAddon files, synthetic zones.

User rule 12.11.2026 (Ashenvale av480a, fishing spot 2803:-2656): the resolver searches in stages (the cell under the target, then the cells
within the radius, then the doubled tolerance). The bands it offered came from a later stage, the answer was applied to the first stage
with candidates; there was one band, so "/vn ebene 2" said "height band invalid". Now:
  * the offered bands and the evaluation of the answer come from the same stage;
  * a question only when at least two bands can be reached from the start (one reachable band: the route goes there);
  * a known target height inside a band decides, also inside several overlapping bands (no question);
  * the same for the certified levels of a target (4.54).

The world: the target stands in the cell of node 1 (floor z 0, no link: the first stage has one band that cannot be routed). 8 yd beside it,
inside the approach radius, node 2 (floor z 0) and node 3 (z 20) in the next cell: the second stage has two bands. The start is node 0, far
away, linked to 2 and (unless "low only") to 3. Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_height_question.py
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
from core_fixtures import first, lua_world, nid, start_runtime, texts  # noqa: E402
import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BOX = (-200, 200, -200, 200)
START = (-100.0, 8.0)
STEPPED = [F.node(*START, 0.0), F.node(8.0, 8.0, 0.0), F.node(24.0, 8.0, 0.0), F.node(24.0, 8.0, 20.0)]


def world(nodes=STEPPED, links=((0, 2), (0, 3)), cells=None):
    L = start_runtime(lua_world(list(nodes), list(links), cells, box=BOX), player=START)
    L.globals().__T.SetHeightAnchor(0.0, *START)
    return L


def target(L, x, y, z=None, levels=None):
    """A live target (as a Questie or group target) at x, y; z or levels optional."""
    L.execute("TARGET = {id='t', kind='mob', nameEn='Wolf', nativeMapId=0, coordinateSpace='world', x=%r, y=%r, z=%s, zStatus=%r, "
              "levels=%s, source={provider='test'}, layeredTarget=true, category={}}"
              % (x, y, "nil" if z is None else repr(z), "unknown" if z is None else "known",
                 "nil" if levels is None else "{" + ", ".join(repr(v) for v in levels) + "}"))


def select(L):
    """The player selects the target: -> (route started, the open question as its band count or 0)."""
    L.execute("_G.outputs = {}")
    started = bool(first(L.eval("WowVisionNavigationLayerTargetStart(TARGET)")))
    pending = L.eval("WowVisionNavigationTargetSelection.pending")
    return started, int(pending.bandCount) if pending is not None else 0


def answer(L, index):
    """The player types /vn ebene <index>."""
    L.execute("_G.outputs = {}")
    L.eval("WowVisionNavigationTargetSelection:Command('level %d')" % index)


def route_end(L):
    T = L.globals().__T
    if not T.Navigation.active:
        return None
    path = [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)]
    physical = int(T.Navigation.logicalPrepoint) if T.Navigation.logicalPrepoint is not None else path[-1]
    return physical


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    no_path = "kein Netzweg"

    print("Unknown height, the bands of the second stage (the first stage has one band without a route):")
    L = world()
    target(L, 8.0, 8.0)
    started, count = select(L)
    lines = texts(L)
    check("two reachable bands: a question with two bands", not started and count == 2, str(lines[-3:]))
    check("no offered band is called 'no network path' (both can be reached)", not any(no_path in t for t in lines), str(lines[-3:]))
    answer(L, 2)
    check("/vn ebene 2: the route goes to the upper band (node 3), not 'height band invalid'", route_end(L) == nid(3),
          f"{route_end(L)} {texts(L)[-2:]}")
    L = world()
    target(L, 8.0, 8.0)
    select(L)
    answer(L, 1)
    check("/vn ebene 1: the route goes to the reachable cell of the lower band (node 2)", route_end(L) == nid(2), f"{route_end(L)} {texts(L)[-2:]}")
    L = world()
    resolved = L.eval("""(function()
        local t = {id='d', kind='mob', nameEn='Wolf', nativeMapId=0, coordinateSpace='world', x=8, y=8, zStatus='unknown', source={provider='test'}, category={}}
        local route = function(id) if id == %d then return nil end return {id}, 1 end
        local r = WowVisionNavigationTargetResolver:Resolve(NavData, t, {heightBand = 2, route = route})
        return tostring(r.endNodeId) .. ' ' .. tostring(r.reason) end)()""" % nid(1))
    check("a direct call with heightBand 2 (no offered band): band 2 of the same question", str(resolved).startswith(str(nid(3))), str(resolved))

    print("Only one band can be reached from the start:")
    L = world(links=[(0, 2)])
    target(L, 8.0, 8.0)
    started, count = select(L)
    check("no question, the route goes to the one reachable band (node 2)", started and count == 0 and route_end(L) == nid(2),
          f"{started} {count} {route_end(L)} {texts(L)[-3:]}")

    print("Known target height inside two overlapping bands (av480a: z 208.8 in 200.8-215.0 and 208.0-219.6):")
    nodes = [F.node(*START, 0.0), F.node(8.0, 8.0, 0.0), F.node(8.0, 8.0, 12.0)]
    cells = F.auto_cells([nodes[0]]) + [
        {"area": "OPEN", "gx": 0, "gy": 0, "zmin": 0.0, "zmax": 14.0, "layer": 0, "attachments": [{"node": 1}]},
        {"area": "OPEN", "gx": 0, "gy": 0, "zmin": 7.0, "zmax": 19.0, "layer": 1, "attachments": [{"node": 2}]}]
    L = world(nodes, [(0, 1), (0, 2)], cells)
    target(L, 8.0, 8.0, z=8.0)
    started, count = select(L)
    check("no question, a route starts", started and count == 0 and route_end(L) in (nid(1), nid(2)), f"{started} {count} {texts(L)[-3:]}")
    L = world(nodes, [(0, 1), (0, 2)], cells)
    target(L, 8.0, 8.0, z=3.0)
    started, count = select(L)
    check("a known height in one band only: that band (node 1), no question", started and count == 0 and route_end(L) == nid(1),
          f"{started} {count} {route_end(L)}")

    print("Known height between two floors (the conflict of 4.41 stays a question):")
    nodes = [F.node(*START, 0.0), F.node(8.0, 8.0, 0.0), F.node(8.0, 8.0, 8.0)]
    L = world(nodes, [(0, 1), (0, 2)])
    target(L, 8.0, 8.0, z=4.0)
    started, count = select(L)
    check("both floors reachable: a question with two bands", not started and count == 2, f"{started} {count}")
    answer(L, 2)
    check("/vn ebene 2: the upper floor (node 2)", route_end(L) == nid(2), f"{route_end(L)} {texts(L)[-2:]}")

    print("Certified levels of a target (4.54):")
    L = world()
    target(L, 24.0, 8.0, levels=[0.0, 20.0])
    started, count = select(L)
    check("both levels reachable: the level question", not started and count == 2, f"{started} {count}")
    answer(L, 2)
    check("/vn ebene 2: level 2 (node 3)", route_end(L) == nid(3), f"{route_end(L)} {texts(L)[-2:]}")
    L = world(links=[(0, 2)])
    target(L, 24.0, 8.0, levels=[0.0, 20.0])
    started, count = select(L)
    check("one level reachable: no question, the route to it (node 2)", started and count == 0 and route_end(L) == nid(2),
          f"{started} {count} {route_end(L)} {texts(L)[-3:]}")
    L = world(links=[])
    target(L, 24.0, 8.0, levels=[0.0, 20.0])
    started, count = select(L)
    check("no level reachable: no question, 'no network path from here'", not started and count == 0
          and any("keinen Netzweg" in t for t in texts(L)), f"{started} {count} {texts(L)[-2:]}")

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All height-question tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
