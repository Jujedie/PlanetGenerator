extends Node

## Régression CPU de la hiérarchie. Elle couvre les quotas par composante, les
## bornes de taille et la remontée des eaux salées sans dépendre d'un GPU.

const WIDTH := 120
const HEIGHT := 60
const INVALID_ID := 0xFFFFFFFF


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var land := PackedByteArray()
	var sea := PackedByteArray()
	var water := PackedByteArray()
	land.resize(WIDTH * HEIGHT * 4)
	sea.resize(WIDTH * HEIGHT * 4)
	water.resize(WIDTH * HEIGHT)
	var freshwater_lake_units: Dictionary = {}
	for offset in range(0, land.size(), 4):
		land.encode_u32(offset, INVALID_ID)
		sea.encode_u32(offset, INVALID_ID)

	for y in range(HEIGHT):
		for x in range(WIDTH):
			var index := y * WIDTH + x
			var left_mass := x < 34 and y >= 8 and y < 54
			var right_mass := x >= 48 and y >= 4 and y < 57
			var small_island := x >= 39 and x < 43 and y >= 2 and y < 6
			var freshwater_lake := x >= 10 and x < 18 and y >= 20 and y < 28
			if (left_mass or right_mass or small_island) and not freshwater_lake:
				var department := (y / 2) * WIDTH + (x / 2)
				land.encode_u32(index * 4, department)
			else:
				var sea_department := 1_000_000 + (y / 3) * WIDTH + (x / 3)
				sea.encode_u32(index * 4, sea_department)
				water[index] = 2 if freshwater_lake else 1
				if freshwater_lake:
					freshwater_lake_units[sea_department] = true

	var settings := {
		"planet_radius": 150.0,
		"ocean_ratio": 55.0,
		"nb_cases_ocean_regions": 24,
		"admin_departments_per_region": 10.0,
	}
	var land_hierarchy := HierarchyBuilder.build_land(
		land, WIDTH, HEIGHT, {}, settings
	)
	var sea_hierarchy := HierarchyBuilder.build_sea(
		sea, WIDTH, HEIGHT, {}, settings, land, {}, land_hierarchy, water
	)
	var scan := HierarchyBuilder._scan(land, WIDTH, HEIGHT, {})
	var department_weights: Dictionary = scan[3]
	var region_weights := _aggregate_weights(land_hierarchy[0], department_weights)
	var region_to_country := _group_mapping(land_hierarchy[0], land_hierarchy[1])
	var country_weights := _aggregate_weights(region_to_country, region_weights)
	var country_to_continent := _group_mapping(land_hierarchy[1], land_hierarchy[2])
	var region_stats := HierarchyBuilder.measure_group_weights(
		land_hierarchy[0], department_weights
	)
	var country_stats := HierarchyBuilder.measure_group_weights(
		region_to_country, region_weights
	)
	var continent_stats := HierarchyBuilder.measure_group_weights(
		country_to_continent, country_weights
	)
	# Une texture plus détaillée peut contenir des centaines de milliers d'IDs
	# locaux. Elle ne doit pas multiplier les niveaux supérieurs ni provoquer une
	# sélection de dizaines de milliers de graines pendant l'export.
	var large_planet_settings := {
		"planet_radius": 550.0,
		"ocean_ratio": 55.0,
		"nb_cases_regions": 15,
	}
	var medium_capacity_targets := HierarchyBuilder.compute_land_hierarchy_targets(
		10_000, large_planet_settings
	)
	var huge_capacity_targets := HierarchyBuilder.compute_land_hierarchy_targets(
		226_727, large_planet_settings
	)
	var resolution_invariant_targets := (
		int(medium_capacity_targets["regions"]) == int(huge_capacity_targets["regions"])
		and int(medium_capacity_targets["middle"]) == int(huge_capacity_targets["middle"])
		and int(medium_capacity_targets["top"]) == int(huge_capacity_targets["top"])
		and int(huge_capacity_targets["regions"]) < 1000
	)
	var land_counts := [
		_count_ids(land),
		HierarchyBuilder._unique_values(land_hierarchy[0]).size(),
		HierarchyBuilder._unique_values(land_hierarchy[1]).size(),
		HierarchyBuilder._unique_values(land_hierarchy[2]).size(),
	]
	var sea_counts := [
		_count_ids(sea),
		HierarchyBuilder._unique_values(sea_hierarchy[0]).size(),
		HierarchyBuilder._unique_values(sea_hierarchy[1]).size(),
		HierarchyBuilder._unique_values(sea_hierarchy[2]).size(),
	]
	var freshwater_propagated := false
	for freshwater_unit in freshwater_lake_units.keys():
		if (sea_hierarchy[0] as Dictionary).has(freshwater_unit):
			freshwater_propagated = true
			break
	var passed: bool = (
		land_counts[0] > land_counts[1]
		and land_counts[1] > land_counts[2]
		and land_counts[2] >= land_counts[3]
		and sea_counts[0] > sea_counts[1]
		and sea_counts[1] > sea_counts[2]
		and sea_counts[2] >= sea_counts[3]
		and sea_counts[3] > 0
		and not freshwater_propagated
		and float(region_stats.get("max_to_mean", 999.0)) <= 3.0
		and float(country_stats.get("max_to_mean", 999.0)) <= 3.0
		and float(continent_stats.get("min_to_mean", 0.0)) >= 0.20
		and resolution_invariant_targets
	)
	print("[HierarchyRegression] land_counts=", land_counts)
	print("[HierarchyRegression] sea_counts=", sea_counts)
	print("[HierarchyRegression] freshwater_propagated=", freshwater_propagated)
	print("[HierarchyRegression] region_stats=", region_stats)
	print("[HierarchyRegression] country_stats=", country_stats)
	print("[HierarchyRegression] continent_stats=", continent_stats)
	print("[HierarchyRegression] huge_capacity_targets=", huge_capacity_targets)
	print("[HierarchyRegression] resolution_invariant_targets=", resolution_invariant_targets)
	if not passed:
		push_error("Hierarchy size/sea propagation regression failed")
	get_tree().quit(0 if passed else 1)


func _count_ids(data: PackedByteArray) -> int:
	var ids: Dictionary = {}
	for offset in range(0, data.size(), 4):
		var value := data.decode_u32(offset)
		if value != INVALID_ID:
			ids[value] = true
	return ids.size()


func _aggregate_weights(mapping: Dictionary, child_weights: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for child in mapping.keys():
		var group = mapping[child]
		result[group] = int(result.get(group, 0)) + maxi(
			int(child_weights.get(child, 1)), 1
		)
	return result


func _group_mapping(lower_mapping: Dictionary, upper_mapping: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for child in lower_mapping.keys():
		if upper_mapping.has(child):
			result[lower_mapping[child]] = upper_mapping[child]
	return result
