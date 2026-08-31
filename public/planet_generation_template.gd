class_name PlanetGenerationTemplate
extends Resource

## Serializable, frontend-independent parameter template.
## Keys intentionally match PGParameterSchema and the standalone parameter model.

@export var template_version: int = PGAddonInfo.TEMPLATE_VERSION
@export var display_name: String = "Custom Planet"

@export_category("General")
@export var seed: int = 0
@export var planet_name: String = "Generated Planet"
@export var planet_radius: float = 150.0
@export var planet_density: float = 5.51
@export_enum("Terran:0", "Toxic:1", "Volcanic:2", "No Atmosphere:3", "Dead:4", "Sterile:5", "Gas Giant:6") var planet_type: int = 0
@export var avg_temperature: float = 21.0
@export var export_worker_count: int = 0

@export_category("Erosion & Tectonics")
@export var terrain_scale: float = 150.0
@export var erosion_iterations: int = 100
@export var erosion_rate: float = 0.05
@export var rain_rate: float = 0.005
@export var evap_rate: float = 0.02
@export var flow_rate: float = 0.25
@export var deposition_rate: float = 0.05
@export var capacity_multiplier: float = 1.0
@export var flux_iterations: int = 10
@export var base_flux: float = 100.0
@export var propagation_rate: float = 0.8
@export var spreading_rate: float = 50.0
@export var max_crust_age: float = 200.0
@export var subsidence_coeff: float = 2800.0

@export_category("Craters")
@export var crater_density: float = 0.5
@export var crater_min_radius: float = 3.0
@export var crater_max_radius: float = 24.0
@export var crater_depth_ratio: float = 0.25
@export var crater_ejecta_extent: float = 2.5
@export var crater_ejecta_decay: float = 3.0
@export var crater_azimuth_var: float = 0.3

@export_category("Water & Climate")
@export var ocean_ratio: float = 55.0
@export var ice_probability: float = 0.9
@export var global_humidity: float = 0.5
@export var sea_level: float = 0.0
@export var freshwater_max_size: float = 1000.0
@export var lake_threshold: float = 20.0
@export var cloud_coverage: float = 0.5
@export var cloud_density: float = 0.8

@export_category("Administrative Regions")
@export var nb_cases_regions: int = 50
@export var region_cost_flat: float = 1.0
@export var region_cost_hill: float = 2.0
@export var region_cost_river: float = 3.0
@export var region_river_threshold: float = 1.0
@export var region_budget_variation: float = 0.5
@export var region_noise_strength: float = 0.5

@export_category("Ocean Regions")
@export var nb_cases_ocean_regions: int = 100
@export var ocean_cost_flat: float = 1.0
@export var ocean_cost_deeper: float = 2.0
@export var ocean_noise_strength: float = 0.5

@export_category("Gas Giant")
@export var gas_giant_num_bands: int = 12
@export var gas_giant_jet_strength: float = 4.0
@export var gas_giant_eddy_strength: float = 2.5
@export var gas_giant_advection_dt: float = 1.4
@export var gas_giant_advection_iterations: int = 40
@export var gas_giant_target_sharpen: float = 1.18

@export_category("Resources")
@export var petrole_probability: float = 0.025
@export var petrole_deposit_size: float = 200.0
@export var global_richness: float = 1.0

const _INT_KEYS: Dictionary = {
	"seed": true,
	"planet_type": true,
	"export_worker_count": true,
	"erosion_iterations": true,
	"flux_iterations": true,
	"nb_cases_regions": true,
	"nb_cases_ocean_regions": true,
	"gas_giant_num_bands": true,
	"gas_giant_advection_iterations": true,
}


static func defaults() -> PlanetGenerationTemplate:
	var result := PlanetGenerationTemplate.new()
	result.apply_dictionary(PGParameterSchema.defaults())
	return result


static func from_preset(preset_name: String) -> PlanetGenerationTemplate:
	var result := defaults()
	result.display_name = preset_name
	result.apply_dictionary(PGPlanetTemplates.values(preset_name))
	return result


static func smart_random(rng: RandomNumberGenerator = null) -> PlanetGenerationTemplate:
	var generator := rng
	if generator == null:
		generator = RandomNumberGenerator.new()
		generator.randomize()
	var values := PGPlanetTemplates.smart_random(generator)
	var result := defaults()
	result.display_name = str(values.get("template_name", "Smart Random"))
	values.erase("template_name")
	result.apply_dictionary(values)
	return result


func to_dictionary() -> Dictionary:
	var result: Dictionary = {}
	for key in PGParameterSchema.keys():
		result[key] = get(key)
	return result


func apply_dictionary(values: Dictionary, clamp_to_schema: bool = true) -> void:
	for key_value in PGParameterSchema.keys():
		var key := str(key_value)
		if not values.has(key):
			continue
		var definition := PGParameterSchema.definition(key)
		var value: Variant = values[key]
		if key == "planet_name":
			set(key, str(value))
			continue
		if key in _INT_KEYS:
			var integer_value := int(value)
			if clamp_to_schema:
				integer_value = _clamp_integer(integer_value, definition)
			set(key, integer_value)
			continue
		if value is int or value is float:
			var numeric_value := float(value)
			if clamp_to_schema:
				numeric_value = _clamp_float(numeric_value, definition)
			set(key, numeric_value)


func validated_values() -> Dictionary:
	var result := to_dictionary()
	for key_value in PGParameterSchema.keys():
		var key := str(key_value)
		var definition := PGParameterSchema.definition(key)
		if not result.has(key) or key == "planet_name":
			continue
		if key in _INT_KEYS:
			result[key] = _clamp_integer(int(result[key]), definition)
		elif result[key] is int or result[key] is float:
			result[key] = _clamp_float(float(result[key]), definition)
	return result


func validation_report() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if template_version > PGAddonInfo.TEMPLATE_VERSION:
		errors.append("Template version %d is newer than supported version %d." % [
			template_version, PGAddonInfo.TEMPLATE_VERSION
		])
	if planet_name.strip_edges().is_empty():
		warnings.append("planet_name is empty; 'Generated Planet' will be used.")
	if crater_min_radius > crater_max_radius:
		errors.append("crater_min_radius cannot be greater than crater_max_radius.")
	for key_value in PGParameterSchema.keys():
		var key := str(key_value)
		if key == "planet_name":
			continue
		var definition := PGParameterSchema.definition(key)
		var value: Variant = get(key)
		if definition.has("min") and float(value) < float(definition["min"]):
			errors.append("%s is below its minimum (%s)." % [key, definition["min"]])
		if definition.has("max") and float(value) > float(definition["max"]):
			errors.append("%s is above its maximum (%s)." % [key, definition["max"]])
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings}


func duplicate_template() -> PlanetGenerationTemplate:
	var result := PlanetGenerationTemplate.new()
	result.template_version = template_version
	result.display_name = display_name
	result.apply_dictionary(to_dictionary(), false)
	return result


func save_json(path: String) -> Error:
	var parent := path.get_base_dir()
	if not parent.is_empty():
		DirAccess.make_dir_recursive_absolute(parent)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"format": "planet_generation_template",
		"template_version": template_version,
		"display_name": display_name,
		"values": to_dictionary(),
	}, "  ", true))
	file.close()
	return OK


static func load_json(path: String) -> PlanetGenerationTemplate:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return null
	var payload := parsed as Dictionary

	# Native addon template format.
	if str(payload.get("format", "")) == "planet_generation_template":
		var result := PlanetGenerationTemplate.new()
		result.template_version = int(payload.get("template_version", 1))
		result.display_name = str(payload.get("display_name", "Imported Planet"))
		var values: Variant = payload.get("values", {})
		if values is Dictionary:
			result.apply_dictionary(values as Dictionary, false)
		return result

	# Standalone 3.x .planetGeneratorParam format: canonical parameter keys
	# are stored directly at the root with optional _meta/_ui dictionaries.
	if _looks_like_standalone_preset(payload):
		var result := PlanetGenerationTemplate.new()
		result.template_version = PGAddonInfo.TEMPLATE_VERSION
		var raw_meta: Variant = payload.get("_meta", {})
		if raw_meta is Dictionary:
			result.display_name = str((raw_meta as Dictionary).get("name", path.get_file().get_basename()))
		else:
			result.display_name = path.get_file().get_basename()
		result.apply_dictionary(payload, false)
		return result

	return null


func save_resource(path: String) -> Error:
	var parent := path.get_base_dir()
	if not parent.is_empty():
		DirAccess.make_dir_recursive_absolute(parent)
	return ResourceSaver.save(self, path)


static func load_resource(path: String) -> PlanetGenerationTemplate:
	var loaded := ResourceLoader.load(path)
	return loaded as PlanetGenerationTemplate


static func _clamp_integer(value: int, definition: Dictionary) -> int:
	if definition.has("min"):
		value = maxi(value, int(definition["min"]))
	if definition.has("max"):
		value = mini(value, int(definition["max"]))
	return value


static func _clamp_float(value: float, definition: Dictionary) -> float:
	if definition.has("min"):
		value = maxf(value, float(definition["min"]))
	if definition.has("max"):
		value = minf(value, float(definition["max"]))
	return value


static func _looks_like_standalone_preset(payload: Dictionary) -> bool:
	var matches := 0
	for key in ["planet_radius", "planet_type", "terrain_scale", "ocean_ratio", "nb_cases_regions"]:
		if payload.has(key):
			matches += 1
	return matches >= 3
