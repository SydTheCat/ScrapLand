extends CharacterBody3D
class_name Player
## SCRAPLAND -- Player robot controller.
##
## Responsibilities (intentionally narrow so later systems stay separate):
##   * camera-relative movement with mechanical acceleration / braking
##   * turning the robot body toward the direction it is travelling
##   * jumping (with a short coyote-time grace window)
##   * a backpack jetpack that burns a short tank while Space is held in the air
##   * the head-mounted flashlight
##   * emitting signals that other systems will listen to later
##
## What this script deliberately does NOT do: energy, inventory, crafting,
## salvaging or building. Those arrive as their own scripts in later steps and
## talk to this one through the signals and the small public API at the bottom.

# --- Signals other systems will connect to -----------------------------------

## Fires when the robot changes locomotion state. The animation system and the
## energy drain system both care about this (walking costs less than sprinting).
signal locomotion_changed(state: StringName)  # &"idle", &"walk", &"run", &"air"
signal jumped
signal landed(fall_speed: float)
signal flashlight_toggled(is_on: bool)
## The interaction system will listen for this instead of reading input itself.
signal interact_requested
## is_alternate = true for right mouse (secondary tool action).
signal tool_used(is_alternate: bool)

# --- Tuning (all adjustable in the Inspector) --------------------------------

@export_group("Movement")
## Normal walking speed in metres per second. The robot is small, so this is slow.
@export var walk_speed: float = 3.6
## Speed while holding Shift.
@export var sprint_speed: float = 6.2
## How quickly the robot reaches target speed. Lower = heavier, more mechanical.
@export var acceleration: float = 9.0
## How quickly the robot brakes when you release the keys.
@export var deceleration: float = 12.0
## Much weaker steering while airborne, so jumps commit to a direction.
@export var air_acceleration: float = 3.0
## How fast the body swivels toward the movement direction (servo-like turning).
@export_range(1.0, 30.0) var turn_speed: float = 9.0

@export_group("Jump & Gravity")
## Peak jump height in metres. Velocity is derived from this, so it stays
## correct even if you change gravity_scale.
@export var jump_height: float = 1.1
## Multiplies project gravity. Above 1.0 gives a snappier, less floaty arc.
@export var gravity_scale: float = 1.5
## Grace period after walking off a ledge during which jumping still works.
@export var coyote_time: float = 0.12

@export_group("Flashlight")
@export var flashlight_starts_on: bool = false

# --- Public state other systems will write to --------------------------------

## Multiplies all movement speed. The energy system will drop this below 1.0
## when the battery is critical, so the robot visibly slows down.
var speed_multiplier: float = 1.0
## Set to false while a menu (inventory, crafting) is open.
var can_move: bool = true
## Set to false while build mode owns the mouse buttons and the number keys. The
## robot can still walk about; it just cannot fire its tool or grab things by
## accident while it is deciding where to put a workbench.
var actions_enabled: bool = true

# --- Internal ---------------------------------------------------------------

var _locomotion: StringName = &"idle"
## Non-empty while a tool owns the body clip (the salvage beam's point).
var _action: StringName = &""
var _coyote_timer: float = 0.0
var _was_on_floor: bool = true
var _gravity: float = 9.8
var _floor_snap: float = 0.3

## The visual robot. Only this node rotates -- the CharacterBody3D itself stays
## axis-aligned, which keeps the collision capsule and camera math simple.
@onready var model: Node3D = $RobotModel
@onready var camera_rig: PlayerCameraRig = $CameraRig
@onready var flashlight: SpotLight3D = get_node_or_null("RobotModel/Head/Flashlight") as SpotLight3D
## Where crafted tools get attached later (salvage tool, mining arm, ...).
@onready var tool_attachment: Node3D = get_node_or_null("RobotModel/ArmRight/ToolAttachment") as Node3D
@onready var jetpack: RobotJetpack = get_node_or_null("RobotModel/Jetpack") as RobotJetpack
## Optional: nothing breaks while there are no animations yet.
var _anim: AnimationPlayer


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_floor_snap = floor_snap_length
	if flashlight:
		flashlight.visible = flashlight_starts_on
	if model and model.has_method("get_animation_player"):
		_anim = model.call("get_animation_player") as AnimationPlayer
	if _anim == null:
		_anim = find_child("AnimationPlayer", true, false) as AnimationPlayer
	# Where the robot is standing and which way it faces belong in save files.
	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


func _unhandled_input(event: InputEvent) -> void:
	# can_move is false while a menu is open or the robot has shut down. In both
	# cases the tool, flashlight and interact keys should do nothing.
	if not can_move:
		return

	# The lamp is exempt from actions_enabled: building in the dark should still
	# be possible.
	if event.is_action_pressed(&"flashlight"):
		toggle_flashlight()
		return

	# Build mode has borrowed the mouse buttons.
	if not actions_enabled:
		return

	# Input is only translated into signals here. The systems that actually
	# react to it are added in later steps.
	if event.is_action_pressed(&"interact"):
		interact_requested.emit()
	elif event.is_action_pressed(&"tool_primary"):
		tool_used.emit(false)
	elif event.is_action_pressed(&"tool_secondary"):
		tool_used.emit(true)


func _physics_process(delta: float) -> void:
	var fall_speed := velocity.y  # remembered so landed() can report impact speed

	_update_coyote_timer(delta)
	_apply_gravity(delta)

	var direction := _get_move_direction()
	_apply_horizontal_movement(direction, delta)
	var jumped := _try_jump()
	if jetpack:
		jetpack.tick(delta, jumped)
		floor_snap_length = 0.0 if jetpack.is_bursting() else _floor_snap

	move_and_slide()

	_report_landing(fall_speed)
	_face_movement_direction(direction, delta)
	_update_locomotion()


# --- Movement pieces --------------------------------------------------------

func _update_coyote_timer(delta: float) -> void:
	if is_on_floor():
		_coyote_timer = coyote_time
	else:
		_coyote_timer = maxf(_coyote_timer - delta, 0.0)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * gravity_scale * delta


## Converts WASD / left stick into a world-space direction that is relative to
## where the camera is looking.
func _get_move_direction() -> Vector3:
	if not can_move:
		return Vector3.ZERO

	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	if input == Vector2.ZERO:
		return Vector3.ZERO

	# The camera rig only ever yaws (pitch lives on its SpringArm3D child), so
	# its basis is already flat -- no need to remove a vertical component from
	# the forward vector. We still zero out Y defensively.
	var rig_basis := camera_rig.global_transform.basis
	var direction := rig_basis.x * input.x + rig_basis.z * input.y
	direction.y = 0.0
	return direction.normalized()


func _apply_horizontal_movement(direction: Vector3, delta: float) -> void:
	var top_speed := (sprint_speed if Input.is_action_pressed(&"sprint") else walk_speed)
	var target := direction * top_speed * speed_multiplier

	# move_toward() gives a constant, linear ramp rather than an exponential
	# ease -- that is what makes the robot feel like it has motors instead of
	# being on ice.
	var rate := acceleration if direction != Vector3.ZERO else deceleration
	if not is_on_floor():
		rate = air_acceleration

	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)


func _try_jump() -> bool:
	if not can_move or _coyote_timer <= 0.0:
		return false
	if not Input.is_action_just_pressed(&"jump"):
		return false
	# v = sqrt(2 * g * h) -- derived from the jump height so tuning stays intuitive.
	velocity.y = sqrt(2.0 * _gravity * gravity_scale * jump_height)
	_coyote_timer = 0.0
	jumped.emit()
	return true


func _report_landing(fall_speed: float) -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(absf(fall_speed))
	_was_on_floor = on_floor


## Swivels the visual model toward the travel direction. The model's front is
## its -Z axis, which is why the target angle is atan2(-x, -z).
func _face_movement_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.01:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	var weight := clampf(turn_speed * delta, 0.0, 1.0)
	model.rotation.y = lerp_angle(model.rotation.y, target_yaw, weight)


# --- Locomotion state / animation hooks -------------------------------------

func _update_locomotion() -> void:
	var speed := get_horizontal_speed()
	var state: StringName = &"idle"
	if not is_on_floor():
		state = &"air"
	elif speed > walk_speed + 0.5:
		state = &"run"
	elif speed > 0.2:
		state = &"walk"

	if state != _locomotion:
		_locomotion = state
		locomotion_changed.emit(state)
		if _action.is_empty():
			_play_animation(state)


## Plays an animation only if it exists, so this is safe before any animations
## have been authored. Later: "idle", "walk", "run", "air", "mine", "use_tool".
func _play_animation(name: StringName) -> void:
	if _anim and _anim.has_animation(String(name)):
		_anim.play(String(name))


## Tools call this so walk/idle cannot steal the clip mid-job.
func play_action(name: StringName) -> void:
	if name.is_empty():
		return
	_action = name
	if _anim and _anim.current_animation == String(name):
		return
	_play_animation(name)


func clear_action() -> void:
	if _action.is_empty():
		return
	_action = &""
	_play_animation(_locomotion)


# --- Public API for later systems -------------------------------------------

func get_horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Camera-relative walk vector. The jetpack uses this to nudge in air.
func get_move_direction() -> Vector3:
	return _get_move_direction()


func get_locomotion_state() -> StringName:
	return _locomotion


func toggle_flashlight() -> void:
	if flashlight == null:
		return
	set_flashlight(not flashlight.visible)


func set_flashlight(on: bool) -> void:
	if flashlight == null:
		return
	flashlight.visible = on
	flashlight_toggled.emit(on)


## Used by respawning at a charging station in a later step.
func teleport_to(world_position: Vector3) -> void:
	global_position = world_position
	velocity = Vector3.ZERO


func is_flashlight_on() -> bool:
	return flashlight != null and flashlight.visible


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {
		"position": global_position,
		"facing": rotation.y,
		"camera_yaw": camera_rig.get_look_yaw_degrees(),
		"flashlight": is_flashlight_on(),
	}


func load_data(data: Dictionary) -> void:
	teleport_to(data.get("position", global_position))
	rotation.y = float(data.get("facing", rotation.y))
	# Put the camera back where it was, and snap it rather than letting it glide
	# in from the old position across half the map.
	camera_rig.set_look_yaw_degrees(float(data.get("camera_yaw", 0.0)))
	camera_rig.snap_to_target()
	set_flashlight(bool(data.get("flashlight", false)))
