extends CanvasLayer

signal room_opacity_changed(value: float)
signal room_selected(room_node_name: String)
signal dither_holes_toggled(enabled: bool)
signal block_selected(block_name: String)

@onready var btn_back: Button = $MenuContainer/VBox/Header/BtnBack
@onready var lbl_title: Label = $MenuContainer/VBox/Header/LblTitle
@onready var content_grid: GridContainer = $MenuContainer/VBox/ContentGrid

# Floors, derived from the room id (same naming cs.gd uses for floor slicing)
const FLOOR_NAMES := {
	1: "Ground Floor",
	2: "First Floor",
	3: "Second Floor"
}

const MENU_DATA := {
	"CSE Block": {
		"Classrooms": [
			{"id": "CS1room1", "label": "Class 1-1"},
			{"id": "CS1room2", "label": "Class 1-2"},
			{"id": "CS1room3", "label": "Class 1-3"},
			{"id": "CS1room5", "label": "Class 1-5"},
			{"id": "CS1room6", "label": "Class 1-6"},
			{"id": "CS2room1", "label": "Class 2-1"},
			{"id": "CS2room2", "label": "Class 2-2"},
			{"id": "CS2room3", "label": "Class 2-3"},
			{"id": "CS2room4", "label": "Class 2-4"},
			{"id": "CS2room5", "label": "Class 2-5"},
			{"id": "CS3room",  "label": "Class 3-1"}
		],
		"Faculty Rooms": [
			{"id": "CS3HOD",    "label": "HOD Room"},
			{"id": "CS1staff1", "label": "Staff Room 1"},
			{"id": "CS2staff1", "label": "Staff Room 2"},
			{"id": "CS2staff2", "label": "Staff Room 3"},
			{"id": "CS3staff1", "label": "Staff Room 4"},
			{"id": "CS3staff2", "label": "Staff Room 5"},
			{"id": "CS3conf",   "label": "Conference Room"}
		],
		"Seminar Hall": [
			{"id": "CS1semhall", "label": "Seminar Hall"}
		],
		"Labs": [
			{"id": "CS2lab",  "label": "Lab 2"},
			{"id": "CS3lab1", "label": "Lab 3-1"},
			{"id": "CS3lab2", "label": "Lab 3-2"},
			{"id": "CS3lab3", "label": "Lab 3-3"}
		],
		"Washrooms": [
			{"id": "CS1gwash", "label": "Girls Washroom (Ground Floor)"},
			{"id": "CS2bwash", "label": "Boys Washroom (First Floor)"},
			{"id": "CS3gwash", "label": "Girls Washroom (Second Floor)"}
		]
	}
}

const ADMIN_MENU_DATA := {
	"Administration": [
		{"id": "AD1prin",   "label": "Principal's Office"},
		{"id": "AD1dean",   "label": "Dean's Office"},
		{"id": "AD1bursar", "label": "Bursar's Room"},
		{"id": "AD1office", "label": "Office"},
		{"id": "AD1conf",   "label": "Conference Hall"}
	],
	"Classrooms": [
		{"id": "AD2class1", "label": "Class 2-1"},
		{"id": "AD2class2", "label": "Class 2-2"},
		{"id": "AD2class3", "label": "Class 2-3"},
		{"id": "AD2class4", "label": "Class 2-4"},
		{"id": "AD2class5", "label": "Class 2-5"},
		{"id": "AD3class1", "label": "Class 3-1"},
		{"id": "AD3class2", "label": "Class 3-2"},
		{"id": "AD3class3", "label": "Class 3-3"},
		{"id": "AD3class4", "label": "Class 3-4"},
		{"id": "AD3class5", "label": "Class 3-5"}
	],
	"Faculty Rooms": [
		{"id": "AD2hod",    "label": "HOD Room"},
		{"id": "AD2staff1", "label": "Staff Room 1"},
		{"id": "AD2staff2", "label": "Staff Room 2"},
		{"id": "AD3hod",    "label": "HOD Room"},
		{"id": "AD3staff1", "label": "Staff Room 1"},
		{"id": "AD3staff2", "label": "Staff Room 2"}
	],
	"Labs": [
		{"id": "AD2lab", "label": "Computer Room"},
		{"id": "AD3lab", "label": "Lab Room"}
	],
	"Halls": [
		{"id": "AD1hall",     "label": "Gallery Hall"},
		{"id": "AD2seminar",  "label": "Seminar Hall"},
		{"id": "AD3drawing1", "label": "Drawing Hall 1"},
		{"id": "AD3drawing2", "label": "Drawing Hall 2"}
	],
	"Washrooms": [
		{"id": "AD1bwash", "label": "Boys Washroom"},
		{"id": "AD1gwash", "label": "Girls Washroom"},
		{"id": "AD2bwash", "label": "Boys Washroom"},
		{"id": "AD2gwash", "label": "Girls Washroom"},
		{"id": "AD3bwash", "label": "Boys Washroom"}
	]
}

var current_view := "blocks"
var selected_block := ""
var selected_category := ""

# Reference for setting panel container
var settings_panel: PanelContainer = null

func _ready():
	btn_back.pressed.connect(on_back_pressed)
	
	# Force shadows disabled and shadow distance to 10m on startup
	var sun = get_sun_light()
	if sun:
		sun.shadow_enabled = false
		sun.directional_shadow_max_distance = 10.0

	create_opacity_slider_ui() # Anchors to screen bottom-center
	create_settings_ui()       # Gear icon & popup settings menu
	show_block_menu()

func get_world_env() -> Environment:
	var world_env = get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_env:
		return world_env.environment
	return null

func get_sun_light() -> DirectionalLight3D:
	return get_tree().root.find_child("DirectionalLight3D", true, false) as DirectionalLight3D

func create_settings_ui():
	# 1. Gear Icon Button anchored to top-right
	var gear_btn := Button.new()
	gear_btn.name = "GearButton"
	gear_btn.text = "⚙"
	gear_btn.custom_minimum_size = Vector2(44, 44)
	gear_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 20)
	gear_btn.add_theme_font_size_override("font_size", 22)
	add_child(gear_btn)

	# 2. Settings Panel Container
	settings_panel = PanelContainer.new()
	settings_panel.name = "SettingsPanel"
	settings_panel.visible = false
	
	settings_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 20)
	settings_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	settings_panel.offset_top = 70
	settings_panel.custom_minimum_size = Vector2(260, 0)
	
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	settings_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Graphics Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	# --- MASTER TOGGLE: OFF BY DEFAULT ---
	var chk_all := CheckBox.new()
	chk_all.text = "Enable Post Processing"
	chk_all.button_pressed = false
	vbox.add_child(chk_all)

	# Individual Toggle: SSAO (Disabled by default)
	var chk_ssao := CheckBox.new()
	chk_ssao.text = "SSAO (Ambient Occlusion)"
	chk_ssao.button_pressed = false
	chk_ssao.disabled = true
	vbox.add_child(chk_ssao)

	# Individual Toggle: Glow (Disabled by default)
	var chk_glow := CheckBox.new()
	chk_glow.text = "Glow / Bloom"
	chk_glow.button_pressed = false
	chk_glow.disabled = true
	vbox.add_child(chk_glow)

	# Individual Toggle: Fog (Disabled by default)
	var chk_fog := CheckBox.new()
	chk_fog.text = "Volumetric Fog"
	chk_fog.button_pressed = false
	chk_fog.disabled = true
	vbox.add_child(chk_fog)

	# FORCE WORLD ENVIRONMENT TO DISABLE ALL POST-PROCESSING ON START
	var env = get_world_env()
	if env:
		env.ssao_enabled = false
		env.glow_enabled = false
		env.fog_enabled = false

	# Trees & Vegetation Toggle
	var chk_trees := CheckBox.new()
	chk_trees.text = "Show Trees & Palms"
	chk_trees.button_pressed = true
	vbox.add_child(chk_trees)

	# See-through dither holes where buildings/trees block the path
	var chk_holes := CheckBox.new()
	chk_holes.text = "See-through Holes (Dither)"
	chk_holes.button_pressed = true
	chk_holes.toggled.connect(func(toggled: bool):
		dither_holes_toggled.emit(toggled)
	)
	vbox.add_child(chk_holes)

	var sep1 := HSeparator.new()
	vbox.add_child(sep1)

	# --- SHADOW TOGGLE (DISABLED BY DEFAULT) ---
	var chk_hq_shadows := CheckBox.new()
	chk_hq_shadows.text = "Enable Shadows"
	chk_hq_shadows.button_pressed = false
	vbox.add_child(chk_hq_shadows)

	# --- SHADOW DISTANCE SLIDER (DEFAULT 10m, DISABLED INITIALLY) ---
	var sun = get_sun_light()
	var current_dist: float = sun.directional_shadow_max_distance if sun else 10.0

	var shadow_label := Label.new()
	shadow_label.text = "Shadow Distance: " + str(int(current_dist)) + "m"
	shadow_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(shadow_label)

	var shadow_slider := HSlider.new()
	shadow_slider.min_value = 10.0
	shadow_slider.max_value = 1500.0
	shadow_slider.step = 10.0
	shadow_slider.value = current_dist
	shadow_slider.editable = false # Grayed out until shadows are enabled
	vbox.add_child(shadow_slider)

	var apply_shadow_quality = func(shadows_enabled: bool):
		var target_sun = get_sun_light()
		if target_sun:
			target_sun.shadow_enabled = shadows_enabled
			if shadows_enabled:
				target_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
				target_sun.shadow_bias = 0.15
				target_sun.shadow_normal_bias = 2.0
				target_sun.directional_shadow_blend_splits = false

	# Explicitly turn shadows OFF on startup
	apply_shadow_quality.call(false)

	# --- CONNECTIONS ---
	chk_all.toggled.connect(func(toggled: bool):
		var target_env = get_world_env()
		if target_env:
			target_env.ssao_enabled = toggled and chk_ssao.button_pressed
			target_env.glow_enabled = toggled and chk_glow.button_pressed
			target_env.fog_enabled = toggled and chk_fog.button_pressed
			
		chk_ssao.disabled = not toggled
		chk_glow.disabled = not toggled
		chk_fog.disabled = not toggled
	)

	chk_ssao.toggled.connect(func(toggled: bool):
		var target_env = get_world_env()
		if target_env:
			target_env.ssao_enabled = toggled
	)

	chk_glow.toggled.connect(func(toggled: bool):
		var target_env = get_world_env()
		if target_env:
			target_env.glow_enabled = toggled
	)

	chk_fog.toggled.connect(func(toggled: bool):
		var target_env = get_world_env()
		if target_env:
			target_env.fog_enabled = toggled
	)

	chk_trees.toggled.connect(func(toggled: bool):
		var trees_node = get_tree().root.find_child("trees", true, false)
		if trees_node:
			trees_node.visible = toggled

		var cse_block = get_tree().root.find_child("cseblock", true, false)
		if cse_block:
			for child in cse_block.get_children():
				if child.name.to_lower().begins_with("coco"):
					child.visible = toggled
	)

	chk_hq_shadows.toggled.connect(func(toggled: bool):
		apply_shadow_quality.call(toggled)
		shadow_slider.editable = toggled
	)

	shadow_slider.value_changed.connect(func(val: float):
		shadow_label.text = "Shadow Distance: " + str(int(val)) + "m"
		var target_sun = get_sun_light()
		if target_sun:
			target_sun.directional_shadow_max_distance = val
	)

	gear_btn.pressed.connect(func():
		settings_panel.visible = not settings_panel.visible
	)

	add_child(settings_panel)

func create_opacity_slider_ui():
	var margin := MarginContainer.new()
	margin.name = "OpacityContainer"
	margin.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 25)
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.grow_vertical = Control.GROW_DIRECTION_BEGIN
	
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	
	var lbl := Label.new()
	lbl.text = "Building Transparency"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	vbox.add_child(lbl)
	
	var slider := HSlider.new()
	slider.min_value = 0.1
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = 1.0
	slider.custom_minimum_size = Vector2(380, 28)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	
	var track_style := StyleBoxFlat.new()
	track_style.bg_color = Color(1.0, 1.0, 1.0, 0.2)
	track_style.corner_radius_top_left = 6
	track_style.corner_radius_top_right = 6
	track_style.corner_radius_bottom_left = 6
	track_style.corner_radius_bottom_right = 6
	track_style.expand_margin_top = 4
	track_style.expand_margin_bottom = 4
	
	var fill_style := track_style.duplicate() as StyleBoxFlat
	fill_style.bg_color = Color("2563eb")
	
	slider.add_theme_stylebox_override("slider", track_style)
	slider.add_theme_stylebox_override("grabber_area", fill_style)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_style)
	
	slider.value_changed.connect(func(val: float):
		room_opacity_changed.emit(val)
	)
	
	vbox.add_child(slider)
	add_child(margin)

# --- LEVEL 1: MAIN BLOCKS ---
# All blocks shown on the first screen (CSE from MENU_DATA, Admin from ADMIN_MENU_DATA)
func get_block_names() -> Array:
	var names: Array = MENU_DATA.keys()
	names.append("Admin Block")
	return names

func get_block_data(block_name: String) -> Dictionary:
	if block_name == "Admin Block":
		return ADMIN_MENU_DATA
	return MENU_DATA[block_name]

func show_block_menu():
	current_view = "blocks"
	btn_back.visible = false
	lbl_title.text = "Campus Navigation"
	content_grid.columns = 1
	clear_grid()
	
	for block_name in get_block_names():
		create_block_card(block_name, func():
			selected_block = block_name
			block_selected.emit(block_name)
			show_category_menu()
		)

func create_block_card(display_text: String, callback: Callable):
	var btn := Button.new()
	btn.text = display_text
	btn.custom_minimum_size = Vector2(200, 80)
	btn.pressed.connect(callback)
	content_grid.add_child(btn)

# --- LEVEL 2: SUB-CATEGORIES ---
func show_category_menu():
	current_view = "categories"
	btn_back.visible = true
	lbl_title.text = selected_block
	content_grid.columns = 1
	clear_grid()
	
	var categories: Dictionary = get_block_data(selected_block)
	for cat_name in categories.keys():
		create_list_button(cat_name, func():
			selected_category = cat_name
			show_room_grid()
		)

# --- LEVEL 3: ROOMS, GROUPED BY FLOOR ---
func show_room_grid():
	current_view = "rooms"
	btn_back.visible = true
	lbl_title.text = selected_category
	content_grid.columns = 1 # Each floor = a heading + its own 2-column grid
	clear_grid()
	
	var rooms: Array = get_block_data(selected_block)[selected_category]
	
	# Group rooms by floor, keeping the MENU_DATA order inside each floor
	var by_floor := {}
	for room_data in rooms:
		var floor_num := get_room_floor(room_data["id"])
		if not by_floor.has(floor_num):
			by_floor[floor_num] = []
		by_floor[floor_num].append(room_data)
	
	var floor_nums: Array = by_floor.keys()
	floor_nums.sort() # Ground -> First -> Second
	
	var is_first := true
	for floor_num in floor_nums:
		add_floor_section(floor_num, by_floor[floor_num], is_first)
		is_first = false

# CS1* = ground, CS2* = first, CS3* = second. Anything else goes last as "Other".
func get_room_floor(room_id: String) -> int:
	if room_id.begins_with("CS1") or room_id.begins_with("AD1"):
		return 1
	elif room_id.begins_with("CS2") or room_id.begins_with("AD2"):
		return 2
	elif room_id.begins_with("CS3") or room_id.begins_with("AD3"):
		return 3
	return 99

func add_floor_section(floor_num: int, rooms: Array, is_first: bool):
	if not is_first:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 10)
		content_grid.add_child(spacer)
	
	var heading := Label.new()
	heading.text = FLOOR_NAMES.get(floor_num, "Other")
	heading.add_theme_font_size_override("font_size", 18)
	content_grid.add_child(heading)
	content_grid.add_child(HSeparator.new())
	
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_grid.add_child(grid)
	
	for room_data in rooms:
		create_room_card(room_data["id"], strip_floor_suffix(room_data["label"]), grid)

# "Girls Washroom (Ground Floor)" -> "Girls Washroom" (the heading already says the floor)
func strip_floor_suffix(text: String) -> String:
	var idx := text.find(" (")
	if idx != -1 and text.ends_with("Floor)"):
		return text.substr(0, idx)
	return text

func create_list_button(text: String, callback: Callable):
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(200, 40)
	btn.pressed.connect(callback)
	content_grid.add_child(btn)

func create_room_card(room_id: String, display_text: String, parent: Control = null):
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(140, 64)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var lbl := Label.new()
	lbl.text = display_text
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lbl)
	
	btn.pressed.connect(func():
		room_selected.emit(room_id)
		
		var handoff = get_node_or_null("/root/CS/HandoffManager")
		if handoff:
			handoff.send_room_to_firebase(room_id)
	)
	
	(parent if parent != null else content_grid).add_child(btn)

func on_back_pressed():
	if current_view == "rooms":
		show_category_menu()
	elif current_view == "categories":
		show_block_menu()

func clear_grid():
	for child in content_grid.get_children():
		child.queue_free()
