extends Node

func _ready() -> void:
	var options := ReleaseCandidateRunner.default_options()
	options["stability_runs"] = 50
	options["include_large_tiled_test"] = false
	var plan := ReleaseCandidateRunner.build_plan(options)
	var stability := 0
	var cancel := 0
	var recovery := 0
	for job in plan:
		match str(job.get("kind", "")):
			"stability": stability += 1
			"cancel": cancel += 1
			"cancel_recovery": recovery += 1
	assert(stability == 50)
	assert(cancel == ReleaseStabilityValidator.CANCELLATION_PHASES.size())
	assert(recovery == cancel)

	var hashes_a := {"height": "a", "water": "b"}
	var hashes_b := {"height": "a", "water": "b"}
	assert(ReleaseStabilityValidator.compare_hash_sets(hashes_a, hashes_b)["ok"])
	hashes_b["water"] = "c"
	assert(not ReleaseStabilityValidator.compare_hash_sets(hashes_a, hashes_b)["ok"])

	var memory_samples: Array = []
	for index in range(50):
		memory_samples.append(1024 * 1024 * 1024 + index * 256 * 1024)
	assert(ReleaseStabilityValidator.evaluate_memory_series(memory_samples)["ok"])

	var regression_assets := ReleaseStabilityValidator.required_regression_scenes_present()
	assert(regression_assets["ok"])
	print("Milestone 8 release stabilization contract: PASS")
	get_tree().quit()
