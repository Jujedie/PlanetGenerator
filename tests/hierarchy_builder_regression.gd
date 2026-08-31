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
	# Une micro-composante enclavée dans un autre pays doit rejoindre le pays
	# hôte, tandis qu'une île éloignée sans voisin local doit conserver son
	# propriétaire. Ce test isole le post-traitement des pays du reste du GPU.
	var enclave_mapping := {
		1: 100, 2: 100, 3: 100, 7: 100,
		4: 200, 5: 200, 6: 200,
	}
	var enclave_adjacency := {
		1: {2: true},
		2: {1: true},
		3: {4: true, 5: true},
		4: {3: true, 5: true},
		5: {3: true, 4: true, 6: true},
		6: {5: true},
		7: {},
	}
	var enclave_coords := {
		1: Vector2(10, 20), 2: Vector2(12, 20),
		3: Vector2(50, 30), 4: Vector2(49, 30), 5: Vector2(51, 30),
		6: Vector2(52, 30), 7: Vector2(90, 50),
	}
	var enclave_weights := {1: 4, 2: 4, 3: 1, 4: 4, 5: 4, 6: 4, 7: 1}
	var enclave_cleaned := HierarchyBuilder._absorb_small_country_enclaves(
		enclave_mapping, enclave_adjacency, enclave_coords, enclave_weights,
		8.0, 2.5, 120, 60, 150.0, 5.0, 0.25, 0.75
	)
	var small_enclave_absorbed := int(enclave_cleaned.get(3, -1)) == 200
	var remote_island_preserved := int(enclave_cleaned.get(7, -1)) == 100

	# Pseudo-enclave : 4 est le goulot du pays 300 et les régions 5-6 sont une
	# petite poche derrière ce goulot, fortement bordée par le pays 400. Sans la
	# détection de points d'articulation, tout 1..6 forme une seule composante et
	# le premier correctif ne pouvait donc jamais absorber 5-6.
	var isthmus_mapping := {
		1: 300, 2: 300, 3: 300, 4: 300, 5: 300, 6: 300,
		10: 400, 11: 400, 12: 400,
	}
	var isthmus_adjacency := {
		1: {2: true},
		2: {1: true, 3: true},
		3: {2: true, 4: true},
		4: {3: true, 5: true},
		5: {4: true, 6: true, 10: true, 11: true},
		6: {5: true, 10: true, 12: true},
		10: {5: true, 6: true, 11: true},
		11: {5: true, 10: true, 12: true},
		12: {6: true, 10: true, 11: true},
	}
	var isthmus_coords := {
		1: Vector2(20, 20), 2: Vector2(22, 20), 3: Vector2(24, 20),
		4: Vector2(26, 20), 5: Vector2(28, 20), 6: Vector2(29, 21),
		10: Vector2(29, 19), 11: Vector2(30, 20), 12: Vector2(30, 22),
	}
	var isthmus_weights := {
		1: 8, 2: 8, 3: 8, 4: 3, 5: 2, 6: 2, 10: 8, 11: 8, 12: 8,
	}
	var isthmus_cleaned := HierarchyBuilder._absorb_small_country_enclaves(
		isthmus_mapping, isthmus_adjacency, isthmus_coords, isthmus_weights,
		16.0, 2.5, 120, 60, 150.0, 10.0, 0.30, 0.60
	)
	var isthmus_pocket_absorbed := (
		int(isthmus_cleaned.get(5, -1)) == 400
		and int(isthmus_cleaned.get(6, -1)) == 400
		and int(isthmus_cleaned.get(1, -1)) == 300
	)

	# Graphe terrestre régulier : chaque niveau doit conserver une vraie échelle
	# et rester continu. Les ratios réduits rendent le cas compact tout en
	# produisant plusieurs pays et continents dans ce test CPU.
	var scale_info := _grid_graph(24, 10)
	var scale_hierarchy := HierarchyBuilder.build_land_from_graph(
		scale_info, 24, 10, {
			"planet_radius": 150.0,
			"ocean_ratio": 55.0,
			"admin_reference_land_regions": 24.0,
			"admin_departments_per_region": 10.0,
			"admin_regions_per_country": 4.0,
			"admin_countries_per_continent": 3.0,
			"admin_min_regions_per_country": 2,
			"admin_min_countries_per_continent": 2,
		}
	)
	var scale_region_to_country := _group_mapping(
		scale_hierarchy[0], scale_hierarchy[1]
	)
	var scale_country_to_continent := _group_mapping(
		scale_hierarchy[1], scale_hierarchy[2]
	)
	var scale_region_ids := HierarchyBuilder._unique_values(scale_hierarchy[0])
	var scale_region_children := HierarchyBuilder._invert(scale_hierarchy[0])
	var scale_region_adjacency := HierarchyBuilder._adj_children(
		scale_region_ids, scale_region_children, scale_info[2]
	)
	var scale_country_ids := HierarchyBuilder._unique_values(scale_region_to_country)
	var scale_country_children := HierarchyBuilder._invert(scale_region_to_country)
	var scale_country_adjacency := HierarchyBuilder._adj_children(
		scale_country_ids, scale_country_children, scale_region_adjacency
	)
	var scale_counts := [
		(scale_info[0] as Array).size(),
		scale_region_ids.size(),
		HierarchyBuilder._unique_values(scale_region_to_country).size(),
		HierarchyBuilder._unique_values(scale_country_to_continent).size(),
	]
	var strict_land_scales: bool = (
		scale_counts[0] > scale_counts[1]
		and scale_counts[1] > scale_counts[2]
		and scale_counts[2] > scale_counts[3]
		and _minimum_group_children(scale_region_to_country) >= 2
		and _minimum_group_children(scale_country_to_continent) >= 2
	)
	var land_groups_contiguous := (
		HierarchyBuilder.groups_are_contiguous(scale_hierarchy[0], scale_info[2])
		and HierarchyBuilder.groups_are_contiguous(
			scale_region_to_country, scale_region_adjacency
		)
		and HierarchyBuilder.groups_are_contiguous(
			scale_country_to_continent, scale_country_adjacency
		)
	)
	var land_groups_without_enclaves := (
		HierarchyBuilder.groups_have_no_land_enclaves(
			scale_hierarchy[0], scale_info[2]
		)
		and HierarchyBuilder.groups_have_no_land_enclaves(
			scale_region_to_country, scale_region_adjacency
		)
		and HierarchyBuilder.groups_have_no_land_enclaves(
			scale_country_to_continent, scale_country_adjacency
		)
	)
	var island_mapping := {1: 10, 2: 10, 3: 10, 4: 10}
	var island_adjacency := {
		1: {2: true}, 2: {1: true}, 3: {4: true}, 4: {3: true},
	}
	var island_allowed := (
		not HierarchyBuilder.groups_are_contiguous(
			island_mapping, island_adjacency
		)
		and HierarchyBuilder.groups_have_no_land_enclaves(
			island_mapping, island_adjacency
		)
	)
	var land_enclave_rejected := not HierarchyBuilder.groups_have_no_land_enclaves(
		{1: 10, 2: 20, 3: 10},
		{1: {2: true}, 2: {1: true, 3: true}, 3: {2: true}}
	)
	# Un petit groupe ne doit jamais être fusionné au groupe géographiquement
	# proche s'il n'a aucune frontière avec lui. Cette situation reproduit les
	# enclaves intercontinentales observées sur l'ancienne carte.
	var adjacency_merge_mapping := {1: 10, 2: 20, 3: 30}
	var adjacency_merge_graph := {
		1: {2: true}, 2: {1: true, 3: true}, 3: {2: true},
	}
	var adjacency_merge_coords := {
		1: Vector2(10, 10), 2: Vector2(100, 10), 3: Vector2(11, 10),
	}
	var adjacency_merge_weights := {1: 1, 2: 10, 3: 10}
	var adjacency_merged := HierarchyBuilder._merge_undersized_groups(
		adjacency_merge_mapping, adjacency_merge_graph,
		adjacency_merge_coords, adjacency_merge_weights,
		120, 60, 2.0, 1, 20.0
	)
	var adjacency_only_merge := (
		int(adjacency_merged.get(1, -1))
		== int(adjacency_merged.get(2, -2))
		and int(adjacency_merged.get(1, -1))
		!= int(adjacency_merged.get(3, -1))
	)

	var passed: bool = (
		land_counts[0] > land_counts[1]
		and land_counts[1] > land_counts[2]
		and land_counts[2] > land_counts[3]
		and sea_counts[0] > sea_counts[1]
		and sea_counts[1] > sea_counts[2]
		and sea_counts[2] >= sea_counts[3]
		and sea_counts[3] > 0
		and not freshwater_propagated
		# Un département source est indivisible ; la fixture en contient un de
		# presque quatre fois la moyenne des régions.
		and float(region_stats.get("max_to_mean", 999.0)) <= 4.0
		and float(country_stats.get("max_to_mean", 999.0)) <= 3.0
		and float(continent_stats.get("min_to_mean", 0.0)) >= 0.20
		and resolution_invariant_targets
		and small_enclave_absorbed
		and remote_island_preserved
		and isthmus_pocket_absorbed
		and strict_land_scales
		and land_groups_contiguous
		and land_groups_without_enclaves
		and island_allowed
		and land_enclave_rejected
		and adjacency_only_merge
	)
	print("[HierarchyRegression] land_counts=", land_counts)
	print("[HierarchyRegression] sea_counts=", sea_counts)
	print("[HierarchyRegression] freshwater_propagated=", freshwater_propagated)
	print("[HierarchyRegression] region_stats=", region_stats)
	print("[HierarchyRegression] country_stats=", country_stats)
	print("[HierarchyRegression] continent_stats=", continent_stats)
	print("[HierarchyRegression] huge_capacity_targets=", huge_capacity_targets)
	print("[HierarchyRegression] resolution_invariant_targets=", resolution_invariant_targets)
	print("[HierarchyRegression] small_enclave_absorbed=", small_enclave_absorbed)
	print("[HierarchyRegression] remote_island_preserved=", remote_island_preserved)
	print("[HierarchyRegression] isthmus_pocket_absorbed=", isthmus_pocket_absorbed)
	print("[HierarchyRegression] scale_counts=", scale_counts)
	print("[HierarchyRegression] strict_land_scales=", strict_land_scales)
	print("[HierarchyRegression] land_groups_contiguous=", land_groups_contiguous)
	print("[HierarchyRegression] land_groups_without_enclaves=", land_groups_without_enclaves)
	print("[HierarchyRegression] island_allowed=", island_allowed)
	print("[HierarchyRegression] land_enclave_rejected=", land_enclave_rejected)
	print("[HierarchyRegression] adjacency_only_merge=", adjacency_only_merge)
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


func _minimum_group_children(mapping: Dictionary) -> int:
	var minimum := 0x7FFFFFFF
	for children_value in HierarchyBuilder._invert(mapping).values():
		minimum = mini(minimum, (children_value as Array).size())
	return 0 if minimum == 0x7FFFFFFF else minimum


func _grid_graph(width: int, height: int) -> Array:
	var units: Array = []
	var coords: Dictionary = {}
	var adjacency: Dictionary = {}
	var weights: Dictionary = {}
	for y in range(height):
		for x in range(width):
			var unit := y * width + x
			units.append(unit)
			coords[unit] = Vector2(x, y)
			weights[unit] = 1
			adjacency[unit] = {}
	for y in range(height):
		for x in range(width):
			var unit := y * width + x
			for offset in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				if nx >= width or ny >= height:
					continue
				var neighbor: int = ny * width + nx
				(adjacency[unit] as Dictionary)[neighbor] = true
				(adjacency[neighbor] as Dictionary)[unit] = true
	return [units, coords, adjacency, weights]
