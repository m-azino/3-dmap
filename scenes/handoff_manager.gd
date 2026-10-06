extends Node

@export var qr_display: TextureRect

@onready var firebase_request = $FirebaseRequest
@onready var qr_request = $QRRequest

# --- CONFIGURE YOUR DEPLOYED WEB APP URL HERE ---
const WEB_APP_BASE_URL = "https://campusnav3d.netlify.app"
const FIREBASE_URL = "https://campasnav-default-rtdb.asia-southeast1.firebasedatabase.app/sessions.json"

func _ready():
	firebase_request.request_completed.connect(_on_firebase_response)
	qr_request.request_completed.connect(_on_qr_image_downloaded)
	
	if qr_display != null:
		qr_display.visible = false
		
	check_for_mobile_session()

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
			
			# Set the exact maximum size you want for the QR frame (e.g., 140x140)
			qr_display.custom_minimum_size = Vector2(140, 140)
			
			qr_display.texture = ImageTexture.create_from_image(image)
			qr_display.visible = true
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
