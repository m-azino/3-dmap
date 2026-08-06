extends Node3D

# --- TUNING SETTINGS ---
@export var move_speed: float = 15.0
@export var rotate_speed: float = 0.3 # Sensitivity for orbiting
@export var zoom_speed: float = 3.0   # How much distance 1 scroll click adds
@export var zoom_smoothness: float = 12.0 # Higher = snappier, Lower = buttery/floaty
@export var min_zoom: float = 5.0     # Closest zoom
@export var max_zoom: float = 45.0    # Farthest zoom out

@onready var camera: Camera3D = $Camera3D

var is_orbiting: bool = false
var yaw: float = 0.0        # Horizontal rotation angle (Y-axis)
var pitch: float = -45.0    # Vertical tilt angle (X-axis)

# --- NEW SMOOTH ZOOM VARIABLES ---
var target_zoom: float = 20.0 # Where the camera WANTS to be
var current_zoom: float = 20.0 # Where the camera ACTUALLY is right now

func _ready():
	# 1. Read the starting rotation directly from what you set in the 3D viewport
	yaw = rotation_degrees.y
	pitch = camera.rotation_degrees.x
	
	# Clamp pitch so starting angle doesn't violate your limits (-80 to -10)
	pitch = clamp(pitch, -80.0, -10.0)
	
	# 2. Initialize zoom trackers to match the camera's starting distance
	current_zoom = camera.position.length()
	target_zoom = current_zoom
	
	# 3. Apply the initial orientation
	update_camera_transform()

func _unhandled_input(event: InputEvent):
	# 1. Start/Stop Orbit on Right-Click or Middle-Click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			is_orbiting = event.pressed
			
		# 2. Smooth Zoom Input (Now adjusts TARGET distance instead of instant snap!)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom = clamp(target_zoom - zoom_speed, min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom = clamp(target_zoom + zoom_speed, min_zoom, max_zoom)

	# 3. Smooth Orbit (Decoupled Yaw & Pitch prevents 90° tilts!)
	elif event is InputEventMouseMotion and is_orbiting:
		yaw -= event.relative.x * rotate_speed
		pitch -= event.relative.y * rotate_speed
		
		# Clamp vertical pitch so you can't flip upside down (-80° to -10°)
		pitch = clamp(pitch, -80.0, -10.0)
		
		update_camera_transform()

func update_camera_transform():
	# Apply Y-rotation (Yaw) to the parent rig
	rotation_degrees.y = yaw
	
	# Apply X-rotation (Pitch) ONLY to the child camera
	# Hardcoding Z to 0.0 guarantees the horizon NEVER tilts sideways
	camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)

func _process(delta: float):
	# --- SMOOTH ZOOM LERP ---
	# Smoothly slide current_zoom toward target_zoom every frame
	if not is_equal_approx(current_zoom, target_zoom):
		current_zoom = lerp(current_zoom, target_zoom, zoom_smoothness * delta)
		camera.position = camera.position.normalized() * current_zoom

	# --- KEYBOARD PANNING (WASD / Arrows) ---
	var input_dir: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.y -= 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1
		
	input_dir = input_dir.normalized()
	
	if input_dir != Vector2.ZERO:
		var forward: Vector3 = -camera.global_transform.basis.z
		forward.y = 0.0 
		forward = forward.normalized()
		
		var right: Vector3 = camera.global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		
		var move_vec: Vector3 = (right * input_dir.x + forward * input_dir.y) * move_speed * delta
		global_position += move_vec
