extends Node

@export var qr_display: TextureRect

@onready var firebase_request = $FirebaseRequest
@onready var qr_request = $QRRequest

# --- CONFIGURE YOUR DEPLOYED WEB APP URL HERE ---
const WEB_APP_BASE_URL = "https://campusnav3d.netlify.app"
# QR frame size and its gap from the screen edges (in UI pixels)
@export var qr_size: float = 140.0
@export var qr_margin: float = 16.0

const CLOSE_BTN_SIZE := 34.0
var _qr_close_btn: Button

const FIREBASE_URL = "https://campasnav-default-rtdb.asia-southeast1.firebasedatabase.app/sessions.json"

func _ready():
	firebase_request.request_completed.connect(_on_firebase_response)
	qr_request.request_completed.connect(_on_qr_image_downloaded)
	
	if qr_display != null:
		qr_display.visible = false
		_create_close_button()
		
	check_for_mobile_session()

# Pins the QR frame to the bottom-right corner of the screen. The anchors are
# set to the corner itself, so it stays there for any resolution, window size,
# phone rotation or browser resize.
func _anchor_qr_bottom_right() -> void:
	qr_display.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_KEEP_SIZE, int(qr_margin))
	qr_display.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	qr_display.grow_vertical = Control.GROW_DIRECTION_BEGIN

# --- QR CLOSE BUTTON ---
func _create_close_button() -> void:
	_qr_close_btn = Button.new()
	_qr_close_btn.text = "X"
	_qr_close_btn.tooltip_text = "Close"
	_qr_close_btn.focus_mode = Control.FOCUS_NONE
	_qr_close_btn.custom_minimum_size = Vector2(CLOSE_BTN_SIZE, CLOSE_BTN_SIZE)
	_qr_close_btn.size = Vector2(CLOSE_BTN_SIZE, CLOSE_BTN_SIZE)
	_qr_close_btn.add_theme_font_size_override("font_size", 16)
	_qr_close_btn.pressed.connect(close_qr)
	# Child of the QR frame, so it shows/hides together with the QR code
	qr_display.add_child(_qr_close_btn)

func close_qr() -> void:
	if qr_display != null:
		qr_display.visible = false

# Sits just OUTSIDE the QR image (so it never covers part of the code).
# Prefers above the QR, then below, then to its left, whichever fits on screen.
func _place_close_button() -> void:
	if _qr_close_btn == null or qr_display == null:
		return
	var rect := qr_display.get_global_rect()
	var view := qr_display.get_viewport_rect().size
	var s := CLOSE_BTN_SIZE
	var gap := 4.0
	if rect.position.y >= s + gap:
		_qr_close_btn.position = Vector2(rect.size.x - s, -s - gap)
	elif rect.end.y + s + gap <= view.y:
		_qr_close_btn.position = Vector2(rect.size.x - s, rect.size.y + gap)
	else:
		_qr_close_btn.position = Vector2(-s - gap, 0.0)

# --- SENDER LOGIC (KIOSK / DESKTOP) ---
func send_room_to_firebase(room_name: String):
	var payload = JSON.stringify({
		"room_id": room_name,
		"timestamp": Time.get_unix_time_from_system()
	})
	
	var headers = ["Content-Type: application/json"]
	firebase_request.request(FIREBASE_URL, headers, HTTPClient.METHOD_POST, payload)

func _on_firebase_response(result, response_code, headers, body):
	if response_code == 200 or response_code == 201:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("name"):
			var session_id = json["name"]
			print("Firebase Session Created ID: ", session_id)
			
			var target_url = WEB_APP_BASE_URL + "/?session=" + session_id
			fetch_qr_code(target_url)
	else:
		print("Firebase Error Code: ", response_code)

func fetch_qr_code(url_to_encode: String):
	var qr_api_url = "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=" + url_to_encode.uri_encode()
	var err = qr_request.request(qr_api_url)
	if err != OK:
		print("Failed to dispatch QR Code HTTP request, error code: ", err)

func _on_qr_image_downloaded(result, response_code, headers, body):
	if response_code == 200:
		var image = Image.new()
		var error = image.load_png_from_buffer(body)
		if error != OK:
			error = image.load_jpg_from_buffer(body)
			
		if error == OK and qr_display != null:
			# Configure TextureRect stretch parameters so it scales down properly
			qr_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			qr_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			
			qr_display.custom_minimum_size = Vector2(qr_size, qr_size)
			qr_display.size = Vector2(qr_size, qr_size)
			
			qr_display.texture = ImageTexture.create_from_image(image)
			_anchor_qr_bottom_right()
			qr_display.visible = true
			get_tree().process_frame.connect(_place_close_button, CONNECT_ONE_SHOT)
		else:
			print("Failed to render QR Image buffer into texture. Code: ", error)
	else:
		print("QR API Download Failed with response code: ", response_code)

# --- RECEIVER LOGIC (MOBILE PHONE BROWSER) ---
func check_for_mobile_session():
	if OS.has_feature("web"):
		var session_id = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('session')")
		if session_id != null and str(session_id) != "null" and str(session_id) != "":
			print("Mobile session detected: ", session_id)
			fetch_session_data(str(session_id))

func fetch_session_data(session_id: String):
	var fetch_req = HTTPRequest.new()
	add_child(fetch_req)
	
	fetch_req.request_completed.connect(func(result, response_code, headers, body):
		_on_session_data_fetched(result, response_code, headers, body)
		fetch_req.queue_free() # Safely free HTTP request node
	)
	
	var fetch_url = "https://campasnav-default-rtdb.asia-southeast1.firebasedatabase.app/sessions/" + session_id + ".json"
	fetch_req.request(fetch_url)

func _on_session_data_fetched(result, response_code, headers, body):
	if response_code == 200:
		var data = JSON.parse_string(body.get_string_from_utf8())
		if data != null:
			var room_id = str(data.get("room_id", data.get("end", "")))
			print("Drawing path on mobile for room: ", room_id)
			
			var cs_root = get_node_or_null("/root/CS")
			if cs_root and cs_root.has_method("navigate_to_room"):
				cs_root.navigate_to_room(room_id)
