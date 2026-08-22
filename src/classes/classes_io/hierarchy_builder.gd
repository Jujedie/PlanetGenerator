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
const LAND_REGIONS_PER_COUNTRY: float = 22.0
const LAND_COUNTRIES_PER_CONTINENT: float = 16.0
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


## Dérive les niveaux terrestres de la surface physique. Le nombre de
## départements effectivement lu ne sert que de borne de capacité : augmenter
## la résolution ne doit jamais multiplier régions, pays et continents.
static func compute_land_hierarchy_targets(department_count: int,
		settings: Dictionary = {}) -> Dictionary:
	var departments := maxi(department_count, 1)
	# department_count * 20 reproduit uniquement la borne de capacité interne
	# (au moins 20 texels par unité) sans faire dépendre la cible de ce nombre.
	var physical := compute_physical_targets(settings, false, departments * 20)
	var regions := clampi(int(physical["regions"]), 1, departments)
	var regions_per_country := float(physical["middle_ratio"])
	var countries_per_continent := float(physical["top_ratio"])
	var countries := clampi(int(physical["middle"]), 1, regions)
	var continents := clampi(int(physical["top"]), 1, countries)
	# Si la capacité réelle contient moins d'unités que la cible physique, les
	# deux niveaux supérieurs doivent eux aussi être recalculés depuis le nombre
	# de régions encore disponible.
	if regions < int(physical["regions"]):
		countries = clampi(
			int(round(float(regions) / maxf(regions_per_country, 2.0))), 1, regions
		)
		continents = clampi(
			int(round(float(countries) / maxf(countries_per_continent, 2.0))),
			1, countries
		)
	return {
		"surface_km2": float(physical["surface_km2"]),
		"departments": departments,
		"regions": regions,
		"middle": countries,
		"top": continents,
		"departments_per_region": float(departments) / float(maxi(regions, 1)),
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
	var surface_km2 := float(targets["surface_km2"])
	var total_land_weight := float(_sum_weights(depts, weights))
	var max_region_factor := clampf(float(settings.get(
		"admin_max_region_area_factor", 2.5
	)), 1.5, 4.0)
	var max_country_factor := clampf(float(settings.get(
		"admin_max_country_area_factor", 2.5
	)), 1.5, 4.0)
	var min_continent_fraction := clampf(float(settings.get(
		"admin_min_continent_area_fraction", 0.55
	)), 0.15, 0.75)

	# Une île proche peut rejoindre une zone côtière. Une composante réellement
	# éloignée reste indépendante, conformément à la règle des petites enclaves.
	var region_bridge_km := 1.8 * sqrt(surface_km2 / float(target_regions))
	print("    %d départements terrestres" % depts.size())
	var dept_to_region := _stable_nearest_groups(
		depts, adjacency, coords, weights, target_regions, w, h, radius_km,
		region_bridge_km, false, gen
	)
	dept_to_region = _split_oversized_groups(
		dept_to_region, adjacency, coords, weights,
		total_land_weight / float(target_regions), max_region_factor,
		w, h, radius_km, gen
	)
	print("    → %d régions" % _unique_values(dept_to_region).size())
	print("      tailles régions: ", measure_group_weights(dept_to_region, weights))

	var region_ids := _unique_values(dept_to_region)
	# Les niveaux supérieurs sont recalculés depuis le nombre effectivement
	# obtenu après la borne de taille, pas depuis le nombre théorique initial.
	var target_countries := clampi(int(round(
		float(region_ids.size()) / float(targets["regions_per_country"])
	)), 1, region_ids.size())
	var country_bridge_km := 2.6 * sqrt(surface_km2 / float(target_countries))
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
	region_to_country = _split_oversized_groups(
		region_to_country, region_adjacency, region_coords, region_weights,
		total_land_weight / float(target_countries), max_country_factor,
		w, h, radius_km, gen
	)
	print("    → %d pays" % _unique_values(region_to_country).size())
	print("      tailles pays: ", measure_group_weights(region_to_country, region_weights))

	var country_ids := _unique_values(region_to_country)
	var target_continents := clampi(int(round(
		float(country_ids.size()) / float(targets["countries_per_continent"])
	)), 1, country_ids.size())
	var continent_bridge_km := 4.0 * sqrt(surface_km2 / float(target_continents))
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
	# Un continent minuscule n'est pas un niveau administratif pertinent. Les
	# continents sous la fraction minimale de la taille physique cible rejoignent
	# le continent
	# valide initialement le plus proche. Les centres ne bougent jamais pendant
	# cette affectation, ce qui évite toute croissance opportuniste.
	country_to_continent = _merge_undersized_groups(
		country_to_continent, country_info[0], country_info[1], w, h,
		(total_land_weight / float(target_continents)) * min_continent_fraction
	)
	print("    → %d continents" % _unique_values(country_to_continent).size())
	print("      tailles continents: ", measure_group_weights(
		country_to_continent, country_info[1]
	))

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
## composantes marines reliées à une zone terrestre valide montent
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
		print("    %d départements maritimes, aucun ancrage terrestre valide" % all_depts.size())
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
		-1.0, true, gen, 1
	)
	print("    → %d régions-mer" % _unique_values(dept_to_region).size())

	var region_ids := _unique_values(dept_to_region)
	var region_children := _invert(dept_to_region)
	var region_adjacency := _adj_children(region_ids, region_children, adjacency)
	var region_info := _aggregate_geometry(region_ids, region_children, coords, weights, w)
	# Une composante qui ne possède pas au moins trois régions maritimes reste
	# au niveau régional. Elle ne peut donc pas fabriquer un bassin puis un océan
	# uniquement parce qu'elle est séparée du réseau marin principal.
	var basin_eligible_regions := _units_in_components_at_least(
		region_ids, region_adjacency, 3
	)
	if basin_eligible_regions.is_empty():
		print("    → 0 bassins (composantes trop petites)")
		print("    → 0 océans")
		return [dept_to_region, {}, {}]
	var region_to_basin := _stable_nearest_groups(
		basin_eligible_regions, region_adjacency, region_info[0], region_info[1],
		mini(target_basins, basin_eligible_regions.size()), w, h, radius_km,
		-1.0, true, gen, 1
	)
	print("    → %d bassins" % _unique_values(region_to_basin).size())

	var basin_ids := _unique_values(region_to_basin)
	var basin_children := _invert(region_to_basin)
	var basin_adjacency := _adj_children(basin_ids, basin_children, region_adjacency)
	var basin_info := _aggregate_geometry(
		basin_ids, basin_children, region_info[0], region_info[1], w
	)
	# Même règle au niveau supérieur : au moins deux bassins continus sont
	# nécessaires pour constituer une entité d'échelle océanique.
	var ocean_eligible_basins := _units_in_components_at_least(
		basin_ids, basin_adjacency, 2
	)
	if ocean_eligible_basins.is_empty():
		print("    → 0 océans (bassins trop petits)")
		var only_dept_to_basin: Dictionary = {}
		for dept in eligible:
			var local_region: int = dept_to_region.get(dept, -1)
			var local_basin: int = region_to_basin.get(local_region, -1)
			if local_basin != -1:
				only_dept_to_basin[dept] = local_basin
		return [dept_to_region, only_dept_to_basin, {}]
	var basin_to_ocean := _stable_nearest_groups(
		ocean_eligible_basins, basin_adjacency, basin_info[0], basin_info[1],
		mini(target_oceans, ocean_eligible_basins.size()), w, h, radius_km,
		-1.0, true, gen, 1
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


## Statistiques exprimées dans le poids physique des enfants (nombre de
## cellules au niveau départemental). Utilisées par les régressions pour
## détecter les régions/pays extrêmes et les continents trop petits.
static func measure_group_weights(mapping: Dictionary,
		child_weights: Dictionary = {}) -> Dictionary:
	if mapping.is_empty():
		return {"count": 0, "mean": 0.0, "min": 0, "median": 0, "p95": 0, "max": 0}
	var totals: Dictionary = {}
	for child in mapping.keys():
		var group = mapping[child]
		totals[group] = int(totals.get(group, 0)) + maxi(
			int(child_weights.get(child, 1)), 1
		)
	var sizes: Array = totals.values()
	sizes.sort()
	var total := 0
	for size in sizes:
		total += int(size)
	var mean := float(total) / float(maxi(sizes.size(), 1))
	return {
		"count": sizes.size(),
		"mean": mean,
		"min": int(sizes[0]),
		"median": int(sizes[int(floor(float(sizes.size() - 1) * 0.50))]),
		"p95": int(sizes[int(floor(float(sizes.size() - 1) * 0.95))]),
		"max": int(sizes[-1]),
		"min_to_mean": float(sizes[0]) / maxf(mean, 1.0),
		"max_to_mean": float(sizes[-1]) / maxf(mean, 1.0),
	}


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
		keep_components_separate: bool, gen: Array,
		component_seed_floor: int = 1) -> Dictionary:
	if units.is_empty():
		return {}
	var components := _connected_components(units, adjacency)
	var seed_target := clampi(target_count, 1, units.size())
	if keep_components_separate:
		var required_component_seeds := 0
		for component in components:
			required_component_seeds += mini(
				maxi(component_seed_floor, 1), (component as Array).size()
			)
		seed_target = mini(units.size(), maxi(seed_target, required_component_seeds))
	var seeds := _select_fixed_seeds(
		units, components, coords, weights, seed_target, w, h,
		keep_components_separate, component_seed_floor
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
		w: int, h: int, keep_components_separate: bool,
		component_seed_floor: int = 1) -> Array:
	if units.is_empty() or components.is_empty():
		return []

	# Le quota de graines est calculé séparément pour chaque masse terrestre.
	# Auparavant, une graine choisie sur le continent principal pouvait priver un
	# autre grand continent de toute graine : celui-ci devenait alors une seule
	# région ou un seul pays gigantesque. La répartition proportionnelle à la
	# surface réelle des enfants borne ce phénomène sans déplacer les références.
	var effective_target := clampi(target_count, 1, units.size())
	var component_reservations: Array = []
	var reserved := 0
	for component in components:
		var reservation := 0
		if keep_components_separate:
			reservation = mini(
				maxi(component_seed_floor, 1), (component as Array).size()
			)
		component_reservations.append(reservation)
		reserved += reservation
	if keep_components_separate:
		effective_target = mini(units.size(), maxi(effective_target, reserved))
	var component_weights: Array = []
	var total_weight := 0.0
	for component in components:
		var component_weight := float(_sum_weights(component, weights))
		component_weights.append(component_weight)
		total_weight += component_weight
	total_weight = maxf(total_weight, 1.0)

	var quotas: Array = []
	var remainders: Array = []
	var allocated := 0
	var distributable := maxi(effective_target - reserved, 0)
	for index in range(components.size()):
		var exact := float(distributable) * float(component_weights[index]) / total_weight
		var quota := int(floor(exact)) + int(component_reservations[index])
		quota = mini(quota, (components[index] as Array).size())
		quotas.append(quota)
		remainders.append(exact - floor(exact))
		allocated += quota

	# Méthode des plus forts restes. Le score de poids départage les fractions
	# identiques et garantit que les grandes composantes sont servies d'abord.
	while allocated < effective_target:
		var best_index := -1
		var best_remainder := -INF
		var best_weight := -1.0
		for index in range(components.size()):
			if int(quotas[index]) >= (components[index] as Array).size():
				continue
			var remainder := float(remainders[index])
			var component_weight := float(component_weights[index])
			if remainder > best_remainder or (
					is_equal_approx(remainder, best_remainder)
					and component_weight > best_weight):
				best_index = index
				best_remainder = remainder
				best_weight = component_weight
		if best_index == -1:
			break
		quotas[best_index] = int(quotas[best_index]) + 1
		# Un plus fort reste ne reçoit qu'une unité. Si des places demeurent à
		# cause de composantes saturées, un nouveau tour pondé les distribue.
		remainders[best_index] = -1.0
		allocated += 1

	var seeds: Array = []
	for index in range(components.size()):
		seeds.append_array(_select_component_seeds(
			components[index], int(quotas[index]), coords, weights, w, h
		))
	return seeds


static func _select_component_seeds(component: Array, quota: int,
		coords: Dictionary, weights: Dictionary, w: int, h: int) -> Array:
	if component.is_empty() or quota <= 0:
		return []
	var first := _representative(component, coords, weights, w)
	var seeds: Array = [first]
	var selected := {first: true}
	var nearest_distance: Dictionary = {}
	var first_position: Vector2 = coords.get(first, Vector2.ZERO)
	for unit in component:
		nearest_distance[unit] = _map_distance_squared(
			coords.get(unit, Vector2.ZERO), first_position, w, h
		)

	while seeds.size() < mini(quota, component.size()):
		var best_unit: int = -1
		var best_score := -1.0
		for unit in component:
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
		for unit in component:
			if selected.has(unit):
				continue
			var candidate_distance := _map_distance_squared(
				coords.get(unit, Vector2.ZERO), best_position, w, h
			)
			if candidate_distance < float(nearest_distance[unit]):
				nearest_distance[unit] = candidate_distance
	return seeds


## Scinde les groupes qui dépassent une borne physique relative à la taille
## moyenne cible. Chaque scission refait une affectation à des graines fixes
## uniquement parmi les enfants du groupe : aucun voisin ne peut être avalé et
## les masques/continuités d'origine restent inchangés.
static func _split_oversized_groups(mapping: Dictionary, adjacency: Dictionary,
		coords: Dictionary, weights: Dictionary, target_weight: float,
		max_factor: float, w: int, h: int, radius_km: float, gen: Array) -> Dictionary:
	if mapping.is_empty() or target_weight <= 0.0:
		return mapping
	var current := mapping.duplicate()
	var maximum_weight := target_weight * max_factor
	for _pass in range(3):
		var children_by_group := _invert(current)
		var changed := false
		var next := current.duplicate()
		for group in children_by_group.keys():
			var children: Array = children_by_group[group]
			var group_weight := float(_sum_weights(children, weights))
			if group_weight <= maximum_weight or children.size() <= 1:
				continue
			var split_count := clampi(
				int(ceil(group_weight / target_weight)), 2, children.size()
			)
			var local := _stable_nearest_groups(
				children, adjacency, coords, weights, split_count,
				w, h, radius_km, -1.0, true, gen
			)
			for child in children:
				next[child] = local.get(child, group)
			changed = true
		current = next
		if not changed:
			break
	return current


## Fusionne les continents trop petits vers le continent valide initialement le
## plus proche. Les centres de référence sont calculés avant toute fusion et ne
## sont jamais recalculés pendant l'opération.
static func _merge_undersized_groups(mapping: Dictionary, unit_coords: Dictionary,
		unit_weights: Dictionary, w: int, h: int,
		minimum_weight: float) -> Dictionary:
	var group_ids := _unique_values(mapping)
	if group_ids.size() <= 1 or minimum_weight <= 0.0:
		return mapping
	var children_by_group := _invert(mapping)
	var group_info := _aggregate_geometry(
		group_ids, children_by_group, unit_coords, unit_weights, w
	)
	var group_coords: Dictionary = group_info[0]
	var group_weights: Dictionary = group_info[1]
	var valid: Array = []
	for group in group_ids:
		if float(group_weights.get(group, 0)) >= minimum_weight:
			valid.append(group)
	if valid.is_empty():
		var largest = group_ids[0]
		for group in group_ids:
			if int(group_weights.get(group, 0)) > int(group_weights.get(largest, 0)):
				largest = group
		valid.append(largest)

	var result := mapping.duplicate()
	for group in group_ids:
		if valid.has(group):
			continue
		var nearest = valid[0]
		var nearest_distance := INF
		for candidate in valid:
			var distance := _map_distance_squared(
				group_coords.get(group, Vector2.ZERO),
				group_coords.get(candidate, Vector2.ZERO), w, h
			)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = candidate
		for child in (children_by_group.get(group, []) as Array):
			result[child] = nearest
	return result


static func _sum_weights(units: Array, weights: Dictionary) -> int:
	var total := 0
	for unit in units:
		total += maxi(int(weights.get(unit, 1)), 1)
	return total


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


## Conserve intégralement les composantes qui ont assez d'unités pour porter
## le niveau hiérarchique suivant. Une petite mer demeure visible à son niveau
## courant au lieu d'être promue artificiellement jusqu'à l'échelle océanique.
static func _units_in_components_at_least(units: Array, adjacency: Dictionary,
		minimum_size: int) -> Array:
	var result: Array = []
	for component in _connected_components(units, adjacency):
		if (component as Array).size() >= minimum_size:
			result.append_array(component)
	return result


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


## Une composante maritime salée monte dans la hiérarchie lorsqu'elle touche
## au moins une zone terrestre déjà présente dans la hiérarchie. C'est la
## relation côte→terre, et non sa surface ni le nombre total de pays, qui rend
## la composante admissible. Les lacs restent exclus par le masque d'eau douce.
static func _eligible_sea_units(sea_units: Array, sea_adjacency: Dictionary,
		sea_data: PackedByteArray, land_data: PackedByteArray, w: int, h: int,
		sea_merge: Dictionary, land_merge: Dictionary,
		land_hierarchy: Array, water_mask_data: PackedByteArray) -> Array:
	if land_data.is_empty() or land_data.size() != sea_data.size() or land_hierarchy.size() < 2:
		return []
	var contacts: Dictionary = {}
	var saltwater_units: Dictionary = {}
	var valid_water_mask := water_mask_data.size() == w * h
	for y in range(h):
		for x in range(w):
			var sea_raw := sea_data.decode_u32((y * w + x) * 4)
			if sea_raw == _INVALID_ID:
				continue
			var sea_unit: int = sea_merge.get(sea_raw, sea_raw)
			if valid_water_mask and water_mask_data[y * w + x] == 1:
				saltwater_units[sea_unit] = true
			if not contacts.has(sea_unit):
				contacts[sea_unit] = {}
			# Les deux cartes de départements peuvent laisser une couture côtière
			# d'un texel après leurs nettoyages de continuité respectifs. Une bande
			# bornée à deux texels rétablit le contact réel sans franchir un lac ou
			# une étendue marine. Le wrap horizontal reste celui de la planète.
			for dy in range(-2, 3):
				var neighbor_y := y + dy
				if neighbor_y < 0 or neighbor_y >= h:
					continue
				for dx in range(-2, 3):
					if absi(dx) + absi(dy) > 2:
						continue
					var neighbor_x := posmod(x + dx, w)
					var land_raw := land_data.decode_u32(
						(neighbor_y * w + neighbor_x) * 4
					)
					if land_raw == _INVALID_ID:
						continue
					var land_unit: int = land_merge.get(land_raw, land_raw)
					(contacts[sea_unit] as Dictionary)[land_unit] = true

	var dept_to_region: Dictionary = land_hierarchy[0]
	var dept_to_country: Dictionary = land_hierarchy[1]
	var saltwater_candidates: Array = []
	for sea_unit in sea_units:
		if saltwater_units.has(sea_unit):
			saltwater_candidates.append(sea_unit)
	var eligible: Array = []
	var saltwater_components := _connected_components(saltwater_candidates, sea_adjacency)
	var anchored_components := 0
	for component in saltwater_components:
		# Une hiérarchie région→bassin→océan exige au moins trois unités
		# maritimes continues. Une crique ou un département isolé reste visible
		# au niveau local mais ne devient jamais un océan miniature.
		if component.size() < 3:
			continue
		var land_regions: Dictionary = {}
		var land_countries: Dictionary = {}
		for sea_unit in component:
			for land_unit in (contacts.get(sea_unit, {}) as Dictionary).keys():
				var region: int = dept_to_region.get(land_unit, -1)
				var country: int = dept_to_country.get(land_unit, -1)
				if region != -1:
					land_regions[region] = true
				if country != -1:
					land_countries[country] = true
		# Une seule relation administrative valide suffit : exiger plusieurs
		# pays supprimait notamment les mers bordant un grand pays. La taille
		# minimale de composante ci-dessus empêche toujours qu'un département
		# isolé devienne à lui seul région, bassin et océan.
		var anchored := not land_regions.is_empty() and not land_countries.is_empty()
		if anchored:
			anchored_components += 1
			eligible.append_array(component)
	print(
		"      ancrage maritime: masque=%s | salés=%d/%d | composantes=%d | valides=%d"
		% [
			str(valid_water_mask), saltwater_candidates.size(), sea_units.size(),
			saltwater_components.size(), anchored_components,
		]
	)
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
