extends Node

func _ready() -> void:
	# Static contract test: cancellation exists for both generation paths and
	# phase progress is now part of PlanetGenerator's public signal API.
	var generator_script := FileAccess.get_file_as_string("res://src/classes/classes_io/planetGenerator.gd")
	assert(generator_script.contains("signal generation_progress"))
	assert(generator_script.contains("signal generation_cancelled"))
	var orchestrator_script := FileAccess.get_file_as_string("res://src/classes/classes_gpu/orchestrator.gd")
	assert(orchestrator_script.contains("func request_cancel"))
	assert(orchestrator_script.contains("signal phase_started"))
	print("Milestone 7.3 UI/progress regression: PASS")
	get_tree().quit()
