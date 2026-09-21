extends Node3D
class_name RobotJetpack
## SCRAPLAND -- Backpack thruster. Short aerial spurts, never sustained flight.
##
## Lives on the robot model so the cans sit on Rocky's back. player.gd calls
## tick() after the ground jump so Space cannot jump and burst on the same
## press. Fuel is a separate tank that only refills on the floor; the battery
## still pays a sip for every second of thrust.

signal burst_started
signal burst_ended
signal fuel_changed(current: float, maximum: float)

@export_group("Thrust")
## Upward acceleration while a spurt is firing, in m/s².
@export var thrust: float = 22.0
## Instant upward kick at the start of a spurt. Arrests a fall and pops Rocky up.
@export var burst_kick: float = 5.8
## Extra air steering while a spurt is firing.
@export var air_nudge: float = 8.0
## How long one tap keeps the nozzles open.
@export var burst_duration: float = 0.38
## Dead time after a spurt before the next tap can fire.
@export var burst_gap: float = 0.18

@export_group("Fuel")
## Seconds of thrust in a full tank. 1.14s is three 0.38s hops.
@export var max_fuel: float = 1.14
## Fuel restored per second while standing on the floor.
@export var recharge_rate: float = 1.6
## Need at least this much fuel to strike a new spurt.
@export var min_fuel_to_fire: float = 0.12

@export_group("Battery")
## Energy drained per second while thrusting. A hop costs a little over 2.
@export var energy_per_second: float = 5.5

@export_group("FX")
@export var exhaust_paths: Array[NodePath] = [^"NozzleL/Exhaust", ^"NozzleR/Exhaust"]
@export var glow_path: NodePath = ^"Glow"

var _fuel: float = 0.0
var _burst_left: float = 0.0
var _gap_left: float = 0.0
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

	if _bursting:
		_run_burst(delta)
		return

	_gap_left = maxf(_gap_left - delta, 0.0)

	if _robot.is_on_floor():
		_recharge(delta)
		return

	if jumped_this_frame or not _robot.can_move:
		return
	if not Input.is_action_just_pressed(&"jump"):
		return
	_try_start_burst()


func is_bursting() -> bool:
	return _bursting


func get_fuel() -> float:
	return _fuel


func get_fuel_ratio() -> float:
	return _fuel / maxf(max_fuel, 0.001)


func _try_start_burst() -> void:
	if _gap_left > 0.0:
		return
	if _fuel < min_fuel_to_fire:
		_notify_empty()
		return
	if _battery:
		if _battery.is_dead() or _battery.get_energy() < 0.4:
			_notify_no_power()
			return
	_bursting = true
	_burst_left = burst_duration
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

	_fuel = maxf(_fuel - delta, 0.0)
	_burst_left -= delta
	fuel_changed.emit(_fuel, max_fuel)

	_robot.velocity.y += thrust * delta
	var nudge := _robot.get_move_direction() * air_nudge * delta
	_robot.velocity.x += nudge.x
	_robot.velocity.z += nudge.z

	if _burst_left <= 0.0 or _fuel <= 0.0:
		_stop_burst()


func _stop_burst() -> void:
	if not _bursting:
		return
	_bursting = false
	_burst_left = 0.0
	_gap_left = burst_gap
	_set_fx(false)
	burst_ended.emit()
	if _fuel <= 0.05:
		_notify_empty()


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
