extends Node

func _ready() -> void:
	assert(PlanetTemplates.ORDER.size() >= 10)
	var earth: Dictionary = PlanetTemplates.values("Earth-like")
	assert(int(earth["planet_type"]) == 0)
	assert(float(earth["ocean_ratio"]) > 50.0)
	var mars: Dictionary = PlanetTemplates.values("Mars-like")
	assert(float(mars["ocean_ratio"]) == 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var a: Dictionary = PlanetTemplates.smart_random(rng)
	rng.seed = 12345
	var b: Dictionary = PlanetTemplates.smart_random(rng)
	assert(a == b)
	assert(a.has("template_name"))
	print("Milestone 7.5 templates regression: PASS")
	get_tree().quit()
