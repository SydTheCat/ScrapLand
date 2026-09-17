extends Control
## SCRAPLAND -- Top-right clock. Reads WorldClock; draws nothing else.

@onready var time_label: Label = $Time
@onready var date_label: Label = $Date


func _ready() -> void:
	var clock := _clock()
	if clock == null:
		push_warning("clock_readout: WorldClock autoload is missing.")
		return
	if clock.has_signal("minute_passed"):
		clock.connect("minute_passed", _on_minute)
	if clock.has_signal("period_changed"):
		clock.connect("period_changed", _on_period)
	_refresh()


func _on_minute(_total: int) -> void:
	_refresh()


func _on_period(_period: StringName) -> void:
	_refresh()


func _refresh() -> void:
	var clock := _clock()
	if clock == null:
		return
	time_label.text = String(clock.call("get_clock_text"))
	date_label.text = String(clock.call("get_date_text"))


func _clock() -> Node:
	return get_tree().root.get_node_or_null("WorldClock")
