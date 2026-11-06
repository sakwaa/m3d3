@tool
extends Node
## Editor helper: clicking an axis on the 3D view's rotation gizmo snaps the camera but
## (in 4.7) skips "Auto Orthogonal", so the view stays "Front Perspective". This watches
## the four editor viewports: when a perspective camera lands exactly on an axis and the
## viewport has Auto Orthogonal ticked, it switches that view to orthogonal through the
## viewport's own menu; orbiting off the axis switches it back to perspective.

const ALIGNED := 0.99999

var _views: Array[Dictionary] = []


func _ready() -> void:
	for i in 4:
		_views.append({aligned = false, ours = false, menu = null, persp = -1, ortho = -1, auto = -1})


func _process(_delta: float) -> void:
	for i in 4:
		var svp := EditorInterface.get_editor_viewport_3d(i)
		var cam := svp.get_camera_3d() if svp else null
		if cam == null or not svp.get_parent().is_visible_in_tree():
			continue
		var v := _views[i]
		var d := -cam.global_basis.z
		var aligned := maxf(absf(d.x), maxf(absf(d.y), absf(d.z))) > ALIGNED
		var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
		if aligned and not v.aligned and not ortho and _auto_on(svp, v):
			_press(v, v.ortho)
			v.ours = true
		elif v.ours and (not ortho or not aligned):
			if ortho:
				_press(v, v.persp)
			v.ours = false
		v.aligned = aligned


## Whether the viewport's "Auto Orthogonal Enabled" item is ticked (finds and caches its
## view menu on first use).
func _auto_on(svp: SubViewport, v: Dictionary) -> bool:
	if not is_instance_valid(v.menu):
		v.menu = null
		_find_menu(svp.get_parent().get_parent(), v)
	if v.menu == null:
		return false
	var m: PopupMenu = v.menu
	return m.is_item_checked(m.get_item_index(v.auto))


func _find_menu(n: Node, v: Dictionary) -> void:
	if n is PopupMenu:
		var m := n as PopupMenu
		var ids := {}
		for i in m.item_count:
			ids[m.get_item_text(i)] = m.get_item_id(i)
		if ids.has("Perspective") and ids.has("Orthogonal") and ids.has("Auto Orthogonal Enabled"):
			v.menu = m
			v.persp = ids["Perspective"]
			v.ortho = ids["Orthogonal"]
			v.auto = ids["Auto Orthogonal Enabled"]
			return
	for c in n.get_children(true):
		_find_menu(c, v)
		if v.menu:
			return


func _press(v: Dictionary, id: int) -> void:
	if v.menu and id >= 0:
		(v.menu as PopupMenu).id_pressed.emit(id)
