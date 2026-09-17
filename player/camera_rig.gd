extends Node3D
class_name PlayerCameraRig
## SCRAPLAND -- Third-person camera rig.
##
## Node layout this script expects:
##   CameraRig (this node)  -- owns YAW (left/right)
##     SpringArm3D          -- owns PITCH (up/down) and pushes the camera in
##                             when a wall would be between it and the robot
##       Camera3D
##
## The rig sets `top_level = true` in _ready(). That means it ignores its
## parent's transform entirely and instead follows the player's POSITION by
## hand each frame. The result: the camera never inherits the robot's body
## rotation, so looking around stays completely independent of which way the
## robot is facing.

@export_group("Follow")
## Leave empty to use the parent node (the player). Set explicitly if you ever
## want the camera to track something else, like a vehicle.
@export var target: Node3D
## Aim point relative to the target. Roughly the robot's head height.
@export var target_offset: Vector3 = Vector3(0.0, 0.9, 0.0)
## 0 = rigidly locked to the target, higher = snappier catch-up. Around 12-20
## feels good; very low values look drunk.
@export_range(0.0, 40.0) var follow_smoothing: float = 16.0

@export_group("Look")
## Degrees of rotation per pixel of mouse movement.
@export var mouse_sensitivity: float = 0.15
## Degrees per second at full right-stick deflection.
@export var stick_sensitivity: float = 180.0
@export var invert_y: bool = false
## Looking down is negative pitch. Clamped so you cannot flip the camera over.
@export var min_pitch: float = -75.0
@export var max_pitch: float = 25.0

@export_group("Zoom")
## Distance behind the robot. Mouse wheel changes this at runtime.
@export var distance: float = 4.5
@export var zoom_step: float = 0.5
@export var min_distance: float = 1.2
@export var max_distance: float = 8.0

@export_group("Mouse")
## Grab the mouse as soon as the game starts. Escape releases it, clicking
## captures it again.
@export var capture_mouse_on_start: bool = true

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

var _yaw: float = 0.0
var _pitch: float = -12.0


func _ready() -> void:
	# Detach from the parent's transform; we drive our own global position.
	top_level = true

	if target == null:
		target = get_parent() as Node3D

	_yaw = rotation_degrees.y
	_pitch = clampf(spring_arm.rotation_degrees.x, min_pitch, max_pitch)
	spring_arm.spring_length = distance

	if target:
		global_position = target.global_position + target_offset
		# Without this the spring arm collides with the player's own capsule
		# and slams the camera into the robot's back.
		if target is CollisionObject3D:
			spring_arm.add_excluded_object((target as CollisionObject3D).get_rid())

	_apply_look()

	if capture_mouse_on_start:
		_set_mouse_captured(true)


func _unhandled_input(event: InputEvent) -> void:
	# Mouse look, but only while the cursor is actually captured.
	if event is InputEventMouseMotion and _is_mouse_captured():
		var motion := (event as InputEventMouseMotion).relative
		_yaw -= motion.x * mouse_sensitivity
		_pitch += motion.y * mouse_sensitivity * (1.0 if invert_y else -1.0)
		_apply_look()
		return

	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button := (event as InputEventMouseButton).button_index
		# Build mode borrows the wheel to rotate the preview. Zoom stays for
		# walking around.
		var player := target as Player
		var building := player != null and not player.actions_enabled
		if button == MOUSE_BUTTON_WHEEL_UP:
			if building:
				return
			_zoom(-zoom_step)
		elif button == MOUSE_BUTTON_WHEEL_DOWN:
			if building:
				return
			_zoom(zoom_step)
		elif not _is_mouse_captured():
			# Clicking back into the window re-grabs the mouse.
			_set_mouse_captured(true)
		return

	# Escape releases the mouse so you can reach the editor again.
	if event.is_action_pressed(&"ui_cancel") and _is_mouse_captured():
		_set_mouse_captured(false)


func _physics_process(delta: float) -> void:
	_handle_stick_look(delta)
	_follow_target(delta)


## Right analog stick look. Deadzones are configured on the actions themselves.
func _handle_stick_look(delta: float) -> void:
	var look := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	if look == Vector2.ZERO:
		return
	_yaw -= look.x * stick_sensitivity * delta
	_pitch += look.y * stick_sensitivity * delta * (1.0 if invert_y else -1.0)
	_apply_look()


func _follow_target(delta: float) -> void:
	if target == null:
		return
	var desired := target.global_position + target_offset
	if follow_smoothing <= 0.0:
		global_position = desired
	else:
		# Frame-rate independent approach toward the target position.
		global_position = global_position.lerp(desired, clampf(follow_smoothing * delta, 0.0, 1.0))


func _apply_look() -> void:
	_pitch = clampf(_pitch, min_pitch, max_pitch)
	rotation_degrees.y = _yaw
	spring_arm.rotation_degrees.x = _pitch


func _zoom(amount: float) -> void:
	distance = clampf(distance + amount, min_distance, max_distance)
	spring_arm.spring_length = distance


func _is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


# --- Public API for later systems -------------------------------------------

## Yaw in radians. Handy later for aligning build-mode previews with the view.
func get_look_yaw() -> float:
	return deg_to_rad(_yaw)


func get_look_yaw_degrees() -> float:
	return _yaw


## Used when loading a save, so you wake up facing the way you were.
func set_look_yaw_degrees(degrees: float) -> void:
	_yaw = degrees
	_apply_look()


## Jump straight to the target instead of easing toward it. Called after a
## teleport or a load, where smoothing would sweep the camera across the map.
func snap_to_target() -> void:
	if target:
		global_position = target.global_position + target_offset


## Menus (inventory, crafting) will call this to free the cursor.
func set_look_enabled(enabled: bool) -> void:
	set_process_unhandled_input(enabled)
	_set_mouse_captured(enabled)
