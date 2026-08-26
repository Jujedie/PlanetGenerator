extends Node

func _ready() -> void:
	var runner := BatchGenerationRunner.new()
	add_child(runner)
	assert(not runner.running)
	assert(not runner.start({}, 0, 1000, "user://invalid_batch"))
	assert(runner.has_signal("batch_progress"))
	assert(runner.has_signal("batch_completed"))
	runner.shutdown()
	print("Milestone 7.6 batch harness regression: PASS")
	get_tree().quit()
