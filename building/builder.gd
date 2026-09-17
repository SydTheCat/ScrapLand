extends Node
class_name Builder
## SCRAPLAND -- Build mode. Attach as a child of the Player.
##
## The hotbar decides what is being placed. Selecting a buildable slot turns this
## on; selecting a tool turns it off. B still toggles the current hotbar
## buildable. Green means the spot works, red means it does not and the panel
## says why. Left mouse commits and spends the item.
##
## WHAT COUNTS AS BUILDABLE
## Nothing here lists the structures. An item is placeable because its .tres has
## a place_scene, so crafting a new kind of building is a data change: make the
## scene, point an item at it, done.
##
## THE PREVIEW
## The ghost is built from the visual half of the structure's scene and nothing
## else -- see _extract_model(). A ghost that ran the real scene's scripts would
## register itself as a working workbench while you were still deciding where to
## put it.
##
## While build mode is on, the robot's actions_enabled flag is false. That is
## what stops the left mouse button from also firing the tool in the hand. The
## number keys stay with the hotbar so you can swap to a pick without backing out.

## Physics layer 1, the world geometry the preview has to stand on.
const WORLD_LAYER: int = 1
## World geometry plus the player, both of which block a placement.
const CLEARANCE_MASK: int = 3

@export_group("Placement")
## Structures further than this from the robot are refused. Short arms.
@export var max_build_distance: float = 6.0
## How far ahead the aiming ray reaches before giving up.
@export var ray_length: float = 14.0
## Positions snap to this grid, so a row of boxes lines up without fuss.
@export var grid_size: float = 0.5
## Degrees per press of the rotate key.
@export var rotation_step: float = 45.0
## How level the ground has to be. 1.0 is perfectly flat.
@export_range(0.0, 1.0) var min_ground_flatness: float = 0.8
## Lifts the clearance box off the floor so it never collides with the ground the
## structure is meant to be standing on.
@export var ground_clearance: float = 0.06

@export_group("Construction")
## Seconds the placed structure takes to print in from the ground. Height still
## stretches this a little.
@export var build_in_duration: float = 1.15

@export_group("Ghost")
@export var valid_color: Color = Color(0.35, 1.0, 0.5, 0.42)
@export var invalid_color: Color = Color(1.0, 0.32, 0.28, 0.42)

# --- Internal ---------------------------------------------------------------

var _active: bool = false
## Placeable items the player currently owns, in ItemDB order.
var _catalogue: Array[ItemData] = []
var _index: int = 0
## Yaw of the thing being placed, in degrees.
var _facing: float = 0.0

var _target: Vector3 = Vector3.ZERO
var _valid: bool = false
var _reason: String = ""

var _ghost: Node3D
var _ghost_meshes: Array[MeshInstance3D] = []
## -1 = no material applied yet, otherwise the validity the ghost is showing.
var _ghost_shows_valid: int = -1

var _valid_material: StandardMaterial3D
var _invalid_material: StandardMaterial3D
## Reused between frames rather than allocated 60 times a second.
var _query := PhysicsShapeQueryParameters3D.new()
var _query_shape := BoxShape3D.new()

var _ui: Node

@onready var _robot: Player = get_parent() as Player
@onready var _inventory: Inventory = _robot.get_node_or_null("Inventory") as Inventory


func _ready() -> void:
	_valid_material = _make_ghost_material(valid_color)
	_invalid_material = _make_ghost_material(invalid_color)

	_query.collide_with_bodies = true
	# Areas are triggers, not obstacles. A workbench's own detection zone must not
	# count as something in the way.
	_query.collide_with_areas = false

	if _inventory:
		_inventory.changed.connect(_on_inventory_changed)
	var hotbar := _robot.get_node_or_null("Hotbar") as Hotbar
	if hotbar:
		hotbar.changed.connect(_on_inventory_changed)
	# Opening the inventory or the crafting screen puts build mode away.
	GameEvents.menu_opened.connect(_on_menu_opened)

	set_physics_process(false)


func _nudge_facing(steps: int) -> void:
	_facing = wrapf(_facing + rotation_step * float(steps), 0.0, 360.0)


func _is_rotate_right(event: InputEvent) -> bool:
	var mouse := event as InputEventMouseButton
	return mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN


func _is_rotate_left(event: InputEvent) -> bool:
	var mouse := event as InputEventMouseButton
	if mouse and mouse.pressed and mouse.button_index == MOUSE_BUTTON_WHEEL_UP:
		return true
	var key := event as InputEventKey
	return key != null and key.pressed and not key.echo and key.physical_keycode == KEY_Q


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"build_mode"):
		# Always allowed to leave; only allowed to enter while the robot is under
		# its own control.
		if _active or _robot.can_move:
			toggle()
			get_viewport().set_input_as_handled()
		return

	if not _active:
		return

	if event.is_action_pressed(&"build_rotate") or _is_rotate_right(event):
		_nudge_facing(1)
		get_viewport().set_input_as_handled()
	elif _is_rotate_left(event):
		_nudge_facing(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"tool_primary"):
		_try_place()
		get_viewport().set_input_as_handled()


## Physics rather than idle, because working out where the preview goes is two
## raycasts and a shape query.
func _physics_process(_delta: float) -> void:
	_update_target()
	_update_ghost()
	_push_status()


# --- Mode -------------------------------------------------------------------

func toggle() -> void:
	if _active:
		close()
		return
	var hotbar := _robot.get_node_or_null("Hotbar") as Hotbar
	var item := hotbar.get_selected_item() if hotbar else null
	if item and item.is_placeable():
		open_item(item)
	else:
		GameEvents.notify("Select a buildable on the hotbar first.", Color(1, 0.7, 0.35))


func open() -> void:
	toggle()


## Places this one item. The hotbar calls this when a buildable slot is selected.
func open_item(item: ItemData) -> void:
	if item == null or not item.is_placeable():
		close()
		return
	var hotbar := _robot.get_node_or_null("Hotbar") as Hotbar
	if hotbar == null or hotbar.count(item.id) <= 0:
		close()
		return

	_catalogue.clear()
	_catalogue.append(item)
	_index = 0

	if _active:
		_build_ghost()
		_push_selection()
		return

	_active = true
	_robot.actions_enabled = false
	# Start facing the same way the camera is looking, so the latch / front of
	# the crate is toward you rather than locked to world +Z.
	if _robot.camera_rig:
		_facing = snappedf(_robot.camera_rig.get_look_yaw_degrees(), rotation_step)
	set_physics_process(true)
	_build_ghost()

	var ui := _get_ui()
	if ui:
		ui.call("open")
	_push_selection()


func close() -> void:
	if not _active:
		return
	_active = false
	_robot.actions_enabled = true
	set_physics_process(false)
	_clear_ghost()

	var ui := _get_ui()
	if ui:
		ui.call("close")


func is_active() -> bool:
	return _active


# --- Selection --------------------------------------------------------------

func get_selected_item() -> ItemData:
	if _index < 0 or _index >= _catalogue.size():
		return null
	return _catalogue[_index]


func select(index: int) -> void:
	if not _active or index < 0 or index >= _catalogue.size() or index == _index:
		return
	_index = index
	_build_ghost()
	_push_selection()


## Everything placeable that is currently in the cargo hold. Walking ItemDB means
## a new buildable item shows up here the moment it exists.
func _refresh_catalogue() -> void:
	var current := get_selected_item()
	_catalogue.clear()
	_index = 0
	var hotbar := _robot.get_node_or_null("Hotbar") as Hotbar
	if current and hotbar and hotbar.count(current.id) > 0:
		_catalogue.append(current)


func _on_inventory_changed() -> void:
	if not _active:
		return
	_refresh_catalogue()
	if _catalogue.is_empty():
		GameEvents.notify("Nothing left to build with.", Color(1, 0.7, 0.35))
		close()
		return
	_push_selection()


func _on_menu_opened(_menu: Node) -> void:
	if _active:
		close()


# --- Placing ----------------------------------------------------------------

func _try_place() -> void:
	if not _valid:
		GameEvents.notify(_reason, Color(1, 0.55, 0.35))
		return

	var item := get_selected_item()
	if item == null:
		return

	var node := item.place_scene.instantiate() as Node3D
	if node == null:
		push_error("builder.gd: %s does not instance as a Node3D." % item.id)
		return

	# A plain, unique name. The save manager rebuilds a structure at the node path
	# it had when saved, and engine-generated names like "@StorageBox@7" contain
	# characters that cannot be assigned back by hand.
	node.name = "Built_%s_%d" % [item.id, node.get_instance_id()]
	_structures_root().add_child(node)
	node.global_position = _target
	node.rotation.y = deg_to_rad(_facing)
	_play_build_in(node)

	var hotbar := _robot.get_node_or_null("Hotbar") as Hotbar
	if hotbar:
		hotbar.consume_selected(1)
	GameEvents.notify("%s placed." % item.display_name, Color(0.6, 1, 0.7))


func _play_build_in(structure: Node3D) -> void:
	if structure.get_node_or_null("Model") == null:
		return
	var effect := Node.new()
	effect.set_script(preload("res://building/build_effect.gd"))
	structure.add_child(effect)
	if effect.has_method("start"):
		if "duration" in effect:
			effect.duration = build_in_duration
		effect.call("start")


func _structures_root() -> Node:
	var root := get_tree().get_first_node_in_group(&"structures")
	if root:
		return root
	# Still works in a scene with no Structures node; the save manager only needs
	# the parent to be somewhere findable.
	return _robot.get_parent()


# --- Where the preview goes -------------------------------------------------

func _update_target() -> void:
	var camera := _robot.camera_rig.camera
	if camera == null:
		_invalidate("No camera to aim with.")
		return

	var space := _robot.get_world_3d().direct_space_state
	var screen_centre := _robot.get_viewport().get_visible_rect().size * 0.5
	var from := camera.project_ray_origin(screen_centre)
	var to := from + camera.project_ray_normal(screen_centre) * ray_length

	var ray := PhysicsRayQueryParameters3D.create(from, to)
	ray.collision_mask = WORLD_LAYER
	var hit := space.intersect_ray(ray)
	if hit.is_empty():
		_target = to
		_invalidate("Aim at the ground.")
		return

	var ground: Vector3 = hit.position
	# Snap across the grid first, then look for the floor again at the snapped
	# spot. Without the second look, a structure placed near the edge of a step
	# ends up half sunk into it.
	_target = Vector3(snappedf(ground.x, grid_size), ground.y, snappedf(ground.z, grid_size))
	_target.y = _ground_height_at(_target, space, ground.y)

	if float(hit.normal.y) < min_ground_flatness:
		_invalidate("The ground is too steep here.")
		return
	if _robot.global_position.distance_to(_target) > max_build_distance:
		_invalidate("Too far away. Get closer.")
		return

	var item := get_selected_item()
	if item and not _has_clearance(item.build_size):
		_invalidate("Something is in the way.")
		return

	_valid = true
	_reason = "Clear. Ready to place."


func _ground_height_at(at: Vector3, space: PhysicsDirectSpaceState3D, fallback: float) -> float:
	var ray := PhysicsRayQueryParameters3D.create(
		at + Vector3.UP * 1.5, at + Vector3.DOWN * 1.5)
	ray.collision_mask = WORLD_LAYER
	var hit := space.intersect_ray(ray)
	if hit.is_empty():
		return fallback
	return float(hit.position.y)


## True when a box the size of the structure fits at the target without touching
## anything solid.
func _has_clearance(size: Vector3) -> bool:
	_query_shape.size = size
	# Reassigned because the query holds the shape it was given, not a live link
	# to the resource.
	_query.shape = _query_shape
	_query.collision_mask = CLEARANCE_MASK

	var centre := _target + Vector3.UP * (size.y * 0.5 + ground_clearance)
	_query.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(_facing)), centre)

	var space := _robot.get_world_3d().direct_space_state
	return space.intersect_shape(_query, 1).is_empty()


func _invalidate(reason: String) -> void:
	_valid = false
	_reason = reason


# --- The ghost --------------------------------------------------------------

func _build_ghost() -> void:
	_clear_ghost()
	var item := get_selected_item()
	if item == null or item.place_scene == null:
		return

	_ghost = Node3D.new()
	_ghost.name = "BuildGhost"
	# Hidden until the first physics frame has worked out where it goes. The
	# aiming raycasts can only run inside physics processing, so without this the
	# ghost appears at the world origin for a frame.
	_ghost.visible = false
	_structures_root().add_child(_ghost)

	var visual := _extract_model(item)
	if visual:
		_ghost.add_child(visual)
	# The ghost is one flat colour, so a crate looks almost square. This arrow
	# sits on the latch side so a rotation is obvious.
	_add_facing_marker(item)
	_collect_meshes(_ghost, _ghost_meshes)


## A flat arrow on the +Z side -- the latch / front of the crate -- so turning
## the preview is readable even after the ghost paint hides the orange latch.
func _add_facing_marker(item: ItemData) -> void:
	var depth := item.build_size.z if item else 1.0
	var marker := MeshInstance3D.new()
	marker.name = "FacingMarker"
	var prism := PrismMesh.new()
	prism.size = Vector3(0.34, 0.22, 0.05)
	marker.mesh = prism
	# Prism apex is +Y. Lay it flat so that apex points along +Z.
	marker.rotation_degrees = Vector3(90, 0, 0)
	marker.position = Vector3(0.0, 0.04, depth * 0.5 + 0.14)
	_ghost.add_child(marker)


## Lifts the visual half out of the structure's scene and throws the rest away.
##
## The scene is instanced but never added to the tree, so none of its scripts get
## a _ready: no collision shapes, no persist group, no workbench announcing
## itself to the crafting system. temp.free() rather than queue_free() because
## nothing here was ever in the tree to begin with.
func _extract_model(item: ItemData) -> Node3D:
	var temp := item.place_scene.instantiate()
	var model := temp.get_node_or_null("Model") as Node3D
	if model:
		temp.remove_child(model)
	else:
		push_warning("builder.gd: %s has no Model node; previewing a plain box." % item.id)
		model = _fallback_box(item.build_size)
	temp.free()

	_prepare_ghost_visual(model)
	return model


## A preview that lit up the room would be distracting, so the workbench's lamp
## stays off until the real one is standing there.
func _prepare_ghost_visual(node: Node) -> void:
	var light := node as Light3D
	if light:
		light.visible = false
	for child in node.get_children():
		_prepare_ghost_visual(child)


func _collect_meshes(node: Node, into: Array[MeshInstance3D]) -> void:
	var mesh := node as MeshInstance3D
	if mesh:
		into.append(mesh)
	for child in node.get_children():
		_collect_meshes(child, into)


## Stand-in preview for a structure whose scene has no Model node. Visible and
## obviously wrong, which beats an invisible ghost.
func _fallback_box(size: Vector3) -> Node3D:
	var holder := Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = Vector3.UP * (size.y * 0.5)
	holder.add_child(mesh)
	return holder


func _update_ghost() -> void:
	if _ghost == null:
		return

	_ghost.global_position = _target
	_ghost.rotation.y = deg_to_rad(_facing)
	_ghost.visible = true

	# Only repaint when the answer actually changes, rather than reassigning a
	# material to every mesh every frame.
	var shows := 1 if _valid else 0
	if shows == _ghost_shows_valid:
		return
	_ghost_shows_valid = shows
	var material := _valid_material if _valid else _invalid_material
	for mesh in _ghost_meshes:
		mesh.material_override = material


func _clear_ghost() -> void:
	_ghost_meshes.clear()
	_ghost_shows_valid = -1
	if _ghost == null:
		return
	# Meshes and nothing else, so there is no collision for the engine to be
	# holding when this goes.
	_ghost.queue_free()
	_ghost = null


func _make_ghost_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = 0.5
	# Without this you see straight through the back faces of a hollow shape.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


# --- Panel ------------------------------------------------------------------

## Looked up on demand rather than in _ready, so it does not matter whether the
## UI or the player finishes entering the tree first.
func _get_ui() -> Node:
	if _ui == null or not is_instance_valid(_ui):
		_ui = get_tree().get_first_node_in_group(&"build_ui")
	return _ui


func _push_selection() -> void:
	var ui := _get_ui()
	if ui == null or not ui.has_method("set_structure"):
		return
	var item := get_selected_item()
	if item == null:
		return

	var choices := PackedStringArray()
	for i in _catalogue.size():
		choices.append("%d %s" % [i + 1, _catalogue[i].display_name])

	ui.call("set_structure", item.display_name, _inventory.count(item.id), choices, _index)


func _push_status() -> void:
	var ui := _get_ui()
	if ui and ui.has_method("set_status"):
		ui.call("set_status", _valid, _reason)
