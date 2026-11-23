This addon serves as demo how the map data may be used.

Please copy the navigation data you want to test into the maps folder of the addon
(for example Forever/EasternKingdoms -> WowVisionNavigation/maps/EasternKingdoms).

The addon itself must be copied to the addon folder of your installation.

Optional partner addons:
- WowVision: accessible target list window and turning with the I key. Without it the addon
  uses its own fallback list window and turns the character with the camera.
- Questie: quest objectives for /vn q when the game's own quest data has none.

The addon routes to the fixed node of a target (fields n and navFingerprint of the catalogues, see
ReadMe.txt sections 7, 8 and 10); data without these fields still works through the attachment cells.
It knows the dock model without a waiting circle (a dock and its point on board), asks for a floor
(/vn ebene) only where the player has a choice, and recognises the arrival of a teleport without a
player height. A walk-in portal is a link of the route, also into the neighbouring zone of the
same map (Rut'theran Village - Darnassus): the route leads into the trigger and goes on by itself
after the teleport, without a waiting point.

Safe routes: /vn safety <p> (German /vn sicherheit <p>, p = 0 to 300 percent, default 0 = off) lets a route be up to 1 + p/100 times as
long as the shortest one if it keeps away from monsters. The monster spawns (classes mob and creature of the logical targets) are read
from the data already in the maps folder; no extra data. Spawns around the start and the target of a route do not count. /vn status
and the start of a route say how many yards the route leads near monsters, compared with the shortest route.

Tests (Lua 5.1 through lupa, no game needed; they use the harness of the build tools in the WowNav
repository): tests/run_all.py [--fast], run with the Python environment of that repository.
