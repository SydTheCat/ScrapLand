extends AudioStreamPlayer3D
## SCRAPLAND -- Procedural hinge sounds for a storage crate.
##
## Same reason as tone_player.gd: the project ships with no audio files, so this
## synthesises a rusty creak and a lid thud at runtime. Callers only use
## play_creak() and play_thud(); swap this script for a real stream later.

enum Kind { SILENCE, CREAK, THUD }

@export var mix_rate: float = 22050.0

@export_group("Creak")
@export var creak_seconds: float = 0.4
@export var creak_start_hz: float = 240.0
@export var creak_end_hz: float = 105.0
@export_range(0.0, 1.0) var creak_volume: float = 0.42

@export_group("Thud")
@export var thud_seconds: float = 0.16
@export var thud_body_hz: float = 68.0
@export var thud_knock_hz: float = 170.0
@export_range(0.0, 1.0) var thud_volume: float = 0.7

var _playback: AudioStreamGeneratorPlayback
var _rng := RandomNumberGenerator.new()
var _kind: Kind = Kind.SILENCE
var _elapsed: float = 0.0
var _duration: float = 0.0
var _phase: float = 0.0


func _ready() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = mix_rate
	generator.buffer_length = 0.15
	stream = generator
	# Stay open and push silence while idle, same as the robot beeper -- starting
	# the stream per sound would clip the attack of the thud.
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback
	_rng.randomize()


func play_creak() -> void:
	_kind = Kind.CREAK
	_elapsed = 0.0
	_duration = maxf(creak_seconds, 0.05)
	_phase = 0.0


func play_thud() -> void:
	_kind = Kind.THUD
	_elapsed = 0.0
	_duration = maxf(thud_seconds, 0.05)
	_phase = 0.0


func _process(_delta: float) -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return

	var seconds_per_frame := 1.0 / mix_rate
	for _i in frames:
		var sample := 0.0
		if _kind != Kind.SILENCE and _elapsed < _duration:
			var t := _elapsed / _duration
			sample = _sample_creak(t) if _kind == Kind.CREAK else _sample_thud(t)
			_elapsed += seconds_per_frame
		else:
			_kind = Kind.SILENCE
		_playback.push_frame(Vector2(sample, sample))


## A rusty hinge: a falling groan mixed with scratchy noise and a few catches.
func _sample_creak(t: float) -> float:
	var freq := lerpf(creak_start_hz, creak_end_hz, t * t)
	freq += sin(t * 17.0 * TAU) * 9.0
	_phase += freq / mix_rate
	var groan := sin(_phase * TAU)
	var harmonic := sin(_phase * TAU * 1.97) * 0.22
	var noise := _rng.randf_range(-1.0, 1.0)
	var scrape := 0.5 + 0.5 * sin(t * 21.0 * TAU + 0.6)
	var grain := noise * 0.3 * clampf(scrape, 0.18, 1.0)
	var hitch := 0.0
	var hitch_phase := fmod(t * 8.5, 1.0)
	if hitch_phase < 0.035:
		hitch = noise * 0.38 * (1.0 - hitch_phase / 0.035)
	var raw := groan * 0.48 + harmonic + grain + hitch
	return raw * creak_volume * _fade(t, 0.06, 0.14)


## A lid dropping shut: low body, a mid knock, and a brief slap of noise.
func _sample_thud(t: float) -> float:
	var seconds := t * _duration
	var body := sin(seconds * thud_body_hz * TAU) * exp(-seconds * 26.0)
	var knock := sin(seconds * thud_knock_hz * TAU) * exp(-seconds * 40.0) * 0.4
	var slap := _rng.randf_range(-1.0, 1.0) * exp(-seconds * 72.0) * 0.55
	return (body + knock + slap) * thud_volume


func _fade(t: float, attack: float, release: float) -> float:
	var fade_in := clampf(t / maxf(attack, 0.001), 0.0, 1.0)
	var fade_out := clampf((1.0 - t) / maxf(release, 0.001), 0.0, 1.0)
	return minf(fade_in, fade_out)
