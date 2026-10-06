extends Node3D
## Orthographic map camera rig (v4) - mouse (PC) + touch (phone).
##
## The RIG ORIGIN is the pivot: the ground point at the centre of the screen.
## The camera is placed by this script at a fixed distance behind the pivot.
## => rotate / tilt always spin around the screen centre, pan moves the pivot.
##
## TOUCH: 1 finger = pan (+fling) | pinch = zoom | twist or 2-finger sideways = rotate | 2-finger up/down = tilt
## MOUSE: left drag = pan | right/middle drag = orbit | wheel = zoom

const VERSION := "v5"

@export_group("Zoom")
@export var min_zoom: float = 10.0
@export var max_zoom: float = 100.0
@export var zoom_speed: float = 2.0
@export var zoom_smoothness: float = 14.0

@export_group("Pan")
@export var pan_sensitivity: float = 1.25     # 1.0 = map sticks to the finger
@export var pan_inertia: bool = true          # Fling after release
@export var inertia_damping: float = 3.5     # Lower = glides further
@export var max_fling_px_per_sec: float = 2500.0

@export_group("Orbit")
@export var rotate_speed: float = 0.07        # Mouse orbit (deg/px)
@export var rotate_smoothness: float = 18.0
@export var min_pitch: float = -90.0     # -90 = straight top-down
@export var max_pitch: float = -10.0     # closer to 0 = nearer the horizon

@export_group("Touch Two-Finger")
@export var twist_gain: float = 2.0           # Negative inverts twist direction
@export var twist_threshold_deg: float = 3.0
@export var tilt_speed: float = 0.4           # deg per px
@export var tilt_threshold_px: float = 8.0
@export var drag_rotate_speed: float = 0.3    # Two fingers sideways = rotate (deg/px). Negative inverts.
@export var drag_rotate_threshold_px: float = 10.0
@export var tilt_inverted: bool = false

@export_group("Scene Setup")
## World Y of the floor the camera pivots around.
@export var focus_plane_y: float = 0.0
## 0 = keep the camera's current distance from the scene. Otherwise force a value.
@export var orbit_distance: float = 0.0
## Keep the pivot inside the map so it can never leave the screen.
@export var auto_bounds: bool = true
@export var bounds_margin: float = 10.0

@export_group("Debug")
@export var debug_overlay: bool = false       # Small text at bottom-left. Turn off when done.

@onready var camera: Camera3D = $Camera3D

# PC state
var is_panning: bool = false
var is_orbiting: bool = false

# Current (rendered) and target (input-driven) values
var yaw: float = 0.0
var pitch: float = -45.0
var target_yaw: float = 0.0
var target_pitch: float = -45.0
var target_zoom: float = 50.0
var current_zoom: float = 50.0

var _dist: float = 100.0
var bounds: Rect2 = Rect2()
var has_bounds: bool = false

# Touch state
var active_touches: Dictionary = {}   # finger index -> last screen position
var _prev_dist: float = 0.0
var _prev_angle: float = 0.0
var _prev_mid: Vector2 = Vector2.ZERO
var _twist_accum: float = 0.0
var _twist_active: bool = false
var _tilt_accum: float = 0.0
var _tilt_active: bool = false
var _drag_rot_accum: float = 0.0
var _drag_rot_active: bool = false

# Fling state (screen pixels per second)
var _fling_px: Vector2 = Vector2.ZERO
var _last_drag_msec: int = 0

var _dbg: Label


func _ready():
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = maxf(camera.far, 1000.0)

	yaw = rotation_degrees.y
	pitch = clampf(camera.rotation_degrees.x, min_pitch, max_pitch)
	target_yaw = yaw
	target_pitch = pitch

	# Measure the scene's current view, then move the rig origin onto the
	# screen-centre ground point so the view looks exactly the same.
	var hit: Variant = _ground_hit(camera.global_position, -camera.global_transform.basis.z)
	if hit != null:
		_dist = camera.global_position.distance_to(hit as Vector3)
		global_position = hit as Vector3
	else:
		_dist = 100.0
		global_position = Vector3(global_position.x, focus_plane_y, global_position.z)
	if orbit_distance > 0.0:
		_dist = orbit_distance

	camera.size = clampf(camera.size, min_zoom, max_zoom)
	target_zoom = camera.size
	current_zoom = camera.size

	_apply_view()

	if debug_overlay:
		_make_debug_overlay()
	if auto_bounds:
		_compute_bounds()


func _ground_hit(origin: Vector3, dir: Vector3) -> Variant:
	return Plane(Vector3.UP, focus_plane_y).intersects_ray(origin, dir)


func _apply_view() -> void:
	rotation_degrees = Vector3(0.0, yaw, 0.0)
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), 0.0, 0.0))
	camera.transform = Transform3D(b, b * Vector3(0.0, 0.0, _dist))


func _compute_bounds() -> void:
	await get_tree().process_frame
	var merged := AABB()
	var first := true
	for n in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		if first:
			merged = box
			first = false
		else:
			merged = merged.merge(box)
	if first:
		return
	bounds = Rect2(merged.position.x, merged.position.z, merged.size.x, merged.size.z).grow(bounds_margin)
	has_bounds = true


func _clamp_pivot() -> void:
	if has_bounds:
		global_position.x = clampf(global_position.x, bounds.position.x, bounds.end.x)
		global_position.z = clampf(global_position.z, bounds.position.y, bounds.end.y)


# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent):
	# --- MOUSE (PC) ---
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		# Ignore fake mouse events Godot generates from touches
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
				pan_pixels(event.relative)
			elif is_orbiting:
				target_yaw -= event.relative.x * rotate_speed
				target_pitch = clampf(target_pitch - event.relative.y * rotate_speed, min_pitch, max_pitch)

	# --- TOUCH (PHONE) ---
	elif event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			active_touches[event.index] = event.position
			_fling_px = Vector2.ZERO
			_last_drag_msec = Time.get_ticks_msec()
		else:
			active_touches.erase(event.index)
			if active_touches.is_empty():
				var idle_ms := Time.get_ticks_msec() - _last_drag_msec
				if not pan_inertia or idle_ms > 80 or _fling_px.length() < 300.0:
					_fling_px = Vector2.ZERO
		_reset_gesture_baseline()

	elif event is InputEventScreenDrag:
		# Only fingers that started on the map (not on UI buttons/sliders)
		if not active_touches.has(event.index):
			return
		# Movement is measured from our own stored positions, not event.relative
		var old_pos: Vector2 = active_touches[event.index]
		var rel: Vector2 = event.position - old_pos
		active_touches[event.index] = event.position

		match active_touches.size():
			1:
				pan_pixels(rel)
				var now := Time.get_ticks_msec()
				var dt := clampf((now - _last_drag_msec) / 1000.0, 0.008, 0.05)
				_fling_px = _fling_px.lerp(rel / dt, 0.4).limit_length(max_fling_px_per_sec)
				_last_drag_msec = now
			2:
				_fling_px = Vector2.ZERO
				_handle_two_finger_gesture()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		active_touches.clear()
		_fling_px = Vector2.ZERO
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
	_drag_rot_accum = 0.0
	_drag_rot_active = false
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
	if dist < 20.0 or _prev_dist < 20.0:   # fingers touching: readings are garbage
		_prev_dist = dist
		return
	var angle := (b - a).angle()
	var mid := (a + b) * 0.5

	# 1) PINCH ZOOM (per-event ratio clamped so a glitch can't launch the zoom)
	var ratio := clampf(_prev_dist / dist, 0.8, 1.25)
	target_zoom = clampf(target_zoom * ratio, min_zoom, max_zoom)

	# 2) TWIST -> yaw
	var d_angle := angle_difference(_prev_angle, angle)
	var twist_weight := clampf(dist / 100.0, 0.0, 1.0)
	if _twist_active:
		target_yaw += rad_to_deg(d_angle) * twist_gain * twist_weight
	else:
		_twist_accum += d_angle
		if absf(rad_to_deg(_twist_accum)) >= twist_threshold_deg:
			_twist_active = true

	# 3) MIDPOINT VERTICAL DRAG -> pitch
	var d_mid_y := mid.y - _prev_mid.y
	if _tilt_active:
		var s := -1.0 if tilt_inverted else 1.0
		target_pitch = clampf(target_pitch - d_mid_y * tilt_speed * s, min_pitch, max_pitch)
	else:
		_tilt_accum += d_mid_y
		if absf(_tilt_accum) >= tilt_threshold_px:
			_tilt_active = true

	# 4) MIDPOINT SIDEWAYS DRAG -> yaw (easier than twisting your wrist)
	var d_mid_x := mid.x - _prev_mid.x
	if _drag_rot_active:
		target_yaw -= d_mid_x * drag_rotate_speed
	else:
		_drag_rot_accum += d_mid_x
		if absf(_drag_rot_accum) >= drag_rotate_threshold_px:
			_drag_rot_active = true

	_prev_dist = dist
	_prev_angle = angle
	_prev_mid = mid


# ---------------------------------------------------------------------------
# PAN
# ---------------------------------------------------------------------------
## World units covered by one screen pixel (horizontal) at the current zoom.
func _units_per_pixel() -> float:
	var vp := get_viewport().get_visible_rect().size
	var px := vp.y if camera.keep_aspect == Camera3D.KEEP_HEIGHT else vp.x
	return current_zoom / maxf(px, 1.0)


func pan_pixels(rel: Vector2) -> void:
	var right: Vector3 = global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var forward: Vector3 = -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()

	# A tilted camera squashes ground distance vertically by sin(pitch); undo it
	var tilt_comp := 1.0 / maxf(sin(deg_to_rad(-pitch)), 0.25)

	global_position += (-right * rel.x + forward * rel.y * tilt_comp) \
			* _units_per_pixel() * pan_sensitivity
	_clamp_pivot()


# ---------------------------------------------------------------------------
# FRAME UPDATE
# ---------------------------------------------------------------------------
func _process(delta: float):
	# Smooth zoom
	if not is_equal_approx(current_zoom, target_zoom):
		current_zoom = lerpf(current_zoom, target_zoom, 1.0 - exp(-zoom_smoothness * delta))
		if absf(current_zoom - target_zoom) < 0.005:
			current_zoom = target_zoom
		camera.size = current_zoom

	# Smooth rotate / tilt
	if not is_equal_approx(yaw, target_yaw) or not is_equal_approx(pitch, target_pitch):
		var t := 1.0 - exp(-rotate_smoothness * delta)
		yaw = lerpf(yaw, target_yaw, t)
		pitch = lerpf(pitch, target_pitch, t)
		if absf(yaw - target_yaw) < 0.01:
			yaw = target_yaw
		if absf(pitch - target_pitch) < 0.01:
			pitch = target_pitch
		_apply_view()

	# Optional fling
	if _fling_px != Vector2.ZERO and active_touches.is_empty():
		pan_pixels(_fling_px * delta)
		_fling_px *= exp(-inertia_damping * delta)
		if _fling_px.length() < 20.0:
			_fling_px = Vector2.ZERO

	if _dbg:
		_dbg.text = "CamRig %s\ntouches %d | zoom %.1f\nyaw %.0f pitch %.0f | dist %.0f\npivot %.0f, %.0f | bounds %s | px=%.3fu" % [
			VERSION, active_touches.size(), current_zoom, yaw, pitch, _dist,
			global_position.x, global_position.z, str(has_bounds), _units_per_pixel()]


func _make_debug_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	_dbg = Label.new()
	_dbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dbg.add_theme_font_size_override("font_size", 14)
	_dbg.add_theme_color_override("font_outline_color", Color.BLACK)
	_dbg.add_theme_constant_override("outline_size", 4)
	layer.add_child(_dbg)
	add_child(layer)
	_dbg.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 10)
