extends Node3D
## Orthographic map camera rig - mouse (PC) + touch (phone).
##
## TOUCH
##   1 finger drag ........ pan (1:1 with finger, with fling/inertia)
##   2 finger pinch ....... zoom (proportional + smoothed)
##   2 finger twist ....... rotate map around the SCREEN CENTER
##   2 finger drag up/down  tilt camera around the SCREEN CENTER
## MOUSE
##   Left drag = pan, Right/Middle drag = orbit, Wheel = zoom

# --- TUNING SETTINGS ---
@export_group("Zoom")
@export var min_zoom: float = 10.0
@export var max_zoom: float = 100.0
@export var zoom_speed: float = 2.0          # Mouse wheel step
@export var zoom_smoothness: float = 14.0    # Higher = snappier, lower = smoother

@export_group("Pan")
@export var pan_sensitivity: float = 1.0     # 1.0 = map sticks to finger exactly
@export var pan_inertia: bool = true
@export var inertia_damping: float = 4.0     # Higher = stops sooner
@export var min_fling_speed: float = 1.0

@export_group("Orbit")
@export var rotate_speed: float = 0.07       # Mouse orbit (deg/px)
@export var rotate_smoothness: float = 14.0  # Higher = snappier, lower = smoother
## Height (world Y) of the ground/floor the camera pivots around.
@export var focus_plane_y: float = 0.0

@export_group("Touch Two-Finger")
@export var twist_gain: float = 1.0          # Negative value inverts twist direction
@export var twist_threshold_deg: float = 6.0
@export var tilt_speed: float = 0.25         # Pitch degrees per pixel
@export var tilt_threshold_px: float = 12.0

@onready var camera: Camera3D = $Camera3D

# PC state
var is_panning: bool = false
var is_orbiting: bool = false

# Current (rendered) values and target (input-driven) values
var yaw: float = 0.0
var pitch: float = -45.0
var target_yaw: float = 0.0
var target_pitch: float = -45.0

var target_zoom: float = 50.0
var current_zoom: float = 50.0

# Touch state
var active_touches: Dictionary = {}
var _prev_dist: float = 0.0
var _prev_angle: float = 0.0
var _prev_mid: Vector2 = Vector2.ZERO
var _twist_accum: float = 0.0
var _twist_active: bool = false
var _tilt_accum: float = 0.0
var _tilt_active: bool = false

# Inertia state
var _pan_velocity: Vector3 = Vector3.ZERO
var _last_drag_msec: int = 0


func _ready():
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 1000.0

	yaw = rotation_degrees.y
	pitch = clampf(camera.rotation_degrees.x, -80.0, -10.0)
	target_yaw = yaw
	target_pitch = pitch

	camera.size = target_zoom
	current_zoom = camera.size

	_apply_view()


func _unhandled_input(event: InputEvent):
	# --- MOUSE (PC) ---
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		# Ignore the fake mouse events Godot creates from touches
		if event.device == InputEvent.DEVICE_ID_EMULATION or not active_touches.is_empty():
			return

		if event is InputEventMouseButton:
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					is_panning = event.pressed
				MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
					is_orbiting = event.pressed
				MOUSE_BUTTON_WHEEL_UP:
					target_zoom = clampf(target_zoom - zoom_speed, min_zoom, max_zoom)
				MOUSE_BUTTON_WHEEL_DOWN:
					target_zoom = clampf(target_zoom + zoom_speed, min_zoom, max_zoom)
		else:
			if is_panning:
				pan_camera(event.relative)
			elif is_orbiting:
				orbit_camera(event.relative)

	# --- TOUCH (PHONE) ---
	elif event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			active_touches[event.index] = event.position
			_pan_velocity = Vector3.ZERO
			_last_drag_msec = Time.get_ticks_msec()
		else:
			active_touches.erase(event.index)
			if active_touches.is_empty():
				var idle_ms := Time.get_ticks_msec() - _last_drag_msec
				if not pan_inertia or idle_ms > 80 or _pan_velocity.length() < min_fling_speed:
					_pan_velocity = Vector3.ZERO
		_reset_gesture_baseline()

	elif event is InputEventScreenDrag:
		if not active_touches.has(event.index):
			return
		active_touches[event.index] = event.position

		match active_touches.size():
			1:
				var move := pan_camera(event.relative)
				var now := Time.get_ticks_msec()
				var dt := clampf((now - _last_drag_msec) / 1000.0, 0.008, 0.05)
				_pan_velocity = _pan_velocity.lerp(move / dt, 0.5)
				_last_drag_msec = now
			2:
				_pan_velocity = Vector3.ZERO
				_handle_two_finger_gesture()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		active_touches.clear()
		_pan_velocity = Vector3.ZERO
		is_panning = false
		is_orbiting = false
		_reset_gesture_baseline()


# ---------------------------------------------------------------------------
# TWO-FINGER GESTURE
# ---------------------------------------------------------------------------
func _reset_gesture_baseline() -> void:
	_twist_accum = 0.0
	_tilt_accum = 0.0
	_twist_active = false
	_tilt_active = false
	if active_touches.size() == 2:
		var pts: Array = active_touches.values()
		_prev_dist = pts[0].distance_to(pts[1])
		_prev_angle = (pts[1] - pts[0]).angle()
		_prev_mid = (pts[0] + pts[1]) * 0.5
	else:
		_prev_dist = 0.0


func _handle_two_finger_gesture() -> void:
	var pts: Array = active_touches.values()
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	var dist := a.distance_to(b)
	if dist < 1.0 or _prev_dist <= 0.0:
		return
	var angle := (b - a).angle()
	var mid := (a + b) * 0.5

	# 1) PINCH ZOOM (smoothed toward target in _process)
	target_zoom = clampf(target_zoom * (_prev_dist / dist), min_zoom, max_zoom)

	# 2) TWIST -> yaw. Angle is noisy when fingers are close, so fade it in with distance.
	var d_angle := angle_difference(_prev_angle, angle)
	var twist_weight := clampf(dist / 150.0, 0.0, 1.0)
	if _twist_active:
		target_yaw += rad_to_deg(d_angle) * twist_gain * twist_weight
	else:
		_twist_accum += d_angle
		if absf(rad_to_deg(_twist_accum)) >= twist_threshold_deg:
			_twist_active = true

	# 3) MIDPOINT VERTICAL DRAG -> pitch
	var d_mid_y := mid.y - _prev_mid.y
	if _tilt_active:
		target_pitch = clampf(target_pitch - d_mid_y * tilt_speed, -80.0, -10.0)
	else:
		_tilt_accum += d_mid_y
		if absf(_tilt_accum) >= tilt_threshold_px:
			_tilt_active = true

	_prev_dist = dist
	_prev_angle = angle
	_prev_mid = mid


# ---------------------------------------------------------------------------
# CAMERA MOVEMENT
# ---------------------------------------------------------------------------
func _units_per_pixel() -> float:
	var vp := get_viewport().get_visible_rect().size
	var px := vp.y if camera.keep_aspect == Camera3D.KEEP_HEIGHT else vp.x
	return current_zoom / maxf(px, 1.0)


func pan_camera(relative: Vector2) -> Vector3:
	var right: Vector3 = camera.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	var forward: Vector3 = -camera.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()

	var tilt_comp := 1.0 / maxf(sin(deg_to_rad(-pitch)), 0.25)

	var move: Vector3 = (-right * relative.x + forward * relative.y * tilt_comp) \
			* _units_per_pixel() * pan_sensitivity
	global_position += move
	return move


func orbit_camera(relative: Vector2):
	target_yaw -= relative.x * rotate_speed
	target_pitch = clampf(target_pitch - relative.y * rotate_speed, -80.0, -10.0)


## Ground point currently at the CENTER of the screen (the natural pivot).
func _focus_point() -> Variant:
	var origin := camera.global_position
	var dir := -camera.global_transform.basis.z
	return Plane(Vector3.UP, focus_plane_y).intersects_ray(origin, dir)


## Applies yaw/pitch, then slides the rig so the screen-center ground point
## does not move. This is what makes rotation/tilt pivot around the screen
## center instead of swinging the map away.
func _apply_view() -> void:
	var before: Variant = _focus_point()
	rotation_degrees.y = yaw
	camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)
	var after: Variant = _focus_point()
	if before != null and after != null:
		global_position += (before as Vector3) - (after as Vector3)


func _process(delta: float):
	# Smooth zoom (wheel + pinch)
	if not is_equal_approx(current_zoom, target_zoom):
		var tz := 1.0 - exp(-zoom_smoothness * delta)
		current_zoom = lerpf(current_zoom, target_zoom, tz)
		if absf(current_zoom - target_zoom) < 0.005:
			current_zoom = target_zoom
		camera.size = current_zoom

	# Smooth rotation / tilt (all orbit input goes through the targets)
	if not is_equal_approx(yaw, target_yaw) or not is_equal_approx(pitch, target_pitch):
		var tr := 1.0 - exp(-rotate_smoothness * delta)
		yaw = lerpf(yaw, target_yaw, tr)
		pitch = lerpf(pitch, target_pitch, tr)
		if absf(yaw - target_yaw) < 0.01:
			yaw = target_yaw
		if absf(pitch - target_pitch) < 0.01:
			pitch = target_pitch
		_apply_view()

	# Fling / inertia after finger release
	if _pan_velocity != Vector3.ZERO and active_touches.is_empty():
		global_position += _pan_velocity * delta
		_pan_velocity *= exp(-inertia_damping * delta)
		if _pan_velocity.length() < 0.2:
			_pan_velocity = Vector3.ZERO
