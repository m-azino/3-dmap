extends CanvasLayer

signal room_opacity_changed(value: float)
signal room_selected(room_node_name: String)

@onready var btn_back: Button = $MenuContainer/VBox/Header/BtnBack
@onready var lbl_title: Label = $MenuContainer/VBox/Header/LblTitle
@onready var content_grid: GridContainer = $MenuContainer/VBox/ContentGrid

const ICON_PATH := "res://icons/"

const ICON_OVERRIDES := {
	"CS3room": "CS2room4",
	"CS2room5": "CS2room2",
	"CS1room1": "CS2room1",
	"CS1room2": "CS2room2",
	"CS1room3": "CS2room2",
	"CS1room6": "CS1room5",
	"CS2staff1": "CS3staff1",
	"CS1staff1": "CS3staff1",
	"CS1gwash": "CS3gwash"
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

var current_view := "blocks"
var selected_block := ""
var selected_category := ""

func _ready():
	btn_back.pressed.connect(on_back_pressed)
	create_opacity_slider_ui() # Anchors to screen bottom-center
	show_block_menu()

func create_opacity_slider_ui():
	# 1. Floating MarginContainer at screen bottom (No black background)
	var margin := MarginContainer.new()
	margin.name = "OpacityContainer"
	
	# Anchor to Bottom Center
	margin.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 25)
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.grow_vertical = Control.GROW_DIRECTION_BEGIN
	
	# 2. Layout Container
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	
	# 3. Clean Label
	var lbl := Label.new()
	lbl.text = "Building Transparency"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	vbox.add_child(lbl)
	
	# 4. Thicker Custom Slider
	var slider := HSlider.new()
	slider.min_value = 0.1
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = 1.0
	slider.custom_minimum_size = Vector2(380, 28)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	
	# --- Thicker Track Style ---
	var track_style := StyleBoxFlat.new()
	track_style.bg_color = Color(1.0, 1.0, 1.0, 0.2) # Semi-transparent white track
	track_style.corner_radius_top_left = 6
	track_style.corner_radius_top_right = 6
	track_style.corner_radius_bottom_left = 6
	track_style.corner_radius_bottom_right = 6
	track_style.expand_margin_top = 4
	track_style.expand_margin_bottom = 4
	
	var fill_style := track_style.duplicate() as StyleBoxFlat
	fill_style.bg_color = Color("2563eb") # Accent color fill
	
	slider.add_theme_stylebox_override("slider", track_style)
	slider.add_theme_stylebox_override("grabber_area", fill_style)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_style)
	
	slider.value_changed.connect(func(val: float):
		room_opacity_changed.emit(val)
	)
	
	vbox.add_child(slider)
	add_child(margin)

# --- LEVEL 1: MAIN BLOCKS ---
func show_block_menu():
	current_view = "blocks"
	btn_back.visible = false
	lbl_title.text = "Campus Navigation"
	content_grid.columns = 1
	clear_grid()
	
	for block_name in MENU_DATA.keys():
		var icon_name := "CSEblock"
		create_block_card(block_name, icon_name, func():
			selected_block = block_name
			show_category_menu()
		)

func create_block_card(display_text: String, icon_name: String, callback: Callable):
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200, 110)
	
	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(hbox)
	
	var texture_path := ICON_PATH + icon_name + ".png"
	var tex_rect := TextureRect.new()
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_rect.custom_minimum_size = Vector2(130, 90)
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	if ResourceLoader.exists(texture_path):
		tex_rect.texture = load(texture_path)
	else:
		print("WARNING: Missing block icon -> ", texture_path)
		
	hbox.add_child(tex_rect)
	
	var lbl := Label.new()
	lbl.text = display_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(lbl)
	
	btn.pressed.connect(callback)
	content_grid.add_child(btn)

# --- LEVEL 2: SUB-CATEGORIES ---
func show_category_menu():
	current_view = "categories"
	btn_back.visible = true
	lbl_title.text = selected_block
	content_grid.columns = 1
	clear_grid()
	
	var categories: Dictionary = MENU_DATA[selected_block]
	for cat_name in categories.keys():
		create_list_button(cat_name, func():
			selected_category = cat_name
			show_room_grid()
		)

# --- LEVEL 3: ROOM CARDS ---
func show_room_grid():
	current_view = "rooms"
	btn_back.visible = true
	lbl_title.text = selected_category
	content_grid.columns = 2
	clear_grid()
	
	var rooms: Array = MENU_DATA[selected_block][selected_category]
	for room_data in rooms:
		create_room_card(room_data["id"], room_data["label"])

func create_list_button(text: String, callback: Callable):
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(200, 40)
	btn.pressed.connect(callback)
	content_grid.add_child(btn)

func create_room_card(room_id: String, display_text: String):
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(140, 140)
	
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vbox)
	
	var icon_name: String = ICON_OVERRIDES.get(room_id, room_id)
	var texture_path := ICON_PATH + icon_name + ".png"
	
	var tex_rect := TextureRect.new()
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_rect.custom_minimum_size = Vector2(120, 85)
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	if ResourceLoader.exists(texture_path):
		tex_rect.texture = load(texture_path)
	else:
		print("WARNING: Missing icon -> ", texture_path)
		
	vbox.add_child(tex_rect)
	
	var lbl := Label.new()
	lbl.text = display_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)
	
	btn.pressed.connect(func():
		room_selected.emit(room_id)
		
		var handoff = get_node_or_null("/root/CS/HandoffManager")
		if handoff:
			handoff.send_room_to_firebase(room_id)
	)
	
	content_grid.add_child(btn)

func on_back_pressed():
	if current_view == "rooms":
		show_category_menu()
	elif current_view == "categories":
		show_block_menu()

func clear_grid():
	for child in content_grid.get_children():
		child.queue_free()
