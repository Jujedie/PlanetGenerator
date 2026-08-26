class_name PlanetTemplates
extends RefCounted

## Milestone 7.5 — coherent parameter templates shared by the standalone UI
## and future API consumers. Keys intentionally match PlanetParameterSchema and
## Master._compile_generation_params().

const ORDER: Array[String] = [
	"Earth-like",
	"Archipelago",
	"Supercontinent",
	"Ocean World",
	"Dry World",
	"Frozen World",
	"Mars-like",
	"Venus-like",
	"High Tectonics",
	"Low Relief",
	"Mountain World",
]

const DISPLAY_KEYS: Dictionary = {
	"Earth-like": "TEMPLATE_EARTH_LIKE",
	"Archipelago": "TEMPLATE_ARCHIPELAGO",
	"Supercontinent": "TEMPLATE_SUPERCONTINENT",
	"Ocean World": "TEMPLATE_OCEAN_WORLD",
	"Dry World": "TEMPLATE_DRY_WORLD",
	"Frozen World": "TEMPLATE_FROZEN_WORLD",
	"Mars-like": "TEMPLATE_MARS_LIKE",
	"Venus-like": "TEMPLATE_VENUS_LIKE",
	"High Tectonics": "TEMPLATE_HIGH_TECTONICS",
	"Low Relief": "TEMPLATE_LOW_RELIEF",
	"Mountain World": "TEMPLATE_MOUNTAIN_WORLD",
}

const TEMPLATES: Dictionary = {
	# terrain_scale is "additional elevation" in metres. Keep ordinary worlds
	# close to the UI default instead of using kilometre-scale positive uplift.
	"Earth-like": {"planet_type": 0, "avg_temperature": 15.0, "ocean_ratio": 70.0, "global_humidity": 0.55, "ice_probability": 0.80, "terrain_scale": 100.0},
	"Archipelago": {"planet_type": 0, "avg_temperature": 20.0, "ocean_ratio": 82.0, "global_humidity": 0.68, "ice_probability": 0.45, "terrain_scale": 50.0},
	"Supercontinent": {"planet_type": 0, "avg_temperature": 17.0, "ocean_ratio": 43.0, "global_humidity": 0.42, "ice_probability": 0.55, "terrain_scale": 150.0},
	"Ocean World": {"planet_type": 0, "avg_temperature": 18.0, "ocean_ratio": 90.0, "global_humidity": 0.85, "ice_probability": 0.35, "terrain_scale": 0.0},
	"Dry World": {"planet_type": 0, "avg_temperature": 31.0, "ocean_ratio": 24.0, "global_humidity": 0.16, "ice_probability": 0.10, "terrain_scale": 100.0},
	"Frozen World": {"planet_type": 0, "avg_temperature": -24.0, "ocean_ratio": 58.0, "global_humidity": 0.45, "ice_probability": 1.0, "terrain_scale": 50.0},
	"Mars-like": {"planet_type": 5, "avg_temperature": -58.0, "ocean_ratio": 0.0, "global_humidity": 0.02, "ice_probability": 0.10, "terrain_scale": 200.0, "crater_density": 0.65},
	"Venus-like": {"planet_type": 1, "avg_temperature": 460.0, "ocean_ratio": 5.0, "global_humidity": 0.12, "ice_probability": 0.0, "terrain_scale": 100.0},
	"High Tectonics": {"planet_type": 0, "avg_temperature": 15.0, "ocean_ratio": 62.0, "global_humidity": 0.50, "terrain_scale": 250.0, "spreading_rate": 120.0},
	"Low Relief": {"planet_type": 0, "avg_temperature": 16.0, "ocean_ratio": 68.0, "global_humidity": 0.55, "terrain_scale": 0.0, "erosion_rate": 0.08},
	"Mountain World": {"planet_type": 0, "avg_temperature": 8.0, "ocean_ratio": 48.0, "global_humidity": 0.50, "terrain_scale": 1200.0, "spreading_rate": 110.0, "erosion_rate": 0.035},
}


static func values(template_name: String) -> Dictionary:
	var fallback: Dictionary = TEMPLATES["Earth-like"]
	var source: Dictionary = TEMPLATES.get(template_name, fallback)
	return source.duplicate(true)


static func translation_key(template_name: String) -> String:
	return str(DISPLAY_KEYS.get(template_name, "TEMPLATE_EARTH_LIKE"))


static func smart_random(rng: RandomNumberGenerator) -> Dictionary:
	var template_name: String = ORDER[rng.randi_range(0, ORDER.size() - 1)]
	var result: Dictionary = values(template_name)
	for key in result.keys():
		if key == "planet_type":
			continue
		var raw_value: Variant = result[key]
		if raw_value is float or raw_value is int:
			var numeric_value := float(raw_value)
			var spread := maxf(absf(numeric_value) * 0.12, 0.05)
			result[key] = numeric_value + rng.randf_range(-spread, spread)
	result["template_name"] = template_name
	return result
