class_name PGParameterSchema
extends RefCounted

## Single source of truth for Planet Generator public parameters.
## Both frontends and code-facing templates use these definitions for defaults and validation.

const CATEGORY_ORDER := ["GENERAL", "EROSION", "CRATER", "EAU", "NUAGE", "REGION", "OCEAN", "GAS", "RESSOURCES"]

const CATEGORY_LABELS := {
	"GENERAL": "GENERAL_PROPRIETE_CATEGORIE",
	"EROSION": "EROSION_TECTONIQUE_CATEGORIE",
	"CRATER": "CRATER_CATEGORIE",
	"EAU": "EAU_CATEGORIE",
	"NUAGE": "NUAGE_CATEGORIE",
	"REGION": "REGION_CATEGORIE",
	"OCEAN": "REGION_OCEAN_CATEGORIE",
	"GAS": "GAS_GIANT_CATEGORIE",
	"RESSOURCES": "RESSOURCES_CATEGORIE",
}

const DEFINITIONS := [
	{"key":"seed", "category":"GENERAL", "kind":"spinbox", "label":"GENERATION_SEED", "default":0.0, "min":0.0, "max":1000000000000.0, "step":1.0, "randomize":false},
	{"key":"planet_name", "category":"GENERAL", "kind":"text", "label":"PLANET_NAME", "default":""},
	{"key":"planet_radius", "category":"GENERAL", "kind":"slider", "label":"PLANET_RADIUS", "unit":" km", "default":150.0, "min":150.0, "max":1500.0, "step":50.0},
	{"key":"planet_density", "category":"GENERAL", "kind":"slider", "label":"PLANET_DENSITY", "unit":" g/cm³", "default":5.51, "min":0.5, "max":10.0, "step":0.01},
	{"key":"planet_type", "category":"GENERAL", "kind":"option", "label":"PLANET_TYPE", "default":0, "options":[["TYPE_DEFAUT",0],["TYPE_TOXIQUE",1],["TYPE_VOLCAN",2],["TYPE_NO_ATMOSPHERE",3],["TYPE_MORTE",4],["TYPE_STERILE",5],["TYPE_GAZEUSE",6]]},
	{"key":"avg_temperature", "category":"GENERAL", "kind":"slider", "label":"PLANET_TEMPERATURE_AVG", "unit":" °C", "default":21.0, "min":-273.0, "max":500.0, "step":1.0},
	{"key":"export_worker_count", "category":"GENERAL", "kind":"slider", "label":"THREAD_NUMBER", "default":0.0, "min":0.0, "max":16.0, "step":1.0, "randomize":false},

	{"key":"terrain_scale", "category":"EROSION", "kind":"slider", "label":"TERRAIN_SCALE", "unit":" m", "default":150.0, "min":0.0, "max":10000.0, "step":50.0},
	{"key":"erosion_iterations", "category":"EROSION", "kind":"slider", "label":"EROSION_ITERATIONS", "default":100.0, "min":1.0, "max":5000.0, "step":1.0},
	{"key":"erosion_rate", "category":"EROSION", "kind":"slider", "label":"EROSION_RATE", "default":0.05, "min":0.01, "max":1.0, "step":0.01},
	{"key":"rain_rate", "category":"EROSION", "kind":"slider", "label":"RAIN_RATE", "default":0.005, "min":0.001, "max":1.0, "step":0.001},
	{"key":"evap_rate", "category":"EROSION", "kind":"slider", "label":"EVAP_RATE", "default":0.02, "min":0.01, "max":1.0, "step":0.01},
	{"key":"flow_rate", "category":"EROSION", "kind":"slider", "label":"FLOW_RATE", "default":0.25, "min":0.01, "max":1.0, "step":0.01},
	{"key":"deposition_rate", "category":"EROSION", "kind":"slider", "label":"DEPOSITION_RATE", "default":0.05, "min":0.01, "max":1.0, "step":0.01},
	{"key":"capacity_multiplier", "category":"EROSION", "kind":"slider", "label":"CAPACITY_MULTIPLIER", "default":1.0, "min":0.5, "max":10.0, "step":0.5},
	{"key":"flux_iterations", "category":"EROSION", "kind":"slider", "label":"FLUX_ITERATIONS", "default":10.0, "min":10.0, "max":100.0, "step":10.0},
	{"key":"base_flux", "category":"EROSION", "kind":"slider", "label":"BASE_FLUX", "default":100.0, "min":1.0, "max":1000.0, "step":1.0},
	{"key":"propagation_rate", "category":"EROSION", "kind":"slider", "label":"PROPAGATION_RATE", "default":0.8, "min":0.1, "max":1.0, "step":0.1},
	{"key":"spreading_rate", "category":"EROSION", "kind":"slider", "label":"SPREADING_RATE", "default":50.0, "min":1.0, "max":500.0, "step":1.0},
	{"key":"max_crust_age", "category":"EROSION", "kind":"slider", "label":"MAX_CRUST_AGE", "unit":" Myr", "default":200.0, "min":1.0, "max":5000.0, "step":1.0},
	{"key":"subsidence_coeff", "category":"EROSION", "kind":"slider", "label":"SUBSIDENCE_COEFFICIENT", "unit":" m/Myr", "default":2800.0, "min":20.0, "max":10000.0, "step":20.0},

	{"key":"crater_density", "category":"CRATER", "kind":"slider", "label":"CRATER_DENSITY", "default":0.5, "min":0.1, "max":1.0, "step":0.1},
	{"key":"crater_min_radius", "category":"CRATER", "kind":"slider", "label":"CRATER_MIN_RADIUS", "unit":" km", "default":3.0, "min":1.0, "max":100.0, "step":1.0},
	{"key":"crater_max_radius", "category":"CRATER", "kind":"slider", "label":"CRATER_MAX_RADIUS", "unit":" km", "default":24.0, "min":4.0, "max":250.0, "step":1.0},
	{"key":"crater_depth_ratio", "category":"CRATER", "kind":"slider", "label":"CRATER_DEPTH_RATIO", "default":0.25, "min":0.01, "max":1.0, "step":0.01},
	{"key":"crater_ejecta_extent", "category":"CRATER", "kind":"slider", "label":"CRATER_EJECTA_EXTENT", "default":2.5, "min":0.1, "max":2.5, "step":0.1},
	{"key":"crater_ejecta_decay", "category":"CRATER", "kind":"slider", "label":"CRATER_EJECTA_DECAY", "default":3.0, "min":0.5, "max":10.0, "step":0.5},
	{"key":"crater_azimuth_var", "category":"CRATER", "kind":"slider", "label":"CRATER_AZIMUTH_VAR", "default":0.3, "min":0.1, "max":1.0, "step":0.1},

	{"key":"ocean_ratio", "category":"EAU", "kind":"slider", "label":"OCEAN_RATIO", "unit":"%", "default":55.0, "min":0.0, "max":100.0, "step":0.1},
	{"key":"ice_probability", "category":"EAU", "kind":"slider", "label":"ICE_PROBABILITY", "unit":"%", "default":0.9, "min":0.0, "max":1.0, "step":0.1},
	{"key":"global_humidity", "category":"EAU", "kind":"slider", "label":"GLOBAL_HUMIDITY", "unit":"%", "default":0.5, "min":0.0, "max":1.0, "step":0.1},
	{"key":"sea_level", "category":"EAU", "kind":"slider", "label":"SEA_LEVEL", "unit":" m", "default":0.0, "min":-5000.0, "max":5000.0, "step":50.0},
	{"key":"freshwater_max_size", "category":"EAU", "kind":"slider", "label":"FRESHWATER_MAX_SIZE", "unit":" km²", "default":1000.0, "min":0.0, "max":1000.0, "step":10.0},
	{"key":"lake_threshold", "category":"EAU", "kind":"slider", "label":"LAKE_THRESHOLD", "default":20.0, "min":0.0, "max":100.0, "step":0.5},

	{"key":"cloud_coverage", "category":"NUAGE", "kind":"slider", "label":"CLOUD_COVERAGE", "unit":"%", "default":0.5, "min":0.1, "max":1.0, "step":0.1},
	{"key":"cloud_density", "category":"NUAGE", "kind":"slider", "label":"CLOUD_DENSITY", "unit":"%", "default":0.8, "min":0.1, "max":1.0, "step":0.1},

	{"key":"nb_cases_regions", "category":"REGION", "kind":"slider", "label":"NB_CASES_REGIONS", "default":50.0, "min":15.0, "max":500.0, "step":5.0},
	{"key":"region_cost_flat", "category":"REGION", "kind":"slider", "label":"REGION_COST_FLAT", "default":1.0, "min":1.0, "max":10.0, "step":1.0},
	{"key":"region_cost_hill", "category":"REGION", "kind":"slider", "label":"REGION_COST_HILL", "default":2.0, "min":1.0, "max":10.0, "step":1.0},
	{"key":"region_cost_river", "category":"REGION", "kind":"slider", "label":"REGION_COST_RIVER", "default":3.0, "min":1.0, "max":10.0, "step":1.0},
	{"key":"region_river_threshold", "category":"REGION", "kind":"slider", "label":"REGION_RIVER_THRESHOLD", "default":1.0, "min":1.0, "max":10.0, "step":0.5},
	{"key":"region_budget_variation", "category":"REGION", "kind":"slider", "label":"REGION_BUDGET_VARIATION", "default":0.5, "min":0.1, "max":1.0, "step":0.1},
	{"key":"region_noise_strength", "category":"REGION", "kind":"slider", "label":"REGION_NOISE_STRENGTH", "default":0.5, "min":0.1, "max":1.0, "step":0.1},

	{"key":"nb_cases_ocean_regions", "category":"OCEAN", "kind":"slider", "label":"NB_CASES_OCEAN_REGIONS", "default":100.0, "min":15.0, "max":500.0, "step":5.0},
	{"key":"ocean_cost_flat", "category":"OCEAN", "kind":"slider", "label":"OCEAN_COST_FLAT", "default":1.0, "min":1.0, "max":10.0, "step":1.0},
	{"key":"ocean_cost_deeper", "category":"OCEAN", "kind":"slider", "label":"OCEAN_COST_DEEPER", "default":2.0, "min":1.0, "max":10.0, "step":1.0},
	{"key":"ocean_noise_strength", "category":"OCEAN", "kind":"slider", "label":"OCEAN_NOISE_STRENGTH", "default":0.5, "min":0.1, "max":1.0, "step":0.1},

	{"key":"gas_giant_num_bands", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_NUM_BANDS", "default":12.0, "min":6.0, "max":24.0, "step":1.0},
	{"key":"gas_giant_jet_strength", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_JET_STRENGTH", "default":4.0, "min":0.5, "max":10.0, "step":0.1},
	{"key":"gas_giant_eddy_strength", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_EDDY_STRENGTH", "default":2.5, "min":0.5, "max":8.0, "step":0.1},
	{"key":"gas_giant_advection_dt", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_ADVECTION_DT", "default":1.4, "min":0.4, "max":2.5, "step":0.05},
	{"key":"gas_giant_advection_iterations", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_ADVECTION_ITERATIONS", "default":40.0, "min":12.0, "max":120.0, "step":4.0},
	{"key":"gas_giant_target_sharpen", "category":"GAS", "kind":"slider", "label":"GAS_GIANT_TARGET_SHARPEN", "default":1.18, "min":1.0, "max":1.5, "step":0.01},

	{"key":"petrole_probability", "category":"RESSOURCES", "kind":"slider", "label":"PETROLE_PROBABILITY", "unit":"%", "default":0.025, "min":0.001, "max":1.0, "step":0.001},
	{"key":"petrole_deposit_size", "category":"RESSOURCES", "kind":"slider", "label":"PETROLE_DEPOSIT_SIZE", "unit":" km²", "default":200.0, "min":1.0, "max":400.0, "step":1.0},
	{"key":"global_richness", "category":"RESSOURCES", "kind":"slider", "label":"GLOBAL_RICHNESS", "default":1.0, "min":0.5, "max":10.0, "step":0.5},
]


static func keys() -> Array[String]:
	var result: Array[String] = []
	for definition in DEFINITIONS:
		result.append(str(definition["key"]))
	return result


static func definition(key: String) -> Dictionary:
	for item in DEFINITIONS:
		if str(item["key"]) == key:
			return item
	return {}


static func defaults() -> Dictionary:
	var result := {}
	for item in DEFINITIONS:
		result[str(item["key"])] = item.get("default")
	return result
