extends Node
## SCRAPLAND -- Turns WorldClock into a sky.
##
## The clock stays the source of truth. This node only paints: sun height and
## colour, a dim moon at night, the procedural sky, fog, and the yard beacons.
## Nothing here saves -- reload the clock and the sky catches up on the next frame.

@export var sun_path: NodePath = ^"../Sun"
@export var moon_path: NodePath = ^"../Moon"
@export var environment_path: NodePath = ^"../WorldEnvironment"

## Minutes after midnight when the sun clears the horizon / drops below it.
@export var sunrise_minute: int = 5 * 60 + 30
@export var sunset_minute: int = 18 * 60 + 45
@export var noon_elevation_degrees: float = 68.0

@onready var _sun: DirectionalLight3D = get_node_or_null(sun_path) as DirectionalLight3D
@onready var _moon: DirectionalLight3D = get_node_or_null(moon_path) as DirectionalLight3D
@onready var _world_env: WorldEnvironment = get_node_or_null(environment_path) as WorldEnvironment

var _sky: ProceduralSkyMaterial
var _environment: Environment
var _yard: Array[OmniLight3D] = []
var _palette: Array[Dictionary] = []


func _ready() -> void:
	if _world_env:
		_environment = _world_env.environment
	if _environment and _environment.sky:
		var mat := _environment.sky.sky_material
		if mat is ProceduralSkyMaterial:
			_sky = mat as ProceduralSkyMaterial
	for node in get_tree().get_nodes_in_group(&"night_lights"):
		var lamp := node as OmniLight3D
		if lamp:
			_yard.append(lamp)
	_palette = _looks()
	_apply(_read_minutes())


func _process(_delta: float) -> void:
	_apply(_read_minutes())


# --- Sampling ---------------------------------------------------------------

func _read_minutes() -> float:
	var clock := _clock()
	if clock and clock.has_method("get_smooth_minutes"):
		return float(clock.call("get_smooth_minutes"))
	if clock and clock.has_method("get_total_minutes"):
		return float(clock.call("get_total_minutes"))
	return 7.0 * 60.0 + 12.0


func _clock() -> Node:
	return get_tree().root.get_node_or_null("WorldClock")


func _apply(total_minutes: float) -> void:
	var minute := fposmod(total_minutes, 1440.0)
	var look := _sample_look(minute)
	_apply_sky(look)
	_apply_fog(look)
	_place_sun(minute, look)
	_place_moon(minute, look)
	_apply_yard(look)


func _sample_look(minute: float) -> Dictionary:
	var keys := _palette
	var previous: Dictionary = keys[keys.size() - 1]
	var nxt: Dictionary = keys[0]
	for i in keys.size():
		var key: Dictionary = keys[i]
		if minute < float(key["m"]):
			nxt = key
			previous = keys[i - 1] if i > 0 else keys[keys.size() - 1]
			break
		if i == keys.size() - 1:
			previous = key
			nxt = keys[0]
	var start := float(previous["m"])
	var finish := float(nxt["m"])
	var span := finish - start
	if span <= 0.0:
		span += 1440.0
	var here := minute - start
	if here < 0.0:
		here += 1440.0
	return _mix(previous, nxt, clampf(here / span, 0.0, 1.0))


## Hand-tuned colour keys. Morning at 8:00 matches the yard you already know.
func _looks() -> Array[Dictionary]:
	return [
		_look(0.0,
			Color(0.03, 0.04, 0.10), Color(0.16, 0.10, 0.20),
			Color(0.05, 0.04, 0.05), Color(0.10, 0.07, 0.09),
			Color(0.35, 0.45, 0.70), 0.0, 0.42,
			Color(0.10, 0.12, 0.18), 0.016, 0.22, 5.0),
		_look(5.0 * 60.0,
			Color(0.22, 0.16, 0.32), Color(0.95, 0.42, 0.28),
			Color(0.12, 0.08, 0.08), Color(0.45, 0.22, 0.16),
			Color(1.0, 0.50, 0.28), 0.25, 0.18,
			Color(0.55, 0.32, 0.24), 0.012, 0.4, 3.2),
		_look(6.5 * 60.0,
			Color(0.30, 0.32, 0.52), Color(1.0, 0.62, 0.40),
			Color(0.18, 0.14, 0.12), Color(0.70, 0.48, 0.32),
			Color(1.0, 0.72, 0.45), 0.7, 0.04,
			Color(0.78, 0.55, 0.40), 0.008, 0.7, 2.0),
		_look(8.0 * 60.0,
			Color(0.26, 0.45, 0.68), Color(0.83, 0.72, 0.55),
			Color(0.24, 0.20, 0.17), Color(0.75, 0.65, 0.50),
			Color(1.0, 0.95, 0.85), 1.15, 0.0,
			Color(0.76, 0.71, 0.62), 0.006, 1.0, 1.2),
		_look(12.0 * 60.0,
			Color(0.34, 0.58, 0.86), Color(0.78, 0.84, 0.90),
			Color(0.28, 0.24, 0.18), Color(0.70, 0.68, 0.58),
			Color(1.0, 0.98, 0.92), 1.35, 0.0,
			Color(0.80, 0.78, 0.70), 0.004, 1.1, 1.0),
		_look(16.5 * 60.0,
			Color(0.28, 0.42, 0.64), Color(0.90, 0.68, 0.42),
			Color(0.24, 0.18, 0.14), Color(0.78, 0.58, 0.38),
			Color(1.0, 0.82, 0.55), 1.05, 0.0,
			Color(0.80, 0.62, 0.45), 0.007, 0.95, 1.4),
		_look(17.75 * 60.0,
			Color(0.20, 0.16, 0.38), Color(0.98, 0.40, 0.26),
			Color(0.14, 0.08, 0.08), Color(0.55, 0.26, 0.18),
			Color(1.0, 0.42, 0.22), 0.45, 0.12,
			Color(0.62, 0.30, 0.22), 0.011, 0.5, 3.0),
		_look(19.5 * 60.0,
			Color(0.06, 0.06, 0.14), Color(0.28, 0.14, 0.22),
			Color(0.06, 0.04, 0.05), Color(0.16, 0.08, 0.10),
			Color(0.40, 0.30, 0.45), 0.0, 0.38,
			Color(0.14, 0.12, 0.18), 0.015, 0.28, 4.6),
	]


func _look(
		minute: float,
		top: Color, horizon: Color,
		ground_bottom: Color, ground_horizon: Color,
		sun_color: Color, sun_energy: float, moon_energy: float,
		fog: Color, fog_density: float,
		ambient: float, yard: float) -> Dictionary:
	return {
		"m": minute,
		"top": top,
		"horizon": horizon,
		"ground_bottom": ground_bottom,
		"ground_horizon": ground_horizon,
		"sun_color": sun_color,
		"sun_energy": sun_energy,
		"moon_energy": moon_energy,
		"fog": fog,
		"fog_density": fog_density,
		"ambient": ambient,
		"yard": yard,
	}


func _mix(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		if key == "m":
			continue
		var left: Variant = a[key]
		var right: Variant = b[key]
		if left is Color:
			out[key] = (left as Color).lerp(right as Color, t)
		else:
			out[key] = lerpf(float(left), float(right), t)
	return out


# --- Painters ---------------------------------------------------------------

func _apply_sky(look: Dictionary) -> void:
	if _sky:
		_sky.sky_top_color = look["top"]
		_sky.sky_horizon_color = look["horizon"]
		_sky.ground_bottom_color = look["ground_bottom"]
		_sky.ground_horizon_color = look["ground_horizon"]
	if _environment:
		_environment.ambient_light_energy = look["ambient"]
		_environment.background_energy_multiplier = clampf(float(look["ambient"]) + 0.15, 0.2, 1.2)


func _apply_fog(look: Dictionary) -> void:
	if _environment == null:
		return
	_environment.fog_light_color = look["fog"]
	_environment.fog_density = look["fog_density"]


func _place_sun(minute: float, look: Dictionary) -> void:
	if _sun == null:
		return
	var rise := float(sunrise_minute)
	var set := float(sunset_minute)
	var u := inverse_lerp(rise, set, minute)
	var elevation := -14.0
	if u >= 0.0 and u <= 1.0:
		elevation = sin(u * PI) * noon_elevation_degrees
	var azimuth := lerpf(-85.0, 85.0, clampf(u, 0.0, 1.0))
	_sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
	_sun.light_color = look["sun_color"]
	_sun.light_energy = look["sun_energy"]
	_sun.shadow_enabled = float(look["sun_energy"]) > 0.08


func _place_moon(minute: float, look: Dictionary) -> void:
	if _moon == null:
		return
	var u := inverse_lerp(float(sunrise_minute), float(sunset_minute), minute)
	var azimuth := lerpf(-85.0, 85.0, clampf(u, 0.0, 1.0)) + 180.0
	_moon.rotation_degrees = Vector3(-38.0, azimuth, 0.0)
	_moon.light_color = Color(0.55, 0.68, 0.95)
	_moon.light_energy = look["moon_energy"]
	_moon.visible = float(look["moon_energy"]) > 0.02


func _apply_yard(look: Dictionary) -> void:
	var energy: float = look["yard"]
	for lamp in _yard:
		if is_instance_valid(lamp):
			lamp.light_energy = energy
