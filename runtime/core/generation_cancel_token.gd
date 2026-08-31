class_name PGGenerationCancelToken
extends RefCounted

# Cancellation requests may be written by the UI/main thread while a tiled
# generation worker reads them. Keep both the flag and reason synchronized.
var _mutex: Mutex = Mutex.new()
var _cancelled := false
var _reason := ""

var reason: String:
	get:
		_mutex.lock()
		var value := _reason
		_mutex.unlock()
		return value

func cancel(cancel_reason: String = "user") -> void:
	_mutex.lock()
	_cancelled = true
	_reason = cancel_reason
	_mutex.unlock()

func is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value
