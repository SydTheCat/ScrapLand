extends AudioStreamPlayer
## SCRAPLAND -- A tiny procedural beeper.
##
## The project ships with no audio files, so this synthesises retro electronic
## blips at runtime using an AudioStreamGenerator. That keeps the prototype
## audible with zero assets.
##
## When you have real sound effects, you can delete this script and swap in
## AudioStreamPlayer nodes with .wav / .ogg streams -- callers only use beep().

## Samples per second. 22050 is plenty for square-wave blips and cheap to fill.
@export var mix_rate: float = 22050.0
@export_range(0.0, 1.0) var default_volume: float = 0.3
## 0 = pure sine (soft), 1 = square (harsh and robotic).
@export_range(0.0, 1.0) var squareness: float = 0.7

var _playback: AudioStreamGeneratorPlayback
var _phase: float = 0.0
var _remaining: float = 0.0
var _elapsed: float = 0.0
var _frequency: float = 440.0
var _amplitude: float = 0.3

## Length of the fade in/out that stops each blip from clicking.
const _FADE: float = 0.012


func _ready() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = mix_rate
	generator.buffer_length = 0.12
	stream = generator
	# The stream stays open for the whole game and we push silence when idle.
	# Starting and stopping it per beep would clip the tail of each sound.
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


## Play a blip. Interrupts whatever is currently sounding.
func beep(frequency: float, duration: float, volume: float = -1.0) -> void:
	_frequency = maxf(frequency, 1.0)
	_remaining = maxf(duration, 0.0)
	_elapsed = 0.0
	_phase = 0.0
	_amplitude = default_volume if volume < 0.0 else volume


func _process(_delta: float) -> void:
	if _playback == null:
		return

	var frames := _playback.get_frames_available()
	if frames <= 0:
		return

	var seconds_per_frame := 1.0 / mix_rate
	var phase_increment := _frequency / mix_rate

	for _i in frames:
		if _remaining <= 0.0:
			_playback.push_frame(Vector2.ZERO)
			continue

		# Blend a sine and a square wave so the tone can be tuned from soft to
		# harsh with a single knob.
		var sine := sin(_phase * TAU)
		var square := 1.0 if fmod(_phase, 1.0) < 0.5 else -1.0
		var wave := lerpf(sine, square, squareness)

		var sample := wave * _amplitude * _envelope()
		_playback.push_frame(Vector2(sample, sample))

		_phase += phase_increment
		_elapsed += seconds_per_frame
		_remaining -= seconds_per_frame


## Ramps volume up at the start of the blip and down at the end.
func _envelope() -> float:
	var fade_in := clampf(_elapsed / _FADE, 0.0, 1.0)
	var fade_out := clampf(_remaining / _FADE, 0.0, 1.0)
	return minf(fade_in, fade_out)
