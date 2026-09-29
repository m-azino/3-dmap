extends Node3D
## CSE block navigation: path drawing, floor slicing, path-occlusion and room styling.
##
## Performance design (mobile web):
##  * Room metadata (name flags, floor, position, mesh, source materials) is parsed ONCE.
##  * The closest path point for every room is computed once per navigation, not per frame.
##  * Occlusion only re-runs when the camera moved/rotated past a threshold (or state changed),
##    and _process() sleeps entirely when no path is active.
##  * Materials are pooled: one SOLID / TARGET / GHOST variant per unique source material,
##    shared by every room. Changing the transparency slider only edits the (few) GHOST
##    variants' albedo alpha - no per-room duplicate(), no shader-mode switching at runtime.
##  * Target room uses UNSHADED rendering with high emission glow to make it stand out.

# --- Occlusion tuning ---
@export_group("Occlusion")
## Re-run occlusion when the camera moves farther than this (world units).
@export var occlusion_move_threshold: float = 0.35
## ...or rotates more than this many degrees.
@export var occlusion_rotate_threshold_deg: float = 1.0
## Minimum seconds between camera-driven occlusion passes.
@export var occlusion_min_interval: float = 0.05

const OCCLUSION_HIDE_ALIGNMENT := 0.45
const OCCLUSION_NEAR_MARGIN := 1.0
const OCCLUSION_HEIGHT_TOLERANCE := 0.5
const OPAQUE_ALPHA_THRESHOLD := 0.99

const PATH_WIDTH := 0.12
const PATH_HEIGHT_OFFSET := Vector3(0.0, 0.4, 0.0)

const STYLE_SOLID := 0
const STYLE_TARGET := 1
const STYLE_GHOST := 2
const STYLE_COUNT := 3


## Pre-parsed per-room data so no string work happens at runtime.
class RoomInfo extends RefCounted:
	var node: Node3D
	var node_name: String
	var mesh: MeshInstance3D = null
	var src_mats: Array[StandardMaterial3D] = [] # Original materials
	var applied_style: int = -1

	# Floor slicing flags
	var is_cs: bool = false
	var is_shared: bool = false
	var is_roof1: bool = false
	var is_roof2: bool = false
	var floor_group: int = 0          # 1, 2, 3 or 0 (= always visible)
	var is_floor_or_stair: bool = false

	# Occlusion flags
	var occ_is_cs: bool = false
	var occ_is_shared: bool = false
	var occ_floor: int = 1
	var occ_exempt: bool = false      # roofs, floor slabs, stairs

	# Spatial cache
	var pos: Vector3 = Vector3.ZERO
	var path_pt: Vector3 = Vector3.ZERO # Closest path point
	var blocks_height: bool = false


@onready var path_line: MeshInstance3D = $PathLine
@onready var cse_block: Node = $cseblock
@onready var start_marker: Node3D = $Marker3D
@onready var ui = $UI

var current_target_room: Node3D = null
var active_path_points: PackedVector3Array = PackedVector3Array()
var active_max_floor: int = 3
var current_room_opacity: float = 1.0 # 1.0 = fully solid

# Cached engine references
var _tree: SceneTree
var _viewport: Viewport
var _nav_map: RID
var _path_mesh: ImmediateMesh
var _camera: Camera3D

# Room caches
var _floor_rooms: Array[RoomInfo] = []   # Rooms touched by floor slicing
var _occ_rooms: Array[RoomInfo] = []     # Rooms touched by path occlusion
var _room_lookup: Dictionary = {}        # room name -> Node3D

# Material pool
var _variant_cache: Dictionary = {}      # source material -> [solid, target, ghost]
var _ghost_variants: Array[StandardMaterial3D] = []
var _outline_material: StandardMaterial3D

# Occlusion throttling state
var _occlusion_dirty: bool = true
var _occlusion_timer: float = 0.0
var _last_cam_pos: Vector3 = Vector3.ZERO
var _last_cam_fwd: Vector3 = Vector3.FORWARD
var _move_threshold_sq: float = 0.0
var _rot_cos: float = 1.0

var _nav_request_id: int = 0


func _ready() -> void:
	_tree = get_tree()
	_viewport = get_viewport()
	_nav_map = get_world_3d().get_navigation_map()
	_path_mesh = path_line.mesh as ImmediateMesh
	_outline_material = create_outline_material()

	_move_threshold_sq = occlusion_move_threshold * occlusion_move_threshold
	_rot_cos = cos(deg_to_rad(occlusion_rotate_threshold_deg))

	_build_room_cache()

	ui.room_selected.connect(navigate_to_room)
	if ui.has_signal("room_opacity_changed"):
		ui.room_opacity_changed.connect(_on_room_opacity_changed)

	set_process(false) # Only runs while a path is active


# ---------------------------------------------------------------------------
# ROOM CACHE
# ---------------------------------------------------------------------------
func _build_room_cache() -> void:
	_floor_rooms.clear()
	_occ_rooms.clear()

	for child in cse_block.get_children():
		var node := child as Node3D
		if node == null:
			continue
		var info := _create_room_info(node)
		if info.is_cs or info.is_shared:
			_floor_rooms.append(info)
		if info.occ_is_cs or info.occ_is_shared:
			_occ_rooms.append(info)


func _create_room_info(node: Node3D) -> RoomInfo:
	var info := RoomInfo.new()
	info.node = node
	info.node_name = String(node.name)
	info.pos = node.global_position

	var n := info.node_name
	var lower := n.to_lower()

	# Floor-slicing classification
	info.is_cs = n.begins_with("CS")
	info.is_shared = n.begins_with("shared")
	info.is_roof1 = n.begins_with("CSroof1")
	info.is_roof2 = n.begins_with("CSroof2")
	if n.begins_with("CS1"):
		info.floor_group = 1
	elif n.begins_with("CS2"):
		info.floor_group = 2
	elif n.begins_with("CS3"):
		info.floor_group = 3
	info.is_floor_or_stair = ("floor" in lower) or ("stair" in lower)

	# Occlusion classification
	info.occ_is_cs = lower.begins_with("cs")
	info.occ_is_shared = lower.begins_with("shared")
	if lower.begins_with("cs2"):
		info.occ_floor = 2
	elif lower.begins_with("cs3"):
		info.occ_floor = 3
	info.occ_exempt = lower.begins_with("csroof") or info.is_floor_or_stair

	var mesh := node as MeshInstance3D
	if mesh != null:
		info.mesh = mesh
		for i in mesh.get_surface_override_material_count():
			info.src_mats.append(mesh.get_active_material(i) as StandardMaterial3D)

	return info


func _find_room(room_name: String) -> Node3D:
	var cached: Variant = _room_lookup.get(room_name)
	if cached != null and is_instance_valid(cached):
		return cached as Node3D
	var found := cse_block.find_child(room_name, true, false) as Node3D
	if found != null:
		_room_lookup[room_name] = found
	return found


# ---------------------------------------------------------------------------
# NAVIGATION
# ---------------------------------------------------------------------------
func _on_room_opacity_changed(new_opacity: float) -> void:
	current_room_opacity = new_opacity

	for mat in _ghost_variants:
		var c := mat.albedo_color
		c.a = new_opacity
		mat.albedo_color = c

	_occlusion_dirty = true
	if current_target_room:
		handle_floor_visibility(current_target_room.name)


func navigate_to_room(room_name: String) -> void:
	var target_room := _find_room(room_name)
	if target_room == null:
		push_warning("Room not found -> " + room_name)
		return

	current_target_room = target_room
	handle_floor_visibility(room_name)

	_nav_request_id += 1
	var request_id := _nav_request_id

	await _tree.physics_frame
	if request_id != _nav_request_id:
		return

	active_path_points = NavigationServer3D.map_get_path(
		_nav_map,
		start_marker.global_position,
		target_room.global_position,
		true
	)

	if OS.is_debug_build():
		print("Calculated Path Points Count: ", active_path_points.size())

	draw_path_line(active_path_points)
	_rebuild_path_cache()

	_camera = _viewport.get_camera_3d()
	_occlusion_dirty = true
	set_process(active_path_points.size() > 0)


func _rebuild_path_cache() -> void:
	var count := active_path_points.size()
	if count == 0:
		return

	for info in _occ_rooms:
		if info.occ_exempt:
			continue
		var best := active_path_points[0]
		var best_d := INF
		for i in range(0, count, 2):
			var pt := active_path_points[i]
			var d := info.pos.distance_squared_to(pt)
			if d < best_d:
				best_d = d
				best = pt
		info.path_pt = best
		info.blocks_height = info.pos.y >= (best.y - OCCLUSION_HEIGHT_TOLERANCE)


# ---------------------------------------------------------------------------
# PATH OCCLUSION (throttled)
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_occlusion_timer = minf(_occlusion_timer + delta, occlusion_min_interval)
	if not _occlusion_dirty and _occlusion_timer < occlusion_min_interval:
		return

	if not is_instance_valid(_camera):
		_camera = _viewport.get_camera_3d()
		if _camera == null:
			return

	var cam_xf := _camera.global_transform
	var cam_pos := cam_xf.origin
	var cam_fwd := -cam_xf.basis.z

	if not _occlusion_dirty:
		var moved := cam_pos.distance_squared_to(_last_cam_pos) >= _move_threshold_sq
		var rotated := cam_fwd.dot(_last_cam_fwd) <= _rot_cos
		if not moved and not rotated:
			return

	_occlusion_dirty = false
	_occlusion_timer = 0.0
	_last_cam_pos = cam_pos
	_last_cam_fwd = cam_fwd
	update_path_occlusion(cam_pos)


func update_path_occlusion(cam_pos: Vector3) -> void:
	if active_path_points.size() == 0 or current_target_room == null:
		return

	for info in _occ_rooms:
		var node := info.node

		if info.occ_is_cs and info.occ_floor > active_max_floor:
			_set_node_visible(node, false)
			continue

		if info.occ_exempt or node == current_target_room:
			continue

		var hide_room := false
		if info.blocks_height:
			var to_room := info.pos - cam_pos
			var to_path := info.path_pt - cam_pos
			var room_dist := to_room.length()
			var path_dist := to_path.length()
			if room_dist < path_dist - OCCLUSION_NEAR_MARGIN:
				hide_room = to_room.dot(to_path) > OCCLUSION_HIDE_ALIGNMENT * room_dist * path_dist

		_set_node_visible(node, not hide_room)
		if not hide_room:
			set_room_style(info, true, false)


func _set_node_visible(node: Node3D, value: bool) -> void:
	if node.visible != value:
		node.visible = value


# ---------------------------------------------------------------------------
# FLOOR SLICING
# ---------------------------------------------------------------------------
func handle_floor_visibility(room_name: String) -> void:
	if not room_name.begins_with("CS"):
		return

	active_max_floor = 1
	if room_name.begins_with("CS2"):
		active_max_floor = 2
	elif room_name.begins_with("CS3"):
		active_max_floor = 3

	for info in _floor_rooms:
		var node := info.node

		if info.is_shared:
			_set_node_visible(node, true)
			set_room_style(info, false, false)
			continue

		if not info.is_cs:
			continue

		if info.is_roof1:
			_set_node_visible(node, false)
			continue
		elif info.is_roof2:
			_set_node_visible(node, true)
			continue

		var should_be_visible: bool = (info.floor_group <= 1) or (active_max_floor >= info.floor_group)
		_set_node_visible(node, should_be_visible)
		if not should_be_visible:
			continue

		if info.is_floor_or_stair:
			set_room_style(info, false, false)
			continue

		if info.node_name == room_name:
			set_room_style(info, false, true)  # Target room: Unshaded + Outline
		else:
			set_room_style(info, true, false)  # Semi-transparent base


# ---------------------------------------------------------------------------
# MATERIAL STYLING (pooled, no per-call duplicate())
# ---------------------------------------------------------------------------
func set_room_style(info: RoomInfo, make_transparent: bool, is_target: bool) -> void:
	var style := STYLE_SOLID
	if is_target:
		style = STYLE_TARGET
	elif make_transparent and current_room_opacity < OPAQUE_ALPHA_THRESHOLD:
		style = STYLE_GHOST
	_apply_style(info, style)


func _apply_style(info: RoomInfo, style: int) -> void:
	if info.mesh == null or info.applied_style == style:
		return
	info.applied_style = style

	for i in info.src_mats.size():
		var src := info.src_mats[i]
		if src == null:
			continue
		info.mesh.set_surface_override_material(i, _get_variant(src, style))


func _get_variant(src: StandardMaterial3D, style: int) -> StandardMaterial3D:
	var slots: Array = _variant_cache.get(src, [])
	if slots.is_empty():
		slots.resize(STYLE_COUNT)
		_variant_cache[src] = slots

	var mat: StandardMaterial3D = slots[style]
	if mat == null:
		mat = _make_variant(src, style)
		slots[style] = mat
	return mat


func _make_variant(src: StandardMaterial3D, style: int) -> StandardMaterial3D:
	var mat := src.duplicate() as StandardMaterial3D
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var color := mat.albedo_color
	match style:
		STYLE_TARGET:
			color.a = 1.0
			# --- UNSHADED & EMISSIVE TARGET ROOM ---
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED # Unaffected by directional lighting/shadows
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = 1.5 # Bright popping glow
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
			mat.next_pass = _outline_material

		STYLE_GHOST:
			color.a = current_room_opacity
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.emission_enabled = false
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
			mat.next_pass = null
			_ghost_variants.append(mat)

		_: # STYLE_SOLID
			color.a = 1.0
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.emission_enabled = false
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
			mat.next_pass = null

	mat.albedo_color = color
	return mat


func create_outline_material() -> StandardMaterial3D:
	var outline_mat := StandardMaterial3D.new()
	outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	outline_mat.albedo_color = Color("ffffffff")
	outline_mat.emission_enabled = true
	outline_mat.emission = Color("ffffffff")
	outline_mat.emission_energy_multiplier = 1.2
	outline_mat.grow = true
	outline_mat.grow_amount = 0.05
	return outline_mat


# ---------------------------------------------------------------------------
# PATH MESH
# ---------------------------------------------------------------------------
func draw_path_line(points: PackedVector3Array) -> void:
	_path_mesh.clear_surfaces()

	var count := points.size()
	if count < 2:
		return

	_path_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	var seg_prev := Vector3.ZERO
	var seg_next := (points[1] - points[0]).normalized()

	for i in count:
		var forward: Vector3
		if i == 0:
			forward = seg_next
		elif i == count - 1:
			forward = seg_prev
		else:
			seg_next = (points[i + 1] - points[i]).normalized()
			forward = (seg_prev + seg_next).normalized()

		var right := forward.cross(Vector3.UP).normalized() * PATH_WIDTH
		var current := points[i] + PATH_HEIGHT_OFFSET

		_path_mesh.surface_add_vertex(current - right)
		_path_mesh.surface_add_vertex(current + right)

		seg_prev = seg_next

	_path_mesh.surface_end()
