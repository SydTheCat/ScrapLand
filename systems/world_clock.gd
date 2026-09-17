extends Node
## SCRAPLAND -- In-game time. Autoloaded as `WorldClock`.
##
## This is only the clock. world/day_night.gd listens to the time and paints
## the sky. Keeping them apart means the HUD can show a time of day even if
## the lighting node is missing.
##
## One real second is one in-game minute, so a full day is 24 real minutes.
## Edit seconds_per_minute if you want time to run faster while testing.

signal minute_passed(total_minutes: int)
signal period_changed(period: StringName)

const MINUTES_PER_DAY: int = 24 * 60
## The robot wakes up just after dawn on day 1.
const START_MINUTES: int = 7 * 60 + 12

## Real seconds that pass for one in-game minute.
var seconds_per_minute: float = 1.0

var _total_minutes: int = START_MINUTES
var _accum: float = 0.0
var _period: StringName = &"MORNING"


func _ready() -> void:
	_period = _period_for(_minute_of_day())
	add_to_group(&"persist")
	minute_passed.emit(_total_minutes)
	period_changed.emit(_period)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"time_forward"):
		skip_minutes(30)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"time_back"):
		skip_minutes(-30)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var step := maxf(seconds_per_minute, 0.05)
	_accum += delta
	var advanced := false
	while _accum >= step:
		_accum -= step
		_total_minutes += 1
		advanced = true
	if not advanced:
		return
	minute_passed.emit(_total_minutes)
	var next := _period_for(_minute_of_day())
	if next != _period:
		_period = next
		period_changed.emit(_period)


# --- Readouts the HUD and later systems use ---------------------------------

func get_total_minutes() -> int:
	return _total_minutes


## Whole minutes plus the fraction currently ticking, so the sun can glide
## instead of jumping once a minute.
func get_smooth_minutes() -> float:
	return float(_total_minutes) + _accum / maxf(seconds_per_minute, 0.05)


## Test / debug. The HUD and the sky both react because they already listen
## to minute_passed and period_changed.
func skip_minutes(amount: int) -> void:
	if amount == 0:
		return
	_total_minutes = maxi(0, _total_minutes + amount)
	_accum = 0.0
	minute_passed.emit(_total_minutes)
	var next := _period_for(_minute_of_day())
	if next != _period:
		_period = next
		period_changed.emit(_period)


func get_day() -> int:
	return (_total_minutes / MINUTES_PER_DAY) + 1


func get_hour() -> int:
	return _minute_of_day() / 60


func get_minute() -> int:
	return _minute_of_day() % 60


func get_period() -> StringName:
	return _period


func is_night() -> bool:
	return _period == &"NIGHT"


func get_clock_text() -> String:
	return "%02d:%02d" % [get_hour(), get_minute()]


func get_date_text() -> String:
	return "DAY %d  ·  %s" % [get_day(), String(_period)]


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {
		"total_minutes": _total_minutes,
		"accum": _accum,
	}


func load_data(data: Dictionary) -> void:
	_total_minutes = maxi(0, int(data.get("total_minutes", START_MINUTES)))
	_accum = maxf(0.0, float(data.get("accum", 0.0)))
	_period = _period_for(_minute_of_day())
	minute_passed.emit(_total_minutes)
	period_changed.emit(_period)


# --- Internals --------------------------------------------------------------

func _minute_of_day() -> int:
	return _total_minutes % MINUTES_PER_DAY


func _period_for(minute_of_day: int) -> StringName:
	if minute_of_day >= 5 * 60 and minute_of_day < 7 * 60:
		return &"DAWN"
	if minute_of_day >= 7 * 60 and minute_of_day < 12 * 60:
		return &"MORNING"
	if minute_of_day >= 12 * 60 and minute_of_day < 17 * 60:
		return &"AFTERNOON"
	if minute_of_day >= 17 * 60 and minute_of_day < 19 * 60 + 30:
		return &"DUSK"
	return &"NIGHT"
