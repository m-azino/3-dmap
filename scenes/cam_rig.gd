extends Node3D

# --- TUNING SETTINGS ---
@export var pan_speed: float = 0.03     # Single-finger pan sensitivity
@export var rotate_speed: float = 0.07   # Mouse/touch orbit sensitivity
@export var zoom_speed: float = 2.0      # Mouse wheel zoom step
@export var pinch_sensitivity: float = 0.04 # Multi-touch pinch zoom speed
@export var zoom_smoothness: float = 12.0
@export var min_zoom: float = 10.0
@export var max_zoom: float = 100.0

@onready var camera: Camera3D = $Camera3D

# PC Drag & Orbit State
var is_panning: bool = false
var is_orbiting: bool = false

var yaw: float = 0.0
var pitch: float = -45.0

var target_zoom: float = 50.0 
var current_zoom: float = 50.0 

# Touch Gesture Tracking
var active_touches: Dictionary = {}
var initial_touch_dist: float = 0.0
var initial_touch_zoom: float = 50.0

func _ready():
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 1000.0
	
	yaw = rotation_degrees.y
	pitch = camera.rotation_degrees.x
	pitch = clamp(pitch, -80.0, -10.0)
	
	camera.size = target_zoom
	current_zoom = camera.size
	
	update_camera_transform()

func _unhandled_input(event: InputEvent):
	# --- MOUSE CONTROLS (PC) ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			is_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom = clamp(target_zoom - zoom_speed, min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom = clamp(target_zoom + zoom_speed, min_zoom, max_zoom)

	elif event is InputEventMouseMotion:
		if is_panning:
			pan_camera(event.relative)
		elif is_orbiting:
			orbit_camera(event.relative)

	# --- TOUCH CONTROLS (MOBILE PHONE) ---
	elif event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
		else:
			active_touches.erase(event.index)
			
		# Reset pinch reference baseline whenever finger count changes
		if active_touches.size() == 2:
			var points = active_touches.values()
			initial_touch_dist = points[0].distance_to(points[1])
			initial_touch_zoom = target_zoom
		else:
			initial_touch_dist = 0.0

	elif event is InputEventScreenDrag:
		active_touches[event.index] = event.position
		
		# 1 FINGER ONLY -> Pan Camera
		if active_touches.size() == 1:
			pan_camera(event.relative)
			
		# EXACTLY 2 FINGERS -> Orbit OR Pinch Zoom
		elif active_touches.size() == 2:
			var keys = active_touches.keys()
			var p1: Vector2 = active_touches[keys[0]]
			var p2: Vector2 = active_touches[keys[1]]
			var current_dist: float = p1.distance_to(p2)
			
			# Check how much fingers moved closer/further apart
			var dist_delta = abs(current_dist - initial_touch_dist)
			
			# If pinch distance delta is small, user is rotating; if large, user is zooming
			if dist_delta > 15.0 and initial_touch_dist > 0.0:
				# --- PINCH ZOOM ---
				var delta_dist: float = initial_touch_dist - current_dist
				target_zoom = clamp(initial_touch_zoom + (delta_dist * pinch_sensitivity), min_zoom, max_zoom)
			else:
				# --- TWO-FINGER ROTATION ---
				orbit_camera(event.relative * 0.3)

func pan_camera(relative: Vector2):
	var right: Vector3 = camera.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	
	var forward: Vector3 = -camera.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	
	# Scale sensitivity down with current orthographic size so drag distance feels 1:1 on screen
	var scale_factor: float = pan_speed * (current_zoom / 40.0)
	var move_vec: Vector3 = (-right * relative.x + forward * relative.y) * scale_factor
	global_position += move_vec

func orbit_camera(relative: Vector2):
	yaw -= relative.x * rotate_speed
	pitch -= relative.y * rotate_speed
	pitch = clamp(pitch, -80.0, -10.0)
	update_camera_transform()

func update_camera_transform():
	rotation_degrees.y = yaw
	camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)

func _process(delta: float):
	if not is_equal_approx(current_zoom, target_zoom):
		current_zoom = lerp(current_zoom, target_zoom, zoom_smoothness * delta)
		camera.size = current_zoom
