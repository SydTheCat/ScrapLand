extends Control
class_name BatteryMeter
## SCRAPLAND -- The battery gauge in the bottom-right of the HUD.
##
## Purely a display. Call bind_battery() once with the robot's RobotBattery and
## it keeps itself up to date from that point on.

@export_group("Fill Colours")
@export var color_normal: Color = Color(0.35, 0.9, 0.45)
@export var color_warning: Color = Color(0.96, 0.8, 0.2)
@export var color_danger: Color = Color(0.95, 0.4, 0.18)
@export var color_critical: Color = Color(1.0, 0.2, 0.2)
@export var color_charging: Color = Color(0.4, 0.85, 1.0)
@export var color_dead: Color = Color(0.3, 0.3, 0.33)

@export_group("Animation")
## How fast the bar slides toward the real value. Higher = more immediate.
@export var fill_speed: float = 8.0
## Pulses per second while power is critical.
@export var pulse_speed: float = 4.0

@onready var fill: ColorRect = $FillBar
@onready var percent_label: Label = $PercentLabel
@onready var status_label: Label = $StatusLabel

var _battery: RobotBattery
## Captured before any resizing so we always scale from the full-width value.
var _max_fill_width: float = 0.0
var _target_ratio: float = 1.0
var _shown_ratio: float = 1.0
var _pulse_time: float = 0.0
var _eta_tick: float = 0.0


func _ready() -> void:
	_max_fill_width = fill.size.x


## Wire this meter to a battery. Safe to call before or after _ready().
func bind_battery(battery: RobotBattery) -> void:
	_battery = battery
	battery.energy_changed.connect(_on_energy_changed)
	battery.state_changed.connect(_on_state_changed)
	battery.charging_changed.connect(_on_charging_changed)

	# Draw the correct values immediately instead of waiting for a change.
	_on_energy_changed(battery.get_energy(), battery.max_energy)
	_shown_ratio = _target_ratio
	_refresh_appearance()


func _process(delta: float) -> void:
	# Glide toward the real value so the bar reads as a physical gauge.
	_shown_ratio = lerpf(_shown_ratio, _target_ratio, clampf(fill_speed * delta, 0.0, 1.0))
	fill.size.x = _max_fill_width * _shown_ratio

	if _battery and _battery.get_state() == RobotBattery.State.CRITICAL:
		_pulse_time += delta * pulse_speed
		fill.modulate.a = lerpf(0.35, 1.0, absf(sin(_pulse_time * PI)))
	elif not is_equal_approx(fill.modulate.a, 1.0):
		fill.modulate.a = 1.0

	# Drain changes with walking and the lamp, so the remaining-time line
	# has to catch up even when the energy number itself has not moved.
	_eta_tick += delta
	if _eta_tick >= 0.4:
		_eta_tick = 0.0
		_refresh_appearance()


func _on_energy_changed(current: float, maximum: float) -> void:
	_target_ratio = clampf(current / maxf(maximum, 0.001), 0.0, 1.0)
	percent_label.text = "%d%%" % roundi(_target_ratio * 100.0)


func _on_state_changed(_state: RobotBattery.State, _previous: RobotBattery.State) -> void:
	_refresh_appearance()


func _on_charging_changed(_is_charging: bool) -> void:
	_refresh_appearance()


## Colour and caption both derive from state, so they update together.
func _refresh_appearance() -> void:
	if _battery == null:
		return

	var eta := _battery.get_eta_text()
	if _battery.is_charging():
		fill.color = color_charging
		_set_status("CHARGING  ·  %s" % eta, color_charging)
		return

	match _battery.get_state():
		RobotBattery.State.NORMAL:
			fill.color = color_normal
			_set_status("POWER  ·  %s" % eta, Color(0.8, 0.85, 0.8))
		RobotBattery.State.WARNING:
			fill.color = color_warning
			_set_status("LOW  ·  %s" % eta, color_warning)
		RobotBattery.State.DANGER:
			fill.color = color_danger
			_set_status("CRITICAL  ·  %s" % eta, color_danger)
		RobotBattery.State.CRITICAL:
			fill.color = color_critical
			_set_status("RESERVE  ·  %s" % eta, color_critical)
		RobotBattery.State.DEAD:
			fill.color = color_dead
			_set_status("OFFLINE", color_dead)


func _set_status(text: String, color: Color) -> void:
	status_label.text = text
	status_label.add_theme_color_override(&"font_color", color)
