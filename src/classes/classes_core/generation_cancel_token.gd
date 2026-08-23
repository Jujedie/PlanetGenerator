class_name GenerationCancelToken
extends RefCounted

var _cancelled := false
var reason := ""

func cancel(cancel_reason: String = "user") -> void:
	_cancelled = true
	reason = cancel_reason

func is_cancelled() -> bool:
	return _cancelled
