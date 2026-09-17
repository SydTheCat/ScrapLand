extends Node
## SCRAPLAND -- Save and load. Autoloaded as `SaveManager`.
##
## F5 saves, F9 loads. The station also autosaves when you repair it.
##
## HOW IT WORKS
## Nothing here knows what a battery or a scrap pile is. Any node that wants to
## be saved does two things:
##
##   1. joins the "persist" group in its _ready()
##   2. implements save_data() -> Dictionary and load_data(data: Dictionary)
##
## This manager walks the group, keys each node's data by its node path, and
## writes the lot to one file. Adding a machine or a building later means adding
## those two methods to it -- this file never changes.
##
## OBJECTS THAT COME AND GO
## Pickups get collected and machines get dismantled, so the world at load time
## rarely matches the world at save time. Two rules cover it:
##
##   * a persistent node in the world that is NOT in the save file was consumed
##     after the save, so it is retired
##   * an entry in the save file with no matching node was created at runtime
##     (a dropped pickup) or has been consumed, so it is rebuilt from the scene
##     file it came from
##
## Those two happen a frame apart. A retired node lives until the end of the
## frame it was freed in, so rebuilding immediately would mean two nodes wanting
## the same name and the engine juggling collision shapes for one of them while
## it is being deleted.
##
## FORMAT
## The file is Godot's own var_to_str text, not JSON, because it round-trips
## Vector3 and nested dictionaries without any conversion code. It is plain text
## and can be opened in any editor while debugging.

## Fired after a successful save or load, in case anything wants to react.
signal saved
signal loaded
signal load_failed(reason: String)

const SAVE_PATH: String = "user://scrapland_save.txt"
## Bumped if the save layout ever changes in a way old files cannot survive.
const SAVE_VERSION: int = 1
## Nodes join this group to be included. See the header.
const PERSIST_GROUP: StringName = &"persist"

@export var notify_on_save: bool = true

## Set to true to print every node as it is retired, restored and rebuilt. Worth
## knowing about: if a load ever misbehaves again, the last line printed names the
## node responsible. Godot also keeps every run's output in
## user://logs/, which is where these traces end up.
var verbose: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"quick_save"):
		save_game()
	elif event.is_action_pressed(&"quick_load"):
		# Deferred on purpose. Loading rips nodes out of the tree and puts new
		# ones in, and doing that from inside input handling means editing the
		# scene while the engine is midway through walking it.
		load_game.call_deferred()


# --- Saving -----------------------------------------------------------------

## Writes every persistent node to disk. `quiet` skips the on-screen message,
## which is what autosaves use.
func save_game(quiet: bool = false) -> bool:
	var nodes := {}

	for node in get_tree().get_nodes_in_group(PERSIST_GROUP):
		# A pile collected this very frame is still in the tree waiting to be
		# freed. Saving it would resurrect an empty pile on load.
		if node.is_queued_for_deletion():
			continue
		if not node.has_method("save_data"):
			push_warning("save_manager: %s is in the persist group but has no save_data()." % node.name)
			continue

		var entry := {"data": node.call("save_data")}

		# scene_file_path is only set on the root of an instanced scene, which is
		# exactly the nodes we might have to rebuild from scratch. Logic nodes
		# living inside another scene (Battery, Inventory) have none, and they
		# never need respawning because their parent scene brings them back.
		if not node.scene_file_path.is_empty() and node.get_parent() != null:
			entry["scene"] = node.scene_file_path
			entry["parent"] = String(node.get_parent().get_path())

		nodes[String(node.get_path())] = entry

	var payload := {
		"version": SAVE_VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"nodes": nodes,
	}

	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var reason := "Could not write %s (error %d)" % [SAVE_PATH, FileAccess.get_open_error()]
		push_error("save_manager: " + reason)
		GameEvents.notify("SAVE FAILED", Color(1, 0.4, 0.35))
		return false

	file.store_string(var_to_str(payload))
	file.close()

	if notify_on_save and not quiet:
		GameEvents.notify("PROGRESS SAVED", Color(0.6, 0.95, 1.0))
	saved.emit()
	return true


# --- Loading ----------------------------------------------------------------

func load_game() -> bool:
	var payload := _read_save_file()
	if payload.is_empty():
		return false

	var saved_nodes: Dictionary = payload.get("nodes", {})

	# 1. Index the world as it stands. Nodes already on their way out count as
	#    gone, so they fall through to the rebuild pass below.
	var present := {}
	for node in get_tree().get_nodes_in_group(PERSIST_GROUP):
		if node.is_queued_for_deletion():
			continue
		present[String(node.get_path())] = node

	# 2. Retire anything the save does not know about.
	for path in present:
		if saved_nodes.has(path):
			continue
		var stale: Node = present[path]
		if not _is_removable(stale):
			continue
		if verbose:
			print("save_manager: retiring ", path)
		_retire(stale)

	# 3. Restore everything that still exists, collecting what needs rebuilding.
	var missing := {}
	for path in saved_nodes:
		var entry: Dictionary = saved_nodes[path]
		var node: Node = present.get(path, null)
		if node == null or node.is_queued_for_deletion():
			missing[path] = entry
			continue
		if verbose:
			print("save_manager: restoring ", path)
		if node.has_method("load_data"):
			node.call("load_data", entry.get("data", {}))

	# 4. Rebuild the rest on a later frame. The nodes retired in step 2 are not
	#    actually gone until the end of this one, and a replacement created now
	#    would be fighting a dying node for its name.
	if not missing.is_empty():
		_rebuild_missing.call_deferred(missing)

	# The salvage bar may have been tracking a machine that is now whole again.
	# The interact prompt is left alone on purpose: the Interactor recalculates
	# it every physics frame, and clearing it here would only desync its cache.
	GameEvents.clear_salvage_progress()

	if verbose:
		print("save_manager: load finished, %d entries applied" % saved_nodes.size())

	GameEvents.notify("PROGRESS RESTORED", Color(0.6, 0.95, 1.0))
	loaded.emit()
	return true


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


## Wipes the save. Useful while testing.
func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


# --- Internals --------------------------------------------------------------

## Returns an empty dictionary and reports the reason if anything is wrong.
func _read_save_file() -> Dictionary:
	if not has_save():
		GameEvents.notify("NO SAVE FOUND", Color(1, 0.7, 0.35))
		load_failed.emit("no save file")
		return {}

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		_fail("Could not read the save file.")
		return {}
	var text := file.get_as_text()
	file.close()

	if verbose:
		print("save_manager: read %d characters from %s" % [text.length(), SAVE_PATH])

	var parsed: Variant = str_to_var(text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("nodes"):
		_fail("Save file is unreadable.")
		return {}

	var payload := parsed as Dictionary
	if int(payload.get("version", 0)) != SAVE_VERSION:
		_fail("Save file is from an older version.")
		return {}
	return payload


func _fail(reason: String) -> void:
	push_error("save_manager: " + reason)
	GameEvents.notify(reason.to_upper(), Color(1, 0.4, 0.35))
	load_failed.emit(reason)


## Takes a node out of play. queue_free alone, deliberately: pulling a node out
## of the tree by hand and freeing it in the same breath leaves the engine
## holding collision shapes for something that is about to vanish. Instead the
## node stays parented and is made completely inert -- invisible, not
## processing, not collidable, no longer persistent -- and the engine collects it
## at the end of the frame on its own terms.
func _retire(node: Node) -> void:
	node.remove_from_group(PERSIST_GROUP)
	node.set_process(false)
	node.set_physics_process(false)
	if node is Node3D:
		(node as Node3D).visible = false
	_silence_collision(node)
	node.queue_free()


## Stops a doomed node reporting overlaps for the rest of the frame, so the
## player's Interactor cannot latch onto something that is already dead.
func _silence_collision(node: Node) -> void:
	var body := node as CollisionObject3D
	if body:
		body.collision_layer = 0
		body.collision_mask = 0
		var area := body as Area3D
		if area:
			area.monitorable = false
			area.monitoring = false
	for child in node.get_children():
		_silence_collision(child)


## Rebuilds the nodes a save expects but the world no longer has. Runs a frame
## after the main restore, once the retired nodes have actually been collected.
##
## Two passes, because a structure can carry persistent nodes inside its own
## scene: a storage box's Inventory has no scene file of its own and only exists
## once the box has been rebuilt. The persist group gives no guarantee that the
## box was saved before its inventory, so everything is created first and only
## then handed its data.
func _rebuild_missing(missing: Dictionary) -> void:
	for path in missing:
		var entry: Dictionary = missing[path]
		if entry.has("scene") and get_node_or_null(String(path)) == null:
			_respawn(String(path), entry)

	for path in missing:
		var node := get_node_or_null(String(path))
		if node == null:
			push_warning("save_manager: %s is in the save but could not be rebuilt." % path)
			continue
		if verbose:
			print("save_manager: rebuilt ", path)
		if node.has_method("load_data"):
			node.call("load_data", (missing[path] as Dictionary).get("data", {}))


## Guards the two cases where deleting a node absent from the save would do far
## more harm than leaving it alone.
func _is_removable(node: Node) -> bool:
	# The robot is not scenery. Removing it takes the camera and the HUD's
	# battery reference with it, which looks exactly like the game locking up.
	if node.is_in_group(&"player") or node.get_parent().is_in_group(&"player"):
		return false
	# No scene file means nothing could ever put it back.
	if node.scene_file_path.is_empty():
		return false
	return true


## Rebuilds a node that existed when the game was saved but does not now.
func _respawn(path: String, entry: Dictionary) -> Node:
	var scene_path := String(entry.get("scene", ""))
	var parent_path := String(entry.get("parent", ""))
	if scene_path.is_empty() or parent_path.is_empty():
		# Callers check for a recorded scene first, so reaching here means the save
		# file itself is inconsistent.
		push_warning("save_manager: cannot respawn %s -- no scene recorded." % path)
		return null

	var parent := get_node_or_null(parent_path)
	if parent == null:
		push_warning("save_manager: cannot respawn %s -- parent %s is gone." % [path, parent_path])
		return null

	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_warning("save_manager: cannot respawn %s -- %s failed to load." % [path, scene_path])
		return null

	var node := scene.instantiate()
	# Reuse the saved name so this node keeps the same path in the next save.
	node.name = path.get_file()
	parent.add_child(node)
	return node
