class_name DepartmentNormalizer
extends RefCounted

## Deterministic post-processing for land departments.
##
## The topology is cylindrical: X wraps and Y never does.  The normalizer
## never changes the land mask.  It fills rare unassigned land remnants,
## splits disconnected uses of one ID, and absorbs genuine undersized
## leftovers into the neighbor with the strongest shared border while
## respecting a soft maximum size.

const INVALID_ID: int = 0xFFFFFFFF
const CARDINAL: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
]


static func build_land_mask(water_data: PackedByteArray,
		_geo_data: PackedByteArray, w: int, h: int,
		_sea_level: float) -> PackedByteArray:
	# The hydrology result is the authoritative surface mask. A dry depression
	# below sea_level is still solid land and must receive an administrative ID.
	# Altitude can shape borders/costs, but it must never override water_mask.
	var pixel_count := w * h
	var result := PackedByteArray()
	if water_data.size() != pixel_count:
		return result
	result.resize(pixel_count)
	for index in range(pixel_count):
		result[index] = 1 if water_data[index] == 0 else 0
	return result


static func normalize(region_data: PackedByteArray,
		land_mask: PackedByteArray, w: int, h: int,
		target_cells: float, minimum_ratio: float = 0.45,
		maximum_ratio: float = 1.85) -> Dictionary:
	var pixel_count := w * h
	if region_data.size() != pixel_count * 4 or land_mask.size() != pixel_count:
		return {}

	var output := region_data.duplicate()
	var used_ids: Dictionary = {}
	var next_id := pixel_count
	var removed_non_land := 0
	var assigned_queue: Array[int] = []
	for index in range(pixel_count):
		var region_id := int(output.decode_u32(index * 4))
		if land_mask[index] == 0:
			if region_id != INVALID_ID:
				removed_non_land += 1
			output.encode_u32(index * 4, INVALID_ID)
			continue
		if region_id != INVALID_ID:
			used_ids[region_id] = true
			next_id = maxi(next_id, region_id + 1)
			assigned_queue.append(index)

	# Extend existing departments only into genuinely unassigned land.  This is
	# a multi-source, four-connected flood: it cannot jump water and its X
	# neighbors cross the equirectangular seam.
	var filled_land := 0
	var head := 0
	while head < assigned_queue.size():
		var current := assigned_queue[head]
		head += 1
		var current_id := int(output.decode_u32(current * 4))
		var x := current % w
		var y := int(current / w)
		for offset in CARDINAL:
			var ny := y + offset.y
			if ny < 0 or ny >= h:
				continue
			var nx := posmod(x + offset.x, w)
			var neighbor := ny * w + nx
			if land_mask[neighbor] == 0:
				continue
			if int(output.decode_u32(neighbor * 4)) != INVALID_ID:
				continue
			output.encode_u32(neighbor * 4, current_id)
			filled_land += 1
			assigned_queue.append(neighbor)

	# A connected island with no seed becomes one department, rather than a
	# field of unrelated local-minimum seeds.
	var seedless_components := 0
	for start in range(pixel_count):
		if land_mask[start] == 0 or int(output.decode_u32(start * 4)) != INVALID_ID:
			continue
		while used_ids.has(next_id):
			next_id += 1
		var component_id := next_id
		next_id += 1
		used_ids[component_id] = true
		seedless_components += 1
		var frontier: Array[int] = [start]
		output.encode_u32(start * 4, component_id)
		head = 0
		while head < frontier.size():
			var current := frontier[head]
			head += 1
			var x := current % w
			var y := int(current / w)
			for offset in CARDINAL:
				var ny := y + offset.y
				if ny < 0 or ny >= h:
					continue
				var nx := posmod(x + offset.x, w)
				var neighbor := ny * w + nx
				if land_mask[neighbor] == 0:
					continue
				if int(output.decode_u32(neighbor * 4)) != INVALID_ID:
					continue
				output.encode_u32(neighbor * 4, component_id)
				filled_land += 1
				frontier.append(neighbor)

	# Label each connected use of an ID separately.  This both recognizes
	# seamless departments crossing X=0 and splits accidental disconnected IDs.
	var pixel_component := PackedInt32Array()
	pixel_component.resize(pixel_count)
	pixel_component.fill(-1)
	var component_ids: Array[int] = []
	var component_areas: Array[int] = []
	var component_min_y: Array[int] = []
	var component_max_y: Array[int] = []
	var component_sum_y: Array[float] = []
	var component_sum_cos: Array[float] = []
	var component_sum_sin: Array[float] = []
	var completed_ids: Dictionary = {}
	var split_fragments := 0

	for start in range(pixel_count):
		if land_mask[start] == 0 or pixel_component[start] != -1:
			continue
		var raw_id := int(output.decode_u32(start * 4))
		if raw_id == INVALID_ID:
			continue
		var effective_id := raw_id
		if completed_ids.has(raw_id):
			while used_ids.has(next_id):
				next_id += 1
			effective_id = next_id
			next_id += 1
			used_ids[effective_id] = true
			split_fragments += 1
		else:
			completed_ids[raw_id] = true

		var component_index := component_ids.size()
		var frontier: Array[int] = [start]
		pixel_component[start] = component_index
		head = 0
		var area := 0
		var min_y := h
		var max_y := -1
		var sum_y := 0.0
		var sum_cos := 0.0
		var sum_sin := 0.0
		while head < frontier.size():
			var current := frontier[head]
			head += 1
			var x := current % w
			var y := int(current / w)
			area += 1
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)
			sum_y += float(y)
			var angle := TAU * (float(x) + 0.5) / float(maxi(w, 1))
			sum_cos += cos(angle)
			sum_sin += sin(angle)
			for offset in CARDINAL:
				var ny := y + offset.y
				if ny < 0 or ny >= h:
					continue
				var nx := posmod(x + offset.x, w)
				var neighbor := ny * w + nx
				if pixel_component[neighbor] != -1:
					continue
				if int(output.decode_u32(neighbor * 4)) != raw_id:
					continue
				pixel_component[neighbor] = component_index
				frontier.append(neighbor)

		component_ids.append(effective_id)
		component_areas.append(area)
		component_min_y.append(min_y)
		component_max_y.append(max_y)
		component_sum_y.append(sum_y)
		component_sum_cos.append(sum_cos)
		component_sum_sin.append(sum_sin)

	var component_count := component_ids.size()
	if component_count == 0:
		return {
			"data": output,
			"removed_non_land": removed_non_land,
			"filled_land": filled_land,
			"seedless_components": seedless_components,
			"split_fragments": split_fragments,
			"merged_components": 0,
			"isolated_undersized": 0,
			"undersized_nonisolated": 0,
		}

	var parent := PackedInt32Array()
	parent.resize(component_count)
	var areas := PackedInt32Array()
	areas.resize(component_count)
	var min_ys := PackedInt32Array()
	min_ys.resize(component_count)
	var max_ys := PackedInt32Array()
	max_ys.resize(component_count)
	var sum_ys := PackedFloat64Array()
	sum_ys.resize(component_count)
	var sum_cosines := PackedFloat64Array()
	sum_cosines.resize(component_count)
	var sum_sines := PackedFloat64Array()
	sum_sines.resize(component_count)
	var adjacency: Array[Dictionary] = []
	for index in range(component_count):
		parent[index] = index
		areas[index] = component_areas[index]
		min_ys[index] = component_min_y[index]
		max_ys[index] = component_max_y[index]
		sum_ys[index] = component_sum_y[index]
		sum_cosines[index] = component_sum_cos[index]
		sum_sines[index] = component_sum_sin[index]
		adjacency.append({})

	# Every undirected contact is counted once, including X=w-1 <-> X=0.
	for y in range(h):
		for x in range(w):
			var index := y * w + x
			var component := pixel_component[index]
			if component < 0:
				continue
			var right := y * w + ((x + 1) % w)
			_add_contact(component, pixel_component[right], adjacency)
			if y + 1 < h:
				_add_contact(component, pixel_component[index + w], adjacency)

	var minimum_cells := maxi(int(ceil(target_cells * clampf(minimum_ratio, 0.0, 1.0))), 2)
	var maximum_cells := maxi(
		int(ceil(target_cells * maxf(maximum_ratio, minimum_ratio + 0.05))),
		minimum_cells + 1
	)
	var merged_components := 0
	var forced_overflow_merges := 0
	var changed := true
	while changed:
		changed = false
		var candidates: Array[int] = []
		for component in range(component_count):
			if parent[component] == component and areas[component] < minimum_cells:
				candidates.append(component)
		candidates.sort_custom(func(a: int, b: int) -> bool:
			if areas[a] == areas[b]:
				return component_ids[a] < component_ids[b]
			return areas[a] < areas[b]
		)
		for original in candidates:
			var root := _find_root(parent, original)
			if root != original:
				continue
			var neighbors := _canonical_neighbors(root, parent, adjacency)
			if neighbors.is_empty():
				continue
			var required_minimum := _local_minimum(
				root, neighbors, areas, minimum_cells
			)
			if areas[root] >= required_minimum:
				continue
			var target := _select_merge_target(
				root, neighbors, parent, areas, min_ys, max_ys,
				sum_ys, sum_cosines, sum_sines, adjacency,
				w, h, target_cells, maximum_cells, false
			)
			if target < 0 and areas[root] <= maxi(int(floor(minimum_cells * 0.5)), 2):
				target = _select_merge_target(
					root, neighbors, parent, areas, min_ys, max_ys,
					sum_ys, sum_cosines, sum_sines, adjacency,
					w, h, target_cells, maximum_cells, true
				)
				if target >= 0:
					forced_overflow_merges += 1
			if target < 0:
				continue
			_merge_root(
				root, target, parent, areas, min_ys, max_ys,
				sum_ys, sum_cosines, sum_sines, adjacency
			)
			merged_components += 1
			changed = true

	var isolated_undersized := 0
	var undersized_nonisolated := 0
	var locally_consistent_undersized := 0
	var oversized := 0
	var extreme_oversized := 0
	var final_sizes: Array[int] = []
	for component in range(component_count):
		if parent[component] != component:
			continue
		final_sizes.append(areas[component])
		var neighbors := _canonical_neighbors(component, parent, adjacency)
		if areas[component] < minimum_cells:
			if neighbors.is_empty():
				isolated_undersized += 1
			elif areas[component] < _local_minimum(
					component, neighbors, areas, minimum_cells
			):
				undersized_nonisolated += 1
			else:
				locally_consistent_undersized += 1
		if areas[component] > maximum_cells:
			oversized += 1
		if areas[component] > int(ceil(float(maximum_cells) * 1.5)):
			extreme_oversized += 1

	# Retain the target root's stable ID.  All cells in a merged department are
	# rewritten, so subsequent adjacency and hierarchy scans see one component.
	for index in range(pixel_count):
		if land_mask[index] == 0:
			output.encode_u32(index * 4, INVALID_ID)
			continue
		var component := pixel_component[index]
		if component < 0:
			output.encode_u32(index * 4, INVALID_ID)
			continue
		var root := _find_root(parent, component)
		output.encode_u32(index * 4, component_ids[root])

	return {
		"data": output,
		"removed_non_land": removed_non_land,
		"filled_land": filled_land,
		"seedless_components": seedless_components,
		"split_fragments": split_fragments,
		"merged_components": merged_components,
		"forced_overflow_merges": forced_overflow_merges,
		"minimum_cells": minimum_cells,
		"maximum_cells": maximum_cells,
		"isolated_undersized": isolated_undersized,
		"undersized_nonisolated": undersized_nonisolated,
		"locally_consistent_undersized": locally_consistent_undersized,
		"oversized": oversized,
		"extreme_oversized": extreme_oversized,
		"final_count": final_sizes.size(),
	}


static func _add_contact(a: int, b: int,
		adjacency: Array[Dictionary]) -> void:
	if a < 0 or b < 0 or a == b:
		return
	adjacency[a][b] = int(adjacency[a].get(b, 0)) + 1
	adjacency[b][a] = int(adjacency[b].get(a, 0)) + 1


static func _find_root(parent: PackedInt32Array, component: int) -> int:
	var root := component
	while parent[root] != root:
		root = parent[root]
	return root


static func _canonical_neighbors(root: int, parent: PackedInt32Array,
		adjacency: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {}
	for raw_neighbor in adjacency[root].keys():
		var neighbor := _find_root(parent, int(raw_neighbor))
		if neighbor == root:
			continue
		result[neighbor] = int(result.get(neighbor, 0)) + int(
			adjacency[root][raw_neighbor]
		)
	return result


static func _local_minimum(root: int, neighbors: Dictionary,
		areas: PackedInt32Array, global_minimum: int) -> int:
	var nearby_sizes: Array[int] = []
	for neighbor in neighbors.keys():
		nearby_sizes.append(areas[int(neighbor)])
	if nearby_sizes.is_empty():
		return global_minimum
	nearby_sizes.sort()
	var local_median := nearby_sizes[int((nearby_sizes.size() - 1) / 2)]
	# On a naturally small island/coastal pocket, comparable neighbors lower the
	# floor modestly.  A dramatic outlier beside normal departments still uses
	# the configured global minimum.
	return mini(global_minimum, maxi(int(ceil(float(local_median) * 0.55)), 2))


static func _select_merge_target(root: int, neighbors: Dictionary,
		parent: PackedInt32Array, areas: PackedInt32Array,
		min_ys: PackedInt32Array, max_ys: PackedInt32Array,
		sum_ys: PackedFloat64Array, sum_cosines: PackedFloat64Array,
		sum_sines: PackedFloat64Array, adjacency: Array[Dictionary],
		w: int, h: int, target_cells: float, maximum_cells: int,
		allow_overflow: bool) -> int:
	var best := -1
	var best_contact := -1
	var best_shape := INF
	var best_target_delta := INF
	for raw_candidate in neighbors.keys():
		var candidate := _find_root(parent, int(raw_candidate))
		if candidate == root:
			continue
		var combined := areas[root] + areas[candidate]
		if not allow_overflow and combined > maximum_cells:
			continue
		var contact := int(neighbors[raw_candidate])
		var vertical_span := maxi(max_ys[root], max_ys[candidate]) - mini(
			min_ys[root], min_ys[candidate]
		) + 1
		var equivalent_diameter := maxf(2.0 * sqrt(float(combined) / PI), 1.0)
		var shape_score := float(vertical_span) / equivalent_diameter
		shape_score += _centroid_distance(
			root, candidate, areas, sum_ys, sum_cosines, sum_sines, w, h
		) / maxf(sqrt(float(combined)), 1.0)
		var target_delta := absf(float(combined) - target_cells)
		if contact > best_contact or (
			contact == best_contact and shape_score < best_shape - 0.000001
		) or (
			contact == best_contact
			and absf(shape_score - best_shape) <= 0.000001
			and target_delta < best_target_delta - 0.000001
		) or (
			contact == best_contact
			and absf(shape_score - best_shape) <= 0.000001
			and absf(target_delta - best_target_delta) <= 0.000001
			and candidate < best
		):
			best = candidate
			best_contact = contact
			best_shape = shape_score
			best_target_delta = target_delta
	return best


static func _centroid_distance(a: int, b: int,
		areas: PackedInt32Array, sum_ys: PackedFloat64Array,
		sum_cosines: PackedFloat64Array, sum_sines: PackedFloat64Array,
		w: int, h: int) -> float:
	var angle_a := atan2(sum_sines[a], sum_cosines[a])
	var angle_b := atan2(sum_sines[b], sum_cosines[b])
	var delta_angle := absf(angle_a - angle_b)
	delta_angle = minf(delta_angle, TAU - delta_angle)
	var dx := delta_angle * float(w) / TAU
	var y_a := sum_ys[a] / float(maxi(areas[a], 1))
	var y_b := sum_ys[b] / float(maxi(areas[b], 1))
	var latitude := ((0.5 * (y_a + y_b) + 0.5) / float(maxi(h, 1)) - 0.5) * PI
	dx *= maxf(cos(latitude), 0.05)
	return Vector2(dx, y_a - y_b).length()


static func _merge_root(source: int, target: int,
		parent: PackedInt32Array, areas: PackedInt32Array,
		min_ys: PackedInt32Array, max_ys: PackedInt32Array,
		sum_ys: PackedFloat64Array, sum_cosines: PackedFloat64Array,
		sum_sines: PackedFloat64Array,
		adjacency: Array[Dictionary]) -> void:
	parent[source] = target
	areas[target] += areas[source]
	min_ys[target] = mini(min_ys[target], min_ys[source])
	max_ys[target] = maxi(max_ys[target], max_ys[source])
	sum_ys[target] += sum_ys[source]
	sum_cosines[target] += sum_cosines[source]
	sum_sines[target] += sum_sines[source]

	for raw_neighbor in adjacency[source].keys():
		var neighbor := _find_root(parent, int(raw_neighbor))
		if neighbor == target:
			adjacency[neighbor].erase(source)
			continue
		var contact := int(adjacency[source][raw_neighbor])
		adjacency[target][neighbor] = int(adjacency[target].get(neighbor, 0)) + contact
		adjacency[neighbor][target] = int(adjacency[neighbor].get(target, 0)) + contact
		adjacency[neighbor].erase(source)
	adjacency[target].erase(source)
	adjacency[target].erase(target)
	adjacency[source].clear()
