class_name PlanetGenerationJob
extends RefCounted

signal progress(phase: String, completed: int, total: int, ratio: float)
signal state_changed(state: int)
signal completed(result: PlanetGenerationResult)
signal failed(error: Dictionary)
signal cancelled(reason: String)
signal finished(job: PlanetGenerationJob)

enum State {
	QUEUED,
	RUNNING,
	CANCELLING,
	COMPLETED,
	FAILED,
	CANCELLED,
}

var id: String = ""
var state: int = State.QUEUED
var current_phase: String = "queued"
var progress_completed: int = 0
var progress_total: int = 1
var result: PlanetGenerationResult = null
var error: Dictionary = {}
var cancel_reason: String = ""
var warnings: Array[String] = []

var _backend: PGPlanetGeneratorBackend = null


func cancel(reason: String = "user") -> void:
	if is_done():
		return
	cancel_reason = reason
	_set_state(State.CANCELLING)
	if _backend != null:
		_backend.cancel_generation(reason)


func is_done() -> bool:
	return state in [State.COMPLETED, State.FAILED, State.CANCELLED]


func succeeded() -> bool:
	return state == State.COMPLETED


func get_progress_ratio() -> float:
	return clampf(float(progress_completed) / float(maxi(progress_total, 1)), 0.0, 1.0)


func wait_for_result() -> PlanetGenerationResult:
	if not is_done():
		await finished
	return result


func _attach_backend(value: PGPlanetGeneratorBackend) -> void:
	_backend = value


func _mark_running() -> void:
	if state == State.QUEUED:
		_set_state(State.RUNNING)


func _update_progress(phase: String, completed_count: int, total_count: int) -> void:
	if is_done():
		return
	if state == State.QUEUED:
		_set_state(State.RUNNING)
	current_phase = phase
	progress_completed = maxi(completed_count, 0)
	progress_total = maxi(total_count, 1)
	emit_signal("progress", current_phase, progress_completed, progress_total, get_progress_ratio())


func _complete(value: PlanetGenerationResult) -> void:
	if is_done():
		return
	result = value
	current_phase = "complete"
	progress_completed = 1
	progress_total = 1
	_backend = null
	_set_state(State.COMPLETED)
	emit_signal("progress", current_phase, 1, 1, 1.0)
	emit_signal("completed", result)
	emit_signal("finished", self)


func _fail(value: Dictionary) -> void:
	if is_done():
		return
	error = value.duplicate(true)
	_backend = null
	_set_state(State.FAILED)
	emit_signal("failed", error)
	emit_signal("finished", self)


func _cancelled(reason: String) -> void:
	if is_done():
		return
	cancel_reason = reason
	_backend = null
	_set_state(State.CANCELLED)
	emit_signal("cancelled", reason)
	emit_signal("finished", self)


func _set_state(value: int) -> void:
	if state == value:
		return
	state = value
	emit_signal("state_changed", state)
