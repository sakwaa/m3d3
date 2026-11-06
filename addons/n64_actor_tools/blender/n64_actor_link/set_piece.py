"""Set piece .blend files for the N64 level tools: level brushes whose geometry is made
in Blender (an amphitheatre sunk into a hillside, a ruin, anything too unique for the
brush tools). Godot keeps where they stand and all their paint, lighting and baking.

Layout of a set piece file:
  - every mesh object is one Godot brush, named like the object (modifiers applied);
  - a FACE int attribute `n64_face` per mesh: ids Godot matches paint by;
  - "Surroundings": the level around the set piece as Godot has it, unselectable and
    never sent back (refreshed whenever Godot opens the file).

Everything here is in Blender space: Godot converts (its Y up <-> Z up, its -Z is +Y
here) on its side. The file's origin is where the set piece's brushes stand in Godot.
"""

import json

import bpy

from . import core

COLLECTION = "Set Piece"
SURROUNDINGS = "Surroundings"
DOOR_CUTS = "Door Cuts"
BOX_FACES = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]


def create(spec, path):
    """A new set piece file from Godot's brushes: one object per brush."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene[core.SET_FLAG] = True
    col = core._collection(scene, COLLECTION)
    nxt = 1
    for o in spec["objects"]:
        me = bpy.data.meshes.new(o["name"])
        me.from_pydata([tuple(v) for v in o["verts"]], [], o["faces"])
        me.update()
        attr = me.attributes.new(core.FACE_ATTR, 'INT', 'FACE')
        attr.data.foreach_set("value", o["face_ids"])
        nxt = max([nxt] + [i + 1 for i in o["face_ids"]])
        obj = bpy.data.objects.new(o["name"], me)
        col.objects.link(obj)
    scene[core.NEXT_FACE] = nxt
    core.apply_workspace(scene, spec.get("settings"))
    if spec.get("context"):
        set_context(scene, spec["context"])
    bpy.ops.wm.save_as_mainfile(filepath=path)


def set_context(scene, path):
    """The level around the set piece (from Godot's surroundings file): one unselectable
    mesh, solid and muted, to fit the set piece into the terrain against."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return
    col = core._collection(scene, SURROUNDINGS)
    obj = _context_mesh(col, SURROUNDINGS, data.get("verts", []), data.get("faces", []))
    mat = bpy.data.materials.get(SURROUNDINGS) or bpy.data.materials.new(SURROUNDINGS)
    mat.diffuse_color = (0.42, 0.45, 0.4, 1.0)
    obj.data.materials.append(mat)
    # Door openings Godot cuts into the set piece (never in this file's geometry): boxes.
    verts = []
    faces = []
    for box in data.get("cuts", []):
        base = len(verts)
        verts += box
        faces += [[base + i for i in f] for f in BOX_FACES]
    cuts = _context_mesh(col, DOOR_CUTS, verts, faces)
    cuts.display_type = 'WIRE'
    cuts.show_in_front = True


def _context_mesh(col, name, verts, faces):
    """A Godot-owned, unselectable mesh object (`name`) with new geometry."""
    obj = next((o for o in col.objects if o.get(core.CONTEXT_FLAG) and o.name.startswith(name)), None)
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    if obj is None:
        obj = bpy.data.objects.new(name, me)
        obj[core.CONTEXT_FLAG] = True
        col.objects.link(obj)
    else:
        old = obj.data
        obj.data = me
        if old.users == 0:
            bpy.data.meshes.remove(old)
    obj.hide_select = True
    return obj


def dump(scene):
    """Geometry for Godot: every mesh object's evaluated mesh (modifiers applied), world
    space, n-gons kept, plus any problems. Leaves the scene as it is (also runs live,
    after each edit)."""
    out = {"objects": [], "issues": [], "settings": core.settings(scene)}
    dg = bpy.context.evaluated_depsgraph_get()
    for obj in core.meshes(scene):
        ev = obj.evaluated_get(dg)
        me = ev.to_mesh()
        mw = obj.matrix_world
        flip = mw.determinant() < 0.0
        verts = [list(mw @ v.co) for v in me.vertices]
        faces = []
        used = set()
        degenerate = 0
        bent = 0
        for poly in me.polygons:
            vs = list(poly.vertices)
            if flip:
                vs.reverse()
            faces.append(vs)
            used.update(vs)
            if poly.area < 1e-10:
                degenerate += 1
            elif len(vs) > 3:
                # Godot paints a face on its plane: bent n-gons smear (triangulate them).
                n = (mw.to_3x3() @ poly.normal).normalized()
                c = mw @ poly.center
                if max(abs((mw @ me.vertices[v].co - c).dot(n)) for v in vs) > 0.002:
                    bent += 1
        ids = [0] * len(me.polygons)
        attr = me.attributes.get(core.FACE_ATTR)
        if attr is not None and attr.domain == 'FACE' and attr.data_type == 'INT':
            attr.data.foreach_get("value", ids)
        out["objects"].append({"name": obj.name, "verts": verts, "faces": faces, "face_ids": ids})
        loose = len(me.vertices) - len(used)
        if loose:
            out["issues"].append({"object": obj.name, "message": "%d loose vertices (not in any face), left out." % loose})
        if degenerate:
            out["issues"].append({"object": obj.name, "message": "%d zero-area faces." % degenerate})
        if bent:
            out["issues"].append({"object": obj.name, "message": "%d bent faces (not flat): paint smears on them; triangulate or flatten." % bent})
        if not faces:
            out["issues"].append({"object": obj.name, "message": "No faces."})
        ev.to_mesh_clear()
    if not out["objects"]:
        out["issues"].append({"object": "", "message": "No mesh objects: Godot keeps the brushes it has."})
    return out


def tris(scene, context):
    dg = context.evaluated_depsgraph_get()
    return sum(len(p.vertices) - 2 for o in core.meshes(scene) for p in o.evaluated_get(dg).data.polygons)

