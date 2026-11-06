"""Headless entry for Godot (Blender -b --factory-startup [file.blend] --python bridge.py -- ...).

  create <spec.json> <out.blend> <result.json>   new character file from Godot's base
  create_set <spec.json> <out.blend> <result.json>   new set piece file from level brushes
  dump <result.json>                             the open file's geometry for Godot (either kind)
  bones <bones.json> <result.json>               the open file's bones moved (meshes stay), saved

Writes {"ok": true, ...} or {"ok": false, "error": "..."} to the result file.
"""

import json
import os
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from n64_actor_link import core, set_piece  # noqa: E402

import bpy  # noqa: E402


def main():
    args = sys.argv[sys.argv.index("--") + 1:]
    result_path = args[-1]
    try:
        if args[0] == "create":
            with open(args[1], "r", encoding="utf-8") as f:
                spec = json.load(f)
            core.create(spec, args[2])
            result = {"ok": True}
        elif args[0] == "create_set":
            with open(args[1], "r", encoding="utf-8") as f:
                spec = json.load(f)
            set_piece.create(spec, args[2])
            result = {"ok": True}
        elif args[0] == "bones":
            with open(args[1], "r", encoding="utf-8") as f:
                bones = json.load(f)
            scene = bpy.context.scene
            arm = core.armature(scene)
            if arm and core.set_armature(scene, arm, bones, move_meshes=False):
                bpy.ops.wm.save_mainfile()
            result = {"ok": True}
        elif args[0] == "dump":
            scene = bpy.context.scene
            result = set_piece.dump(scene) if core.is_set_piece(scene) else core.dump(scene)
            result["ok"] = True
        else:
            result = {"ok": False, "error": "unknown command %s" % args[0]}
    except Exception as e:
        traceback.print_exc()
        result = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump(result, f)


main()
