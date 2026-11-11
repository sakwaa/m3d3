"""Limited dissolve for the level build, run by Blender headless:
  Blender -b --factory-startup --python dissolve.py -- IN.json OUT.json [ANGLE_DEG]
IN: {"meshes": [{"verts": [x, y, z, ...], "faces": [[i, ...], ...], "group": [g per face],
     "sharp": [[i, j], ...]}]}   (group: faces only merge within one group; sharp edges stay)
OUT: {"meshes": [{"faces": [[i, ...], ...], "src": [source face per output face]}]}
Vertices are never moved or added: every output face lists original vertex indices, and
`src` is one of the input faces it was merged from (its texture, UVs, surface carry over).
Faces bmesh can't hold (sharing all their corners with another face) come back as they were.
"""
import json
import math
import sys

import bmesh
import bpy

args = sys.argv[sys.argv.index("--") + 1:]
src_path, out_path = args[0], args[1]
angle = math.radians(float(args[2]) if len(args) > 2 else 1.0)
data = json.load(open(src_path))
out = {"meshes": []}
for m in data["meshes"]:
	vs = m["verts"]
	sharp = {tuple(sorted(e)) for e in m.get("sharp", [])}
	res = {"faces": [], "src": []}
	# Each merge group alone (faces of different groups can't merge then, whatever the delimit
	# does: it let a floor merge into a wall's material). A group's border edges have one face
	# in its own mesh, so their vertices stay (use_dissolve_boundaries off): the faces of the
	# group next door still meet them, no cracks.
	by_group = {}
	for fi, gi in enumerate(m["group"]):
		by_group.setdefault(gi, []).append(fi)
	for gi, fis in by_group.items():
		bm = bmesh.new()
		# (Layers before elements: adding a layer invalidates element references.)
		vid = bm.verts.layers.int.new("vid")
		src = bm.faces.layers.int.new("src")
		made = {}
		kept = []  # faces bmesh won't take (the same corners as another face, e.g. a wall's two
		           # sides, or repeated corners): passed through untouched, never dropped
		for fi in fis:
			poly = m["faces"][fi]
			try:
				if len(set(poly)) != len(poly):
					raise ValueError("repeated corner")
				vs_ = []
				for i in poly:
					if i not in made:
						v = bm.verts.new((vs[i * 3], vs[i * 3 + 1], vs[i * 3 + 2]))
						v[vid] = i
						made[i] = v
					vs_.append(made[i])
				f = bm.faces.new(vs_)
			except ValueError:
				kept.append(fi)
				continue
			f[src] = fi
		for e in bm.edges:
			e.smooth = (e.verts[0][vid], e.verts[1][vid]) not in sharp and (e.verts[1][vid], e.verts[0][vid]) not in sharp
		bm.normal_update()  # (the angle test reads face normals; new faces have none)
		bmesh.ops.dissolve_limit(bm, angle_limit=angle, use_dissolve_boundaries=False,
			verts=bm.verts[:], edges=bm.edges[:], delimit={"SHARP"})
		for f in bm.faces:
			res["faces"].append([v[vid] for v in f.verts])
			res["src"].append(f[src])
		for fi in kept:
			res["faces"].append(list(m["faces"][fi]))
			res["src"].append(fi)
		bm.free()
	out["meshes"].append(res)
json.dump(out, open(out_path, "w"))
print("dissolved", len(out["meshes"]), "meshes")
