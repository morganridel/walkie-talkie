#!/usr/bin/env python3
"""Rank recently used Codex project folders, without model calls or journal access."""
import argparse
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from codex_bridge import main as bridge_main

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(Path.home() / ".walkie-talkie/recent-projects.json"))
    parser.add_argument("--print", action="store_true", dest="show")
    args = parser.parse_args()
    # Bridge owns the current Codex metadata schema. Capture only project metadata.
    import contextlib
    import io
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = bridge_main(["projects"])
    if result not in (None, 0):
        raise SystemExit(result)
    data = json.loads(output.getvalue().strip().splitlines()[-1])
    target = Path(args.out)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n")
    tmp.replace(target)
    if args.show:
        print(json.dumps(data, ensure_ascii=False, indent=2))
