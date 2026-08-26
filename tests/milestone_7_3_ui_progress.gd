extends Node

func _ready() -> void:
	# Static contract test: M7.3 must keep the scene/main thread free while both
	# monolithic GPU simulation and tiled generation run on the dedicated worker.
	var generator_script := FileAccess.get_file_as_string("res://src/classes/classes_io/planetGenerator.gd")
	assert(generator_script.contains("signal generation_progress"))
	assert(generator_script.contains("signal generation_cancelled"))
	assert(generator_script.contains("GPUGenerationWorker.submit"))
	assert(generator_script.contains("func _run_monolithic_generation_worker"))
	assert(generator_script.contains("orchestrator.export_all_maps"))
	# getMaps must only consume already-exported files; exporting here would
	# reintroduce a multi-second UI stall after the GPU simulation.
	var get_maps_start := generator_script.find("func getMaps()")
	var get_maps_end := generator_script.find("static func save_image_temp", get_maps_start)
	assert(get_maps_start >= 0 and get_maps_end > get_maps_start)
	var get_maps_body := generator_script.substr(get_maps_start, get_maps_end - get_maps_start)
	assert(not get_maps_body.contains("export_all_maps"))

	var worker_script := FileAccess.get_file_as_string("res://src/classes/classes_gpu/gpu_generation_worker.gd")
	assert(worker_script.contains("class_name GPUGenerationWorker"))
	assert(worker_script.contains("Thread.new()"))
	assert(worker_script.contains("Semaphore.new()"))
	assert(worker_script.contains("GPUContext.shutdown_shared_device()"))

	var orchestrator_script := FileAccess.get_file_as_string("res://src/classes/classes_gpu/orchestrator.gd")
	assert(orchestrator_script.contains("func request_cancel"))
	assert(orchestrator_script.contains("cancellation_probe"))
	assert(orchestrator_script.contains("signal phase_started"))
	print("Milestone 7.3 non-blocking UI/progress regression: PASS")
	get_tree().quit()
