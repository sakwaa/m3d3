"""N64 Actor Link: Blender side of the Godot character tools (character editor v2) and
the level tools' set pieces (set_piece.py).

Loaded by Godot's "Edit in Blender" (or installed as an add-on). For character files
(made by Godot) it:
  - sets up the workspace on open: angle snap, viewport look, framed on the character;
  - labels the grid with distances in front / side / top views (labels.py);
  - follows Godot's state file next to the .blend (<name>.n64link.json): armature
    (proportion changes move and stretch the attached meshes like Godot does), snap
    settings, reference images, the last pull's problems and selection requests;
  - writes a heartbeat (<name>.n64live.json) so Godot knows the file is open here;
  - stamps an id on new faces when saving, so Godot's paint follows them.
  - sends the geometry to Godot a moment after each edit (<name>.n64geo.json); Godot
    fits the skeleton to it and sends bones back, which move without the meshes.
Godot also pulls the geometry itself whenever the .blend is saved.
Set piece files get the same workspace, labels, face ids, heartbeat and live geometry
(every mesh object is a level brush), and show the level around them (Surroundings).
"""

bl_info = {
    "name": "N64 Actor Link",
    "author": "m3d3",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "location": "3D View > Sidebar > N64 Actor",
    "description": "Character and set piece files shared with the m3d3 Godot tools",
    "category": "Import-Export",
}

import json
import os
import time
import traceback

import bpy
from bpy.app.handlers import persistent
from mathutils import Vector

from . import core, labels, set_piece

_state = {"file": "", "link_mtime": 0.0, "pending": None, "beat": 0.0, "select": -1,
          "geo_dirty": 0.0, "geo_seq": 0}
# Quiet time after an edit before its geometry goes to Godot (seconds).
GEO_DELAY = 0.3


def _scene():
    return bpy.context.scene


def _read_link(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _heartbeat(path):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"time": time.time(), "file": bpy.data.filepath, "pid": os.getpid()}, f)
    except OSError:
        pass


def _apply(scene, link):
    if "settings" in link and link["settings"] != core.settings(scene):
        core.apply_workspace(scene, link["settings"])
    if "references" in link:
        key = json.dumps(link["references"], sort_keys=True)
        if scene.get("n64_refs_key") != key:
            core.set_references(scene, link["references"])
            scene["n64_refs_key"] = key
    scene["n64_report"] = json.dumps(link.get("report", []))
    sel = link.get("select") or {}
    if sel.get("seq", -1) != _state["select"]:
        _state["select"] = sel.get("seq", -1)
        obj = scene.objects.get(sel.get("object", ""))
        if obj and bpy.context.mode == 'OBJECT':
            for o in bpy.context.selected_objects:
                o.select_set(False)
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
    if link.get("armature"):
        _state["pending"] = (link["armature"], link.get("armature_mode", "stretch"))
    ctx = link.get("context") or {}
    if ctx.get("path") and scene.get("n64_context_key") != ctx.get("key"):
        set_piece.set_context(scene, ctx["path"])
        scene["n64_context_key"] = ctx.get("key")


def _tick():
    try:
        scene = _scene()
        path = bpy.data.filepath
        if scene is None or not path or not core.is_linked(scene):
            return 1.0
        link_path, live_path = core.link_paths(path)
        if path != _state["file"]:
            _state.update(file=path, link_mtime=0.0, pending=None, select=-1)
            core.apply_workspace(scene, core.settings(scene))
            core.frame_views(scene)
        now = time.time()
        if now - _state["beat"] > 1.0:
            _state["beat"] = now
            _heartbeat(live_path)
        if os.path.exists(link_path):
            mtime = os.path.getmtime(link_path)
            if mtime != _state["link_mtime"]:
                link = _read_link(link_path)
                if link is not None:
                    _state["link_mtime"] = mtime
                    _apply(scene, link)
        # Bones move in Object mode only (never under an edit in progress).
        if _state["pending"] and bpy.context.mode == 'OBJECT':
            arm = core.armature(scene)
            bones, mode = _state["pending"]
            if arm:
                core.set_armature(scene, arm, bones, move_meshes=mode != "fit")
            _state["pending"] = None
        # Geometry to Godot a moment after the last edit (Godot fits the skeleton to it).
        if _state["geo_dirty"] and now - _state["geo_dirty"] > GEO_DELAY:
            _state["geo_dirty"] = 0.0
            _write_geometry(scene, path)
    except Exception:
        traceback.print_exc()
    return 0.5


def _write_geometry(scene, path):
    geo, seq_path = core.geo_paths(path)
    _state["geo_seq"] += 1
    data = set_piece.dump(scene) if core.is_set_piece(scene) else core.dump(scene)
    data["ok"] = True
    data["seq"] = _state["geo_seq"]
    try:
        with open(geo, "w", encoding="utf-8") as f:
            json.dump(data, f)
        with open(seq_path, "w", encoding="utf-8") as f:
            f.write("%d %f" % (_state["geo_seq"], time.time()))
    except OSError:
        pass


@persistent
def _on_depsgraph(scene, depsgraph):
    if not core.is_linked(scene):
        return
    for u in depsgraph.updates:
        if u.is_updated_geometry and (isinstance(u.id, bpy.types.Mesh) or
                                      (isinstance(u.id, bpy.types.Object) and u.id.type == 'MESH')):
            _state["geo_dirty"] = time.time()
            return


@persistent
def _on_load(_dummy):
    _state["file"] = ""


@persistent
def _on_save(_dummy):
    scene = _scene()
    if scene is not None and core.is_linked(scene):
        try:
            core.stamp_faces(scene)
        except Exception:
            traceback.print_exc()


class N64ACTOR_OT_select(bpy.types.Operator):
    """Select the object this problem is about"""
    bl_idname = "n64_actor.select"
    bl_label = "Select"
    bl_options = {'REGISTER', 'UNDO'}

    object: bpy.props.StringProperty()

    def execute(self, context):
        obj = context.scene.objects.get(self.object)
        if obj is None:
            return {'CANCELLED'}
        if context.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        for o in context.selected_objects:
            o.select_set(False)
        obj.hide_set(False)
        obj.select_set(True)
        context.view_layer.objects.active = obj
        return {'FINISHED'}


_bone_items = []


def _bones_enum(_self, context):
    """Bone list for the piece operators (kept referenced: Blender needs that)."""
    global _bone_items
    arm = core.armature(context.scene)
    items = [("NEAREST", "Nearest Bone", "The bone closest to the 3D cursor / the object")]
    if arm:
        items += [(b.name, b.name, "") for b in arm.data.bones]
    _bone_items = items
    return _bone_items


class N64ACTOR_OT_add_piece(bpy.types.Operator):
    """New mesh piece on a bone: a tube or box from the bone's head to its tail, attached
    to it and ready for Godot"""
    bl_idname = "n64_actor.add_piece"
    bl_label = "Add Piece"
    bl_options = {'REGISTER', 'UNDO'}

    bone: bpy.props.EnumProperty(name="Bone", items=_bones_enum)
    shape: bpy.props.EnumProperty(name="Shape", items=[("TUBE", "Tube", ""), ("BOX", "Box", "")])
    sides: bpy.props.IntProperty(name="Sides", default=6, min=3, max=16)

    @classmethod
    def poll(cls, context):
        return core.is_actor(context.scene) and core.armature(context.scene) is not None

    def invoke(self, context, _event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        scene = context.scene
        arm = core.armature(scene)
        if context.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        bone = core.nearest_bone(arm, scene.cursor.location) if self.bone == "NEAREST" else self.bone
        obj = core.make_piece(scene, arm, bone, self.shape, self.sides)
        for o in context.selected_objects:
            o.select_set(False)
        obj.select_set(True)
        context.view_layer.objects.active = obj
        self.report({'INFO'}, "%s on %s" % (obj.name, bone))
        return {'FINISHED'}


class N64ACTOR_OT_attach(bpy.types.Operator):
    """Attach the selected meshes to a bone (each to its nearest, or one you pick), so
    Godot takes them as pieces"""
    bl_idname = "n64_actor.attach"
    bl_label = "Attach to Bone"
    bl_options = {'REGISTER', 'UNDO'}

    bone: bpy.props.EnumProperty(name="Bone", items=_bones_enum)

    @classmethod
    def poll(cls, context):
        return core.is_actor(context.scene) and core.armature(context.scene) is not None and any(
            o.type == 'MESH' for o in context.selected_objects)

    def invoke(self, context, _event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        scene = context.scene
        arm = core.armature(scene)
        if context.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        done = []
        for o in [o for o in context.selected_objects if o.type == 'MESH']:
            if self.bone == "NEAREST":
                corners = [o.matrix_world @ Vector(c) for c in o.bound_box]
                bone = core.nearest_bone(arm, sum(corners, Vector()) / 8.0)
            else:
                bone = self.bone
            core.adopt(scene, o, arm, bone)
            done.append("%s > %s" % (o.name, bone))
        self.report({'INFO'}, ", ".join(done))
        return {'FINISHED'}


def _add_menu(self, context):
    if core.is_actor(context.scene):
        self.layout.separator()
        self.layout.operator_context = 'INVOKE_DEFAULT'
        self.layout.operator("n64_actor.add_piece", icon='BONE_DATA')


class N64ACTOR_OT_workspace(bpy.types.Operator):
    """Snapping, grid and viewport back to the defaults"""
    bl_idname = "n64_actor.workspace"
    bl_label = "Reset Workspace"

    def execute(self, context):
        core.apply_workspace(context.scene, core.settings(context.scene))
        return {'FINISHED'}


class N64ACTOR_PT_panel(bpy.types.Panel):
    bl_label = "N64 Actor"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "N64 Actor"

    @classmethod
    def poll(cls, context):
        return core.is_actor(context.scene)

    def draw(self, context):
        layout = self.layout
        scene = context.scene
        s = core.settings(scene)
        arm = core.armature(scene)
        tris = 0
        if arm:
            dg = context.evaluated_depsgraph_get()
            for o in core.pieces(scene, arm):
                me = o.evaluated_get(dg).data
                tris += sum(len(p.vertices) - 2 for p in me.polygons)
        row = layout.row()
        row.alert = tris > s.get("budget", 600)
        row.label(text="%d / %d tris" % (tris, s.get("budget", 600)), icon='MESH_DATA')
        layout.label(text="Rotate snap %g°" % s.get("angle", 7.5), icon='SNAP_GRID')
        layout.prop(context.window_manager, "n64_grid_labels")
        if _state["pending"]:
            layout.label(text="Godot moved bones: back to Object mode to apply", icon='INFO')
        _draw_report(layout, scene)
        row = layout.row(align=True)
        row.operator_context = 'INVOKE_DEFAULT'
        row.operator("n64_actor.add_piece", icon='ADD')
        row.operator("n64_actor.attach", icon='BONE_DATA')
        layout.operator("n64_actor.workspace", icon='FILE_REFRESH')
        layout.label(text="Godot updates as you edit; save to keep it.")


def _draw_report(layout, scene):
    try:
        report = json.loads(scene.get("n64_report", "[]"))
    except ValueError:
        report = []
    if not report:
        return
    box = layout.box()
    box.label(text="Last pull into Godot", icon='ERROR')
    for issue in report:
        row = box.row()
        row.label(text=issue.get("message", ""))
        if issue.get("object"):
            op = row.operator("n64_actor.select", text="", icon='RESTRICT_SELECT_OFF')
            op.object = issue["object"]


class N64SET_PT_panel(bpy.types.Panel):
    bl_label = "N64 Set Piece"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "N64 Set Piece"

    @classmethod
    def poll(cls, context):
        return core.is_set_piece(context.scene)

    def draw(self, context):
        layout = self.layout
        scene = context.scene
        layout.label(text="%d tris" % set_piece.tris(scene, context), icon='MESH_DATA')
        layout.label(text="Rotate snap %g°" % core.settings(scene).get("angle", 7.5), icon='SNAP_GRID')
        layout.prop(context.window_manager, "n64_grid_labels")
        col = bpy.data.collections.get(set_piece.SURROUNDINGS)
        if col is not None:
            layout.prop(col, "hide_viewport", text="Hide Surroundings", toggle=True)
        _draw_report(layout, scene)
        layout.operator("n64_actor.workspace", icon='FILE_REFRESH')
        layout.label(text="Each mesh object is a level brush.")
        layout.label(text="Godot updates as you edit; save to keep it.")


_classes = (N64ACTOR_OT_select, N64ACTOR_OT_add_piece, N64ACTOR_OT_attach, N64ACTOR_OT_workspace, N64ACTOR_PT_panel,
            N64SET_PT_panel)


def register():
    for c in _classes:
        bpy.utils.register_class(c)
    labels.register()
    bpy.types.VIEW3D_MT_mesh_add.append(_add_menu)
    bpy.types.VIEW3D_MT_add.append(_add_menu)
    bpy.app.handlers.load_post.append(_on_load)
    bpy.app.handlers.save_pre.append(_on_save)
    bpy.app.handlers.depsgraph_update_post.append(_on_depsgraph)
    bpy.app.timers.register(_tick, first_interval=0.2, persistent=True)


def unregister():
    if bpy.app.timers.is_registered(_tick):
        bpy.app.timers.unregister(_tick)
    if _on_depsgraph in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.remove(_on_depsgraph)
    if _on_save in bpy.app.handlers.save_pre:
        bpy.app.handlers.save_pre.remove(_on_save)
    if _on_load in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_on_load)
    bpy.types.VIEW3D_MT_add.remove(_add_menu)
    bpy.types.VIEW3D_MT_mesh_add.remove(_add_menu)
    labels.unregister()
    for c in reversed(_classes):
        bpy.utils.unregister_class(c)
