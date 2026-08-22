class_name HierarchyBuilder
extends RefCounted

## Construit les hiérarchies administratives à partir des départements GPU.
## Chaque niveau choisit d'abord ses graines, puis fige l'affectation de tous
## les enfants à leur graine la plus proche. La croissance d'un groupe ne peut
## donc plus déplacer le centre de référence ni avaler les groupes suivants.

const REFERENCE_RADIUS_KM: float = 150.0
const REFERENCE_LAND_RATIO: float = 0.45
const DEPARTMENTS_PER_REGION: float = 9.0
const LAND_DEPARTMENTS_PER_REGION_TARGET: float = 10.0
const LAND_REGIONS_PER_COUNTRY: float = 7.5
const LAND_COUNTRIES_PER_CONTINENT: float = 8.0
const SEA_REGIONS_PER_BASIN: float = 10.0
const SEA_BASINS_PER_OCEAN: float = 9.0

const _ID_LAND: int = 10_000_000
const _ID_SEA: int = 50_000_000
const _INVALID_ID: int = 0xFFFFFFFF
const _DIST_EPSILON: float = 0.000001


static func compute_merge_map(_data: PackedByteArray, _w: int, _h: int) -> Dictionary:
	# Les cartes JFA sont déjà raccordées horizontalement. Fusionner les IDs
	# présents de part et d'autre de la couture créerait des zones disjointes.
	return {}


## Les densités sont calculées depuis la surface réelle de la planète. La
## résolution ne sert que de garde-fou pour conserver assez de texels par zone.
static func compute_physical_targets(settings: Dictionary, maritime: bool = false,
		sample_capacity: int = 0x7FFFFFFF) -> Dictionary:
	var radius_km := maxf(float(settings.get("planet_radius", REFERENCE_RADIUS_KM)), 1.0)
	var ocean_fraction := clampf(float(settings.get("ocean_ratio", 55.0)) / 100.0, 0.01, 0.99)
	var coverage := ocean_fraction if maritime else 1.0 - ocean_fraction
	var reference_coverage := 1.0 - REFERENCE_LAND_RATIO if maritime else REFERENCE_LAND_RATIO
	var surface_km2 := 4.0 * PI * radius_km * radius_km * coverage
	var reference_surface_km2 := (
		4.0 * PI * REFERENCE_RADIUS_KM * REFERENCE_RADIUS_KM * reference_coverage
	)
	var surface_scale := maxf(surface_km2 / maxf(reference_surface_km2, 1.0), 0.0001)
	var radius_scale := maxf(radius_km / REFERENCE_RADIUS_KM, 0.01)
	var base_key := "nb_cases_ocean_regions" if maritime else "nb_cases_regions"
	var base_default := 100.0 if maritime else 50.0
	var base_regions := maxf(float(settings.get(base_key, base_default)), 1.0)

	# Sous-linéaire en surface : une grande planète reçoit davantage de zones,
	# mais chacune couvre aussi une aire physique plus grande.
	var regions := maxi(1, int(round(base_regions * pow(surface_scale, 0.72))))
	var departments := maxi(regions, int(round(float(regions) * DEPARTMENTS_PER_REGION)))
	var capacity := maxi(sample_capacity, 1)
	departments = mini(departments, maxi(1, capacity / 20))
	regions = mini(regions, departments)

	var middle_ratio := (
		SEA_REGIONS_PER_BASIN * pow(radius_scale, 0.12)
		if maritime else LAND_REGIONS_PER_COUNTRY * pow(radius_scale, 0.12)
	)
	var top_ratio := (
		SEA_BASINS_PER_OCEAN * pow(radius_scale, 0.08)
		if maritime else LAND_COUNTRIES_PER_CONTINENT * pow(radius_scale, 0.08)
	)
	var middle := clampi(int(round(float(regions) / maxf(middle_ratio, 2.0))), 1, regions)
	var top := clampi(int(round(float(middle) / maxf(top_ratio, 2.0))), 1, middle)

	return {
		"surface_km2": surface_km2,
		"regions": regions,
		"departments": departments,
		"middle": middle,
		"top": top,
		"middle_ratio": middle_ratio,
		"top_ratio": top_ratio,
	}


## Dérive les niveaux terrestres du nombre de départements effectivement
## générés. Les valeurs sont des tailles moyennes de niveau, jamais des nombres
## d'entités imposés. Exemple : 2 909 départements donnent environ 291 régions,
## 36 pays et 5 continents au lieu de 20 / 3 / 1.
static func compute_land_hierarchy_targets(department_count: int,
		settings: Dictionary = {}) -> Dictionary:
	var departments := maxi(department_count, 1)
	var radius_km := maxf(float(settings.get("planet_radius", REFERENCE_RADIUS_KM)), 1.0)
	var land_fraction := 1.0 - clampf(
		float(settings.get("ocean_ratio", 55.0)) / 100.0, 0.01, 0.99
	)
	var surface_km2 := 4.0 * PI * radius_km * radius_km * land_fraction
	var departments_per_region := clampf(float(settings.get(
		"admin_departments_per_region", LAND_DEPARTMENTS_PER_REGION_TARGET
	)), 4.0, 24.0)
	var regions_per_country := clampf(float(settings.get(
		"admin_regions_per_country", 8.0
	)), 3.0, 20.0)
	var countries_per_continent := clampf(float(settings.get(
		"admin_countries_per_continent", LAND_COUNTRIES_PER_CONTINENT
	)), 3.0, 24.0)
	var regions := clampi(
		int(round(float(departments) / departments_per_region)), 1, departments
	)
	var countries := clampi(
		int(round(float(regions) / regions_per_country)), 1, regions
	)
	var continents := clampi(
		int(round(float(countries) / countries_per_continent)), 1, countries
	)
	return {
		"surface_km2": surface_km2,
		"departments": departments,
		"regions": regions,
		"middle": countries,
		"top": continents,
		"departments_per_region": departments_per_region,
		"regions_per_country": regions_per_country,
		"countries_per_continent": countries_per_continent,
	}


## Retourne [département→région, département→pays, département→continent].
static func build_land(data: PackedByteArray, w: int, h: int,
		merge: Dictionary, settings: Dictionary = {}) -> Array:
	var info := _scan(data, w, h, merge)
	var depts: Array = info[0]
	var coords: Dictionary = info[1]
	var adjacency: Dictionary = info[2]
	var weights: Dictionary = info[3]
	if depts.is_empty():
		return [{}, {}, {}]

	var gen := [_ID_LAND]
	var radius_km := maxf(float(settings.get("planet_radius", REFERENCE_RADIUS_KM)), 1.0)
	var targets := compute_land_hierarchy_targets(depts.size(), settings)
	var target_regions := clampi(int(targets["regions"]), 1, depts.size())
	var target_countries := clampi(int(targets["middle"]), 1, target_regions)
	var target_continents := clampi(int(targets["top"]), 1, target_countries)
	var surface_km2 := float(targets["surface_km2"])

	# Une île proche peut rejoindre une zone côtière. Une composante réellement
	# éloignée reste indépendante, conformément à la règle des petites enclaves.
	var region_bridge_km := 1.8 * sqrt(surface_km2 / float(target_regions))
	var country_bridge_km := 2.6 * sqrt(surface_km2 / float(target_countries))
	var continent_bridge_km := 4.0 * sqrt(surface_km2 / float(target_continents))

	print("    %d départements terrestres" % depts.size())
	var dept_to_region := _stable_nearest_groups(
		depts, adjacency, coords, weights, target_regions, w, h, radius_km,
		region_bridge_km, false, gen
	)
	print("    → %d régions" % _unique_values(dept_to_region).size())

	var region_ids := _unique_values(dept_to_region)
	var region_children := _invert(dept_to_region)
	var region_adjacency := _adj_children(region_ids, region_children, adjacency)
	var region_info := _aggregate_geometry(region_ids, region_children, coords, weights, w)
	var region_coords: Dictionary = region_info[0]
	var region_weights: Dictionary = region_info[1]
	var region_to_country := _stable_nearest_groups(
		region_ids, region_adjacency, region_coords, region_weights,
		mini(target_countries, region_ids.size()), w, h, radius_km,
		country_bridge_km, false, gen
	)
	print("    → %d pays" % _unique_values(region_to_country).size())

	var country_ids := _unique_values(region_to_country)
	var country_children := _invert(region_to_country)
	var country_adjacency := _adj_children(country_ids, country_children, region_adjacency)
	var country_info := _aggregate_geometry(
		country_ids, country_children, region_coords, region_weights, w
	)
	var country_to_continent := _stable_nearest_groups(
		country_ids, country_adjacency, country_info[0], country_info[1],
		mini(target_continents, country_ids.size()), w, h, radius_km,
		continent_bridge_km, false, gen
	)
	print("    → %d continents" % _unique_values(country_to_continent).size())

	var dept_to_country: Dictionary = {}
	var dept_to_continent: Dictionary = {}
	for dept in depts:
		var region: int = dept_to_region.get(dept, -1)
		var country: int = region_to_country.get(region, -1)
		if country == -1:
			continue
		dept_to_country[dept] = country
		var continent: int = country_to_continent.get(country, -1)
		if continent != -1:
			dept_to_continent[dept] = continent
	return [dept_to_region, dept_to_country, dept_to_continent]


## Retourne [département-mer→région-mer, →bassin, →océan]. Seules les
## composantes marines reliées à plusieurs zones terrestres valides montent
## dans la hiérarchie. Les lacs/départements isolés restent uniquement au
## niveau départemental et ne peuvent jamais devenir un « océan ».
static func build_sea(data: PackedByteArray, w: int, h: int,
		merge: Dictionary, settings: Dictionary = {},
		land_data: PackedByteArray = PackedByteArray(),
		land_merge: Dictionary = {}, land_hierarchy: Array = [],
		water_mask_data: PackedByteArray = PackedByteArray()) -> Array:
	var info := _scan(data, w, h, merge)
	var all_depts: Array = info[0]
	if all_depts.is_empty():
		return [{}, {}, {}]

	var eligible := _eligible_sea_units(
		all_depts, info[2], data, land_data, w, h, merge, land_merge,
		land_hierarchy, water_mask_data
	)
	if eligible.is_empty():
		print("    %d départements maritimes, aucun ancrage terrestre multi-région" % all_depts.size())
		return [{}, {}, {}]

	var coords: Dictionary = info[1]
	var adjacency: Dictionary = info[2]
	var weights: Dictionary = info[3]
	var gen := [_ID_SEA]
	var radius_km := maxf(float(settings.get("planet_radius", REFERENCE_RADIUS_KM)), 1.0)
	var targets := compute_physical_targets(settings, true, eligible.size() * 20)
	var target_regions := clampi(int(targets["regions"]), 1, eligible.size())
	var target_basins := clampi(int(targets["middle"]), 1, target_regions)
	var target_oceans := clampi(int(targets["top"]), 1, target_basins)

	print("    %d/%d départements maritimes ancrés à la terre" % [eligible.size(), all_depts.size()])
	# Aucune liaison artificielle entre composantes marines : chaque région,
	# bassin et océan reste topologiquement continu et sans enclave.
	var dept_to_region := _stable_nearest_groups(
		eligible, adjacency, coords, weights, target_regions, w, h, radius_km,
		-1.0, true, gen
	)
	print("    → %d régions-mer" % _unique_values(dept_to_region).size())

	var region_ids := _unique_values(dept_to_region)
	var region_children := _invert(dept_to_region)
	var region_adjacency := _adj_children(region_ids, region_children, adjacency)
	var region_info := _aggregate_geometry(region_ids, region_children, coords, weights, w)
	var region_to_basin := _stable_nearest_groups(
		region_ids, region_adjacency, region_info[0], region_info[1],
		mini(target_basins, region_ids.size()), w, h, radius_km,
		-1.0, true, gen
	)
	print("    → %d bassins" % _unique_values(region_to_basin).size())

	var basin_ids := _unique_values(region_to_basin)
	var basin_children := _invert(region_to_basin)
	var basin_adjacency := _adj_children(basin_ids, basin_children, region_adjacency)
	var basin_info := _aggregate_geometry(
		basin_ids, basin_children, region_info[0], region_info[1], w
	)
	var basin_to_ocean := _stable_nearest_groups(
		basin_ids, basin_adjacency, basin_info[0], basin_info[1],
		mini(target_oceans, basin_ids.size()), w, h, radius_km,
		-1.0, true, gen
	)
	print("    → %d océans" % _unique_values(basin_to_ocean).size())

	var dept_to_basin: Dictionary = {}
	var dept_to_ocean: Dictionary = {}
	for dept in eligible:
		var region: int = dept_to_region.get(dept, -1)
		var basin: int = region_to_basin.get(region, -1)
		if basin == -1:
			continue
		dept_to_basin[dept] = basin
		var ocean: int = basin_to_ocean.get(basin, -1)
		if ocean != -1:
			dept_to_ocean[dept] = ocean
	return [dept_to_region, dept_to_basin, dept_to_ocean]


static func assign_colors(group_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	var index := 0
	for gid in group_ids:
		if out.has(gid):
			continue
		var hue := fposmod(float(index) * 0.61803398875, 1.0)
		var saturation := 0.58 + 0.12 * float(index % 3) / 2.0
		var value_band := floori(float(index) / 3.0) % 3
		var value := 0.72 + 0.16 * float(value_band) / 2.0
		out[gid] = Color.from_hsv(hue, saturation, value, 1.0)
		index += 1
	return out


## Extrait les IDs, centres pondérés, poids surfaciques et adjacences. La
## moyenne circulaire de X évite de déplacer les zones traversant la couture.
static func _scan(data: PackedByteArray, w: int, h: int,
		merge: Dictionary) -> Array:
	var ids: Array = []
	var seen: Dictionary = {}
	var stats: Dictionary = {}
	var adjacency: Dictionary = {}
	for y in range(h):
		for x in range(w):
			var raw := data.decode_u32((y * w + x) * 4)
			if raw == _INVALID_ID:
				continue
			var unit: int = merge.get(raw, raw)
			if not seen.has(unit):
				seen[unit] = true
				ids.append(unit)
				stats[unit] = [0.0, 0.0, 0.0, 0]
				adjacency[unit] = {}
			var values: Array = stats[unit]
			var angle := TAU * (float(x) + 0.5) / float(maxi(w, 1))
			values[0] = float(values[0]) + cos(angle)
			values[1] = float(values[1]) + sin(angle)
			values[2] = float(values[2]) + float(y)
			values[3] = int(values[3]) + 1

			if x + 1 < w:
				_add_pixel_adjacency(data, y * w + x + 1, unit, merge, adjacency)
			if y + 1 < h:
				_add_pixel_adjacency(data, (y + 1) * w + x, unit, merge, adjacency)
			if x == w - 1:
				_add_pixel_adjacency(data, y * w, unit, merge, adjacency)

	var coords: Dictionary = {}
	var weights: Dictionary = {}
	for unit in ids:
		var values: Array = stats[unit]
		var count := maxi(int(values[3]), 1)
		var angle := atan2(float(values[1]), float(values[0]))
		if angle < 0.0:
			angle += TAU
		coords[unit] = Vector2(
			angle * float(w) / TAU - 0.5,
			float(values[2]) / float(count)
		)
		weights[unit] = count
	return [ids, coords, adjacency, weights]


static func _add_pixel_adjacency(data: PackedByteArray, pixel_index: int,
		unit: int, merge: Dictionary, adjacency: Dictionary) -> void:
	var raw := data.decode_u32(pixel_index * 4)
	if raw == _INVALID_ID:
		return
	var neighbor: int = merge.get(raw, raw)
	if neighbor == unit:
		return
	if not adjacency.has(neighbor):
		adjacency[neighbor] = {}
	(adjacency[unit] as Dictionary)[neighbor] = true
	(adjacency[neighbor] as Dictionary)[unit] = true


## Sélectionne les graines une seule fois, puis calcule le plus court chemin
## sur le graphe des voisins vers ces graines. Les propriétaires des graines
## restent immuables pendant toute l'agrégation.
static func _stable_nearest_groups(units: Array, adjacency: Dictionary,
		coords: Dictionary, weights: Dictionary, target_count: int,
		w: int, h: int, radius_km: float, bridge_limit_km: float,
		keep_components_separate: bool, gen: Array) -> Dictionary:
	if units.is_empty():
		return {}
	var components := _connected_components(units, adjacency)
	var seed_target := clampi(target_count, 1, units.size())
	if keep_components_separate:
		seed_target = mini(units.size(), maxi(seed_target, components.size()))
	var seeds := _select_fixed_seeds(
		units, components, coords, weights, seed_target, w, h,
		keep_components_separate
	)

	var owner: Dictionary = {}
	var distance: Dictionary = {}
	var seed_group: Dictionary = {}
	var heap_nodes: Array = []
	var heap_distances: Array = []
	for seed in seeds:
		var gid: int = gen[0]
		gen[0] += 1
		seed_group[seed] = gid
		owner[seed] = seed
		distance[seed] = 0.0
		_heap_push(heap_nodes, heap_distances, seed, 0.0)

	var allowed: Dictionary = {}
	for unit in units:
		allowed[unit] = true

	while not heap_nodes.is_empty():
		var item := _heap_pop(heap_nodes, heap_distances)
		var current: int = item[0]
		var current_distance: float = item[1]
		if current_distance > float(distance.get(current, INF)) + _DIST_EPSILON:
			continue
		for neighbor in (adjacency.get(current, {}) as Dictionary).keys():
			if not allowed.has(neighbor):
				continue
			var step := maxf(sqrt(_map_distance_squared(
				coords.get(current, Vector2.ZERO),
				coords.get(neighbor, Vector2.ZERO), w, h
			)), _DIST_EPSILON)
			var candidate := current_distance + step
			var old_distance := float(distance.get(neighbor, INF))
			var candidate_owner: int = owner[current]
			var old_owner: int = owner.get(neighbor, 0x7FFFFFFF)
			if candidate < old_distance - _DIST_EPSILON or (
					absf(candidate - old_distance) <= _DIST_EPSILON
					and candidate_owner < old_owner):
				distance[neighbor] = candidate
				owner[neighbor] = candidate_owner
				_heap_push(heap_nodes, heap_distances, neighbor, candidate)

	var result: Dictionary = {}
	for unit in units:
		if owner.has(unit):
			result[unit] = seed_group[owner[unit]]

	# Une composante sans graine ne peut pas être atteinte par le graphe. Elle
	# rejoint en bloc la graine géographiquement la plus proche seulement dans
	# la limite physique autorisée; sinon elle conserve son indépendance.
	for component in components:
		if component.is_empty() or result.has(component[0]):
			continue
		var representative := _representative(component, coords, weights, w)
		var nearest_seed: int = -1
		var nearest_distance := INF
		for seed in seeds:
			var angular := sqrt(_map_distance_squared(
				coords.get(representative, Vector2.ZERO),
				coords.get(seed, Vector2.ZERO), w, h
			))
			var physical_km := angular * radius_km
			if physical_km < nearest_distance:
				nearest_distance = physical_km
				nearest_seed = seed
		var gid := -1
		if not keep_components_separate and nearest_seed != -1 and (
				bridge_limit_km < 0.0 or nearest_distance <= bridge_limit_km):
			gid = int(seed_group[nearest_seed])
		else:
			gid = int(gen[0])
			gen[0] += 1
		for unit in component:
			result[unit] = gid
	return result


static func _select_fixed_seeds(units: Array, components: Array,
		coords: Dictionary, weights: Dictionary, target_count: int,
		w: int, h: int, keep_components_separate: bool) -> Array:
	var seeds: Array = []
	var selected: Dictionary = {}
	if keep_components_separate:
		for component in components:
			var seed := _representative(component, coords, weights, w)
			seeds.append(seed)
			selected[seed] = true
	else:
		var seed := _representative(units, coords, weights, w)
		seeds.append(seed)
		selected[seed] = true

	# Cache incrémental : recalculer la distance à toutes les graines à chaque
	# ajout serait O(N×K²) et devient prohibitif avec ~18 000 départements.
	# La graine la plus proche ne peut que s'améliorer, donc une comparaison
	# avec la nouvelle graine suffit à chaque itération (O(N×K)).
	var nearest_distance: Dictionary = {}
	for unit in units:
		var nearest := INF
		for seed in seeds:
			nearest = minf(nearest, _map_distance_squared(
				coords.get(unit, Vector2.ZERO), coords.get(seed, Vector2.ZERO), w, h
			))
		nearest_distance[unit] = nearest

	while seeds.size() < target_count:
		var best_unit: int = -1
		var best_score := -1.0
		for unit in units:
			if selected.has(unit):
				continue
			var weight_factor := pow(maxf(float(weights.get(unit, 1)), 1.0), 0.08)
			var score := float(nearest_distance[unit]) * weight_factor
			if score > best_score:
				best_score = score
				best_unit = unit
		if best_unit == -1:
			break
		seeds.append(best_unit)
		selected[best_unit] = true
		var best_position: Vector2 = coords.get(best_unit, Vector2.ZERO)
		for unit in units:
			if selected.has(unit):
				continue
			var candidate_distance := _map_distance_squared(
				coords.get(unit, Vector2.ZERO), best_position, w, h
			)
			if candidate_distance < float(nearest_distance[unit]):
				nearest_distance[unit] = candidate_distance
	return seeds


static func _connected_components(units: Array, adjacency: Dictionary) -> Array:
	var allowed: Dictionary = {}
	for unit in units:
		allowed[unit] = true
	var visited: Dictionary = {}
	var components: Array = []
	for start in units:
		if visited.has(start):
			continue
		var component: Array = []
		var queue: Array = [start]
		visited[start] = true
		var head := 0
		while head < queue.size():
			var current = queue[head]
			head += 1
			component.append(current)
			for neighbor in (adjacency.get(current, {}) as Dictionary).keys():
				if allowed.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)
	return components


static func _representative(units: Array, coords: Dictionary,
		weights: Dictionary, w: int) -> int:
	if units.is_empty():
		return -1
	var center := _weighted_center(units, coords, weights, w)
	var best = units[0]
	var best_distance := INF
	for unit in units:
		var position: Vector2 = coords.get(unit, Vector2.ZERO)
		var dx := absf(position.x - center.x)
		dx = minf(dx, float(w) - dx)
		var dy := position.y - center.y
		var distance_squared := dx * dx + dy * dy
		if distance_squared < best_distance:
			best_distance = distance_squared
			best = unit
	return int(best)


static func _weighted_center(units: Array, coords: Dictionary,
		weights: Dictionary, w: int) -> Vector2:
	var sum_cos := 0.0
	var sum_sin := 0.0
	var sum_y := 0.0
	var sum_weight := 0.0
	for unit in units:
		var position: Vector2 = coords.get(unit, Vector2.ZERO)
		var weight := maxf(float(weights.get(unit, 1)), 1.0)
		var angle := TAU * (position.x + 0.5) / float(maxi(w, 1))
		sum_cos += cos(angle) * weight
		sum_sin += sin(angle) * weight
		sum_y += position.y * weight
		sum_weight += weight
	var center_angle := atan2(sum_sin, sum_cos)
	if center_angle < 0.0:
		center_angle += TAU
	return Vector2(
		center_angle * float(w) / TAU - 0.5,
		sum_y / maxf(sum_weight, 1.0)
	)


## Distance angulaire équirectangulaire, raccordée en longitude et corrigée
## par la latitude. Multipliée par le rayon, elle devient une distance en km.
static func _map_distance_squared(a: Vector2, b: Vector2, w: int, h: int) -> float:
	var dx_pixels := absf(a.x - b.x)
	dx_pixels = minf(dx_pixels, maxf(float(w) - dx_pixels, 0.0))
	var dx := dx_pixels * TAU / float(maxi(w, 1))
	var dy := (a.y - b.y) * PI / float(maxi(h, 1))
	var latitude := ((a.y + b.y) * 0.5 / float(maxi(h, 1)) - 0.5) * PI
	dx *= maxf(cos(latitude), 0.05)
	return dx * dx + dy * dy


static func _heap_push(nodes: Array, distances: Array, node: int, value: float) -> void:
	nodes.append(node)
	distances.append(value)
	var index := nodes.size() - 1
	while index > 0:
		var parent := (index - 1) >> 1
		if float(distances[parent]) <= value:
			break
		nodes[index] = nodes[parent]
		distances[index] = distances[parent]
		index = parent
	nodes[index] = node
	distances[index] = value


static func _heap_pop(nodes: Array, distances: Array) -> Array:
	var result_node = nodes[0]
	var result_distance: float = distances[0]
	var last_node = nodes.pop_back()
	var last_distance = distances.pop_back()
	if not nodes.is_empty():
		var index := 0
		while true:
			var left := index * 2 + 1
			if left >= nodes.size():
				break
			var right := left + 1
			var child := left
			if right < nodes.size() and float(distances[right]) < float(distances[left]):
				child = right
			if float(distances[child]) >= float(last_distance):
				break
			nodes[index] = nodes[child]
			distances[index] = distances[child]
			index = child
		nodes[index] = last_node
		distances[index] = last_distance
	return [result_node, result_distance]


static func _adj_children(group_ids: Array, group_children: Dictionary,
		child_adjacency: Dictionary) -> Dictionary:
	var child_to_group: Dictionary = {}
	for group in group_ids:
		for child in (group_children.get(group, []) as Array):
			child_to_group[child] = group
	var adjacency: Dictionary = {}
	for group in group_ids:
		adjacency[group] = {}
	for child in child_adjacency.keys():
		var group_a: int = child_to_group.get(child, -1)
		if group_a == -1:
			continue
		for neighbor in (child_adjacency[child] as Dictionary).keys():
			var group_b: int = child_to_group.get(neighbor, -1)
			if group_b == -1 or group_b == group_a:
				continue
			(adjacency[group_a] as Dictionary)[group_b] = true
			(adjacency[group_b] as Dictionary)[group_a] = true
	return adjacency


static func _aggregate_geometry(group_ids: Array, group_children: Dictionary,
		child_coords: Dictionary, child_weights: Dictionary, w: int) -> Array:
	var coords: Dictionary = {}
	var weights: Dictionary = {}
	for group in group_ids:
		var children: Array = group_children.get(group, [])
		coords[group] = _weighted_center(children, child_coords, child_weights, w)
		var total_weight := 0
		for child in children:
			total_weight += int(child_weights.get(child, 1))
		weights[group] = maxi(total_weight, 1)
	return [coords, weights]


## Une composante maritime ne monte dans la hiérarchie que si son littoral
## touche un réseau d'au moins six régions appartenant à trois pays distincts.
## Le critère est relationnel, jamais fondé sur son aire.
static func _eligible_sea_units(sea_units: Array, sea_adjacency: Dictionary,
		sea_data: PackedByteArray, land_data: PackedByteArray, w: int, h: int,
		sea_merge: Dictionary, land_merge: Dictionary,
		land_hierarchy: Array, water_mask_data: PackedByteArray) -> Array:
	if land_data.is_empty() or land_data.size() != sea_data.size() or land_hierarchy.size() < 2:
		return []
	var contacts: Dictionary = {}
	var saltwater_units: Dictionary = {}
	for y in range(h):
		for x in range(w):
			var sea_raw := sea_data.decode_u32((y * w + x) * 4)
			if sea_raw == _INVALID_ID:
				continue
			var sea_unit: int = sea_merge.get(sea_raw, sea_raw)
			if water_mask_data.size() == w * h and water_mask_data[y * w + x] == 1:
				saltwater_units[sea_unit] = true
			if not contacts.has(sea_unit):
				contacts[sea_unit] = {}
			var neighbors := [
				Vector2i(posmod(x - 1, w), y), Vector2i((x + 1) % w, y),
				Vector2i(x, y - 1), Vector2i(x, y + 1),
			]
			for position in neighbors:
				if position.y < 0 or position.y >= h:
					continue
				var land_raw := land_data.decode_u32((position.y * w + position.x) * 4)
				if land_raw == _INVALID_ID:
					continue
				var land_unit: int = land_merge.get(land_raw, land_raw)
				(contacts[sea_unit] as Dictionary)[land_unit] = true

	var dept_to_region: Dictionary = land_hierarchy[0]
	var dept_to_country: Dictionary = land_hierarchy[1]
	var total_land_regions := _unique_values(dept_to_region).size()
	var total_land_countries := _unique_values(dept_to_country).size()
	var minimum_region_links := clampi(
		int(ceil(float(total_land_regions) * 0.04)), 6, 80
	)
	var minimum_country_links := clampi(
		int(ceil(float(total_land_countries) * 0.08)), 3, 20
	)
	var eligible: Array = []
	for component in _connected_components(sea_units, sea_adjacency):
		var land_regions: Dictionary = {}
		var land_countries: Dictionary = {}
		var contains_saltwater := false
		for sea_unit in component:
			if saltwater_units.has(sea_unit):
				contains_saltwater = true
			for land_unit in (contacts.get(sea_unit, {}) as Dictionary).keys():
				var region: int = dept_to_region.get(land_unit, -1)
				var country: int = dept_to_country.get(land_unit, -1)
				if region != -1:
					land_regions[region] = true
				if country != -1:
					land_countries[country] = true
		var anchored := (
			contains_saltwater
			and land_regions.size() >= minimum_region_links
			and land_countries.size() >= minimum_country_links
		)
		if anchored:
			eligible.append_array(component)
	return eligible


static func _unique_values(mapping: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for value in mapping.values():
		if not seen.has(value):
			seen[value] = true
			out.append(value)
	return out


static func _invert(child_to_group: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for child in child_to_group.keys():
		var group = child_to_group[child]
		if not out.has(group):
			out[group] = []
		(out[group] as Array).append(child)
	return out
