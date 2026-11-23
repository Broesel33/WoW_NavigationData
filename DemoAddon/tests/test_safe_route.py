"""Safe routes (DemoAddon, 23.11.2026): /vn safety <p> (German: /vn sicherheit <p>), p percent 0 to 300, default 0 = off.

X = 1 + p/100 is how much longer a safer route may be than the shortest one (pass a). The danger of a link is its length (yd, horizontal) within
DANGER_RADIUS (20 yd) of a monster spawn (logical classes of kind mob / creature) at about the height of the link (DANGER_DZ 8 yd); spawns of the same name
within 2 yd count once; spawns within the radius of the start or the target of the route do not count for that route. Lua 5.1 via lupa, REAL DemoAddon files.

Synthetic zone (nodes S (0, 0), G (100, 0), M (50, 0), D (50, 60)): the short way S-M-G is 100 yd, the way round S-D-G 156 yd (1.56 x).
A monster stands at (50, 5) next to M unless the case says otherwise: 19.4 yd of each of the two short links lie within 20 yd of it.

Run from anywhere:
    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe
        C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/test_safe_route.py
(exit code 0 = all green)
"""

import math
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent / "WowVisionNavigation"
TOOLS = Path(os.environ.get("WOWNAV_TOOLS", r"C:\Users\Manu\projects\WowNav\tools"))
os.environ["WOW_addon_dir"] = str(ADDON)       # the harness must load the DemoAddon, not addon/
sys.path.insert(0, str(TOOLS))

import core_fixtures as C  # noqa: E402
import schema7_fixture as F  # noqa: E402
from core_fixtures import H, nid  # noqa: E402

assert Path(H.ADDON).resolve() == ADDON.resolve(), "harness does not use the DemoAddon"

NODES = [(0, 0, 5.0), (100, 0, 5.0), (50, 0, 5.0), (50, 60, 5.0)]     # S, G, M, D
LINKS = [(0, 2), (2, 1), (0, 3), (3, 1)]
SHORT_LENGTH, ROUND_LENGTH = 100.0, 2 * math.hypot(50, 60)
CAMP_YARDS = 2 * math.sqrt(20 ** 2 - 5 ** 2)          # the two short links together, spawn 5 yd beside M: 2 x 19.36


def mob(index, x, y, z=5.0, name="Wolf", kind="mob"):
    row = C.target_row(f"{kind}:{index}", name, name, x, y, z, category=(kind,), kind=kind)
    if kind not in ("mob", "creature", "npc"):
        row["type"] = None            # the kind of an object does not follow from "creature"
    return row


def start(spawns=(), saved=None, comfort=0):
    kinds = [F.node(x, y, z, area="OPEN", radius=1.0) for x, y, z in NODES]
    sources = C.lua_world(kinds, LINKS, box=(-1000, 1000, -1000, 1000), maps=(37,), targets=list(spawns))
    L = H.new_runtime(data_sources=sources)
    L.execute("BOXES[37] = {-1000.0, 1000.0, -1000.0, 1000.0}")
    L.execute("_G.bestMapID = 37")
    H.set_player(L, 0, 0)
    if saved is not None:
        L.globals().WowVisionNavigationDB = L.eval("{safety = %s}" % saved)
    H.fire_addon_loaded(L)
    L.execute(f"WowVisionNavigationNavNetwork.SetComfort({comfort})")
    L.execute('''
        function SafeRoute(sx, sy, gx, gy, points)
            local N = WowVisionNavigationNavNetwork
            local r = N.Route(N.Bind(sx, sy, 5.0, {}), N.Bind(gx, gy, 5.0, {}), nil, nil, nil, nil, points)
            local ids = {}
            for _, id in ipairs(r.path) do ids[#ids + 1] = id end
            return r.pass, table.concat(ids, ","), r.length, r.lengthA, r.danger or -1, r.dangerA or -1
        end
        function ZoneYards()
            local N = WowVisionNavigationNavNetwork
            local d = N.ZoneDanger(N.zones[37])
            local sum = 0
            for _, v in pairs(d.len) do sum = sum + v end
            return sum, d.count
        end''')
    return L


def T(L):
    return getattr(L.globals(), "__T")


def route(L, goal=(100, 0)):
    which, ids, length, length_a, danger, danger_a = L.eval("SafeRoute")(0, 0, goal[0], goal[1], None)
    return str(which), [int(v) for v in str(ids).split(",")], float(length), float(length_a), float(danger), float(danger_a)


def set_safety(L, percent):
    T(L).ExecuteSlashCommand(f"safety {percent}")


def last(L):
    outputs = L.globals().outputs
    return str(outputs[len(outputs)])


class SafeRoutes(unittest.TestCase):
    def test_off_is_the_route_of_today(self):
        L = start([mob(1, 50, 5)])
        N = L.eval("WowVisionNavigationNavNetwork")
        self.assertEqual((N.safety, N.SAFETY_DEFAULT), (0, 0))
        which, ids, length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids, nid(3) in ids), ("a", True, False))
        self.assertEqual((danger, danger_a), (-1.0, -1.0))          # nothing computed, nothing reported
        self.assertAlmostEqual(length, SHORT_LENGTH, delta=0.01)

    def test_factor_too_small_keeps_the_shortest_route(self):
        L = start([mob(1, 50, 5)])
        set_safety(L, 40)                                           # X = 1.4 < 1.56
        which, ids, _length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids), ("a", True))
        self.assertAlmostEqual(danger, CAMP_YARDS, delta=0.05)
        self.assertAlmostEqual(danger_a, CAMP_YARDS, delta=0.05)

    def test_factor_large_enough_takes_the_detour(self):
        L = start([mob(1, 50, 5)])
        set_safety(L, 100)                                          # X = 2
        which, ids, length, length_a, danger, danger_a = route(L)
        self.assertEqual((which, nid(3) in ids, nid(2) in ids), ("s", True, False))
        self.assertAlmostEqual(length, ROUND_LENGTH, delta=0.05)
        self.assertAlmostEqual(length_a, SHORT_LENGTH, delta=0.01)
        self.assertEqual(danger, 0.0)
        self.assertAlmostEqual(danger_a, CAMP_YARDS, delta=0.05)

    def test_the_limit_is_exact(self):
        L = start([mob(1, 50, 5)])
        set_safety(L, 55)                                           # 1.55 < 1.5620
        self.assertEqual(route(L)[0], "a")
        set_safety(L, 57)                                           # 1.57 > 1.5620
        self.assertEqual(route(L)[0], "s")

    def test_default_comfort_does_not_change_the_result(self):
        L = start([mob(1, 50, 5)], comfort=60)
        set_safety(L, 100)
        which, ids, _length, _la, danger, _da = route(L)
        self.assertEqual((which, nid(3) in ids, danger), ("s", True, 0.0))

    def test_no_danger_no_change(self):
        L = start([mob(1, 50, 40)])                                 # 40 yd from the short way
        set_safety(L, 300)
        which, ids, _length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids, danger, danger_a), ("a", True, 0.0, 0.0))

    def test_spawn_at_the_target_does_not_count(self):
        L = start([mob(1, 100, 5)])                                 # in the camp of the target
        set_safety(L, 300)
        which, ids, _length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids, danger, danger_a), ("a", True, 0.0, 0.0))

    def test_spawn_at_the_start_does_not_count(self):
        L = start([mob(1, 0, 5)])
        set_safety(L, 300)
        which, ids, _length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids, danger, danger_a), ("a", True, 0.0, 0.0))

    def test_exact_target_position_excludes_its_spawns_too(self):
        """The core also passes the exact position of the target (points): a spawn 15 yd from it, 35 yd from the node G."""
        L = start([mob(1, 50, 5)])
        set_safety(L, 300)
        L.execute("PointsRoute = function(points) return SafeRoute(0, 0, 100, 0, points) end")
        points = L.eval("{ {x = 50, y = 15, z = 5.0} }")
        which, _ids, _length, _la, danger, danger_a = L.eval("PointsRoute")(points)
        self.assertEqual((str(which), float(danger), float(danger_a)), ("a", 0.0, 0.0))

    def test_spawn_on_another_height_is_ignored(self):
        L = start([mob(1, 50, 5, z=30.0)])                          # 25 yd above the way (cave, floor)
        set_safety(L, 300)
        which, ids, _length, _la, danger, danger_a = route(L)
        self.assertEqual((which, nid(2) in ids, danger, danger_a), ("a", True, 0.0, 0.0))

    def test_spawn_without_height_counts(self):
        L = start([mob(1, 50, 5, z=None)])
        set_safety(L, 100)
        self.assertEqual(route(L)[0], "s")

    def test_npc_and_objects_do_not_count(self):
        for kind in ("npc", "gameobject", "herb"):
            L = start([mob(1, 50, 5, kind=kind)])
            set_safety(L, 300)
            which, ids, _length, _la, danger, danger_a = route(L)
            self.assertEqual((which, nid(2) in ids, danger, danger_a), ("a", True, 0.0, 0.0), kind)

    def test_creature_counts_like_mob(self):
        L = start([mob(1, 50, 5, kind="creature")])
        set_safety(L, 100)
        self.assertEqual(route(L)[0], "s")

    def test_duplicates_of_several_sources_count_once(self):
        once = start([mob(1, 50, 5)])
        twice = start([mob(1, 50, 5), mob(2, 50.8, 5.7)])           # same name, 1.1 yd apart: one spawn
        other = start([mob(1, 50, 5), mob(2, 50.8, 5.7, name="Boar")])   # another name: two spawns
        far = start([mob(1, 50, 5), mob(2, 53, 5)])                 # same name, 3 yd apart: two spawns
        for L in (once, twice, other, far):
            set_safety(L, 100)
            route(L)
        self.assertEqual(int(once.eval("ZoneYards")()[1]), 1)
        self.assertEqual(int(twice.eval("ZoneYards")()[1]), 1)
        self.assertEqual(int(other.eval("ZoneYards")()[1]), 2)
        self.assertEqual(int(far.eval("ZoneYards")()[1]), 2)
        base = float(once.eval("ZoneYards")()[0])
        self.assertAlmostEqual(float(twice.eval("ZoneYards")()[0]), base, delta=0.01)
        self.assertGreater(float(other.eval("ZoneYards")()[0]), base * 1.9)

    def test_weights_pick_the_least_danger_then_the_shorter(self):
        """Never 'no route' because of the safety: with the detour too long, the shortest route stays."""
        L = start([mob(1, 50, 5)])
        set_safety(L, 10)
        which, ids, length, *_ = route(L)
        self.assertEqual((which, nid(2) in ids), ("a", True))
        self.assertAlmostEqual(length, SHORT_LENGTH, delta=0.01)


class SafetyCommand(unittest.TestCase):
    def test_command_and_german_alias(self):
        L = start()
        N = L.eval("WowVisionNavigationNavNetwork")
        T(L).ExecuteSlashCommand("safety 150")
        self.assertEqual((N.safety, float(N.SAFETY_RATIO)), (150, 2.5))
        self.assertEqual(L.globals().WowVisionNavigationDB.safety, 150)
        T(L).ExecuteSlashCommand("sicherheit 50")
        self.assertEqual(N.safety, 50)
        T(L).ExecuteSlashCommand("safety 0")
        self.assertEqual(N.safety, 0)

    def test_invalid_values_are_refused(self):
        L = start()
        N = L.eval("WowVisionNavigationNavNetwork")
        set_safety(L, 100)
        for value in ("301", "-1", "abc"):
            T(L).ExecuteSlashCommand(f"safety {value}")
            self.assertEqual(N.safety, 100, value)
            self.assertIn(value, last(L))
        self.assertTrue(float(N.safety) == 100)

    def test_saved_value_is_loaded_and_a_broken_one_means_off(self):
        self.assertEqual(start(saved=120).eval("WowVisionNavigationNavNetwork").safety, 120)
        self.assertEqual(start(saved=999).eval("WowVisionNavigationNavNetwork").safety, 0)

    def test_status_text_without_value(self):
        L = start()
        set_safety(L, 100)
        T(L).ExecuteSlashCommand("safety")
        text = last(L)
        self.assertIn("100", text)
        self.assertIn("2", text)

    def test_help_lists_the_command(self):
        L = start()
        self.assertIn("help_safety", [str(k) for k in L.eval("WowVisionNavigationLocalization.helpKeys").values()])


if __name__ == "__main__":
    unittest.main(verbosity=1)
