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
##  * DITHER HOLES (additive, see dither_hole.gd): trees/props and visible roofs that block the
##    path get a see-through dithered tunnel. Room hiding / roof logic is unchanged.

# --- Occlusion tuning ---
@export_group("Occlusion")
## Re-run occlusion when the camera moves farther than this (world units).
@export var occlusion_move_threshold: float = 0.35
## ...or rotates more than this many degrees.
@export var occlusion_rotate_threshold_deg: float = 1.0
## Minimum seconds between camera-driven occlusion passes.
@export var occlusion_min_interval: float = 0.05

# --- Dither hole tuning (trees, palms, visible roofs, extra props) ---
@export_group("Dither Hole")
@export var dither_holes_enabled: bool = true
@export_file("*.gdshader") var hole_shader_path: String = "res://dither_hole.gdshader"
## Hole radius as a fraction of the orthographic view size (constant on screen when zooming).
@export_range(0.02, 0.4) var hole_radius_screen: float = 0.08
@export_range(0.05, 0.95) var hole_softness: float = 0.4
## Geometry must be at least this far in front of the path to be cut (world units).
@export var hole_depth_margin: float = 0.75
## Size of one dither cell in screen pixels.
@export var hole_pixel_size: float = 3.0
## true = hole follows the whole path, false = only over the destination.
@export var hole_follow_path: bool = true
## Also give the CS roofs (which stay visible) a hole. Roof hiding itself is untouched.
@export var hole_on_roofs: bool = true
## Also dither CS rooms that are still visible while blocking the path (hiding still happens first).
@export var hole_on_rooms: bool = true
## Clone custom foliage/wind ShaderMaterials with the hole code injected into their own shader.
## Turn off if a tree turns invisible/pink while it is being cut.
@export var hole_patch_shader_materials: bool = true
## Give EVERY other mesh in the scene a hole too (other buildings, props...), not just trees/roofs.
## CS rooms are never touched here - they keep their existing hide / ghost behaviour.
@export var hole_on_everything: bool = true
## Meshes whose node name contains one of these (case-insensitive) never get holes (terrain etc.).
## Flat, wide meshes (ground-like) are skipped automatically as well.
@export var hole_skip_name_keywords: PackedStringArray = ["ground", "floor", "road", "grass", "terrain", "stair", "water", "sky"]
## Extra nodes whose meshes should also get holes (other buildings, props...).
@export var extra_occluder_paths: Array[NodePath] = []

# --- Admin block ---
@export_group("Admin Block")
## Shown while the admin block is collapsed (every AD<digit>* room is hidden then).
@export var admin_block_node_name: String = "ADMIN_BLOCK"
## Name of the block card in the UI menu that expands the admin block.
@export var admin_menu_name: String = "Admin Block"

const OCCLUSION_HIDE_ALIGNMENT := 0.45
const OCCLUSION_NEAR_MARGIN := 1.0
const OCCLUSION_HEIGHT_TOLERANCE := 0.5
const OPAQUE_ALPHA_THRESHOLD := 0.99

const PATH_WIDTH := 0.12
const PATH_HEIGHT_OFFSET := Vector3(0.0, 0.4, 0.0)

const STYLE_SOLID := 0
const STYLE_TARGET := 1
const STYLE_GHOST := 2
const STYLE_HOLE := 3
const STYLE_COUNT := 4

# Which building a room belongs to, so CS and Admin rooms never interfere with each other
const BLOCK_COMMON := 0 # shared walkways: follow whichever block is active
const BLOCK_CS := 1
const BLOCK_AD := 2


## Pre-parsed per-room data so no string work happens at runtime.
class RoomInfo extends RefCounted:
	var node: Node3D
	var node_name: String
	var mesh: MeshInstance3D = null
	var src_mats: Array[StandardMaterial3D] = [] # Original materials
	var block: int = 1                # 0 = common (shared), 1 = CS, 2 = Admin
	var applied_style: int = -1
	var pre_hole_style: int = -1      # Style to return to when leaving the HOLE style

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
	var aabb: AABB = AABB()           # World-space bounds (for the dither blocker test)
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

# Dither holes (null if the shader could not be loaded)
var _hole: DitherHole = null

# Occlusion throttling state
var _occlusion_dirty: bool = true
var _occlusion_timer: float = 0.0
var _last_cam_pos: Vector3 = Vector3.ZERO
var _last_cam_fwd: Vector3 = Vector3.FORWARD
var _move_threshold_sq: float = 0.0
var _rot_cos: float = 1.0

var _nav_request_id: int = 0

# Admin block: collapsed = only ADMIN_BLOCK visible, expanded = all AD<digit>* rooms visible
var _admin_block: Node3D = null
var _admin_nodes: Array[Node3D] = []
var _admin_expanded: bool = false
var _target_block: int = BLOCK_CS


func _ready() -> void:
	_tree = get_tree()
	_viewport = get_viewport()
	_nav_map = get_world_3d().get_navigation_map()
	_path_mesh = path_line.mesh as ImmediateMesh
	_outline_material = create_outline_material()

	_move_threshold_sq = occlusion_move_threshold * occlusion_move_threshold
	_rot_cos = cos(deg_to_rad(occlusion_rotate_threshold_deg))

	_build_room_cache()
	_init_admin_block()
	_setup_dither_holes()

	ui.room_selected.connect(navigate_to_room)
	if ui.has_signal("room_opacity_changed"):
		ui.room_opacity_changed.connect(_on_room_opacity_changed)
	if ui.has_signal("dither_holes_toggled"):
		ui.dither_holes_toggled.connect(set_dither_holes_enabled)
	if ui.has_signal("block_selected"):
		ui.block_selected.connect(_on_block_selected)

	set_process(false) # Only runs while a path is active


# ---------------------------------------------------------------------------
# ROOM CACHE
# ---------------------------------------------------------------------------
func _build_room_cache() -> void:
	_floor_rooms.clear()
	_occ_rooms.clear()
	_admin_nodes.clear()

	# CSE block children + every admin-block object (AD<digit>*) wherever it sits in the scene
	var candidates: Array[Node] = cse_block.get_children()
	for scene_node in _tree.root.find_children("*", "Node3D", true, false):
		if _is_admin_name(String(scene_node.name)):
			candidates.append(scene_node)

	var seen := {}
	for child in candidates:
		var node := child as Node3D
		if node == null or seen.has(node.get_instance_id()):
			continue
		seen[node.get_instance_id()] = true

		var info := _create_room_info(node)
		if info.is_cs or info.is_shared:
			_floor_rooms.append(info)
		if info.occ_is_cs or info.occ_is_shared:
			_occ_rooms.append(info)
		if info.block == BLOCK_AD:
			_admin_nodes.append(node)


func _create_room_info(node: Node3D) -> RoomInfo:
	var info := RoomInfo.new()
	info.node = node
	var raw_name := String(node.name)
	if _is_admin_name(raw_name):
		info.block = BLOCK_AD
		raw_name = _normalize_room_name(raw_name) # AD1bursar -> CS1bursar: same floor / room logic
	info.node_name = raw_name
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
	if info.occ_is_shared:
		info.block = BLOCK_COMMON
	if lower.begins_with("cs2"):
		info.occ_floor = 2
	elif lower.begins_with("cs3"):
		info.occ_floor = 3
	info.occ_exempt = lower.begins_with("csroof") or info.is_floor_or_stair

	var mesh := node as MeshInstance3D
	if mesh != null:
		info.mesh = mesh
		info.aabb = mesh.global_transform * mesh.get_aabb()
		for i in mesh.get_surface_override_material_count():
			info.src_mats.append(mesh.get_active_material(i) as StandardMaterial3D)

	return info


func _find_room(room_name: String) -> Node3D:
	var cached: Variant = _room_lookup.get(room_name)
	if cached != null and is_instance_valid(cached):
		return cached as Node3D
	var found := cse_block.find_child(room_name, true, false) as Node3D
	if found == null:
		found = _tree.root.find_child(room_name, true, false) as Node3D # e.g. admin block rooms
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
	_target_block = BLOCK_AD if _is_admin_name(String(target_room.name)) else BLOCK_CS
	if _target_block == BLOCK_AD and not _admin_expanded:
		_set_admin_expanded(true, false) # e.g. a phone opening a shared admin-room link
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
	if _hole != null:
		_hole.set_path(active_path_points)

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
	_track_hole_camera()
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
	_update_holes(cam_xf)


func update_path_occlusion(cam_pos: Vector3) -> void:
	if active_path_points.size() == 0 or current_target_room == null:
		return

	for info in _occ_rooms:
		if not _in_active_block(info):
			continue
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
	room_name = _normalize_room_name(room_name) # AD1xxx -> CS1xxx
	if not room_name.begins_with("CS"):
		return

	active_max_floor = 1
	if room_name.begins_with("CS2"):
		active_max_floor = 2
	elif room_name.begins_with("CS3"):
		active_max_floor = 3

	for info in _floor_rooms:
		if not _in_active_block(info):
			continue
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
	# A room wearing the dither material keeps it when the existing logic re-requests SOLID
	if info.applied_style == STYLE_HOLE and style == STYLE_SOLID:
		info.pre_hole_style = STYLE_SOLID
		return
	info.applied_style = style

	for i in info.src_mats.size():
		var src := info.src_mats[i]
		if src == null:
			continue
		info.mesh.set_surface_override_material(i, _get_variant(src, style))



## Swap a visible, blocking room to the dither-hole material (remembering where to return to).
func _enter_hole(info: RoomInfo) -> void:
	if info.applied_style == STYLE_HOLE:
		return
	info.pre_hole_style = info.applied_style
	_apply_style(info, STYLE_HOLE)


func _exit_hole(info: RoomInfo) -> void:
	if info.applied_style != STYLE_HOLE:
		return
	var previous := info.pre_hole_style
	info.applied_style = -1 # Leave the HOLE state first so _apply_style doesn't treat this as a re-request
	if previous == -1:
		_restore_original(info)
	else:
		_apply_style(info, previous)


## Puts the room's untouched source materials back.
func _restore_original(info: RoomInfo) -> void:
	for i in info.src_mats.size():
		var src := info.src_mats[i]
		if src != null:
			info.mesh.set_surface_override_material(i, src)
	info.applied_style = -1


func _get_variant(src: StandardMaterial3D, style: int) -> Material:
	var slots: Array = _variant_cache.get(src, [])
	if slots.is_empty():
		slots.resize(STYLE_COUNT)
		_variant_cache[src] = slots

	var mat: Material = slots[style]
	if mat == null:
		mat = _make_variant(src, style)
		slots[style] = mat
	return mat


func _make_variant(src: StandardMaterial3D, style: int) -> Material:
	# Hole variant: same look as the SOLID variant, rendered by the dither-hole shader
	if style == STYLE_HOLE:
		return _hole.make_material(_get_variant(src, STYLE_SOLID) as BaseMaterial3D)

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


# ---------------------------------------------------------------------------
# DITHER HOLES (additive - does not touch room hiding / roof logic above)
# ---------------------------------------------------------------------------
func _setup_dither_holes() -> void:
	var hole := DitherHole.new()
	if not hole.setup(hole_shader_path):
		return # Warning already printed; everything else keeps working
	hole.configure(hole_radius_screen, hole_softness, hole_depth_margin,
			hole_pixel_size, hole_follow_path)
	hole.skip_keywords = PackedStringArray(
		Array(hole_skip_name_keywords).map(func(k: String) -> String: return k.to_lower()))
	hole.patch_shader_materials = hole_patch_shader_materials
	_hole = hole

	# Nodes the existing room logic manages (hide / ghost / target style) are left alone.
	# Roofs are NOT in this list: they are never restyled, only shown/hidden.
	var excluded: Dictionary = {}
	excluded[path_line.get_instance_id()] = true
	for info in _occ_rooms:
		if not info.node_name.to_lower().begins_with("csroof"):
			excluded[info.node.get_instance_id()] = true
	for info in _floor_rooms:
		if not info.node_name.to_lower().begins_with("csroof"):
			excluded[info.node.get_instance_id()] = true

	# 1. TREES - the same ids the settings "Show Trees & Palms" button uses:
	#    the node named "trees" and the coco* children of the CSE block.
	var trees := _tree.root.find_child("trees", true, false)
	if trees != null:
		_hole.register_props(trees, true, excluded)
	for child in cse_block.get_children():
		if String(child.name).to_lower().begins_with("coco"):
			_hole.register_props(child, true, excluded)

	# 2. CS roofs (they stay visible, so they block the path with no hole otherwise)
	if hole_on_roofs:
		for info in _occ_rooms:
			if info.node_name.to_lower().begins_with("csroof"):
				_hole.register_props(info.node, true, excluded)

	# 3. Anything you point it at explicitly
	for path in extra_occluder_paths:
		var extra := get_node_or_null(path)
		if extra != null:
			_hole.register_props(extra, true, excluded)

	# 4. EVERYTHING else in the scene (other buildings, props, ...)
	if hole_on_everything:
		_hole.register_props(_tree.root, false, excluded)

	_hole.print_report()
	_hole.finish_csg(_tree) # Bakes Godot-built CSG trees a couple of frames later
	_hole.prewarm(_tree, _viewport)


## Called by the settings panel checkbox.
func set_dither_holes_enabled(on: bool) -> void:
	dither_holes_enabled = on
	if not on and _hole != null:
		_hole.release_props()
		for info in _occ_rooms:
			_exit_hole(info)
	_occlusion_dirty = true


## Every frame: keep the shader's shared data in sync (only uploads when the
## view direction or zoom changed noticeably).
func _track_hole_camera() -> void:
	if _hole == null or not dither_holes_enabled or not is_instance_valid(_camera):
		return
	var cam_xf := _camera.global_transform
	var ortho_size := _camera.size if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL else 50.0
	if _hole.track_camera(cam_xf.basis.z, ortho_size):
		_occlusion_dirty = true # Hole radius changed with zoom


## Runs right after the (unchanged) room occlusion pass.
func _update_holes(cam_xf: Transform3D) -> void:
	if _hole == null or not dither_holes_enabled:
		return
	_hole.begin_query(cam_xf)
	_update_room_holes()
	_hole.update_props()


## Rooms that are STILL VISIBLE after the existing hide logic ran, and that sit between the
## camera and the path, get the dither hole. (Hidden rooms need nothing; the target room,
## roofs, floor slabs and stairs are never dithered here.)
## Translucent rooms (Building Transparency < 100%) are already see-through, so they skip it.
func _update_room_holes() -> void:
	var rooms_use_holes := hole_on_rooms and current_room_opacity >= OPAQUE_ALPHA_THRESHOLD
	for info in _occ_rooms:
		if not _in_active_block(info):
			_exit_hole(info)
			continue
		if info.mesh == null:
			continue
		if (not rooms_use_holes) or (not info.node.visible) \
				or info.node == current_target_room or info.occ_exempt:
			_exit_hole(info)
			continue
		if _hole.is_blocking(info.aabb):
			_enter_hole(info)
		else:
			_exit_hole(info)


# ---------------------------------------------------------------------------
# ADMIN BLOCK (collapsed = ADMIN_BLOCK only, expanded = all AD rooms)
# ---------------------------------------------------------------------------
## "AD1", "AD2xxx", "AD3.001" ... but NOT "ADMIN_BLOCK".
func _is_admin_name(room_name: String) -> bool:
	return room_name.length() > 2 and room_name.begins_with("AD") and room_name.substr(2, 1).is_valid_int()


## AD<floor>... uses exactly the same floor / room logic as CS<floor>...
func _normalize_room_name(room_name: String) -> String:
	if _is_admin_name(room_name):
		return "CS" + room_name.substr(2)
	return room_name


## Admin rooms only take part while the admin block is expanded; CS rooms and shared
## walkways follow the block that is currently targeted.
func _in_active_block(info: RoomInfo) -> bool:
	if info.block == BLOCK_AD and not _admin_expanded:
		return false
	return info.block == BLOCK_COMMON or info.block == _target_block


func _init_admin_block() -> void:
	_admin_block = _tree.root.find_child(admin_block_node_name, true, false) as Node3D
	if _admin_block == null and not _admin_nodes.is_empty():
		push_warning("Admin block: node '%s' not found - admin rooms stay hidden until the admin block is selected." % admin_block_node_name)
	_set_admin_expanded(false, false) # Start: only ADMIN_BLOCK visible


func _on_block_selected(block_name: String) -> void:
	_set_admin_expanded(block_name == admin_menu_name)


func _set_admin_expanded(on: bool, reapply_floors: bool = true) -> void:
	_admin_expanded = on
	if _admin_block != null:
		_set_node_visible(_admin_block, not on)
	for node in _admin_nodes:
		_set_node_visible(node, on)
	_occlusion_dirty = true
	# Re-apply floor slicing if an admin room is already the target
	if on and reapply_floors and current_target_room != null and _target_block == BLOCK_AD:
		handle_floor_visibility(current_target_room.name)
