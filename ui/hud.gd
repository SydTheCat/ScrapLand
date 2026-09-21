extends CanvasLayer
## SCRAPLAND -- The heads-up display.
##
## Add one instance of hud.tscn to the world scene. It finds the player through
## the "player" group, so it needs no configuration and does not care where the
## player sits in the scene tree.
##
## Owns the clock, hull, battery and jetpack cluster, the message line, the objective,
## the interact prompt, the salvage bar, the hotbar, and the shutdown overlay.

@export_group("Messages")
## Seconds a message stays fully visible before it starts fading.
@export var message_duration: float = 3.5
@export var message_fade: float = 0.8

@onready var hull_meter: HullMeter = $HullMeter
@onready var battery_meter: BatteryMeter = $BatteryMeter
@onready var jetpack_meter: JetpackMeter = $JetpackMeter
@onready var message_label: Label = $MessageLabel
@onready var interact_prompt: Label = $InteractPrompt
@onready var objective_caption: Label = $ObjectiveCaption
@onready var objective_label: Label = $ObjectiveLabel
@onready var shutdown_overlay: Control = $ShutdownOverlay
@onready var salvage_bar: Control = $SalvageBar
@onready var salvage_label: Label = $SalvageBar/Label
@onready var salvage_fill: ColorRect = $SalvageBar/Fill
@onready var tool_slots: HotbarUI = $HotbarLayer/ToolSlots

var _message_timer: float = 0.0
## Captured before the bar is ever scaled so we always grow from full width.
var _salvage_fill_width: float = 0.0
var _last_period: StringName = &""


func _ready() -> void:
	message_label.modulate.a = 0.0
	shutdown_overlay.visible = false
	interact_prompt.visible = false
	_salvage_fill_width = salvage_fill.size.x
	salvage_bar.visible = false

	# World objects talk to the HUD through the event bus, never directly.
	GameEvents.notification_requested.connect(_on_notification_requested)
	GameEvents.prompt_changed.connect(_on_prompt_changed)
	GameEvents.objective_changed.connect(_set_objective)
	GameEvents.salvage_progress_changed.connect(_on_salvage_progress_changed)
	GameEvents.salvage_ended.connect(_on_salvage_ended)
	# Catch up on an objective that was announced before this HUD existed.
	_set_objective(GameEvents.current_objective)

	var clock := get_tree().root.get_node_or_null("WorldClock")
	if clock and clock.has_signal("period_changed"):
		clock.connect("period_changed", _on_period_changed)
		if clock.has_method("get_period"):
			_last_period = StringName(clock.call("get_period"))

	var player := get_tree().get_first_node_in_group(&"player")
	if player == null:
		push_warning("hud.gd: no node in the 'player' group. HUD will stay blank.")
		return

	# Bound before the battery, which returns early if it is missing. A robot with
	# no battery is broken, but its tool slots should still draw.
	var hotbar := player.get_node_or_null("Hotbar") as Hotbar
	if hotbar:
		tool_slots.bind_hotbar(hotbar)

	var hull := player.get_node_or_null("Hull")
	if hull and hull_meter:
		hull_meter.bind_hull(hull)
		if hull.has_signal("state_changed"):
			hull.connect("state_changed", _on_hull_state_changed)

	var pack := player.get_node_or_null("RobotModel/Jetpack") as RobotJetpack
	if pack and jetpack_meter:
		jetpack_meter.bind_jetpack(pack)

	var battery := player.get_node_or_null("Battery") as RobotBattery
	if battery == null:
		push_warning("hud.gd: the player has no Battery child. HUD will stay blank.")
		return

	battery_meter.bind_battery(battery)
	battery.state_changed.connect(_on_battery_state_changed)
	battery.charging_changed.connect(_on_charging_changed)
	battery.shutdown.connect(_on_shutdown)
	battery.rebooted.connect(_on_rebooted)

	show_message("SYSTEM ONLINE. Memory: corrupted. Battery: also bad.", Color(0.7, 0.9, 1))


func _process(delta: float) -> void:
	if _message_timer <= 0.0:
		return
	_message_timer -= delta
	# Hold at full opacity, then fade out over the last `message_fade` seconds.
	message_label.modulate.a = clampf(_message_timer / message_fade, 0.0, 1.0)


# --- Public API -------------------------------------------------------------

## Show a line of text in the centre of the screen. Later systems will use this
## for pickup notifications ("+3 Scrap Metal") and objective updates.
func show_message(text: String, color: Color = Color(1, 1, 1)) -> void:
	message_label.text = text
	message_label.add_theme_color_override(&"font_color", color)
	message_label.modulate.a = 1.0
	_message_timer = message_duration


# --- Event bus reactions ----------------------------------------------------

func _on_notification_requested(text: String, color: Color) -> void:
	show_message(text, color)


## The interactor sends an empty string when nothing is in reach.
func _on_prompt_changed(text: String) -> void:
	interact_prompt.text = text
	interact_prompt.visible = not text.is_empty()


## The bar shows work DONE, so it fills up as the machine's integrity falls. The
## label arrives complete ("MINING — Copper Deposit") because the verb belongs to
## whichever tool is doing the work.
func _on_salvage_progress_changed(integrity_ratio: float, label: String) -> void:
	salvage_bar.visible = true
	salvage_label.text = label
	salvage_fill.size.x = _salvage_fill_width * clampf(1.0 - integrity_ratio, 0.0, 1.0)


func _on_salvage_ended() -> void:
	salvage_bar.visible = false


func _set_objective(text: String) -> void:
	objective_label.text = text
	var has_objective := not text.is_empty()
	objective_label.visible = has_objective
	objective_caption.visible = has_objective


# --- Battery reactions ------------------------------------------------------

## The robot narrates its own decline. Keeping the humour here (rather than in
## battery.gd) means the tone of the game lives in one file.
func _on_battery_state_changed(state: RobotBattery.State, previous: RobotBattery.State) -> void:
	var getting_worse := state > previous
	match state:
		RobotBattery.State.NORMAL:
			if not getting_worse:
				show_message("POWER LEVEL: ACCEPTABLE", Color(0.5, 1, 0.6))
		RobotBattery.State.WARNING:
			show_message("POWER RESERVES: SUBOPTIMAL", Color(1, 0.85, 0.3))
		RobotBattery.State.DANGER:
			show_message("WARNING: POWER LOW. Panic is a valid response.", Color(1, 0.5, 0.25))
		RobotBattery.State.CRITICAL:
			show_message("POWER LEVEL: TERRIBLE", Color(1, 0.3, 0.3))


func _on_charging_changed(is_charging: bool) -> void:
	if is_charging:
		show_message("CHARGING. This is the good part.", Color(0.5, 0.9, 1))


func _on_shutdown() -> void:
	shutdown_overlay.visible = true
	_message_timer = 0.0
	message_label.modulate.a = 0.0


func _on_rebooted() -> void:
	shutdown_overlay.visible = false
	show_message("REBOOT COMPLETE. Memory: still missing.", Color(0.7, 0.9, 1))


func _on_period_changed(period: StringName) -> void:
	if period == _last_period:
		return
	var first := _last_period == &""
	_last_period = period
	if first:
		return
	match period:
		&"DAWN":
			show_message("DAWN. The sky is trying.", Color(1.0, 0.7, 0.45))
		&"MORNING":
			show_message("MORNING. Battery still bad.", Color(0.75, 0.9, 1.0))
		&"AFTERNOON":
			show_message("AFTERNOON. The sun has opinions.", Color(1.0, 0.88, 0.55))
		&"DUSK":
			show_message("DUSK. Find a lamp or a charger.", Color(1.0, 0.5, 0.32))
		&"NIGHT":
			show_message("NIGHT. The lamp is not optional.", Color(0.6, 0.72, 1.0))


func _on_hull_state_changed(state: Variant, previous: Variant) -> void:
	var next := int(state)
	var was := int(previous)
	if next <= was:
		return
	match next:
		1:
			show_message("CHASSIS: DENTED. Walk it off.", Color(0.96, 0.8, 0.35))
		2:
			show_message("CHASSIS: DAMAGED. That one counted.", Color(0.95, 0.55, 0.25))
		3:
			show_message("CHASSIS: CRITICAL. Please stop falling.", Color(1, 0.35, 0.28))
		4:
			show_message("CHASSIS: RUINED. Still technically a robot.", Color(1, 0.25, 0.25))
