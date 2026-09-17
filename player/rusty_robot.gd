extends Node3D
## SCRAPLAND -- Drives the imported rusty robot mesh.
##
## The walking GLB is the visible body. The other GLBs only donate animations,
## renamed to the names player.gd already plays: idle, walk, run, air.
##
## Head, the right arm (tools) and the chest gizmos stay as children of this
## node so existing paths keep working. Each frame they snap to Mixamo bones.

@export var visual_path: NodePath = ^"Visual"
@export var model_scale: float = 0.52
## Mixamo characters often face +Z. Godot's robot faces -Z.
@export var yaw_offset_degrees: float = 180.0

@export_group("Animation sources")
@export var idle_scene: PackedScene
@export var run_scene: PackedScene
@export var air_scene: PackedScene
## Extra unnamed Meshy clip, kept as idle_alt if you want to swap later.
@export var idle_alt_scene: PackedScene

@export_group("Bone follow")
@export var head_path: NodePath = ^"Head"
@export var arm_path: NodePath = ^"ArmRight"
@export var chest_path: NodePath = ^"BatteryIndicator"
@export var sparks_path: NodePath = ^"Sparks"

var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _head_bone: int = -1
var _hand_bone: int = -1
var _chest_bone: int = -1


func _ready() -> void:
	var visual := get_node_or_null(visual_path) as Node3D
	if visual:
		visual.scale = Vector3.ONE * model_scale
		visual.rotation_degrees.y = yaw_offset_degrees

	_skeleton = _find_skeleton(self)
	_anim = _find_anim(self)
	if _skeleton:
		_head_bone = _find_bone(["Head"], ["Top", "End"])
		_hand_bone = _find_bone(["RightHand"], ["Middle", "Thumb", "Index", "Pinky", "Ring"])
		if _hand_bone < 0:
			_hand_bone = _find_bone(["Right_Hand"], ["Middle"])
		_chest_bone = _find_bone(["Spine2"], [])
		if _chest_bone < 0:
			_chest_bone = _find_bone(["Spine1"], [])
		if _chest_bone < 0:
			_chest_bone = _find_bone(["Spine"], ["1", "2"])

	if _anim:
		_install_animations()
		if _anim.has_animation(&"idle"):
			_anim.play(&"idle")


func _process(_delta: float) -> void:
	if _skeleton == null:
		return
	_follow(head_path, _head_bone, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.06, 0.08)))
	_follow(arm_path, _hand_bone, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.04)))
	_follow(chest_path, _chest_bone, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.04, -0.12)))
	_follow(sparks_path, _chest_bone, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.02, 0.1)))


func get_animation_player() -> AnimationPlayer:
	return _anim


# --- Animations -------------------------------------------------------------

func _install_animations() -> void:
	var lib := _writable_library(_anim)
	_rename_first(lib, ["Walking", "walking"], "walk")
	_import_named(lib, idle_scene, "idle")
	_import_named(lib, run_scene, "run")
	_import_named(lib, air_scene, "air")
	_import_named(lib, idle_alt_scene, "idle_alt")
	_set_loop(lib, "idle", true)
	_set_loop(lib, "walk", true)
	_set_loop(lib, "run", true)
	_set_loop(lib, "air", false)


func _writable_library(ap: AnimationPlayer) -> AnimationLibrary:
	# Mixamo GLBs often store clips in a named library, not the default "".
	# Copy into "" so player.gd can play("idle") without a library prefix.
	var lib_name := &""
	var names := ap.get_animation_library_list()
	if not names.is_empty():
		lib_name = names[0]
	var existing: AnimationLibrary = null
	if ap.has_animation_library(lib_name):
		existing = ap.get_animation_library(lib_name)
	var copy := AnimationLibrary.new()
	if existing:
		for n in existing.get_animation_list():
			var src := existing.get_animation(n)
			if src:
				copy.add_animation(n, src.duplicate(true))
		ap.remove_animation_library(lib_name)
	ap.add_animation_library(&"", copy)
	return copy


func _rename_first(lib: AnimationLibrary, candidates: PackedStringArray, dest: String) -> void:
	if lib.has_animation(dest):
		return
	for n in lib.get_animation_list():
		if n.ends_with(".001"):
			continue
		for c in candidates:
			if n == c or n.begins_with(c):
				lib.add_animation(dest, lib.get_animation(n).duplicate(true))
				return
	# Fall back to the first real clip so walk still plays something.
	for n in lib.get_animation_list():
		if not n.ends_with(".001"):
			lib.add_animation(dest, lib.get_animation(n).duplicate(true))
			return


func _import_named(lib: AnimationLibrary, scene: PackedScene, dest: String) -> void:
	if scene == null or lib.has_animation(dest):
		return
	var inst := scene.instantiate()
	var ap := _find_anim(inst)
	if ap == null:
		inst.free()
		return
	var picked: Animation = null
	for n in ap.get_animation_list():
		if n.ends_with(".001"):
			continue
		picked = ap.get_animation(n)
		if picked:
			break
	if picked:
		lib.add_animation(dest, picked.duplicate(true))
	inst.free()


func _set_loop(lib: AnimationLibrary, name: String, loop: bool) -> void:
	if not lib.has_animation(name):
		return
	var anim := lib.get_animation(name)
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE


# --- Bones ------------------------------------------------------------------

func _follow(path: NodePath, bone: int, extra: Transform3D) -> void:
	if bone < 0:
		return
	var node := get_node_or_null(path) as Node3D
	if node == null:
		return
	node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone) * extra


func _find_bone(must_have: PackedStringArray, must_not: PackedStringArray) -> int:
	if _skeleton == null:
		return -1
	for i in _skeleton.get_bone_count():
		var n := _skeleton.get_bone_name(i)
		var ok := true
		for p in must_have:
			if n.findn(p) < 0:
				ok = false
				break
		if not ok:
			continue
		for p in must_not:
			if n.findn(p) >= 0:
				ok = false
				break
		if ok:
			return i
	return -1


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var found := _find_skeleton(c)
		if found:
			return found
	return null


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var found := _find_anim(c)
		if found:
			return found
	return null
