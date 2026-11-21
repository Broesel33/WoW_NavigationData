"""A walk-in portal is a link of the route (DemoAddon, 21.11.2026). Lua 5.1 via lupa, REAL DemoAddon files, two synthetic zones of ONE native map.

User request 21.11.2026: the portal between Rut'theran and Darnassus works like the one of the Stormwind sanctum, without a waiting circle: the
route is simply walked through it. Three things made the portal into a neighbouring zone of the same map behave differently:
  * the leg ended at the pre-point (the start node of the action, outside the trigger: 11.0 yd from the centre of a 10 yd trigger at Rut'theran),
    and the action said "wait at the pre-point" with no guidance on into the trigger;
  * a leg that crosses the trigger before its last waypoint (Darnassus) was teleported away by the game while the core still waited for that
    waypoint;
  * the action into another zone completed only after the zone event of the client had switched the active zone (exitReady): without it, it ran
    into its time limit after 30 s.
Now (generic, by the data): the leg goes on from the pre-point to the activation point of the trigger (the entrance capture whose pre-point is the
start node and whose activation point lies inside the trigger); the action begins as soon as the player, at the height of the route there, is in
the trigger; after the proven arrival the core activates the zone of the exit itself when it lies on the same native map. Its texts: no "go to
the pre-point", no "wait at the pre-point".

World (native map 0, continent EasternKingdoms, no seam between the zones):
    Alpha (37): A0 (0, 0) - A1 (20, 0) - P (40, 0), trigger: sphere (52, 0, 5) radius 10, activation point (45, 0)
    Beta  (38): E (200, 0) - T (240, 0); the portal P -> E, arrival volume (200, 0, 5) radius 10
Variant "crossing": A0 (0, 0) - A1 (70, 0) - P (40, 0): the leg to A1 crosses the trigger before the pre-point.
Variant "above": the same, the trigger 35 yd above the ground (a level over the leg): the leg crosses its plane, not the trigger.

Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_portal_link.py
(exit code 0 = all green)
"""

import math
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
from core_fixtures import start_runtime, texts, tick  # noqa: E402
import core_schema7_harness as H  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

BASE = 10_000_000
BOXES = {37: (-10, 110, -50, 50), 38: (150, 290, -50, 50)}
TRIGGER = (52.0, 0.0, 5.0, 10.0)            # x, y, z, radius
ACTIVATION = (45.0, 0.0, 5.0)               # inside the trigger, 5 yd beyond the pre-point
EXIT, TARGET = 38 * BASE + 0, 38 * BASE + 1


def a(i):
    return 37 * BASE + i


def world(alpha_points, trigger_z=TRIGGER[2]):
    x, y, _z, r = TRIGGER
    action = {
        "id": "portal:link", "kind": "portal", "from": 2, "to": EXIT, "toZone": 38, "toMapId": 0, "cost": 5,
        "conditions": {"status": "unconditional", "proof": "fixture"},
        "activation": {"mode": "walk_into_volume", "verified": True, "proof": "fixture"},
        "arrival": {"mode": "same_map_distinct_volume", "proof": "fixture"},
        "timing": {"timeout_seconds": 30},
        "sourceVolume": {"type": "sphere", "x": x, "y": y, "z": trigger_z, "radius": r},
        "arrivalVolume": {"type": "sphere", "x": 200, "y": 0, "z": 5, "radius": 10},
    }
    capture = {"activationMode": "walk_into_trigger", "facilityRole": "entrance", "nativeMapId": 0,
               "activationPreX": alpha_points[2][0], "activationPreY": alpha_points[2][1], "activationPreZ": 5.0,
               "activationCaptureRadius": 1.0, "approachProofId": "approach:fixture",
               "x": ACTIVATION[0], "y": ACTIVATION[1], "z": ACTIVATION[2]}
    alpha = [F.node(px, py, 5.0) for px, py in alpha_points]
    beta = [F.node(200, 0, 5.0), F.node(240, 0, 5.0)]
    zones = [{"zoneId": 37, "name": "Alpha", "uiMaps": [37], "box": BOXES[37], "seams": []},
             {"zoneId": 38, "name": "Beta", "uiMaps": [38], "box": BOXES[38], "seams": []}]
    sources = C.World([F.index_text("EasternKingdoms", zones),
                       F.zone_text(37, alpha, [(0, 1), (1, 2)], actions=[action], captures=[capture]),
                       F.zone_text(38, beta, [(0, 1)]),
                       F.catalog_text(37, "logical", []), F.catalog_text(37, "dyn", []),
                       F.catalog_text(38, "logical", []), F.catalog_text(38, "dyn", [])])
    sources.box, sources.maps = BOXES[37], (37,)
    L = start_runtime(sources, player=alpha_points[0])
    for map_id, box in BOXES.items():
        L.execute("BOXES[%d] = {%s}" % (map_id, ", ".join(repr(float(v)) for v in box)))
    L.execute("_G.bestMapID = 37")
    L.execute("UnitPosition = function() return playerX, playerY, 0, 0 end")      # native map 0, no usable height
    return L


def path_ids(T):
    return [int(T.Navigation.path[i]) for i in range(1, len(T.Navigation.path) + 1)] if T.Navigation.path else []


def run(L, ground_z=5.0, trigger_z=TRIGGER[2], frames=2000, on_step=None):
    """The player walks the route in 0.5 yd steps (one step a frame); the game teleports him to the exit the moment he is in the trigger (3D: he walks
    on the ground at ground_z), whatever the core does. No zone event is fired: the core must get along without it. -> log of (event, details)."""
    g = L.globals()
    T = g.__T
    actions = g.WowVisionNavigationActionNavigation
    log = []
    for step in range(frames):
        x, y = float(g.playerX), float(g.playerY)
        tx, ty, _tz, r = TRIGGER
        if (x - tx) ** 2 + (y - ty) ** 2 + (ground_z - trigger_z) ** 2 <= r * r:
            log.append(("teleport", (x, y), actions.current is not None))
            g.playerX, g.playerY = 200.0, 0.0
            g.bestMapID = 38
        elif actions.current is not None:
            # in the trigger already or on the way into it: straight on towards its centre
            d = math.hypot(tx - x, ty - y)
            if d > 0.5:
                g.playerX, g.playerY = x + (tx - x) / d * 0.5, y + (ty - y) / d * 0.5
        elif T.Navigation.active and T.Navigation.path:
            wx, wy, _wz = T.NodePosition(T.Navigation.path[int(T.Navigation.pathIndex)])
            d = math.hypot(wx - x, wy - y)
            g.playerX, g.playerY = (wx, wy) if d <= 0.5 else (x + (wx - x) / d * 0.5, y + (wy - y) / d * 0.5)
        else:
            break
        before = actions.current is not None
        tick(L, 0.05)
        if not before and actions.current is not None:
            log.append(("action", (float(g.playerX), float(g.playerY)), str(actions.current.phase)))
        if on_step:
            on_step(step)
    return log


def main():
    failures = []

    def check(name, ok, info=""):
        print(("  OK   " if ok else "  FAIL ") + name + ("  " + info if info else ""))
        if not ok:
            failures.append(name)

    print("Rut'theran-like: the pre-point lies outside the trigger, the exit in the neighbouring zone of the same map")
    L = world([(0, 0), (20, 0), (40, 0)])
    g = L.globals()
    T = g.__T
    L.eval("WowVisionNavigationNavNetwork").LoadZone(38)
    T.Navigation.manualStartNode = a(0)
    started = T.StartNavigationToNode(TARGET, "Target T")
    check("the route starts and the portal travels with it", bool(started) and T.Navigation.active and T.Navigation.pendingAction is not None
          and str(T.Navigation.pendingAction.actionId) == "portal:link", str(texts(L)[-2:]))
    ids = path_ids(T)
    vx, vy, _vz = T.NodePosition(ids[-1]) if ids else (None, None, None)
    check("the leg does not stop at the pre-point: it goes on to the activation point inside the trigger",
          len(ids) >= 2 and ids[-2] == a(2) and ids[-1] >= int(g.WowVisionNavigationNavNetwork.VIRT_BASE) and (vx, vy) == ACTIVATION[:2], str(ids))
    log = run(L)
    begun = [e for e in log if e[0] == "action"]
    teleports = [e for e in log if e[0] == "teleport"]
    check("the action begins where the player enters the trigger (10 yd from its centre), before the activation point",
          bool(begun) and abs(math.hypot(begun[0][1][0] - TRIGGER[0], begun[0][1][1] - TRIGGER[1]) - TRIGGER[3]) <= 0.5, str(log[:3]))
    check("the game teleports him once, while the action runs", len(teleports) == 1 and teleports[0][2] is True, str(teleports))
    out = texts(L)
    check("no 'go to the pre-point' and no 'wait at the pre-point'",
          not any("Vorpunkt von" in t or "Warte am Vorpunkt" in t for t in out), str(out[-6:]))
    check("the walk-in text says to walk on straight", any("Geradeaus weitergehen" in t for t in out), str(out[-6:]))
    check("without a zone event the core activates the zone of the exit itself", int(g.NavData.zoneId) == 38)
    check("the action is complete and nothing ran into its time limit", g.WowVisionNavigationActionNavigation.current is None
          and not any("Zeitueberschreitung" in t for t in out), str(out[-4:]))
    check("the route went on from the exit to the target and arrived", not T.Navigation.active and any("'Target T' erreicht" in t for t in out),
          str(out[-3:]))

    print("\nDarnassus-like: the leg crosses the trigger before its pre-point")
    L = world([(0, 0), (70, 0), (40, 0)])
    g = L.globals()
    T = g.__T
    L.eval("WowVisionNavigationNavNetwork").LoadZone(38)
    T.Navigation.manualStartNode = a(0)
    started = T.StartNavigationToNode(TARGET, "Target T")
    check("the route starts", bool(started) and T.Navigation.active, str(texts(L)[-2:]))
    log = run(L)
    begun = [e for e in log if e[0] == "action"]
    check("the action begins at the trigger on the way to the second waypoint, not only at the pre-point",
          bool(begun) and begun[0][1][0] < TRIGGER[0] and abs(begun[0][1][0] - (TRIGGER[0] - TRIGGER[3])) <= 0.5, str(log[:3]))
    out = texts(L)
    check("after the teleport the route goes on and arrives", int(g.NavData.zoneId) == 38 and not T.Navigation.active
          and any("'Target T' erreicht" in t for t in out), str(out[-4:]))

    print("\nControl: the trigger is a level above the leg (its plane is crossed, not the trigger)")
    above = TRIGGER[2] + 35.0
    L = world([(0, 0), (70, 0), (40, 0)], trigger_z=above)
    g = L.globals()
    T = g.__T
    L.eval("WowVisionNavigationNavNetwork").LoadZone(38)
    T.Navigation.manualStartNode = a(0)
    T.StartNavigationToNode(TARGET, "Target T")
    ids = path_ids(T)
    check("no activation point in the trigger: the leg ends at the pre-point", bool(ids) and ids[-1] == a(2), str(ids))
    seen = []
    log = run(L, trigger_z=above, frames=400,
              on_step=lambda step: seen.append((float(g.playerX), int(T.Navigation.pathIndex) if T.Navigation.active else 0,
                                                g.WowVisionNavigationActionNavigation.current is not None)))
    crossing = [s for s in seen if s[1] == 2 and abs(s[0] - TRIGGER[0]) < TRIGGER[3]]
    check("crossing the plane of the trigger on the way to the second waypoint begins nothing",
          bool(crossing) and not any(s[2] for s in crossing), str(crossing[:2]))
    begun = [e for e in log if e[0] == "action"]
    check("the action begins at the pre-point", bool(begun) and math.hypot(begun[0][1][0] - 40.0, begun[0][1][1]) <= 1.5, str(log[:2]))

    print("\n" + ("Failed: " + "; ".join(failures) if failures else "All portal link tests passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
