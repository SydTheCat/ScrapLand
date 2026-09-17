extends Area3D
class_name Interactor
## SCRAPLAND -- Finds the thing the player is about to interact with.
##
## Attach to an Area3D child of the Player with a SphereShape3D roughly the size
## of `interaction_distance`. The area gathers every Interactable in reach, then
## each frame this script scores them and picks the best one:
##
##   * how close it is to the middle of the screen (are you looking at it?)
##   * how close it is to the robot (near things beat far things)
##
## Scoring beats a plain raycast here because the camera is behind the robot:
## you can pick up something at your feet without having to aim down at it.

## Fires when the player's target changes. Passes null when nothing is in range.
signal focus_changed(interactable: Interactable)

@export_group("Reach")
## Objects further than this from the ROBOT are ignored, even if the detection
## sphere is bigger.
@export var interaction_distance: float = 2.6
## How much of a candidate's score comes from being centred on screen vs being
## nearby. Raise to make aiming matter more.
@export var facing_weight: float = 1.0
@export var distance_weight: float = 0.15
## Ignore anything more than roughly this far off-centre. -1 = even behind you.
@export_range(-1.0, 1.0) var min_facing: float = -0.15

var _candidates: Array[Interactable] = []
var _focused: Interactable
var _last_prompt: String = ""

@onready var _player: Player = get_parent() as Player


func _ready() -> void:
	# Detect physics layer 4 (interactable); be detectable by nothing.
	collision_layer = 0
	collision_mask = Interactable.INTERACTABLE_LAYER
	monitoring = true
	monitorable = false

	area_entered.connect(_on_area_entered)
	area_exited.connect(_on_area_exited)
	# The player turns the key press into a signal; we decide what it acts on.
	_player.interact_requested.connect(_on_interact_requested)


func _physics_process(_delta: float) -> void:
	_prune_candidates()
	# Build mode wants the screen to itself: no ground glow and no "E — Salvage"
	# prompt competing with the placement panel.
	_set_focused(_pick_best_candidate() if _player.actions_enabled else null)
	_refresh_prompt()


# --- Candidate tracking -----------------------------------------------------

func _on_area_entered(area: Area3D) -> void:
	var interactable := area as Interactable
	if interactable and not _candidates.has(interactable):
		_candidates.append(interactable)


func _on_area_exited(area: Area3D) -> void:
	var interactable := area as Interactable
	if interactable:
		_candidates.erase(interactable)


## Drops candidates that have been freed. Loading a save deletes pickups that
## may still be sitting in this list, and area_exited does not always arrive for
## a node that was pulled out of the tree and freed in the same breath.
func _prune_candidates() -> void:
	for i in range(_candidates.size() - 1, -1, -1):
		if not is_instance_valid(_candidates[i]) or not _candidates[i].is_inside_tree():
			_candidates.remove_at(i)


## Highest score wins. Returns null when nothing qualifies.
func _pick_best_candidate() -> Interactable:
	var camera := _get_camera()
	if camera == null:
		return null

	var eye := camera.global_position
	var view_direction := -camera.global_transform.basis.z
	var best: Interactable = null
	var best_score := -INF

	for candidate in _candidates:
		if not is_instance_valid(candidate) or not candidate.enabled:
			continue

		var distance := _player.global_position.distance_to(candidate.global_position)
		if distance > interaction_distance:
			continue

		# How centred on screen the candidate is: 1 = dead ahead, -1 = behind.
		var to_candidate := candidate.global_position - eye
		if to_candidate.length_squared() < 0.0001:
			continue
		var facing := to_candidate.normalized().dot(view_direction)
		if facing < min_facing:
			continue

		var score := facing * facing_weight - distance * distance_weight
		if score > best_score:
			best_score = score
			best = candidate

	return best


func _set_focused(next: Interactable) -> void:
	# A freed reference does not compare equal to null, so clear it explicitly
	# before the early-out below can be fooled by it.
	if not is_instance_valid(_focused):
		_focused = null
	if next == _focused:
		return
	if is_instance_valid(_focused):
		_focused.set_focused(false)
	_focused = next
	if is_instance_valid(_focused):
		_focused.set_focused(true)
	focus_changed.emit(_focused)


## Re-sent whenever the text itself changes, so a charger that switches from
## "Repair" to "Use" updates the prompt without any extra plumbing.
func _refresh_prompt() -> void:
	var prompt := _focused.get_prompt() if is_instance_valid(_focused) else ""
	if prompt == _last_prompt:
		return
	_last_prompt = prompt
	GameEvents.set_prompt(prompt)


func _on_interact_requested() -> void:
	if is_instance_valid(_focused):
		_focused.interact(_player)


func _get_camera() -> Camera3D:
	var rig := _player.camera_rig
	return rig.camera if rig else null


# --- Public API -------------------------------------------------------------

## What the player would interact with right now, or null. Never hands back a
## freed node -- callers run every frame and would touch it before this node's
## next physics tick got the chance to clear it.
func get_focused() -> Interactable:
	return _focused if is_instance_valid(_focused) else null
