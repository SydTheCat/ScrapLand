extends Node
class_name RobotHull
## SCRAPLAND -- The robot's chassis. Battery is power; this is the body.
##
## Attach as a CHILD of the Player. Pure logic: it tracks integrity, takes
## fall damage from the player's landed signal, and shouts through signals.
## The HUD draws the bar. The repair tool calls repair().
##
## Hull at zero does not shut the robot down -- the battery already owns that.
## It just sits at RUINED until something patches it.

signal integrity_changed(current: float, maximum: float)
signal state_changed(state: State, previous: State)

enum State {
	SOUND,      ## 100 - 70
	DENTED,     ## 69 - 40
	DAMAGED,    ## 39 - 15
	CRITICAL,   ## 14 - 1
	RUINED,     ## 0
}

@export_group("Capacity")
@export var max_integrity: float = 100.0
## Wakes up already scuffed. This robot did not have a gentle landing.
@export var starting_integrity: float = 74.0

@export_group("Falls")
## Impact speed in m/s that a landing is allowed to ignore. Ordinary jumps
## stay under this; a drop off the test platform does not.
@export var safe_fall_speed: float = 6.0
## Integrity lost per m/s faster than safe_fall_speed.
@export var damage_per_excess: float = 4.0

@export_group("State Thresholds")
@export_range(0.0, 100.0) var dented_percent: float = 70.0
@export_range(0.0, 100.0) var damaged_percent: float = 40.0
@export_range(0.0, 100.0) var critical_percent: float = 15.0

var _integrity: float = 0.0
var _state: State = State.SOUND

@onready var _robot: Player = get_parent() as Player


func _ready() -> void:
	_integrity = clampf(starting_integrity, 0.0, max_integrity)
	_state = _state_for(_integrity)
	if _robot:
		_robot.landed.connect(_on_landed)
	integrity_changed.emit(_integrity, max_integrity)
	state_changed.emit(_state, _state)
	add_to_group(&"persist")


func _on_landed(fall_speed: float) -> void:
	var excess := fall_speed - safe_fall_speed
	if excess <= 0.0:
		return
	apply_damage(excess * damage_per_excess)


# --- Public API -------------------------------------------------------------

func apply_damage(amount: float) -> void:
	_change(-absf(amount))


func repair(amount: float) -> void:
	_change(absf(amount))


## Upgrade plates call this. Keeps the current integrity, raises the ceiling.
func set_max_integrity(new_maximum: float) -> void:
	max_integrity = maxf(1.0, new_maximum)
	_integrity = clampf(_integrity, 0.0, max_integrity)
	integrity_changed.emit(_integrity, max_integrity)
	var next := _state_for(_integrity)
	if next != _state:
		var was := _state
		_state = next
		state_changed.emit(next, was)


func get_integrity() -> float:
	return _integrity


func get_ratio() -> float:
	return _integrity / maxf(max_integrity, 0.001)


func get_state() -> State:
	return _state


func is_ruined() -> bool:
	return _state == State.RUINED


func needs_repair() -> bool:
	return _integrity < max_integrity - 0.25


# --- Bookkeeping ------------------------------------------------------------

func _change(amount: float) -> void:
	if is_zero_approx(amount):
		return
	var previous := _integrity
	_integrity = clampf(_integrity + amount, 0.0, max_integrity)
	if is_equal_approx(previous, _integrity):
		return
	integrity_changed.emit(_integrity, max_integrity)
	var next := _state_for(_integrity)
	if next != _state:
		var was := _state
		_state = next
		state_changed.emit(next, was)


func _state_for(integrity: float) -> State:
	if integrity <= 0.0:
		return State.RUINED
	var percent := integrity / maxf(max_integrity, 0.001) * 100.0
	if percent < critical_percent:
		return State.CRITICAL
	if percent < damaged_percent:
		return State.DAMAGED
	if percent < dented_percent:
		return State.DENTED
	return State.SOUND


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {
		"integrity": _integrity,
		"max_integrity": max_integrity,
	}


func load_data(data: Dictionary) -> void:
	max_integrity = maxf(1.0, float(data.get("max_integrity", max_integrity)))
	_integrity = clampf(float(data.get("integrity", _integrity)), 0.0, max_integrity)
	var next := _state_for(_integrity)
	if next != _state:
		var was := _state
		_state = next
		state_changed.emit(next, was)
	integrity_changed.emit(_integrity, max_integrity)
