extends Node
## SCRAPLAND -- Turns battery state into things you can see and hear on the robot.
##
## Attach as a CHILD of the Player, as a sibling of Battery. It reacts to the
## battery's signals and drives:
##   * the battery indicator bar on the robot's chest (green -> yellow -> red)
##   * eye and head-lamp flicker while power is critical
##   * spark bursts from the battery compartment
##   * warning beeps
##
## Nodes it expects to find on the player (paths are relative to the player).
## All lookups are optional:
##   RobotModel/Head/Flashlight
##   RobotModel/BatteryIndicator
##   RobotModel/Sparks
##   Beeper

@export_group("Indicator Colours")
@export var color_normal: Color = Color(0.3, 1.0, 0.4)
@export var color_warning: Color = Color(1.0, 0.85, 0.2)
@export var color_danger: Color = Color(1.0, 0.4, 0.15)
@export var color_critical: Color = Color(1.0, 0.15, 0.15)
@export var color_charging: Color = Color(0.3, 0.8, 1.0)

@export_group("Critical Flicker")
## Seconds between flicker attempts while critical.
@export var flicker_interval: float = 0.09
## Chance each attempt that the lights drop out.
@export_range(0.0, 1.0) var flicker_chance: float = 0.35

@export_group("Sparks")
## Average seconds between spark bursts while critical.
@export var spark_interval_min: float = 1.2
@export var spark_interval_max: float = 3.0

@export_group("Beeps")
## Seconds between low-power warning beeps while critical.
@export var beep_interval: float = 2.5
@export var beep_frequency: float = 720.0

# --- Internal ---------------------------------------------------------------

var _state: RobotBattery.State = RobotBattery.State.NORMAL
var _charging: bool = false
var _flicker_timer: float = 0.0
var _spark_timer: float = 0.0
var _beep_timer: float = 0.0
var _lights_on: bool = true

## Duplicated so runtime colour changes never touch the shared scene material.
var _eye_material: StandardMaterial3D
var _indicator_material: StandardMaterial3D
var _eye_base_energy: float = 4.0
var _lamp_base_energy: float = 6.0

@onready var _robot: Player = get_parent() as Player
@onready var _battery: RobotBattery = _robot.get_node_or_null("Battery") as RobotBattery
@onready var _eyes: Array[MeshInstance3D] = _collect_eyes()
@onready var _indicator: MeshInstance3D = _robot.get_node_or_null("RobotModel/BatteryIndicator") as MeshInstance3D
@onready var _flashlight: SpotLight3D = _robot.get_node_or_null("RobotModel/Head/Flashlight") as SpotLight3D
@onready var _sparks: GPUParticles3D = _robot.get_node_or_null("RobotModel/Sparks") as GPUParticles3D
@onready var _beeper: Node = _robot.get_node_or_null("Beeper")
@onready var _inventory: Inventory = _robot.get_node_or_null("Inventory") as Inventory


func _ready() -> void:
	_setup_materials()
	if _flashlight:
		_lamp_base_energy = _flashlight.light_energy

	# A short blip confirms a pickup landed without needing to open the bag.
	if _inventory:
		_inventory.item_added.connect(_on_item_added)

	if _battery == null:
		push_warning("robot_effects.gd: no Battery sibling found; effects disabled.")
		set_process(false)
		return

	_battery.state_changed.connect(_on_state_changed)
	_battery.charging_changed.connect(_on_charging_changed)
	_battery.shutdown.connect(_on_shutdown)
	_battery.rebooted.connect(_on_rebooted)

	_state = _battery.get_state()
	_apply_indicator_colour()


func _collect_eyes() -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	for path in ["RobotModel/Head/EyeLeft", "RobotModel/Head/EyeRight"]:
		var eye := _robot.get_node_or_null(path) as MeshInstance3D
		if eye:
			found.append(eye)
	return found


## Give this robot its own copies of the glowing materials, applied as surface
## overrides. Without this we would be editing the materials stored inside the
## scene file, which every future robot would share.
func _setup_materials() -> void:
	if not _eyes.is_empty():
		_eye_material = _clone_material(_eyes[0])
		if _eye_material:
			_eye_base_energy = _eye_material.emission_energy_multiplier
			for eye in _eyes:
				eye.set_surface_override_material(0, _eye_material)

	if _indicator:
		_indicator_material = _clone_material(_indicator)
		if _indicator_material:
			_indicator.set_surface_override_material(0, _indicator_material)


## Copies the material off a primitive mesh so we can animate it without
## editing the shared copy saved inside the scene file.
func _clone_material(instance: MeshInstance3D) -> StandardMaterial3D:
	var primitive := instance.mesh as PrimitiveMesh
	if primitive == null:
		return null
	var source := primitive.material as StandardMaterial3D
	if source == null:
		return null
	return source.duplicate() as StandardMaterial3D


func _process(delta: float) -> void:
	if _state != RobotBattery.State.CRITICAL:
		if not _lights_on:
			_set_lights(true)
		return

	_process_flicker(delta)
	_process_sparks(delta)
	_process_beeps(delta)


# --- Critical-power effects -------------------------------------------------

## Brownout flicker: the eyes and head lamp cut out at random.
func _process_flicker(delta: float) -> void:
	_flicker_timer -= delta
	if _flicker_timer > 0.0:
		return
	_flicker_timer = flicker_interval
	_set_lights(randf() > flicker_chance)


func _process_sparks(delta: float) -> void:
	_spark_timer -= delta
	if _spark_timer > 0.0:
		return
	_spark_timer = randf_range(spark_interval_min, spark_interval_max)
	emit_sparks()


func _process_beeps(delta: float) -> void:
	_beep_timer -= delta
	if _beep_timer > 0.0:
		return
	_beep_timer = beep_interval
	_beep(beep_frequency, 0.1)
	_beep(beep_frequency, 0.1, 0.16)


## Fires one burst of sparks. Salvaging will reuse this later.
func emit_sparks() -> void:
	if _sparks:
		_sparks.emitting = true
		_sparks.restart()


func _set_lights(on: bool) -> void:
	if _lights_on == on:
		return
	_lights_on = on
	if _eye_material:
		_eye_material.emission_energy_multiplier = _eye_base_energy if on else 0.05
	# Only dim the lamp if the player actually has it switched on.
	if _flashlight and _flashlight.visible:
		_flashlight.light_energy = _lamp_base_energy if on else _lamp_base_energy * 0.07


# --- Indicator --------------------------------------------------------------

func _apply_indicator_colour() -> void:
	if _indicator_material == null:
		return
	var target := color_normal
	if _charging:
		target = color_charging
	else:
		match _state:
			RobotBattery.State.WARNING:
				target = color_warning
			RobotBattery.State.DANGER:
				target = color_danger
			RobotBattery.State.CRITICAL:
				target = color_critical
			RobotBattery.State.DEAD:
				target = Color(0.1, 0.1, 0.1)
	_indicator_material.albedo_color = target
	_indicator_material.emission = target
	_indicator_material.emission_energy_multiplier = 0.2 if _state == RobotBattery.State.DEAD else 3.0


# --- Signal handlers --------------------------------------------------------

func _on_state_changed(state: RobotBattery.State, previous: RobotBattery.State) -> void:
	_state = state
	_apply_indicator_colour()

	if state == RobotBattery.State.CRITICAL:
		# Start beeping immediately rather than after the first full interval.
		_beep_timer = 0.0
		_spark_timer = 0.4
	else:
		_set_lights(true)

	# A short descending chirp whenever power gets worse; ascending when better.
	if state > previous and state != RobotBattery.State.DEAD:
		_beep(520.0, 0.08)
	elif state < previous:
		_beep(880.0, 0.08)


func _on_item_added(_item: ItemData, _amount: int) -> void:
	_beep(1150.0, 0.05)


func _on_charging_changed(is_charging: bool) -> void:
	_charging = is_charging
	_apply_indicator_colour()
	if is_charging:
		_beep(660.0, 0.07)
		_beep(990.0, 0.09, 0.09)


func _on_shutdown() -> void:
	_set_lights(false)
	if _eye_material:
		_eye_material.emission_energy_multiplier = 0.0
	emit_sparks()
	# Sad power-down slide.
	_beep(400.0, 0.18)
	_beep(300.0, 0.18, 0.18)
	_beep(200.0, 0.35, 0.36)


func _on_rebooted() -> void:
	_lights_on = false  # force _set_lights to actually run
	_set_lights(true)
	_beep(700.0, 0.07)
	_beep(1050.0, 0.12, 0.09)


## Small wrapper so a missing Beeper node is harmless.
func _beep(frequency: float, duration: float, delay: float = 0.0) -> void:
	if _beeper == null or not _beeper.has_method("beep"):
		return
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if _beeper == null:
			return
	_beeper.call("beep", frequency, duration)
