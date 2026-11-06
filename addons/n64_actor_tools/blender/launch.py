"""Godot's "Edit in Blender": Blender <file.blend> --python launch.py

Turns on the N64 Actor Link add-on for this session (from the project, so it's always
the project's version), unless it's installed in Blender already.
"""

import os
import sys

import bpy

sys.dont_write_bytecode = True

if "n64_actor_link" not in bpy.context.preferences.addons:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import n64_actor_link

    n64_actor_link.register()
