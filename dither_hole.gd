class_name DitherHole
extends RefCounted
## Helper for dither_hole.gdshader.
##
## Responsibilities
##  * Owns the shared path-data texture (updated only when the path / camera
##    direction / zoom actually change - never per material, never per mesh).
##  * Builds ShaderMaterials that mimic a StandardMaterial3D (cached per source).
##  * Cheaply tests whether a world-space AABB sits between the camera and the
##    path (so only real blockers pay for the discard-based shader).
##  * Registers meshes (trees, buildings, props - anything except what you
##    exclude) and swaps them between original and hole materials.
##  * Pre-warms the shader so the first swap does not hitch (WebGL compiles
##    shaders lazily on first draw).
##
## The camera is orthographic, so "in front of the path" and "screen-plane
## distance" are exact. With a perspective camera they are close approximations.

const MAX_POINTS := 10
const DATA_WIDTH := MAX_POINTS + 2        # texel 0 = header, texel 1 = camera, then points
const PATH_LIFT := Vector3(0.0, 0.5, 0.0) # Aim the hole at chest height above the floor
const ZOOM_REBUILD_RATIO := 0.04          # Re-upload when ortho zoom changes by 4%
const CAMERA_REUPLOAD_DOT := 0.99998      # ~0.36 degrees

# Tunables (set through configure() / directly)
var radius_screen: float = 0.08   # Hole radius as a fraction of the ortho view size
var softness: float = 0.4         # Fraction of the radius used for the dithered fade
var depth_margin: float = 0.75    # Only cut geometry at least this far in front of the path
var pixel_size: float = 3.0       # Dither cell size in screen pixels
var follow_path: bool = true      # false = only open a hole at the destination

# Ground-like meshes are skipped by the automatic "everything" registration so the
# terrain does not get cut open. A mesh is "ground-like" if it is flat AND wide.
var skip_flat_height: float = 1.0
var skip_flat_extent: float = 6.0
var skip_keywords := PackedStringArray()   # lowercase substrings of node names to skip

var _radius: float = 8.0          # Current radius in world units
var _last_ortho_size: float = 50.0

var _shader: Shader
var _shader_double: Shader
var _img: Image
var _data_tex: ImageTexture
var _mats: Dictionary = {}        # source material -> ShaderMaterial
var _registered: Dictionary = {}  # instance id -> true (de-duplication)

# Path (world space), reused every navigation
var _pts := PackedVector3Array()
var _count: int = 0
var _sent_back := Vector3.ZERO

# Per-query camera data (reused, no allocations)
var _right := Vector3.RIGHT
var _up := Vector3.UP
var _back := Vector3.BACK
var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _pz := PackedFloat32Array()
var _bmin := Vector2.ZERO
var _bmax := Vector2.ZERO
var _min_z: float = 0.0

var _props: Array[PropEntry] = []

# Registration statistics (printed by the caller in debug builds)
var stat_meshes: int = 0
var stat_multimeshes: int = 0
var stat_skipped_material: int = 0
var stat_skipped_ground: int = 0
var stat_skipped_excluded: int = 0
var stat_csg_baked: int = 0
var skipped_report := PackedStringArray()   # human-readable reasons (trees / roofs / extras only)
var _report_printed: int = 0

# Godot-built CSG shapes (e.g. trees made from CSGCylinder3D / CSGSphere3D). Their mesh only
# exists after the engine has built them, so they are baked into a MeshInstance3D a couple of
# frames after startup (see finish_csg()).
var _pending_csg: Array[CSGShape3D] = []
var _pending_force: Array[bool] = []
var _default_mat: StandardMaterial3D = null

## true = ShaderMaterials (e.g. a tree's wind/foliage shader) are cloned with the hole code
## injected into their own shader, so they keep their look and gain the hole.
var patch_shader_materials: bool = true
var stat_shader_patched: int = 0
var _patched_shaders: Dictionary = {}   # source Shader -> patched Shader (or null if it can't be patched)

# GLSL injected into other spatial shaders (same maths as dither_hole.gdshader)
const INJECT_DECLS := """
uniform sampler2D dh_data : filter_nearest, repeat_disable;

const float DH_BAYER[16] = float[16](
	0.03125, 0.53125, 0.15625, 0.65625,
	0.78125, 0.28125, 0.90625, 0.40625,
	0.21875, 0.71875, 0.09375, 0.59375,
	0.96875, 0.46875, 0.84375, 0.34375
);

float dh_coverage(vec3 p, vec3 back) {
	vec4 head = texelFetch(dh_data, ivec2(0, 0), 0);
	int count = int(head.x + 0.5);
	if (count <= 0) {
		return 0.0;
	}
	float radius = head.y;
	float margin = head.z;
	float inner = radius * (1.0 - head.w);
	float cover = 0.0;
	vec3 a = texelFetch(dh_data, ivec2(2, 0), 0).xyz;
	int segs = max(count - 1, 1);
	for (int i = 0; i < segs; i++) {
		vec3 b = texelFetch(dh_data, ivec2(2 + min(i + 1, count - 1), 0), 0).xyz;
		vec3 s = b - a;
		vec3 v = p - a;
		vec3 sp = s - back * dot(s, back);
		vec3 vp = v - back * dot(v, back);
		float len2 = dot(sp, sp);
		float t = 0.0;
		if (len2 > 0.0001) {
			t = clamp(dot(vp, sp) / len2, 0.0, 1.0);
		}
		float d = length(vp - sp * t);
		float depth = dot(v - s * t, back);
		float edge = 1.0 - smoothstep(inner, radius, d);
		float gate = clamp(depth - margin, 0.0, 1.0);
		cover = max(cover, edge * gate);
		a = b;
	}
	return cover;
}
"""

# Runs at the very start of the host shader's fragment(): VERTEX is still the untouched
# view-space position there (already includes any wind displacement from vertex()).
const INJECT_CALL := """
	{
		vec4 dh_h1 = texelFetch(dh_data, ivec2(1, 0), 0);
		vec3 dh_back = normalize(INV_VIEW_MATRIX[2].xyz);
		if (dot(dh_back, dh_h1.yzw) > 0.999) {
			vec3 dh_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
			float dh_cover = dh_coverage(dh_world, dh_back);
			if (dh_cover > 0.0) {
				vec2 dh_cell = floor(FRAGCOORD.xy / max(dh_h1.x, 1.0));
				ivec2 dh_px = ivec2(mod(dh_cell, 4.0));
				if (dh_cover > DH_BAYER[dh_px.y * 4 + dh_px.x]) {
					discard;
				}
			}
		}
	}
"""


## One mesh that can swap between its original and hole materials.
class PropEntry extends RefCounted:
	var geo: GeometryInstance3D
	var aabb: AABB
	var use_override: bool = false            # true = swap material_override (MultiMesh / overridden)
	var original_override: Material = null
	var override_hole: ShaderMaterial = null
	var originals: Array[Material] = []       # per-surface override materials (null = none)
	var hole_mats: Array[ShaderMaterial] = [] # per-surface hole materials (null = leave alone)
	var active: bool = false


# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------
func setup(shader_path: String) -> bool:
	if not ResourceLoader.exists(shader_path):
		push_warning("DitherHole: shader not found at '%s' - holes disabled." % shader_path)
		return false
	_shader = load(shader_path) as Shader
	if _shader == null:
		push_warning("DitherHole: '%s' is not a Shader - holes disabled." % shader_path)
		return false

	# Double-sided twin (for foliage with culling disabled)
	_shader_double = Shader.new()
	_shader_double.code = _shader.code.replace("cull_back", "cull_disabled")

	_pts.resize(MAX_POINTS)
	_px.resize(MAX_POINTS)
	_py.resize(MAX_POINTS)
	_pz.resize(MAX_POINTS)

	_img = Image.create(DATA_WIDTH, 1, false, Image.FORMAT_RGBAF)
	_data_tex = ImageTexture.create_from_image(_img)
	return true


func configure(p_radius_screen: float, p_softness: float, p_depth_margin: float,
		p_pixel_size: float, p_follow_path: bool) -> void:
	radius_screen = p_radius_screen
	softness = clampf(p_softness, 0.05, 0.95)
	depth_margin = p_depth_margin
	pixel_size = maxf(p_pixel_size, 1.0)
	follow_path = p_follow_path
	_radius = radius_screen * _last_ortho_size
	_write_texture()


# ---------------------------------------------------------------------------
# PATH + CAMERA DATA
# ---------------------------------------------------------------------------
func set_path(points: PackedVector3Array) -> void:
	var n := points.size()
	if n == 0:
		clear()
		return

	if not follow_path:
		_pts[0] = points[n - 1] + PATH_LIFT
		_count = 1
	elif n <= MAX_POINTS:
		for i in n:
			_pts[i] = points[i] + PATH_LIFT
		_count = n
	else:
		# Evenly resample, always keeping the first and last point
		for i in MAX_POINTS:
			var idx := roundi(float(i) * float(n - 1) / float(MAX_POINTS - 1))
			_pts[i] = points[idx] + PATH_LIFT
		_count = MAX_POINTS
	_write_texture()


func clear() -> void:
	_count = 0
	_write_texture()
	release_props()


func has_path() -> bool:
	return _count > 0


## Call every frame while a path is active. Only touches the GPU texture when the
## camera direction or the ortho zoom changed noticeably.
## Returns true if the hole radius changed (so blockers should be re-evaluated).
func track_camera(back: Vector3, ortho_size: float) -> bool:
	if _count == 0:
		return false

	var radius_changed := false
	if absf(ortho_size - _last_ortho_size) > _last_ortho_size * ZOOM_REBUILD_RATIO:
		_last_ortho_size = ortho_size
		_radius = radius_screen * ortho_size
		radius_changed = true

	var b := back.normalized()
	if radius_changed or b.dot(_sent_back) < CAMERA_REUPLOAD_DOT:
		_sent_back = b
		_write_texture()
	return radius_changed


func _write_texture() -> void:
	if _img == null:
		return
	_img.set_pixel(0, 0, Color(float(_count), _radius, depth_margin, softness))
	_img.set_pixel(1, 0, Color(pixel_size, _sent_back.x, _sent_back.y, _sent_back.z))
	for i in _count:
		var p := _pts[i]
		_img.set_pixel(2 + i, 0, Color(p.x, p.y, p.z, 0.0))
	_data_tex.update(_img)


# ---------------------------------------------------------------------------
# MATERIALS
# ---------------------------------------------------------------------------
func _new_material(double_sided: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader_double if double_sided else _shader
	m.set_shader_parameter("hole_data", _data_tex)
	return m


## Builds (once per source material) a ShaderMaterial that looks like 'src'.
func make_material(src: BaseMaterial3D) -> ShaderMaterial:
	var cached := _mats.get(src) as ShaderMaterial
	if cached != null:
		return cached

	var m := _new_material(src.cull_mode == BaseMaterial3D.CULL_DISABLED)
	m.set_shader_parameter("albedo", src.albedo_color)
	m.set_shader_parameter("albedo_tex", src.albedo_texture)
	m.set_shader_parameter("uv1_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
	m.set_shader_parameter("uv1_offset", Vector2(src.uv1_offset.x, src.uv1_offset.y))
	m.set_shader_parameter("roughness", src.roughness)
	m.set_shader_parameter("metallic", src.metallic)
	m.set_shader_parameter("specular", src.metallic_specular)
	m.set_shader_parameter("use_vertex_color", src.vertex_color_use_as_albedo)

	var cut := 0.0
	if src.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		cut = src.alpha_scissor_threshold
	elif src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		cut = 0.5 # Blended / hashed leaves become cut-outs while holed
	m.set_shader_parameter("alpha_cut", cut)

	_mats[src] = m
	return m


# ---------------------------------------------------------------------------
# BLOCKER TEST (CPU, conservative: false positives only cost a shader swap)
# ---------------------------------------------------------------------------
func begin_query(cam_xf: Transform3D) -> void:
	_right = cam_xf.basis.x.normalized()
	_up = cam_xf.basis.y.normalized()
	_back = cam_xf.basis.z.normalized()
	if _count == 0:
		return

	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	var min_z := INF
	for i in _count:
		var p := _pts[i]
		var x := p.dot(_right)
		var y := p.dot(_up)
		var z := p.dot(_back)
		_px[i] = x
		_py[i] = y
		_pz[i] = z
		min_x = minf(min_x, x)
		max_x = maxf(max_x, x)
		min_y = minf(min_y, y)
		max_y = maxf(max_y, y)
		min_z = minf(min_z, z)

	_bmin = Vector2(min_x - _radius, min_y - _radius)
	_bmax = Vector2(max_x + _radius, max_y + _radius)
	_min_z = min_z


## True if the world-space box is between the camera and (part of) the path.
func is_blocking(aabb: AABB) -> bool:
	if _count == 0:
		return false

	var e := aabb.size * 0.5
	var c := aabb.position + e
	var cx := c.dot(_right)
	var cy := c.dot(_up)
	var cz := c.dot(_back)
	var hx := absf(_right.x) * e.x + absf(_right.y) * e.y + absf(_right.z) * e.z
	var hy := absf(_up.x) * e.x + absf(_up.y) * e.y + absf(_up.z) * e.z
	var hz := absf(_back.x) * e.x + absf(_back.y) * e.y + absf(_back.z) * e.z

	# Quick reject: box (in the screen plane) misses the path's padded bounds
	if cx + hx < _bmin.x or cx - hx > _bmax.x or cy + hy < _bmin.y or cy - hy > _bmax.y:
		return false

	# The box must reach in front of the path
	var front := cz + hz
	if front < _min_z + depth_margin:
		return false

	var reach := _radius + sqrt(hx * hx + hy * hy)
	var reach_sq := reach * reach
	var segs := maxi(_count - 1, 1)
	for i in segs:
		var j := mini(i + 1, _count - 1)
		var ax := _px[i]
		var ay := _py[i]
		var dx := _px[j] - ax
		var dy := _py[j] - ay
		var len2 := dx * dx + dy * dy
		var t := 0.0
		if len2 > 0.0001:
			t = clampf(((cx - ax) * dx + (cy - ay) * dy) / len2, 0.0, 1.0)
		var qx := ax + dx * t - cx
		var qy := ay + dy * t - cy
		if qx * qx + qy * qy <= reach_sq:
			if front > lerpf(_pz[i], _pz[j], t) + depth_margin:
				return true
	return false


# ---------------------------------------------------------------------------
# REGISTRATION (trees, buildings, props ...)
# ---------------------------------------------------------------------------
## Registers every MeshInstance3D / MultiMeshInstance3D under 'root' (root included).
##  force    = true  -> never skipped as ground-like (use for trees, roofs).
##  excluded = instance-id dictionary of nodes (and their children) to leave alone,
##             e.g. the CS rooms whose materials are managed elsewhere.
## Returns how many meshes were newly registered.
func register_props(root: Node, force: bool = false, excluded: Dictionary = {}) -> int:
	if _shader == null:
		return 0

	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "GeometryInstance3D", true, false))

	var added := 0
	for node in nodes:
		var id := node.get_instance_id()
		if _registered.has(id):
			continue
		if not excluded.is_empty() and _is_excluded(node, excluded):
			stat_skipped_excluded += 1
			continue

		var ok := false
		if node is MeshInstance3D:
			ok = _register_mesh(node as MeshInstance3D, force)
		elif node is MultiMeshInstance3D:
			ok = _register_multimesh(node as MultiMeshInstance3D, force)
		elif node is CSGShape3D:
			# Only the ROOT csg shape renders; its children are merged into it.
			var csg := node as CSGShape3D
			if csg.is_root_shape():
				_pending_csg.append(csg)
				_pending_force.append(force)
				_registered[id] = true
			continue
		else:
			if force and node is GeometryInstance3D:
				_note(node, "unsupported node type")
			continue

		if ok:
			_registered[id] = true
			added += 1
	return added


func _is_excluded(node: Node, excluded: Dictionary) -> bool:
	var p := node
	while p != null:
		if excluded.has(p.get_instance_id()):
			return true
		p = p.get_parent()
	return false


func _is_ground_like(node: Node, aabb: AABB) -> bool:
	if aabb.size.y <= skip_flat_height and maxf(aabb.size.x, aabb.size.z) >= skip_flat_extent:
		return true
	if not skip_keywords.is_empty():
		var lower := String(node.name).to_lower()
		for key in skip_keywords:
			if key != "" and lower.contains(key):
				return true
	return false


func _register_mesh(mi: MeshInstance3D, force: bool) -> bool:
	if mi.mesh == null:
		if force:
			_note(mi, "MeshInstance3D has no mesh")
		return false

	var aabb := mi.global_transform * mi.get_aabb()
	if not force and _is_ground_like(mi, aabb):
		stat_skipped_ground += 1
		return false

	var entry := PropEntry.new()
	entry.geo = mi
	entry.aabb = aabb

	if mi.material_override != null:
		var override_hole := _hole_material_for(mi.material_override)
		if override_hole == null:
			_skip_material(mi, mi.material_override, force)
			return false
		entry.use_override = true
		entry.original_override = mi.material_override
		entry.override_hole = override_hole
	else:
		var any := false
		for i in mi.mesh.get_surface_count():
			entry.originals.append(mi.get_surface_override_material(i))
			var current := mi.get_active_material(i)
			var hole_mat := _hole_material_for(current)
			if hole_mat != null:
				any = true
			else:
				_skip_material(mi, current, force)
			entry.hole_mats.append(hole_mat)
		if not any:
			return false

	_props.append(entry)
	stat_meshes += 1
	return true


func _register_multimesh(mmi: MultiMeshInstance3D, force: bool) -> bool:
	var mm := mmi.multimesh
	if mm == null or mm.mesh == null:
		if force:
			_note(mmi, "MultiMeshInstance3D has no multimesh/mesh")
		return false

	var src: Material = null
	if mmi.material_override != null:
		src = mmi.material_override
	elif mm.mesh.get_surface_count() == 1:
		src = mm.mesh.surface_get_material(0)
	else:
		if force:
			_note(mmi, "multimesh with several surfaces and no material_override")
		return false

	var multi_hole := _hole_material_for(src)
	if multi_hole == null:
		_skip_material(mmi, src, force)
		return false

	var entry := PropEntry.new()
	entry.geo = mmi
	entry.aabb = mmi.global_transform * mmi.get_aabb()
	entry.use_override = true
	entry.original_override = mmi.material_override
	entry.override_hole = multi_hole
	_props.append(entry)
	stat_multimeshes += 1
	return true


## Returns a hole-capable material that looks like 'mat', or null if that is impossible.
func _hole_material_for(mat: Material) -> ShaderMaterial:
	if mat == null:
		return make_material(_get_default_material()) # No material set: Godot's plain white default
	if mat is BaseMaterial3D:
		return make_material(mat as BaseMaterial3D)
	if patch_shader_materials and mat is ShaderMaterial:
		return _patch_shader_material(mat as ShaderMaterial)
	return null


## Clones a ShaderMaterial onto a copy of its own shader that has the hole code injected.
func _patch_shader_material(src: ShaderMaterial) -> ShaderMaterial:
	var cached := _mats.get(src) as ShaderMaterial
	if cached != null:
		return cached

	var shader := src.shader
	if shader == null:
		return null

	var patched: Shader = null
	if _patched_shaders.has(shader):
		patched = _patched_shaders[shader] as Shader
	else:
		patched = _patch_shader(shader)
		_patched_shaders[shader] = patched
	if patched == null:
		return null

	var m := ShaderMaterial.new()
	m.shader = patched
	for u in shader.get_shader_uniform_list():
		var uniform_name: String = u["name"]
		var value: Variant = src.get_shader_parameter(uniform_name)
		if value != null:
			m.set_shader_parameter(uniform_name, value)
	m.set_shader_parameter("dh_data", _data_tex)
	m.next_pass = src.next_pass
	m.render_priority = src.render_priority

	stat_shader_patched += 1
	_mats[src] = m
	return m


func _patch_shader(shader: Shader) -> Shader:
	if shader.get_mode() != Shader.MODE_SPATIAL:
		return null
	var code := shader.code

	var re := RegEx.new()
	re.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
	var found := re.search(code)

	var out := ""
	if found == null:
		# No fragment() at all: add one that only applies the hole
		out = code + "\n" + INJECT_DECLS + "\nvoid fragment() {" + INJECT_CALL + "}\n"
	else:
		var s := found.get_start()
		var e := found.get_end()
		out = code.substr(0, s) + INJECT_DECLS + "\n" + code.substr(s, e - s) + INJECT_CALL + code.substr(e)

	var patched := Shader.new()
	patched.code = out
	return patched


func _get_default_material() -> StandardMaterial3D:
	if _default_mat == null:
		_default_mat = StandardMaterial3D.new()
	return _default_mat


func _skip_material(node: Node, mat: Material, force: bool) -> void:
	stat_skipped_material += 1
	if force:
		if mat is ShaderMaterial:
			_note(node, "ShaderMaterial could not be patched (not a spatial shader?)")
		else:
			_note(node, "material is %s (needs a StandardMaterial3D or spatial ShaderMaterial)" % mat.get_class())


func _note(node: Node, reason: String) -> void:
	if skipped_report.size() < 30:
		skipped_report.append("%s [%s]: %s" % [node.get_path(), node.get_class(), reason])


# ---------------------------------------------------------------------------
# CSG SHAPES (trees etc. built from CSG nodes in the editor)
# ---------------------------------------------------------------------------
## Call once after register_props(). Waits for the engine to build the CSG meshes, then
## bakes each root CSG shape into a MeshInstance3D (sharing the same mesh resource, so no
## extra memory) which is registered like any other mesh. The original CSG node is only
## hidden. Falls back to a single-material override on engines without bake_static_mesh().
func finish_csg(tree: SceneTree) -> void:
	if _pending_csg.is_empty():
		return
	await tree.process_frame
	await tree.process_frame

	for i in _pending_csg.size():
		var csg := _pending_csg[i]
		if not is_instance_valid(csg):
			continue
		var force := _pending_force[i]

		var baked: Mesh = null
		if csg.has_method("bake_static_mesh"):
			baked = csg.call("bake_static_mesh") as Mesh

		if baked != null and baked.get_surface_count() > 0:
			var mi := MeshInstance3D.new()
			mi.name = String(csg.name) + "_hole"
			mi.mesh = baked
			mi.transform = csg.transform
			mi.cast_shadow = csg.cast_shadow
			mi.layers = csg.layers
			mi.visible = csg.visible
			csg.get_parent().add_child(mi)
			csg.visible = false # The baked copy replaces it visually
			if _register_mesh(mi, force):
				_registered[mi.get_instance_id()] = true
				stat_csg_baked += 1
		else:
			_register_csg_override(csg, force)

	_pending_csg.clear()
	_pending_force.clear()
	print_report()


## Fallback for engines without bake_static_mesh(): only works when the whole CSG tree
## uses one material (material_override replaces every surface).
func _register_csg_override(csg: CSGShape3D, force: bool) -> void:
	var mats: Array[Material] = []
	var has_unset := false
	var shapes: Array[Node] = [csg]
	shapes.append_array(csg.find_children("*", "CSGShape3D", true, false))
	for s in shapes:
		var m: Variant = s.get("material")
		if m == null:
			if s is CSGPrimitive3D or s is CSGMesh3D or s is CSGPolygon3D:
				has_unset = true
		elif not mats.has(m):
			mats.append(m)

	if mats.size() + (1 if has_unset else 0) > 1:
		if force:
			_note(csg, "CSG uses several materials and this engine has no bake_static_mesh()")
		return

	var base: BaseMaterial3D = null
	if mats.is_empty():
		base = _get_default_material()
	else:
		base = mats[0] as BaseMaterial3D
	if base == null:
		_skip_material(csg, mats[0], force)
		return

	var entry := PropEntry.new()
	entry.geo = csg
	entry.aabb = csg.global_transform * csg.get_aabb()
	entry.use_override = true
	entry.original_override = csg.material_override
	entry.override_hole = make_material(base)
	_props.append(entry)
	stat_meshes += 1


## Debug-build summary of what was (and wasn't) registered.
func print_report() -> void:
	if not OS.is_debug_build():
		return
	print("DitherHole: %d meshes registered (%d multimesh, %d baked CSG, %d patched ShaderMaterials) | skipped: %d ground-like, %d unsupported material, %d room-managed" % [
		_props.size(), stat_multimeshes, stat_csg_baked, stat_shader_patched,
		stat_skipped_ground, stat_skipped_material, stat_skipped_excluded])
	while _report_printed < skipped_report.size():
		print("  skipped -> ", skipped_report[_report_printed])
		_report_printed += 1


## Call after begin_query(): swaps meshes that currently block the path.
func update_props() -> void:
	for entry in _props:
		var want := is_blocking(entry.aabb)
		if want != entry.active:
			_set_prop_state(entry, want)


func release_props() -> void:
	for entry in _props:
		if entry.active:
			_set_prop_state(entry, false)


func _set_prop_state(entry: PropEntry, on: bool) -> void:
	entry.active = on
	if entry.use_override:
		entry.geo.material_override = entry.override_hole if on else entry.original_override
		return

	var mi := entry.geo as MeshInstance3D
	for i in entry.hole_mats.size():
		var hole_mat := entry.hole_mats[i]
		if hole_mat == null:
			continue
		mi.set_surface_override_material(i, hole_mat if on else entry.originals[i])


func registered_count() -> int:
	return _props.size()


# ---------------------------------------------------------------------------
# PREWARM (avoids a compile hitch the first time a blocker is swapped in)
# ---------------------------------------------------------------------------
## Draws a tiny quad with each shader variant for a couple of frames at startup.
func prewarm(tree: SceneTree, viewport: Viewport) -> void:
	if _shader == null:
		return
	await tree.process_frame
	var cam := viewport.get_camera_3d()
	if cam == null:
		return

	var quads: Array[MeshInstance3D] = []
	for double_sided in [false, true]:
		var quad_mesh := QuadMesh.new()
		quad_mesh.size = Vector2(0.01, 0.01)
		var mi := MeshInstance3D.new()
		mi.mesh = quad_mesh
		mi.material_override = _new_material(double_sided)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0.0, 0.0, -1.0)
		cam.add_child(mi)
		quads.append(mi)

	await tree.process_frame
	await tree.process_frame
	for mi in quads:
		if is_instance_valid(mi):
			mi.queue_free()
