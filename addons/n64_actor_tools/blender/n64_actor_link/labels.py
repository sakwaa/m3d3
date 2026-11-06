"""Grid measurements for character and set piece files: in front / side / top views, distances from
the origin along the centre line (heights) and the ground line (widths): "50 cm",
"1 m". The step follows the zoom (1 / 2 / 5 series) so labels never crowd."""

import blf
import bpy
from bpy_extras.view3d_utils import location_3d_to_region_2d, region_2d_to_location_3d
from mathutils import Vector

from . import core

STEPS = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
GAP_UP = 40  # pixels between height labels
GAP_ACROSS = 90  # between width labels (wider text)
COLOR = (1.0, 1.0, 1.0, 0.55)

_handle = None


def text(metres: float, signed=False) -> str:
    m = abs(metres)
    sign = "-" if signed and metres < 0.0 else ""
    if m < 1e-6:
        return "0"
    if m < 0.01:
        return "%s%g mm" % (sign, round(m * 1000.0, 3))
    if m < 1.0:
        return "%s%g cm" % (sign, round(m * 100.0, 3))
    return "%s%g m" % (sign, round(m, 3))


def _step(ppm: float, gap: float) -> float:
    return next((s for s in STEPS if s * ppm >= gap), STEPS[-1])


def _axis(v: Vector):
    """Index of the world axis `v` lies on (and its sign), or None if it doesn't."""
    for i in range(3):
        if abs(v[i]) > 0.9999:
            return i, (1.0 if v[i] > 0.0 else -1.0)
    return None


def _draw():
    context = bpy.context
    scene = context.scene
    if scene is None or not core.is_linked(scene) or not context.window_manager.n64_grid_labels:
        return
    region, rv3d = context.region, context.region_data
    if rv3d is None or rv3d.is_perspective:
        return
    inv = rv3d.view_matrix.inverted()
    right = _axis(inv.col[0].xyz)
    up = _axis(inv.col[1].xyz)
    if right is None or up is None:
        return
    w, h = region.width, region.height
    centre = rv3d.view_location
    a = region_2d_to_location_3d(region, rv3d, (0, 0), centre)
    b = region_2d_to_location_3d(region, rv3d, (w, h), centre)
    ppm = w / max(abs((b - a)[right[0]]), 1e-9)  # pixels per metre
    origin = location_3d_to_region_2d(region, rv3d, Vector((0.0, 0.0, 0.0)))
    if origin is None:
        return
    scale = context.preferences.system.ui_scale
    font = 0
    blf.size(font, 11 * scale)
    blf.color(font, *COLOR)
    blf.enable(font, blf.SHADOW)
    blf.shadow(font, 3, 0.0, 0.0, 0.0, 0.8)
    # Heights along the centre line (kept on screen), widths along the ground line.
    x0 = min(max(origin.x + 6 * scale, 70 * scale), w - 60 * scale)
    y0 = min(max(origin.y - 16 * scale, 30 * scale), h - 60 * scale)
    lo_up = min(a[up[0]], b[up[0]]) * up[1]
    hi_up = max(a[up[0]], b[up[0]]) * up[1]
    lo_up, hi_up = min(lo_up, hi_up), max(lo_up, hi_up)
    step = _step(ppm, GAP_UP * scale)
    k = int(lo_up // step)
    while k * step <= hi_up:
        y = origin.y + k * step * ppm
        # Clear of the width row along the ground.
        if k != 0 and 20 * scale < y < h - 50 * scale and abs(y - (y0 + 4 * scale)) > 14 * scale:
            blf.position(font, x0, y - 4 * scale, 0)
            blf.draw(font, text(k * step, signed=True))
        k += 1
    lo_r = min(a[right[0]] * right[1], b[right[0]] * right[1])
    hi_r = max(a[right[0]] * right[1], b[right[0]] * right[1])
    step = _step(ppm, GAP_ACROSS * scale)
    k = int(lo_r // step)
    while k * step <= hi_r:
        x = origin.x + k * step * ppm
        if k != 0 and 70 * scale < x < w - 60 * scale and abs(x - x0) > 40 * scale:
            label = text(k * step)
            tw = blf.dimensions(font, label)[0]
            blf.position(font, x - tw * 0.5, y0, 0)
            blf.draw(font, label)
        k += 1
    blf.disable(font, blf.SHADOW)


def register():
    global _handle
    bpy.types.WindowManager.n64_grid_labels = bpy.props.BoolProperty(
        name="Grid Measurements", default=True,
        description="Distances from the origin in front / side / top views")
    _handle = bpy.types.SpaceView3D.draw_handler_add(_draw, (), 'WINDOW', 'POST_PIXEL')


def unregister():
    global _handle
    if _handle is not None:
        bpy.types.SpaceView3D.draw_handler_remove(_handle, 'WINDOW')
        _handle = None
    del bpy.types.WindowManager.n64_grid_labels
