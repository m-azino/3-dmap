extends Node3D

@onready var path_line = $PathLine
@onready var cse_block = $cseblock
@onready var start_marker = $Marker3D

var current_target_room: Node3D = null
var active_path_points: PackedVector3Array = PackedVector3Array()
var active_max_floor: int = 3

func _ready():
	# Connects the UI menu's selection signal to your pathfinder
	$UI.room_selected.connect(navigate_to_room)

func navigate_to_room(room_name: String):
	var target_room = cse_block.find_child(room_name, true, false)
	if not target_room:
		print("ERROR: Room not found -> ", room_name)
		return
	
	current_target_room = target_room
	handle_floor_visibility(room_name)
	
	await get_tree().physics_frame
	
	var map = get_world_3d().get_navigation_map()
	active_path_points = NavigationServer3D.map_get_path(
		map, 
		start_marker.global_position, 
		target_room.global_position, 
		true
	)
	
	print("Calculated Path Points Count: ", active_path_points.size())
	draw_path_line(active_path_points)

func _process(_delta: float):
	# Continually check which rooms obstruct the cyan path as you orbit the camera!
	if active_path_points.size() > 0 and current_target_room:
		update_path_occlusion()

func update_path_occlusion():
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return
		
	var cam_pos: Vector3 = cam.global_position
	
	for child in cse_block.get_children():
		var node_name: String = child.name
		
		# 1. Check which floor this room belongs to. If it's above our target floor, KEEP IT HIDDEN!
		var room_floor := 1
		if node_name.begins_with("CS2"):
			room_floor = 2
		elif node_name.begins_with("CS3"):
			room_floor = 3
			
		if room_floor > active_max_floor:
			child.visible = false
			continue
		
		# 2. Never apply occlusion hiding to roofs, floor slabs, stairs, or our target room
		if node_name.begins_with("CSroof") or "floor" in node_name.to_lower() or "stair" in node_name.to_lower() or child == current_target_room:
			continue
			
		var room_pos: Vector3 = child.global_position
		var cam_to_room_dist: float = cam_pos.distance_to(room_pos)
		
		# 3. FIND THE CLOSEST POINT ON THE CYAN PATH TO THIS ROOM
		var closest_path_point: Vector3 = active_path_points[0]
		var min_dist_to_path: float = 999999.0
		
		for i in range(0, active_path_points.size(), 2):
			var pt = active_path_points[i]
			var d = room_pos.distance_to(pt)
			if d < min_dist_to_path:
				min_dist_to_path = d
				closest_path_point = pt
				
		var cam_to_path_dist: float = cam_pos.distance_to(closest_path_point)
		var cam_to_path_dir: Vector3 = (closest_path_point - cam_pos).normalized()
		
		# 4. IS THIS ROOM OBSTRUCTING OUR VIEW OF THAT PATH POINT?
		var is_closer: bool = cam_to_room_dist < (cam_to_path_dist - 1.0)
		
		var cam_to_room_dir: Vector3 = (room_pos - cam_pos).normalized()
		var alignment: float = cam_to_room_dir.dot(cam_to_path_dir) # 1.0 = direct alignment
		
		var is_blocking_height: bool = room_pos.y >= (closest_path_point.y - 0.5)
		
		# IF OBSTRUCTING: Make it FULLY INVISIBLE (`visible = false`)!
		# IF NOT OBSTRUCTING: Restore visibility (`visible = true`) & set to 75% semi-transparent!
		if is_closer and alignment > 0.45 and is_blocking_height:
			child.visible = false # CUTS THE ROOM ENTIRELY!
		else:
			child.visible = true  # RESTORES THE ROOM WHEN CAMERA ROTATES AWAY!
			set_room_style(child, true, false) # 75% Semi-Transparent

func handle_floor_visibility(room_name: String):
	# 1. Determine target floor (1, 2, or 3) and store it globally
	active_max_floor = 1
	if room_name.begins_with("CS2"):
		active_max_floor = 2
	elif room_name.begins_with("CS3"):
		active_max_floor = 3
	
	for child in cse_block.get_children():
		var node_name: String = child.name
		
		# 2. Hide top roofs when navigating inside
		if node_name.begins_with("CSroof1"):
			child.visible = false
			continue
		elif node_name.begins_with("CSroof2"):
			child.visible = true
			continue
			
		# 3. DOLLHOUSE SLICE: Completely hide floors above our destination!
		var should_be_visible := true
		if node_name.begins_with("CS1"):
			should_be_visible = true
		elif node_name.begins_with("CS2"):
			should_be_visible = (active_max_floor >= 2)
		elif node_name.begins_with("CS3"):
			should_be_visible = (active_max_floor >= 3)
			
		child.visible = should_be_visible
		if not should_be_visible:
			continue # Skip styling if the entire floor is sliced away!
			
		# 4. Keep floor slabs and stairs 100% solid always
		if "floor" in node_name.to_lower() or "stair" in node_name.to_lower():
			child.visible = true
			set_room_style(child, false, false) # 100% Solid
			continue
			
		# 5. Target room gets full visibility + Cyan Outline border
		if node_name == room_name:
			child.visible = true
			set_room_style(child, false, true) # 100% Solid + Outline
		else:
			child.visible = true
			set_room_style(child, true, false) # 75% Semi-Transparent base

func set_room_style(node: Node, make_transparent: bool, is_target: bool):
	if not node is MeshInstance3D:
		return
		
	for i in range(node.get_surface_override_material_count()):
		var mat = node.get_active_material(i)
		if not mat is StandardMaterial3D:
			continue
			
		mat = mat.duplicate()
		node.set_surface_override_material(i, mat)
		mat.emission_enabled = false
		
		if is_target:
			# Target Room: 100% Solid Opaque + Cyan Outline
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
			mat.next_pass = create_outline_material()
			
		elif make_transparent:
			# Non-blocking rooms: 75% Semi-Transparent + FORCE DEPTH DRAW!
			# (This stops Godot from eating the outer walls when alpha is turned on)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 1
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
			mat.next_pass = null
		else:
			# Solid 100% Opaque (For floors/stairs)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
			mat.next_pass = null

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

func draw_path_line(points: PackedVector3Array):
	var mesh = path_line.mesh as ImmediateMesh
	mesh.clear_surfaces()
	
	if points.size() < 2:
		return
		
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	
	var path_width: float = 0.12 
	var height_offset: Vector3 = Vector3(0.0, 0.4, 0.0)
	
	for i in range(points.size()):
		var current: Vector3 = points[i] + height_offset
		var forward: Vector3 = Vector3.FORWARD
		
		if i == 0:
			forward = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			forward = (points[i] - points[i - 1]).normalized()
		else:
			var dir_in: Vector3 = (points[i] - points[i - 1]).normalized()
			var dir_out: Vector3 = (points[i + 1] - points[i]).normalized()
			forward = (dir_in + dir_out).normalized()
			
		var right: Vector3 = forward.cross(Vector3.UP).normalized() * path_width
		
		mesh.surface_add_vertex(current - right)
		mesh.surface_add_vertex(current + right)
		
	mesh.surface_end()
