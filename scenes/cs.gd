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
	# Loop through EVERY child node inside your imported cseblock model
	for child in cse_block.get_children():
		var node_name: String = child.name
		
		# 1. ALWAYS hide CSroof1 when ANY CS room is chosen (CSroof2 stays visible)
		if node_name.begins_with("CSroof1"):
			child.visible = false
			continue
		elif node_name.begins_with("CSroof2"):
			child.visible = true
			continue
		
		# 2. Ground floor (CS1) is ALWAYS visible no matter what
		if node_name.begins_with("CS1"):
			child.visible = true
			
		# 3. First floor (CS2) is hidden ONLY if a CS1 room was chosen
		elif node_name.begins_with("CS2"):
			if room_name.begins_with("CS1"):
				child.visible = false
			else:
				child.visible = true
				
		# 4. Second floor (CS3) is hidden if a CS1 OR CS2 room was chosen
		elif node_name.begins_with("CS3"):
			if room_name.begins_with("CS1") or room_name.begins_with("CS2"):
				child.visible = false
			else:
				child.visible = true

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
