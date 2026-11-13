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
player height.

Tests (Lua 5.1 through lupa, no game needed; they use the harness of the build tools in the WowNav
repository): tests/run_all.py [--fast], run with the Python environment of that repository.
