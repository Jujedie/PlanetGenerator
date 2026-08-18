extends RefCounted
class_name HydrologySolver

## Deterministic CPU reference solver used by Milestone 2.
##
## The current maps are small enough that an exact priority flood and a
## topological drainage pass are preferable to iteration-count-dependent GPU
## approximations. Milestone 3 may move these algorithms back to batched GPU
## work after their invariants have been established here.

const DIR_SINK := 255
const WATER_NONE := 0
const WATER_SALT := 1
const WATER_FRESH := 2
const WATER_MIN_TEMP := -21.0
const WATER_MAX_TEMP := 100.0
const MIN_ROUTING_EPSILON_M := 0.01

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0),                         Vector2i(1, 0),
	Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1),
]

## Builds a globally converged filled surface, identifies lakes from basin
## depth, removes sub-resolution lake components, and classifies complete water
## components with horizontal wrapping.
func solve_surface_and_water(
	geo_data: PackedByteArray,
	climate_data: PackedByteArray,
	initial_water_mask: PackedByteArray,
	width: int,
	height: int,
	sea_level: float,
	min_lake_depth_m: float,
	min_lake_cells: int,
	saltwater_min_cells: int,
	atmosphere_type: int,
) -> Dictionary:
	var pixel_count := width * height
	if (
		width <= 0
		or height <= 0
		or geo_data.size() != pixel_count * 16
		or climate_data.size() != pixel_count * 16
		or initial_water_mask.size() != pixel_count
	):
		push_error("[Hydrology] Invalid input sizes for surface solve")
		return {}

	var original := PackedFloat32Array()
	var filled := PackedFloat32Array()
	var routing_surface := PackedFloat32Array()
	var routing_parent := PackedInt32Array()
	var temperatures := PackedFloat32Array()
	original.resize(pixel_count)
	filled.resize(pixel_count)
	routing_surface.resize(pixel_count)
	routing_parent.resize(pixel_count)
	routing_parent.fill(-1)
	temperatures.resize(pixel_count)

	for index in range(pixel_count):
		var byte_offset := index * 16
		var elevation := geo_data.decode_float(byte_offset)
		original[index] = elevation
		filled[index] = elevation
		routing_surface[index] = elevation
		temperatures[index] = climate_data.decode_float(byte_offset)

	var visited := PackedByteArray()
	visited.resize(pixel_count)
	visited.fill(0)
	var heap: Array[int] = []

	# Oceans and the two polar rows are the global outlets. X remains periodic;
	# there are deliberately no artificial outlets at the left/right seam.
	for index in range(pixel_count):
		var y := index / width
		if initial_water_mask[index] > WATER_NONE or y < 2 or y >= height - 2:
			visited[index] = 1
			_heap_push(heap, filled, index)

	var visited_count := heap.size()
	while not heap.is_empty():
		var current := _heap_pop(heap, filled)
		var current_level := filled[current]
		var current_routing_level := routing_surface[current]
		for direction in range(NEIGHBORS.size()):
			var neighbor := _neighbor_index(current, direction, width, height)
			if visited[neighbor] != 0:
				continue

			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			# `filled` is the true spill surface used for lake depth. A separate
			# routing surface adds the smallest reliably representable downhill
			# gradient, avoiding cycles without inflating calculated lake depth.
			filled[neighbor] = maxf(original[neighbor], current_level)
			var routing_epsilon := maxf(
				MIN_ROUTING_EPSILON_M,
				absf(current_routing_level) * 0.000001,
			)
			routing_surface[neighbor] = maxf(
				original[neighbor],
				current_routing_level + routing_epsilon,
			)
			_heap_push(heap, filled, neighbor)

	if visited_count != pixel_count:
		push_error("[Hydrology] Priority flood did not visit the complete map")

	var candidate_mask := PackedByteArray()
	candidate_mask.resize(pixel_count)
	candidate_mask.fill(0)
	var filled_cell_count := 0
	var lake_candidate_cells := 0
	var lake_depth_threshold: float = maxf(min_lake_depth_m, MIN_ROUTING_EPSILON_M)

	for index in range(pixel_count):
		var fill_depth := filled[index] - original[index]
		if fill_depth > MIN_ROUTING_EPSILON_M:
			filled_cell_count += 1

		var liquid_temperature := (
			temperatures[index] >= WATER_MIN_TEMP
			and temperatures[index] <= WATER_MAX_TEMP
		)
		if (
			initial_water_mask[index] == WATER_NONE
			and liquid_temperature
			and fill_depth >= lake_depth_threshold
		):
			candidate_mask[index] = 1
			lake_candidate_cells += 1

	var water_mask := initial_water_mask.duplicate()
	var lake_component_stats := _retain_lake_components(
		candidate_mask,
		water_mask,
		width,
		height,
		max(min_lake_cells, 1),
	)
	var water_stats := _classify_water_components(
		water_mask,
		original,
		width,
		height,
		sea_level,
		max(saltwater_min_cells, 1),
	)
	var flow_result := _build_flow_directions(routing_parent, water_mask, width, height)

	var stats := {
		"priority_flood_visited_cells": visited_count,
		"depression_filled_cells": filled_cell_count,
		"lake_candidate_cells": lake_candidate_cells,
	}
	stats.merge(lake_component_stats, true)
	stats.merge(water_stats, true)
	stats.merge(Dictionary(flow_result["stats"]), true)

	return {
		"water_mask": water_mask,
		"water_colored": _build_water_colors(water_mask, atmosphere_type),
		"flow_direction": flow_result["flow_direction"],
		"stats": stats,
	}

## Accumulates each land cell's local precipitation exactly once along an
## acyclic D8 graph. Kahn's algorithm makes the result independent of a
## propagation-pass count and exposes any residual cycle as an invariant error.
func accumulate_flow(
	flow_direction: PackedByteArray,
	water_mask: PackedByteArray,
	local_flux_data: PackedByteArray,
	width: int,
	height: int,
) -> Dictionary:
	var pixel_count := width * height
	if (
		flow_direction.size() != pixel_count
		or water_mask.size() != pixel_count
		or local_flux_data.size() != pixel_count * 4
	):
		push_error("[Hydrology] Invalid input sizes for flow accumulation")
		return {}

	var flux := PackedFloat32Array()
	var downstream := PackedInt32Array()
	var indegree := PackedInt32Array()
	flux.resize(pixel_count)
	downstream.resize(pixel_count)
	indegree.resize(pixel_count)
	downstream.fill(-1)
	indegree.fill(0)

	var land_cells := 0
	var local_precipitation := 0.0
	var seam_flow_links := 0
	var nonpolar_land_sinks := 0

	for index in range(pixel_count):
		var local_flux: float = maxf(local_flux_data.decode_float(index * 4), 0.0)
		flux[index] = local_flux
		if water_mask[index] != WATER_NONE:
			continue

		land_cells += 1
		local_precipitation += local_flux
		var direction := int(flow_direction[index])
		if direction < 0 or direction >= NEIGHBORS.size():
			var y := index / width
			if y >= 2 and y < height - 2:
				nonpolar_land_sinks += 1
			continue

		var target := _neighbor_index(index, direction, width, height)
		downstream[index] = target
		if water_mask[target] == WATER_NONE:
			indegree[target] += 1

		var x := index % width
		var target_x := target % width
		if abs(target_x - x) > 1:
			seam_flow_links += 1

	var queue: Array[int] = []
	for index in range(pixel_count):
		if water_mask[index] == WATER_NONE and indegree[index] == 0:
			queue.append(index)

	var queue_head := 0
	var processed_land_cells := 0
	while queue_head < queue.size():
		var current := queue[queue_head]
		queue_head += 1
		processed_land_cells += 1

		var target := downstream[current]
		if target < 0:
			continue

		flux[target] += flux[current]
		if water_mask[target] == WATER_NONE:
			indegree[target] -= 1
			if indegree[target] == 0:
				queue.append(target)

	var terminal_flux := 0.0
	var max_land_flux := 0.0
	for index in range(pixel_count):
		if water_mask[index] != WATER_NONE:
			terminal_flux += flux[index]
		else:
			max_land_flux = max(max_land_flux, flux[index])
			if downstream[index] < 0:
				terminal_flux += flux[index]

	var unresolved_land_cells := land_cells - processed_land_cells
	var mass_error: float = absf(terminal_flux - local_precipitation)
	var relative_mass_error: float = mass_error / maxf(local_precipitation, 0.000001)

	var accumulated_data := PackedByteArray()
	accumulated_data.resize(pixel_count * 4)
	for index in range(pixel_count):
		accumulated_data.encode_float(index * 4, flux[index])

	return {
		"flux_data": accumulated_data,
		"max_land_flux": max_land_flux,
		"stats": {
			"land_cells": land_cells,
			"processed_land_cells": processed_land_cells,
			"unresolved_land_cells": unresolved_land_cells,
			"nonpolar_land_sinks": nonpolar_land_sinks,
			"seam_flow_links": seam_flow_links,
			"local_precipitation": local_precipitation,
			"terminal_flux": terminal_flux,
			"mass_error": mass_error,
			"relative_mass_error": relative_mass_error,
		},
	}

func _retain_lake_components(
	candidates: PackedByteArray,
	water_mask: PackedByteArray,
	width: int,
	height: int,
	minimum_size: int,
) -> Dictionary:
	var visited := PackedByteArray()
	visited.resize(candidates.size())
	visited.fill(0)
	var candidate_components := 0
	var retained_components := 0
	var retained_cells := 0
	var removed_cells := 0

	for start in range(candidates.size()):
		if candidates[start] == 0 or visited[start] != 0:
			continue

		candidate_components += 1
		var component: Array[int] = [start]
		visited[start] = 1
		var head := 0
		while head < component.size():
			var current := component[head]
			head += 1
			for direction in range(NEIGHBORS.size()):
				var neighbor := _neighbor_index(current, direction, width, height)
				if candidates[neighbor] == 0 or visited[neighbor] != 0:
					continue
				visited[neighbor] = 1
				component.append(neighbor)

		if component.size() >= minimum_size:
			retained_components += 1
			retained_cells += component.size()
			for index in component:
				water_mask[index] = WATER_FRESH
		else:
			removed_cells += component.size()

	return {
		"lake_candidate_components": candidate_components,
		"lake_components_retained": retained_components,
		"lake_cells_retained": retained_cells,
		"lake_cells_removed": removed_cells,
	}

func _classify_water_components(
	water_mask: PackedByteArray,
	original_height: PackedFloat32Array,
	width: int,
	height: int,
	sea_level: float,
	saltwater_min_cells: int,
) -> Dictionary:
	var visited := PackedByteArray()
	visited.resize(water_mask.size())
	visited.fill(0)
	var salt_components := 0
	var fresh_components := 0
	var total_water_cells := 0
	var largest_component := 0

	for start in range(water_mask.size()):
		if water_mask[start] == WATER_NONE or visited[start] != 0:
			continue

		var component: Array[int] = [start]
		visited[start] = 1
		var touches_subsea := original_height[start] < sea_level
		var head := 0
		while head < component.size():
			var current := component[head]
			head += 1
			for direction in range(NEIGHBORS.size()):
				var neighbor := _neighbor_index(current, direction, width, height)
				if water_mask[neighbor] == WATER_NONE or visited[neighbor] != 0:
					continue
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				component.append(neighbor)

		var water_type := WATER_FRESH
		if touches_subsea and component.size() >= saltwater_min_cells:
			water_type = WATER_SALT
			salt_components += 1
		else:
			fresh_components += 1

		total_water_cells += component.size()
		largest_component = max(largest_component, component.size())
		for index in component:
			water_mask[index] = water_type

	return {
		"water_components": salt_components + fresh_components,
		"saltwater_components": salt_components,
		"freshwater_components": fresh_components,
		"total_water_cells": total_water_cells,
		"largest_water_component": largest_component,
	}

func _build_water_colors(water_mask: PackedByteArray, atmosphere_type: int) -> PackedByteArray:
	var salt_color := _saltwater_color(atmosphere_type)
	var fresh_color := _freshwater_color(atmosphere_type)
	var output := PackedByteArray()
	output.resize(water_mask.size() * 4)
	output.fill(0)

	for index in range(water_mask.size()):
		var color: Array[int]
		if water_mask[index] == WATER_SALT:
			color = salt_color
		elif water_mask[index] == WATER_FRESH:
			color = fresh_color
		else:
			continue

		var offset := index * 4
		output[offset] = color[0]
		output[offset + 1] = color[1]
		output[offset + 2] = color[2]
		output[offset + 3] = 255

	return output

func _build_flow_directions(
	routing_parent: PackedInt32Array,
	water_mask: PackedByteArray,
	width: int,
	height: int,
) -> Dictionary:
	var flow_direction := PackedByteArray()
	flow_direction.resize(routing_parent.size())
	flow_direction.fill(DIR_SINK)
	var invalid_parents := 0
	var seam_links := 0

	for index in range(routing_parent.size()):
		if water_mask[index] != WATER_NONE:
			continue
		var y := index / width
		if y < 2 or y >= height - 2:
			continue

		var parent := int(routing_parent[index])
		if parent < 0:
			invalid_parents += 1
			continue

		var direction := _direction_between_neighbors(index, parent, width)
		if direction < 0:
			invalid_parents += 1
			continue

		flow_direction[index] = direction
		if abs((parent % width) - (index % width)) > 1:
			seam_links += 1

	return {
		"flow_direction": flow_direction,
		"stats": {
			"routing_invalid_parents": invalid_parents,
			"routing_seam_links": seam_links,
		},
	}

func _direction_between_neighbors(index: int, target: int, width: int) -> int:
	var x := index % width
	var y := index / width
	var target_x := target % width
	var target_y := target / width
	var dx := target_x - x
	if dx > 1:
		dx = -1
	elif dx < -1:
		dx = 1
	var offset := Vector2i(dx, target_y - y)
	return NEIGHBORS.find(offset)

func _saltwater_color(atmosphere_type: int) -> Array[int]:
	match atmosphere_type:
		1: return [50, 155, 131]
		2: return [214, 150, 23]
		4: return [73, 121, 74]
		_: return [37, 82, 138]

func _freshwater_color(atmosphere_type: int) -> Array[int]:
	match atmosphere_type:
		1: return [72, 214, 59]
		2: return [183, 73, 14]
		4: return [97, 159, 99]
		_: return [69, 132, 210]

func _neighbor_index(index: int, direction: int, width: int, height: int) -> int:
	var x := index % width
	var y := index / width
	var offset := NEIGHBORS[direction]
	var nx := posmod(x + offset.x, width)
	var ny := clampi(y + offset.y, 0, height - 1)
	return ny * width + nx

func _heap_push(heap: Array[int], priorities: PackedFloat32Array, index: int) -> void:
	heap.append(index)
	var position := heap.size() - 1
	while position > 0:
		var parent := (position - 1) / 2
		if not _has_higher_priority(heap[position], heap[parent], priorities):
			break
		var temporary := heap[parent]
		heap[parent] = heap[position]
		heap[position] = temporary
		position = parent

func _heap_pop(heap: Array[int], priorities: PackedFloat32Array) -> int:
	var result := heap[0]
	var last: int = heap.pop_back()
	if heap.is_empty():
		return result

	heap[0] = last
	var position := 0
	while true:
		var left := position * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var best := left
		if right < heap.size() and _has_higher_priority(heap[right], heap[left], priorities):
			best = right
		if not _has_higher_priority(heap[best], heap[position], priorities):
			break
		var temporary := heap[position]
		heap[position] = heap[best]
		heap[best] = temporary
		position = best

	return result

func _has_higher_priority(first: int, second: int, priorities: PackedFloat32Array) -> bool:
	var first_level := priorities[first]
	var second_level := priorities[second]
	return first_level < second_level or (first_level == second_level and first < second)
