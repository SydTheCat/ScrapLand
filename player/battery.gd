extends Node
class_name RobotBattery
## SCRAPLAND -- The robot's battery. This is the game's primary survival stat.
##
## Attach this as a CHILD of the Player. It is pure logic: it knows how much
## energy is left, drains it based on what the robot is doing, and shouts about
## it through signals. It never draws anything and never plays a sound -- the
## HUD and player/robot_effects.gd handle all of that.
##
## It learns what the robot is doing purely by listening to the player's
## signals, so it never reaches into the player's node tree.

# --- Signals ----------------------------------------------------------------

## Fires every frame energy changes. The HUD battery meter listens to this.
signal energy_changed(current: float, maximum: float)
## Fires only when crossing a threshold, so effects don't retrigger constantly.
signal state_changed(state: State, previous: State)
## Battery hit zero. The robot is dead until it reboots.
signal shutdown
## Finished rebooting at the respawn point.
signal rebooted
signal charging_changed(is_charging: bool)
## Emitted on shutdown so the inventory (a later step) can drop part of the
## robot's cargo. Nothing listens to it yet.
signal resources_lost(fraction: float)

# --- Battery states ---------------------------------------------------------

## Thresholds are configured below, not hard-coded into this enum.
enum State {
	NORMAL,    ## 100% - 50%
	WARNING,   ## 49% - 25%   (yellow)
	DANGER,    ## 24% - 10%   (red)
	CRITICAL,  ## below 10%   (sparks, flicker, slowdown)
	DEAD,      ## 0% -- shut down
}

# --- Tuning -----------------------------------------------------------------

@export_group("Capacity")
## Battery upgrades raise this later. Use set_max_energy() so the HUD updates.
@export var max_energy: float = 100.0
## The robot wakes up damaged, at roughly 40%.
@export var starting_energy: float = 40.0

@export_group("Drain Per Second")
## Turn this off in the Inspector when you want to test something else in peace.
@export var drain_enabled: bool = true
## Idling still costs a trickle -- the robot is never truly off.
@export var idle_drain: float = 0.08
@export var walk_drain: float = 0.25
@export var run_drain: float = 0.6
@export var air_drain: float = 0.3
## Added on top of the movement drain while the head lamp is on.
@export var flashlight_drain: float = 0.15

@export_group("Action Costs")
## One-off cost each time the equipped tool is used. Salvaging and crafting
## will call consume() with their own costs later.
@export var tool_use_cost: float = 1.5

@export_group("Charging")
## Energy per second restored while touching a working charger.
@export var charge_rate: float = 12.0

@export_group("State Thresholds")
## Percentages, not absolute energy, so they keep working after upgrades.
@export_range(0.0, 100.0) var warning_percent: float = 50.0
@export_range(0.0, 100.0) var danger_percent: float = 25.0
@export_range(0.0, 100.0) var critical_percent: float = 10.0
## Movement speed multiplier applied to the player while critical.
@export_range(0.1, 1.0) var critical_speed_multiplier: float = 0.55

@export_group("Shutdown")
## Seconds spent powered down before rebooting.
@export var reboot_delay: float = 3.0
## Energy the robot wakes up with after a shutdown.
@export var reboot_energy: float = 25.0
## Fraction of carried resources lost on shutdown (used by inventory later).
@export_range(0.0, 1.0) var resource_loss_fraction: float = 0.25

# --- Internal ---------------------------------------------------------------

var _energy: float = 0.0
var _state: State = State.NORMAL
var _locomotion: StringName = &"idle"
var _flashlight_on: bool = false
var _charging: bool = false
var _reboot_timer: float = 0.0

## Where the robot wakes up after a shutdown. Charging stations will overwrite
## this in a later step; for now it is wherever the player started.
var respawn_position: Vector3 = Vector3.ZERO

@onready var _robot: Player = get_parent() as Player


func _ready() -> void:
	_energy = clampf(starting_energy, 0.0, max_energy)
	_state = _state_for_energy(_energy)
	respawn_position = _robot.global_position

	# Listen to the player instead of polling its nodes. Note we cannot read the
	# player's @onready vars here -- children become ready before their parent.
	_robot.locomotion_changed.connect(_on_locomotion_changed)
	_robot.flashlight_toggled.connect(_on_flashlight_toggled)
	_robot.tool_used.connect(_on_tool_used)

	# Let listeners draw the correct starting values on frame one.
	energy_changed.emit(_energy, max_energy)
	state_changed.emit(_state, _state)

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


func _process(delta: float) -> void:
	if _state == State.DEAD:
		_process_reboot(delta)
		return

	if _charging:
		_change_energy(charge_rate * delta)
	elif drain_enabled:
		_change_energy(-_current_drain_rate() * delta)


## Picks the drain rate for whatever the robot is currently doing.
func _current_drain_rate() -> float:
	var rate := idle_drain
	match _locomotion:
		&"walk":
			rate = walk_drain
		&"run":
			rate = run_drain
		&"air":
			rate = air_drain
	if _flashlight_on:
		rate += flashlight_drain
	return rate


# --- Energy bookkeeping -----------------------------------------------------

func _change_energy(amount: float) -> void:
	if is_zero_approx(amount):
		return
	var previous := _energy
	_energy = clampf(_energy + amount, 0.0, max_energy)
	if is_equal_approx(previous, _energy):
		return

	energy_changed.emit(_energy, max_energy)
	_refresh_state()

	if _energy <= 0.0:
		_shut_down()


func _refresh_state() -> void:
	var next := _state_for_energy(_energy)
	if next != _state:
		_set_state(next)


func _state_for_energy(energy: float) -> State:
	if energy <= 0.0:
		return State.DEAD
	var percent := energy / max_energy * 100.0
	if percent < critical_percent:
		return State.CRITICAL
	if percent < danger_percent:
		return State.DANGER
	if percent < warning_percent:
		return State.WARNING
	return State.NORMAL


func _set_state(next: State) -> void:
	var previous := _state
	_state = next
	# Critical power physically slows the robot down. This is the only place the
	# battery writes to the player, and speed_multiplier exists for exactly it.
	_robot.speed_multiplier = critical_speed_multiplier if next == State.CRITICAL else 1.0
	state_changed.emit(next, previous)


# --- Shutdown and reboot ----------------------------------------------------

func _shut_down() -> void:
	if _state == State.DEAD:
		return
	_energy = 0.0
	_charging = false
	_robot.can_move = false
	_robot.velocity = Vector3.ZERO
	_set_state(State.DEAD)
	resources_lost.emit(resource_loss_fraction)
	shutdown.emit()
	_reboot_timer = reboot_delay


func _process_reboot(delta: float) -> void:
	_reboot_timer -= delta
	if _reboot_timer > 0.0:
		return
	_robot.teleport_to(respawn_position)
	_robot.can_move = true
	_energy = clampf(reboot_energy, 1.0, max_energy)
	_set_state(_state_for_energy(_energy))
	energy_changed.emit(_energy, max_energy)
	rebooted.emit()


# --- Signal handlers --------------------------------------------------------

func _on_locomotion_changed(state: StringName) -> void:
	_locomotion = state


func _on_flashlight_toggled(is_on: bool) -> void:
	_flashlight_on = is_on


func _on_tool_used(_is_alternate: bool) -> void:
	consume(tool_use_cost)


# --- Public API -------------------------------------------------------------

## Spend energy for an action. Returns false (and spends nothing) if there is
## not enough left, so callers can refuse to salvage or craft.
func consume(amount: float) -> bool:
	if _state == State.DEAD:
		return false
	if amount > _energy:
		return false
	_change_energy(-amount)
	return true


## Restore energy directly -- used by portable batteries and pickups.
func add_energy(amount: float) -> void:
	_change_energy(absf(amount))


## Charging stations call this while the robot stands in their area.
func set_charging(charging: bool) -> void:
	if _charging == charging:
		return
	_charging = charging
	charging_changed.emit(_charging)


## Battery upgrades call this. Keeps the current charge, raises the ceiling.
func set_max_energy(new_maximum: float) -> void:
	max_energy = maxf(1.0, new_maximum)
	_energy = clampf(_energy, 0.0, max_energy)
	energy_changed.emit(_energy, max_energy)
	_refresh_state()


func get_energy() -> float:
	return _energy


## 0.0 - 1.0, handy for driving bars and shaders.
func get_ratio() -> float:
	return _energy / max_energy


func get_percent() -> float:
	return get_ratio() * 100.0


func get_state() -> State:
	return _state


func is_charging() -> bool:
	return _charging


func is_dead() -> bool:
	return _state == State.DEAD


## How fast energy is leaving right now. Zero while charging or shut down.
func get_drain_rate() -> float:
	if _state == State.DEAD or _charging:
		return 0.0
	return _current_drain_rate()


## Short caption for the HUD: "18M", "FULL 6S", or "HOLDING".
func get_eta_text() -> String:
	if _state == State.DEAD:
		return "OFFLINE"
	if _charging:
		var need := max_energy - _energy
		if need <= 0.05:
			return "FULL"
		return "FULL %s" % _format_span(need / maxf(charge_rate, 0.001))
	var rate := _current_drain_rate()
	if rate <= 0.001:
		return "HOLDING"
	return _format_span(_energy / rate)


func _format_span(seconds: float) -> String:
	var total := maxi(0, roundi(seconds))
	var minutes := total / 60
	if minutes >= 60:
		return "%dH" % (minutes / 60)
	if minutes >= 1:
		return "%dM" % minutes
	return "%dS" % total


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {
		"energy": _energy,
		"max_energy": max_energy,
		"respawn": respawn_position,
	}


func load_data(data: Dictionary) -> void:
	var was_dead := _state == State.DEAD

	max_energy = maxf(1.0, float(data.get("max_energy", max_energy)))
	respawn_position = data.get("respawn", respawn_position)
	_energy = clampf(float(data.get("energy", _energy)), 0.0, max_energy)

	# Charging is decided by standing on a pad, and the physics engine will work
	# that out again a frame from now.
	set_charging(false)

	var next := _state_for_energy(_energy)
	if next != _state:
		_set_state(next)
	else:
		# Same power band as before. Keep the speed multiplier honest without
		# re-announcing the power level across the screen.
		_robot.speed_multiplier = critical_speed_multiplier if next == State.CRITICAL else 1.0

	# Only touch can_move when death status actually changed, otherwise loading
	# with a menu open would hand control back while the menu is still up.
	if _state == State.DEAD:
		_reboot_timer = reboot_delay
		_robot.can_move = false
	elif was_dead:
		# Loading out of a shutdown counts as a reboot, which is what clears the
		# HUD's shutdown overlay.
		_robot.can_move = true
		rebooted.emit()

	energy_changed.emit(_energy, max_energy)
