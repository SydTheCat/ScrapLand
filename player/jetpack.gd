extends Node3D
class_name RobotJetpack
## SCRAPLAND -- Backpack thruster. Hold Space in the air to burn a short tank.
##
## Ground jumps still use the same key. Once Rocky has left the floor, holding
## Space opens the nozzles until fuel runs out or the key is released. The tank
## only refills while standing. The battery pays a sip for every second of thrust.

signal burst_started
signal burst_ended
signal fuel_changed(current: float, maximum: float)

@export_group("Thrust")
## Upward acceleration while the nozzles are open, in m/s².
@export var thrust: float = 24.0
## Instant upward kick the moment a hold starts. Arrests a fall and pops Rocky up.
@export var burst_kick: float = 5.4
## Extra air steering while thrusting.
@export var air_nudge: float = 8.0

@export_group("Fuel")
## Seconds of hold time in a full tank. Short on purpose — this is a spurt, not flight.
@export var max_fuel: float = 1.8
## Fuel restored per second while standing on the floor.
@export var recharge_rate: float = 1.35
## Need at least this much fuel to light the nozzles.
@export var min_fuel_to_fire: float = 0.04

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

@onready var _robot: Player = _find_player()
@onready var _battery: RobotBattery = (
		_robot.get_node_or_null("Battery") as RobotBattery if _robot else null
)
@onready var _beeper: Node = _robot.get_node_or_null("Beeper") if _robot else null


func _ready() -> void:
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


## Called from Player._physics_process after the ground jump has had its say.
func tick(delta: float, jumped_this_frame: bool) -> void:
	if _robot == null:
		return

	var holding := _robot.can_move and Input.is_action_pressed(&"jump")
	var want_thrust := (
			holding
			and not jumped_this_frame
			and not _robot.is_on_floor()
			and _fuel > 0.0
	)

	if want_thrust:
		if not _has_power():
			if _bursting:
				_stop_burst()
			_notify_no_power()
			return
		if not _bursting:
			if _fuel < min_fuel_to_fire:
				_notify_empty()
				return
			_start_burst()
		_run_burst(delta)
		return

	if _bursting:
		_stop_burst()

	if _robot.is_on_floor():
		_recharge(delta)
	elif holding and _fuel <= 0.0:
		_notify_empty()


func is_bursting() -> bool:
	return _bursting


func get_fuel() -> float:
	return _fuel


func get_fuel_ratio() -> float:
	return _fuel / maxf(max_fuel, 0.001)


func _start_burst() -> void:
	_bursting = true
	_empty_notified = false
	_robot.velocity.y = maxf(_robot.velocity.y + burst_kick, burst_kick)
	_set_fx(true)
	_whoosh()
	burst_started.emit()


func _run_burst(delta: float) -> void:
	if not _robot.can_move or _robot.is_on_floor() or _fuel <= 0.0:
		_stop_burst()
		return

	var cost := energy_per_second * delta
	if _battery and cost > 0.0 and not _battery.consume(cost):
		_stop_burst()
		_notify_no_power()
		return

	var previous := _fuel
	_fuel = maxf(_fuel - delta, 0.0)
	if not is_equal_approx(previous, _fuel):
		fuel_changed.emit(_fuel, max_fuel)

	_robot.velocity.y += thrust * delta
	var nudge := _robot.get_move_direction() * air_nudge * delta
	_robot.velocity.x += nudge.x
	_robot.velocity.z += nudge.z

	if _fuel <= 0.0:
		_stop_burst()
		_notify_empty()


func _stop_burst() -> void:
	if not _bursting:
		return
	_bursting = false
	_set_fx(false)
	burst_ended.emit()


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
	return not _battery.is_dead() and _battery.get_energy() >= 0.4


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


func _find_player() -> Player:
	var n: Node = self
	while n:
		if n is Player:
			return n as Player
		n = n.get_parent()
	return null
