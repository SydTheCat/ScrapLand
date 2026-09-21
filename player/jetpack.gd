extends Node3D
## SCRAPLAND -- Backpack thruster. Hold Space in the air to burn a short tank.
##
## Runs its own physics so a missing class_name cache cannot mute it. Ground
## jumps still use Space; once Rocky is off the floor, holding Space opens the
## nozzles until fuel runs out or the key is released. The tank only refills
## while standing.

signal burst_started
signal burst_ended
signal fuel_changed(current: float, maximum: float)

@export_group("Thrust")
## Upward acceleration while the nozzles are open, in m/s².
@export var thrust: float = 28.0
## Instant upward kick the moment a hold starts.
@export var burst_kick: float = 6.2
## Extra air steering while thrusting.
@export var air_nudge: float = 9.0

@export_group("Fuel")
## Seconds of hold time in a full tank.
@export var max_fuel: float = 2.2
## Fuel restored per second while standing on the floor.
@export var recharge_rate: float = 1.4
## Need at least this much fuel to light the nozzles.
@export var min_fuel_to_fire: float = 0.03

@export_group("Battery")
## Energy drained per second while thrusting.
@export var energy_per_second: float = 5.5

@export_group("FX")
@export var exhaust_paths: Array[NodePath] = [^"NozzleL/Exhaust", ^"NozzleR/Exhaust"]
@export var glow_path: NodePath = ^"Glow"

var _fuel: float = 0.0
var _bursting: bool = false
var _empty_notified: bool = false
var _power_notified: bool = false
var _exhaust: Array[GPUParticles3D] = []
var _glow: OmniLight3D
var _glow_energy: float = 2.6
var _body: CharacterBody3D
var _battery: Node
var _beeper: Node
var _floor_snap: float = 0.3
var _last_tick_frame: int = -1


func _ready() -> void:
	_body = _find_body()
	if _body:
		_floor_snap = _body.floor_snap_length
		_battery = _body.get_node_or_null("Battery")
		_beeper = _body.get_node_or_null("Beeper")
	_fuel = max_fuel
	for path in exhaust_paths:
		var node := get_node_or_null(path) as GPUParticles3D
		if node:
			_exhaust.append(node)
			node.emitting = false
	_glow = get_node_or_null(glow_path) as OmniLight3D
	if _glow:
		if _glow.light_energy > 0.01:
			_glow_energy = _glow.light_energy
		_glow.light_energy = 0.0
	_set_fx(false)
	fuel_changed.emit(_fuel, max_fuel)


## Player may call this before move_and_slide so thrust applies the same frame.
## Safe to skip: _physics_process will still run the pack on its own.
func tick(delta: float, jumped_this_frame: bool = false) -> void:
	_last_tick_frame = Engine.get_physics_frames()
	_apply(delta, jumped_this_frame)


func _physics_process(delta: float) -> void:
	if Engine.get_physics_frames() == _last_tick_frame:
		return
	_apply(delta, false)


func is_bursting() -> bool:
	return _bursting


func get_fuel() -> float:
	return _fuel


func get_fuel_ratio() -> float:
	return _fuel / maxf(max_fuel, 0.001)


func _apply(delta: float, jumped_this_frame: bool) -> void:
	if _body == null:
		_body = _find_body()
		if _body == null:
			return

	var can_move := true
	if "can_move" in _body:
		can_move = bool(_body.can_move)

	var holding := can_move and Input.is_action_pressed(&"jump")
	# Treat a rising jump as airborne even if floor-snap has not let go yet.
	var airborne := (not _body.is_on_floor()) or _body.velocity.y > 0.4
	var want_thrust := holding and airborne and _fuel > 0.0
	# The press that starts a ground jump is allowed to keep thrusting.
	if jumped_this_frame and _body.is_on_floor() and _body.velocity.y <= 0.4:
		want_thrust = false

	if want_thrust:
		if not _has_power():
			if _bursting:
				_stop_burst()
			_notify_no_power()
			_restore_snap()
			return
		if not _bursting:
			if _fuel < min_fuel_to_fire:
				_notify_empty()
				_restore_snap()
				return
			_start_burst()
		_run_burst(delta)
		return

	if _bursting:
		_stop_burst()

	if _body.is_on_floor():
		_recharge(delta)
	elif holding and _fuel <= 0.0:
		_notify_empty()
	_restore_snap()


func _start_burst() -> void:
	_bursting = true
	_empty_notified = false
	_body.velocity.y = maxf(_body.velocity.y + burst_kick, burst_kick)
	_body.floor_snap_length = 0.0
	_set_fx(true)
	_whoosh()
	burst_started.emit()
	fuel_changed.emit(_fuel, max_fuel)


func _run_burst(delta: float) -> void:
	_body.floor_snap_length = 0.0
	if _fuel <= 0.0:
		_stop_burst()
		_notify_empty()
		return

	var cost := energy_per_second * delta
	if _battery and _battery.has_method("consume") and cost > 0.0:
		if not bool(_battery.call("consume", cost)):
			_stop_burst()
			_notify_no_power()
			return

	var previous := _fuel
	_fuel = maxf(_fuel - delta, 0.0)
	if not is_equal_approx(previous, _fuel):
		fuel_changed.emit(_fuel, max_fuel)

	_body.velocity.y += thrust * delta
	var nudge := _move_direction() * air_nudge * delta
	_body.velocity.x += nudge.x
	_body.velocity.z += nudge.z

	if _fuel <= 0.0:
		_stop_burst()
		_notify_empty()


func _stop_burst() -> void:
	if not _bursting:
		return
	_bursting = false
	_set_fx(false)
	burst_ended.emit()
	fuel_changed.emit(_fuel, max_fuel)


func _recharge(delta: float) -> void:
	if _fuel >= max_fuel:
		_fuel = max_fuel
		_empty_notified = false
		_power_notified = false
		return
	var previous := _fuel
	_fuel = minf(_fuel + recharge_rate * delta, max_fuel)
	if _fuel >= min_fuel_to_fire:
		_empty_notified = false
	if not is_equal_approx(previous, _fuel):
		fuel_changed.emit(_fuel, max_fuel)


func _has_power() -> bool:
	if _battery == null:
		return true
	if _battery.has_method("is_dead") and bool(_battery.call("is_dead")):
		return false
	if _battery.has_method("get_energy"):
		return float(_battery.call("get_energy")) >= 0.4
	return true


func _move_direction() -> Vector3:
	if _body and _body.has_method("get_move_direction"):
		return _body.call("get_move_direction") as Vector3
	return Vector3.ZERO


func _restore_snap() -> void:
	if _body:
		_body.floor_snap_length = _floor_snap


func _set_fx(on: bool) -> void:
	for p in _exhaust:
		p.emitting = on
		if on:
			p.restart()
	if _glow:
		_glow.light_energy = _glow_energy if on else 0.0


func _notify_empty() -> void:
	if _empty_notified:
		return
	_empty_notified = true
	GameEvents.notify("JETPACK EMPTY", Color(1.0, 0.55, 0.25))


func _notify_no_power() -> void:
	if _power_notified:
		return
	_power_notified = true
	GameEvents.notify("JETPACK: NO POWER", Color(1.0, 0.45, 0.25))


func _whoosh() -> void:
	if _beeper == null or not _beeper.has_method("beep"):
		return
	_beeper.call("beep", 110.0, 0.1, 0.18)


func _find_body() -> CharacterBody3D:
	var n: Node = get_parent()
	while n:
		if n is CharacterBody3D:
			return n as CharacterBody3D
		n = n.get_parent()
	return null
