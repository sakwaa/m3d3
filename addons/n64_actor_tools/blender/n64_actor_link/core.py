"""Character .blend files for the N64 actor tools (character editor v2), plus what set
piece files (set_piece.py, the level tools) share with them.

Godot owns the skeleton, texturing and rigging; the .blend owns the geometry. Shared by
the headless bridge (create / dump) and the add-on (live sync while Blender is open).

Everything here is in Blender space: Godot converts (its Y up, facing -Z <-> Z up,
facing -Y) on its side.

Layout of a character file:
  - one armature (bones named and placed like the Godot skeleton);
  - mesh objects bone-parented to it (one per piece, N64 style), with their local frame
    on the world origin so a plain Mirror modifier mirrors across the body's centre;
  - a FACE int attribute `n64_face` per mesh: ids Godot matches paint by;
  - reference images as image empties, shown only in their axis view.
"""

import json
import math
import os

import bpy
import bmesh
from mathutils import Matrix, Vector

FACE_ATTR = "n64_face"
SCENE_FLAG = "n64_actor"
SET_FLAG = "n64_set_piece"
CONTEXT_FLAG = "n64_context"
NEXT_FACE = "n64_next_face"
REF_VIEW = "n64_ref_view"
PIECES = "Pieces"
REFERENCES = "References"

# Applied when the file opens (and when Godot changes them): Godot's angle snap, the
# triangle budget and the N64 viewport look (the model grid is Godot-side only).
DEFAULT_SETTINGS = {"grid": 0.0125, "angle": 7.5, "budget": 600}


def is_actor(scene) -> bool:
    return bool(scene.get(SCENE_FLAG, False))


def is_set_piece(scene) -> bool:
    return bool(scene.get(SET_FLAG, False))


def is_linked(scene) -> bool:
    """A file made by Godot (character or set piece)."""
    return is_actor(scene) or is_set_piece(scene)


def meshes(scene):
    """The mesh objects Godot takes: a character's attached pieces, or every mesh object
    of a set piece (not the surroundings Godot shows)."""
    if is_set_piece(scene):
        return [o for o in scene.objects if o.type == 'MESH' and not o.get(CONTEXT_FLAG) and not o.get(REF_VIEW)]
    arm = armature(scene)
    return pieces(scene, arm) if arm else []


def link_paths(blend_path: str):
    """(Godot -> Blender state file, Blender heartbeat file) for a character .blend."""
    base = os.path.splitext(blend_path)[0]
    return base + ".n64link.json", base + ".n64live.json"


def geo_paths(blend_path: str):
    """(live geometry for Godot, its sequence number) while the file is open here."""
    base = os.path.splitext(blend_path)[0]
    return base + ".n64geo.json", base + ".n64geo.seq"


def armature(scene):
    for obj in scene.objects:
        if obj.type == 'ARMATURE':
            return obj
    return None


def pieces(scene, arm):
    """Mesh objects attached to a bone of the armature."""
    return [o for o in scene.objects if o.type == 'MESH' and o.parent == arm
            and o.parent_type == 'BONE' and o.parent_bone in arm.data.bones]


def _collection(scene, name):
    col = bpy.data.collections.get(name)
    if col is None:
        col = bpy.data.collections.new(name)
    if col.name not in scene.collection.children:
        scene.collection.children.link(col)
    return col


def _bone_parent_matrix(arm, bone_name):
    """World matrix a bone-parented child hangs from (rest: the bone's tail)."""
    bone = arm.data.bones[bone_name]
    return arm.matrix_world @ bone.matrix_local @ Matrix.Translation((0, bone.length, 0))


def attach(obj, arm, bone_name):
    """Bone-parents `obj` keeping its world matrix."""
    world = obj.matrix_world.copy()
    obj.parent = arm
    obj.parent_type = 'BONE'
    obj.parent_bone = bone_name
    obj.matrix_parent_inverse = _bone_parent_matrix(arm, bone_name).inverted() @ world @ obj.matrix_basis.inverted()


# --- New pieces -----------------------------------------------------------------------------

def nearest_bone(arm, point):
    """Name of the bone whose segment passes closest to `point` (world)."""
    best, best_d = None, float("inf")
    for b in arm.data.bones:
        h = arm.matrix_world @ b.head_local
        t = arm.matrix_world @ b.tail_local
        seg = t - h
        k = 0.0 if seg.length_squared < 1e-12 else max(0.0, min(1.0, (point - h).dot(seg) / seg.length_squared))
        d = (point - (h + seg * k)).length
        if d < best_d:
            best, best_d = b.name, d
    return best


def adopt(scene, obj, arm, bone_name):
    """Makes `obj` a piece: attached to the bone (world placement kept), in Pieces, with a
    face id on every face."""
    attach(obj, arm, bone_name)
    col = _collection(scene, PIECES)
    if obj.name not in col.objects:
        for c in list(obj.users_collection):
            c.objects.unlink(obj)
        col.objects.link(obj)
    if obj.data.attributes.get(FACE_ATTR) is None:
        obj.data.attributes.new(FACE_ATTR, 'INT', 'FACE')
    stamp_faces(scene)


def make_piece(scene, arm, bone_name, shape="TUBE", sides=6):
    """A starter mesh along a bone, like Godot's (tube or box from head to tail), its
    object frame on the world origin (so a plain Mirror modifier mirrors across the body)."""
    bone = arm.data.bones[bone_name]
    m = arm.matrix_world @ bone.matrix_local
    length = bone.length
    r = max(min(length * 0.18, 0.08), 0.015)
    verts, faces = [], []
    if shape == "BOX":
        for y in (0.0, length):
            for x, z in ((-r, -r), (r, -r), (r, r), (-r, r)):
                verts.append((x, y, z))
        faces = [(0, 1, 2, 3), (4, 7, 6, 5)] + [(k, (k + 1) % 4, (k + 1) % 4 + 4, k + 4) for k in range(4)]
    else:
        n = max(3, sides)
        for y in (0.0, length):
            for k in range(n):
                a = math.tau * (k + 0.5) / n
                verts.append((math.cos(a) * r, y, math.sin(a) * r))
        faces = [(k, (k + 1) % n, n + (k + 1) % n, n + k) for k in range(n)]
        faces.append(tuple(reversed(range(n))))
        faces.append(tuple(range(n, 2 * n)))
    me = bpy.data.meshes.new(bone_name)
    me.from_pydata([m @ Vector(v) for v in verts], [], faces)
    me.update()
    me.validate()
    obj = bpy.data.objects.new(bone_name, me)
    scene.collection.objects.link(obj)
    adopt(scene, obj, arm, bone_name)
    # Outward faces whichever way the bone's frame turns.
    if _inward(obj):
        me.flip_normals()
    return obj


def _inward(obj):
    me = obj.data
    c = sum((v.co for v in me.vertices), Vector()) / max(len(me.vertices), 1)
    out = sum(1 for p in me.polygons if p.normal.dot(p.center - c) > 0.0)
    return out < len(me.polygons) * 0.5


# --- Workspace ------------------------------------------------------------------------------

def apply_workspace(scene, settings):
    """Viewport look for character files; Blender's own grid and units. Snapping starts
    off (the magnet / Ctrl: Blender's grid), rotation steps are Godot's angle snap."""
    s = dict(DEFAULT_SETTINGS)
    s.update(settings or {})
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 1.0
    ts = scene.tool_settings
    ts.use_snap = False
    try:
        ts.snap_elements = {'GRID'}
    except TypeError:
        ts.snap_elements = {'INCREMENT'}
        ts.use_snap_grid_absolute = True
    ts.use_snap_translate = True
    ts.use_snap_rotate = True
    ts.use_snap_scale = False
    ts.snap_angle_increment_3d = math.radians(s["angle"])
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type != 'VIEW_3D':
                continue
            for space in area.spaces:
                if space.type != 'VIEW_3D':
                    continue
                space.overlay.grid_scale = 1.0
                space.overlay.grid_subdivisions = 10
                space.overlay.show_stats = True
                space.clip_start = 0.01
                space.clip_end = 100.0
                space.shading.show_backface_culling = True
    scene["n64_settings"] = json.dumps(s)


def frame_views(scene):
    """Points every open 3D view at the character / set piece (Blender opens files ~15 m
    back)."""
    objs = meshes(scene)
    if not objs:
        return
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != 'VIEW_3D':
                continue
            r3d = area.spaces.active.region_3d
            r3d.view_location = (lo + hi) * 0.5
            r3d.view_distance = max((hi - lo).length * 1.4, 0.3)


def settings(scene):
    try:
        return json.loads(scene.get("n64_settings", "{}"))
    except ValueError:
        return dict(DEFAULT_SETTINGS)


# --- Armature -------------------------------------------------------------------------------

def _set_edit_bone(eb, spec):
    eb.head = Vector(spec["head"])
    eb.tail = Vector(spec["tail"])
    eb.align_roll(Vector(spec["z"]))


def armature_matches(arm, bones) -> bool:
    for spec in bones:
        b = arm.data.bones.get(spec["name"])
        if b is None:
            return False
        if (b.head_local - Vector(spec["head"])).length > 1e-5 or (b.tail_local - Vector(spec["tail"])).length > 1e-5:
            return False
        if (b.matrix_local.to_3x3().col[2] - Vector(spec["z"]).normalized()).length > 1e-4:
            return False
    return True


def set_armature(scene, arm, bones, move_meshes=True):
    """Moves the bones to Godot's rest pose; attached meshes follow like Godot's pieces
    (rigid on their bone, stretched along it), or stay where they are (`move_meshes`
    off: the skeleton was fitted to them). Object mode only. True when changed."""
    if armature_matches(arm, bones):
        return False
    old = {b.name: (arm.matrix_world @ b.matrix_local, b.length) for b in arm.data.bones}
    objs = pieces(scene, arm)
    worlds = {o.name: o.matrix_world.copy() for o in objs}
    view_layer = bpy.context.view_layer
    active = view_layer.objects.active
    hidden = arm.hide_get()
    arm.hide_set(False)
    view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    for spec in bones:
        eb = arm.data.edit_bones.get(spec["name"])
        if eb:
            _set_edit_bone(eb, spec)
    bpy.ops.object.mode_set(mode='OBJECT')
    arm.hide_set(hidden)
    view_layer.objects.active = active
    done = set()
    for o in objs:
        name = o.parent_bone
        b = arm.data.bones[name]
        new = arm.matrix_world @ b.matrix_local
        before, length = old[name]
        stretch = Matrix.Diagonal((1.0, b.length / max(length, 1e-6), 1.0, 1.0))
        delta = new @ stretch @ before.inverted()
        world = worlds[o.name]
        o.matrix_parent_inverse = _bone_parent_matrix(arm, name).inverted() @ world @ o.matrix_basis.inverted()
        if move_meshes and o.data.name not in done:
            o.data.transform(world.inverted() @ delta @ world)
            o.data.update()
            done.add(o.data.name)
    return True


# --- Face ids -------------------------------------------------------------------------------

def stamp_faces(scene):
    """Gives faces without an id (made in Blender) a new one, so Godot can follow them."""
    nxt = int(scene.get(NEXT_FACE, 1))
    for o in meshes(scene):
        me = o.data
        if o.mode == 'EDIT':
            bm = bmesh.from_edit_mesh(me)
            layer = bm.faces.layers.int.get(FACE_ATTR) or bm.faces.layers.int.new(FACE_ATTR)
            changed = False
            for f in bm.faces:
                if f[layer] <= 0:
                    f[layer] = nxt
                    nxt += 1
                    changed = True
            if changed:
                bmesh.update_edit_mesh(me, loop_triangles=False, destructive=False)
            continue
        attr = me.attributes.get(FACE_ATTR)
        if attr is None or attr.domain != 'FACE' or attr.data_type != 'INT':
            if attr is not None:
                me.attributes.remove(attr)
            attr = me.attributes.new(FACE_ATTR, 'INT', 'FACE')
        values = [0] * len(me.polygons)
        attr.data.foreach_get("value", values)
        changed = False
        for i, v in enumerate(values):
            if v <= 0:
                values[i] = nxt
                nxt += 1
                changed = True
        if changed:
            attr.data.foreach_set("value", values)
    scene[NEXT_FACE] = nxt


# --- Reference images -----------------------------------------------------------------------

VIEW_NAMES = {1: "Front", 2: "Back", 3: "Left", 4: "Right", 5: "Top", 6: "Bottom"}


def set_references(scene, refs):
    """Image empties per view: {view, path, centre, right, up, toward, size [w, h],
    opacity, visible}. Shown only when looking straight down their axis."""
    col = _collection(scene, REFERENCES)
    by_view = {o.get(REF_VIEW): o for o in col.objects if o.get(REF_VIEW)}
    keep = set()
    for r in refs:
        v = int(r["view"])
        img = None
        if os.path.exists(r["path"]):
            img = bpy.data.images.load(r["path"], check_existing=True)
        if img is None:
            continue
        keep.add(v)
        e = by_view.get(v)
        if e is None:
            e = bpy.data.objects.new("Ref " + VIEW_NAMES.get(v, str(v)), None)
            e[REF_VIEW] = v
            col.objects.link(e)
        e.empty_display_type = 'IMAGE'
        e.data = img
        e.empty_display_size = 1.0
        e.empty_image_offset = (-0.5, -0.5)
        e.empty_image_side = 'FRONT'
        e.show_empty_image_only_axis_aligned = True
        e.show_empty_image_perspective = False
        e.show_empty_image_orthographic = True
        e.use_empty_image_alpha = True
        e.color[3] = float(r["opacity"])
        e.hide_select = True
        e.hide_viewport = not r["visible"]
        # The image's longer side spans the display size: scale to the frame's size.
        w, h = img.size if img.size[0] > 0 else (1, 1)
        base = (1.0, h / w) if w >= h else (w / h, 1.0)
        rot = Matrix((r["right"], r["up"], r["toward"])).transposed()
        e.matrix_world = Matrix.Translation(r["centre"]) @ rot.to_4x4() @ Matrix.Diagonal(
            (r["size"][0] / base[0], r["size"][1] / base[1], 1.0, 1.0))
    for v, e in by_view.items():
        if v not in keep:
            bpy.data.objects.remove(e)


# --- Create / dump --------------------------------------------------------------------------

def create(spec, path):
    """A new character file from Godot's base: armature, one object per piece."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene[SCENE_FLAG] = True
    data = bpy.data.armatures.new(spec["name"])
    data.display_type = 'STICK'
    arm = bpy.data.objects.new(spec["name"], data)
    arm.show_in_front = True
    scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    made = {}
    for b in spec["bones"]:
        eb = data.edit_bones.new(b["name"])
        _set_edit_bone(eb, b)
        made[b["name"]] = eb
    for b in spec["bones"]:
        if b["parent"]:
            made[b["name"]].parent = made[b["parent"]]
    bpy.ops.object.mode_set(mode='OBJECT')
    col = _collection(scene, PIECES)
    nxt = 1
    for p in spec["pieces"]:
        me = bpy.data.meshes.new(p["name"])
        me.from_pydata([Vector(v) for v in p["verts"]], [], p["faces"])
        me.update()
        attr = me.attributes.new(FACE_ATTR, 'INT', 'FACE')
        attr.data.foreach_set("value", p["face_ids"])
        nxt = max([nxt] + [i + 1 for i in p["face_ids"]])
        obj = bpy.data.objects.new(p["name"], me)
        col.objects.link(obj)
        attach(obj, arm, p["bone"])
    scene[NEXT_FACE] = nxt
    apply_workspace(scene, spec.get("settings"))
    set_references(scene, spec.get("references", []))
    bpy.ops.wm.save_as_mainfile(filepath=path)


def dump(scene):
    """Geometry for Godot: every attached object's evaluated mesh (modifiers applied) in
    the rest pose, world space, n-gons kept, plus the armature and any problems. Leaves
    the scene as it is (also runs live, after each edit)."""
    arm = armature(scene)
    out = {"bones": {}, "objects": [], "issues": [], "settings": settings(scene)}
    if arm is None:
        out["issues"].append({"object": "", "message": "No armature in the file."})
        return out
    for b in arm.data.bones:
        m = arm.matrix_world @ b.matrix_local
        out["bones"][b.name] = {"head": list(m.translation), "x": list(m.col[0][:3]), "y": list(m.col[1][:3]),
                                "z": list(m.col[2][:3]), "length": b.length}
    attached = set(o.name for o in pieces(scene, arm))
    dg = bpy.context.evaluated_depsgraph_get()
    for obj in scene.objects:
        if obj.type != 'MESH' or obj.get(REF_VIEW):
            continue
        if obj.name not in attached:
            out["issues"].append({"object": obj.name, "message": "Not attached to a bone (N64 Actor tab > Attach to Bone). Left out."})
            continue
        ev = obj.evaluated_get(dg)
        me = ev.to_mesh()
        # Rest pose (whatever the armature is posed in here).
        mw = _bone_parent_matrix(arm, obj.parent_bone) @ obj.matrix_parent_inverse @ obj.matrix_basis
        flip = mw.determinant() < 0.0
        verts = [list(mw @ v.co) for v in me.vertices]
        faces = []
        used = set()
        degenerate = 0
        for poly in me.polygons:
            vs = list(poly.vertices)
            if flip:
                vs.reverse()
            faces.append(vs)
            used.update(vs)
            if poly.area < 1e-10:
                degenerate += 1
        ids = [0] * len(me.polygons)
        attr = me.attributes.get(FACE_ATTR)
        if attr is not None and attr.domain == 'FACE' and attr.data_type == 'INT':
            attr.data.foreach_get("value", ids)
        mirrored = any(m.type == 'MIRROR' and m.show_viewport and m.use_axis[0] for m in obj.modifiers)
        out["objects"].append({"name": obj.name, "bone": obj.parent_bone, "verts": verts, "faces": faces,
                               "face_ids": ids, "mirrored": mirrored})
        loose = len(me.vertices) - len(used)
        if loose:
            out["issues"].append({"object": obj.name, "message": "%d loose vertices (not in any face), left out." % loose})
        if degenerate:
            out["issues"].append({"object": obj.name, "message": "%d zero-area faces." % degenerate})
        if not faces:
            out["issues"].append({"object": obj.name, "message": "No faces."})
        ev.to_mesh_clear()
    return out
