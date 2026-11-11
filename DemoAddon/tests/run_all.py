"""Runs all tests of the DemoAddon one after the other (the set to run before a push or a deploy of the DemoAddon or of new data).

    C:/Users/Manu/projects/WowNav/tools/.build_env/Scripts/python.exe C:/Users/Manu/projects/WoW_NavigationData/DemoAddon/tests/run_all.py [--fast]

--fast leaves out the real-data test (test_wait_targets_real_data.py, a few minutes). Exit code 0 = all green.
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAST = ["test_floor_arrival.py", "test_height_hint.py", "test_target_nodes.py", "test_wait_target_end.py", "test_dock_model.py",
        "test_trigger_after_action.py", "test_teleport_arrival.py", "test_dock_portal_route.py"]
DATA = ["test_wait_targets_real_data.py"]


def main(argv):
    names = FAST + ([] if "--fast" in argv else DATA)
    failed = []
    for name in names:
        print(f"== {name}", flush=True)
        if subprocess.run([sys.executable, "-X", "utf8", str(HERE / name)]).returncode:
            failed.append(name)
    print("\n" + ("Failed: " + ", ".join(failed) if failed else "All DemoAddon tests passed."))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
