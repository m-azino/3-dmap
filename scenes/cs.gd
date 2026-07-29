extends Node3D

@onready var path_line = $PathLine
@onready var cse_block = $cseblock
# 1. Grab the Marker3D node from your scene:
@onready var start_marker = $Marker3D 

func _ready():
	$UI/Panel/VBoxContainer/BtnHOD.pressed.connect(func(): navigate_to_room("CS3HOD"))
	$UI/Panel/VBoxContainer/BtnSemHall.pressed.connect(func(): navigate_to_room("CS1semhall"))

func navigate_to_room(room_name: String):
	var target_room = cse_block.find_child(room_name, true, false)
	if not target_room:
		print("ERROR: Room not found -> ", room_name)
		return
	
	handle_floor_visibility(room_name)
	
	# 1. WAIT for the NavigationServer to sync the map!
	await get_tree().physics_frame
	
	# 2. Get the navigation map and calculate the path
	var map = get_world_3d().get_navigation_map()
	var path_points = NavigationServer3D.map_get_path(
		map, 
		start_marker.global_position, 
		target_room.global_position, 
		true
	)
	
	# Debug print so you can see if it found points in the bottom console!
	print("Calculated Path Points Count: ", path_points.size())
	
	draw_path_line(path_points)

func handle_floor_visibility(room_name: String):
	# Determine target floor (1, 2, or 3)
	var target_floor := 1
	if room_name.begins_with("CS2"):
		target_floor = 2
	elif room_name.begins_with("CS3"):
		target_floor = 3
	
	for child in cse_block.get_children():
		var node_name: String = child.name
		
		# 1. Roofs
		if node_name.begins_with("CSroof1"):
			child.visible = false
			continue
		elif node_name.begins_with("CSroof2"):
			child.visible = true
			continue
		
		# 2. Floor Slice Visibility
		if node_name.begins_with("CS1"):
			child.visible = true
		elif node_name.begins_with("CS2"):
			child.visible = (target_floor >= 2)
		elif node_name.begins_with("CS3"):
			child.visible = (target_floor >= 3)
			
		# 3. KEEP ALL FLOOR SLABS SOLID! (No grass peeking through!)
		# This skips applying transparency to CS1floor, CS2floor, and CS3floor
		if "floor" in node_name.to_lower():
			set_room_style(child, false, false) # Opaque, no glow
			continue
			
		# 4. GLOW & TRANSPARENCY APPLY TO ROOMS/WALLS
		if node_name == room_name:
			set_room_style(child, false, true) # Not transparent, YES glow
		else:
			set_room_style(child, true, false) # YES transparent (40%), NO glow

func set_room_style(node: Node, make_transparent: bool, make_glow: bool):
	if not node is MeshInstance3D:
		return
		
	for i in range(node.get_surface_override_material_count()):
		var mat = node.get_active_material(i)
		if not mat is StandardMaterial3D:
			continue
			
		mat = mat.duplicate()
		node.set_surface_override_material(i, mat)
		
		if make_glow:
			# 1. Solid opaque + Soft, subtle highlight glow
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0
			mat.emission_enabled = true
			
			# Use a softer cyan-white tint so you can still see the original wall texture
			mat.emission = Color(1.0, 1.0, 1.0, 1.0) 
			
			# Dropped from 2.5 to 0.6 so it glows gently instead of blinding you
			mat.emission_energy_multiplier = 0.1 
			
		elif make_transparent:
			# 2. Bumped up to 40% opacity ("Glass Mode")
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.40 
			mat.emission_enabled = false
			
func draw_path_line(points: PackedVector3Array):
	var mesh = path_line.mesh as ImmediateMesh
	mesh.clear_surfaces()
	
	if points.size() < 2:
		return
		
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	
	# 1. Much sleeker width (0.12 instead of 0.35)
	var path_width := 0.12 
	var height_offset := Vector3(0, 0.4, 0)
	
	for i in range(points.size()):
		var current = points[i] + height_offset
		var forward = Vector3.FORWARD
		
		# 2. Smoother direction calculation for corners
		if i == 0:
			forward = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			forward = (points[i] - points[i - 1]).normalized()
		else:
			# Average the incoming and outgoing directions so turns look clean!
			var dir_in = (points[i] - points[i - 1]).normalized()
			var dir_out = (points[i + 1] - points[i]).normalized()
			forward = (dir_in + dir_out).normalized()
			
		var right = forward.cross(Vector3.UP).normalized() * path_width
		
		mesh.surface_add_vertex(current - right)
		mesh.surface_add_vertex(current + right)
		
	mesh.surface_end()
