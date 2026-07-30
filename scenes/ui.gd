extends CanvasLayer

signal room_selected(room_node_name: String)

@onready var btn_back: Button = $MenuContainer/VBox/Header/BtnBack
@onready var lbl_title: Label = $MenuContainer/VBox/Header/LblTitle
@onready var content_grid: GridContainer = $MenuContainer/VBox/ContentGrid

# Path where your rendered PNG icons are stored in the filesystem
const ICON_PATH := "res://icons/"

# --- IMAGE REUSE MAPPING ---
# --- IMAGE REUSE MAPPING ---
# Maps a room node name to the exact icon file it should display
const ICON_OVERRIDES := {
	"CS3room": "CS2room4",
	"CS2room5": "CS2room2",
	"CS1room1": "CS2room1",
	"CS1room2": "CS2room2",
	"CS1room3": "CS2room2",
	"CS1room6": "CS1room5",
	"CS2staff1": "CS3staff1",
	"CS1staff1": "CS3staff1",
	"CS1gwash": "CS3gwash" # <- Reuses the 3rd floor Girls Washroom icon!
}

# --- 3-LEVEL MENU DATA ARCHITECTURE ---
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

var current_view := "blocks" # Modes: "blocks", "categories", "rooms"
var selected_block := ""
var selected_category := ""

func _ready():
	btn_back.pressed.connect(on_back_pressed)
	show_block_menu()

# --- LEVEL 1: MAIN BLOCKS ---
# --- LEVEL 1: MAIN BLOCKS ---
func show_block_menu():
	current_view = "blocks"
	btn_back.visible = false
	lbl_title.text = "Campus Navigation"
	content_grid.columns = 1 # Keeps it as a neat vertical card list
	clear_grid()
	
	for block_name in MENU_DATA.keys():
		# Use CSEblock as the icon filename for the "CSE Block" card
		var icon_name := "CSEblock"
		create_block_card(block_name, icon_name, func():
			selected_block = block_name
			show_category_menu()
		)

# --- NEW HELPER: CARD WITH ICON FOR BLOCKS ---
func create_block_card(display_text: String, icon_name: String, callback: Callable):
	# 1. Clickable Card Button
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200, 110)
	
	# 2. HBox to display Icon on the Left, Text on the Right
	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(hbox)
	
	# 3. Block Image Icon (CSEblock.png)
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
	
	# 4. Block Label
	var lbl := Label.new()
	lbl.text = display_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(lbl)
	
	# 5. Connect Callback
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

# --- LEVEL 3: ROOM CARDS (ICON + TEXT) ---
func show_room_grid():
	current_view = "rooms"
	btn_back.visible = true
	lbl_title.text = selected_category
	content_grid.columns = 2 # 2-column grid for cards
	clear_grid()
	
	var rooms: Array = MENU_DATA[selected_block][selected_category]
	for room_data in rooms:
		create_room_card(room_data["id"], room_data["label"])

# --- UI BUILDER HELPERS ---
func create_list_button(text: String, callback: Callable):
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(200, 40)
	btn.pressed.connect(callback)
	content_grid.add_child(btn)

func create_room_card(room_id: String, display_text: String):
	# 1. Base button acts as the clickable card
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(140, 140)
	
	# 2. VBox inside the button stacks image on top of text
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE # Lets clicks pass through to button
	btn.add_child(vbox)
	
	# 3. Resolve icon file name (applies your reuse dictionary automatically)
	var icon_name: String = ICON_OVERRIDES.get(room_id, room_id)
	var texture_path := ICON_PATH + icon_name + ".png"
	
	# 4. Image Icon (TextureRect)
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
	
	# 5. Room Label
	var lbl := Label.new()
	lbl.text = display_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)
	
	# 6. Connect navigation trigger
	btn.pressed.connect(func():
		room_selected.emit(room_id)
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
