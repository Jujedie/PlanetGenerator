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
# Integer D8 offsets used in the hot loops. Keeping these separate avoids
# allocating/accessing Vector2i values millions of times during hydrology.
const NEIGHBOR_DX: Array[int] = [-1, 0, 1, -1, 1, -1, 0, 1]
const NEIGHBOR_DY: Array[int] = [-1, -1, -1, 0, 0, 1, 1, 1]

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
	var solve_start_usec: int = Time.get_ticks_usec()
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

	# Only the original and filled surfaces are required. The previous
	# routing_surface duplicated another float per pixel solely to manufacture a
	# downhill epsilon. routing_parent already is a tree by construction, so it
	# cannot contain a cycle and needs no synthetic elevation gradient.
	var original := PackedFloat32Array()
	var filled := PackedFloat32Array()
	var routing_parent := PackedInt32Array()
	original.resize(pixel_count)
	filled.resize(pixel_count)
	routing_parent.resize(pixel_count)
	routing_parent.fill(-1)

	for index in range(pixel_count):
		var elevation := geo_data.decode_float(index * 16)
		original[index] = elevation
		filled[index] = elevation
	var decode_ms: float = float(Time.get_ticks_usec() - solve_start_usec) / 1000.0

	var flood_start_usec: int = Time.get_ticks_usec()
	var visited := PackedByteArray()
	visited.resize(pixel_count)
	visited.fill(0)
	var visited_count := 0

	# Mark all global outlets first. Initial ocean cells are independent outlets,
	# and the polar rows deliberately remain open. Unlike the old implementation,
	# we do NOT insert every ocean pixel into the heap: an interior water pixel
	# can never discover land because all water pixels are already marked visited.
	for y in range(height):
		var row := y * width
		var polar_outlet := y < 2 or y >= height - 2
		for x in range(width):
			var index := row + x
			if initial_water_mask[index] > WATER_NONE or polar_outlet:
				visited[index] = 1
				visited_count += 1

	# Only outlet cells touching an unvisited cell need to enter the priority
	# queue. On an Earth-like planet this changes the initial heap from tens or
	# hundreds of thousands of ocean pixels to roughly the shoreline length.
	# Fixed-size packed storage removes the Variant-heavy Array[int] churn from
	# the hottest Priority-Flood path. The effective heap size is tracked
	# separately, so no resize/pop allocation occurs while preserving exactly the
	# same (elevation, pixel-index) ordering as the previous binary heap.
	var heap := PackedInt32Array()
	heap.resize(pixel_count)
	var heap_size := 0
	# Scan whichever side of the visited/unvisited boundary is smaller. Both
	# branches produce exactly the same set of outlet frontier pixels. On
	# ocean-heavy planets this avoids probing eight neighbors for every ocean
	# pixel just to recover a shoreline-sized frontier.
	if visited_count * 2 > pixel_count:
		var frontier_added := PackedByteArray()
		frontier_added.resize(pixel_count)
		frontier_added.fill(0)
		for y in range(height):
			var row := y * width
			for x in range(width):
				var index := row + x
				if visited[index] != 0:
					continue
				for direction in range(8):
					var nx := x + NEIGHBOR_DX[direction]
					if nx < 0:
						nx += width
					elif nx >= width:
						nx -= width
					var ny := y + NEIGHBOR_DY[direction]
					if ny < 0:
						ny = 0
					elif ny >= height:
						ny = height - 1
					var outlet := ny * width + nx
					if visited[outlet] == 0 or frontier_added[outlet] != 0:
						continue
					frontier_added[outlet] = 1
					_heap_push_fixed(heap, heap_size, filled, outlet)
					heap_size += 1
	else:
		for y in range(height):
			var row := y * width
			for x in range(width):
				var index := row + x
				if visited[index] == 0:
					continue
				var is_frontier := false
				for direction in range(8):
					var nx := x + NEIGHBOR_DX[direction]
					if nx < 0:
						nx += width
					elif nx >= width:
						nx -= width
					var ny := y + NEIGHBOR_DY[direction]
					if ny < 0:
						ny = 0
					elif ny >= height:
						ny = height - 1
					if visited[ny * width + nx] == 0:
						is_frontier = true
						break
				if is_frontier:
					_heap_push_fixed(heap, heap_size, filled, index)
					heap_size += 1

	var outlet_frontier_cells := heap_size

	# Optimized Priority-Flood (Barnes-style pit queue): cells lying at or below
	# the current spill elevation belong to the same depression and can be
	# processed FIFO. A preallocated PackedInt32Array keeps this queue numeric and
	# allocation-free. Only terrain rising above the spill level needs O(log N)
	# heap work. The resulting filled surface is still exact and deterministic.
	var pit_queue := PackedInt32Array()
	pit_queue.resize(pixel_count)
	var pit_head := 0
	var pit_tail := 0
	var heap_pop_count := 0
	var pit_pop_count := 0
	while heap_size > 0 or pit_head < pit_tail:
		var current: int
		if pit_head < pit_tail:
			current = pit_queue[pit_head]
			pit_head += 1
			pit_pop_count += 1
		else:
			# The queue storage is reused rather than cleared/reallocated.
			pit_head = 0
			pit_tail = 0
			current = _heap_pop_fixed(heap, heap_size, filled)
			heap_size -= 1
			heap_pop_count += 1

		var current_level := filled[current]
		var current_x := current % width
		var current_y := current / width
		for direction in range(8):
			var nx := current_x + NEIGHBOR_DX[direction]
			if nx < 0:
				nx += width
			elif nx >= width:
				nx -= width
			var ny := current_y + NEIGHBOR_DY[direction]
			if ny < 0:
				ny = 0
			elif ny >= height:
				ny = height - 1
			var neighbor := ny * width + nx
			if visited[neighbor] != 0:
				continue

			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			var neighbor_level := original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				_heap_push_fixed(heap, heap_size, filled, neighbor)
				heap_size += 1

	if visited_count != pixel_count:
		push_error("[Hydrology] Priority flood did not visit the complete map")
	var priority_flood_ms: float = float(Time.get_ticks_usec() - flood_start_usec) / 1000.0

	var candidate_start_usec: int = Time.get_ticks_usec()
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

		# Ocean cells can never become lake candidates. Skip their climate decode;
		# on ocean-heavy planets this avoids decoding most climate pixels here.
		if initial_water_mask[index] != WATER_NONE:
			continue
		var temperature := climate_data.decode_float(index * 16)
		var liquid_temperature := temperature >= WATER_MIN_TEMP and temperature <= WATER_MAX_TEMP
		if liquid_temperature and fill_depth >= lake_depth_threshold:
			candidate_mask[index] = 1
			lake_candidate_cells += 1
	var candidate_ms: float = float(Time.get_ticks_usec() - candidate_start_usec) / 1000.0

	var water_mask := initial_water_mask.duplicate()
	var lake_components_start_usec: int = Time.get_ticks_usec()
	var lake_component_stats := _retain_lake_components(
		candidate_mask,
		water_mask,
		width,
		height,
		max(min_lake_cells, 1),
	)
	var lake_components_ms: float = float(Time.get_ticks_usec() - lake_components_start_usec) / 1000.0

	var water_components_start_usec: int = Time.get_ticks_usec()
	var water_stats := _classify_water_components(
		water_mask,
		original,
		width,
		height,
		sea_level,
		max(saltwater_min_cells, 1),
	)
	var water_components_ms: float = float(Time.get_ticks_usec() - water_components_start_usec) / 1000.0

	var flow_start_usec: int = Time.get_ticks_usec()
	var flow_result := _build_flow_directions(routing_parent, water_mask, width, height)
	var flow_direction_ms: float = float(Time.get_ticks_usec() - flow_start_usec) / 1000.0

	var color_start_usec: int = Time.get_ticks_usec()
	var water_colored := _build_water_colors(water_mask, atmosphere_type)
	var water_color_ms: float = float(Time.get_ticks_usec() - color_start_usec) / 1000.0
	var surface_total_ms: float = float(Time.get_ticks_usec() - solve_start_usec) / 1000.0

	var stats := {
		"priority_flood_visited_cells": visited_count,
		"priority_flood_outlet_frontier_cells": outlet_frontier_cells,
		"priority_flood_heap_pops": heap_pop_count,
		"priority_flood_pit_pops": pit_pop_count,
		"depression_filled_cells": filled_cell_count,
		"lake_candidate_cells": lake_candidate_cells,
		"surface_decode_ms": decode_ms,
		"priority_flood_ms": priority_flood_ms,
		"lake_candidate_ms": candidate_ms,
		"lake_components_ms": lake_components_ms,
		"water_components_ms": water_components_ms,
		"flow_direction_ms": flow_direction_ms,
		"water_color_ms": water_color_ms,
		"surface_total_ms": surface_total_ms,
	}
	stats.merge(lake_component_stats, true)
	stats.merge(water_stats, true)
	stats.merge(Dictionary(flow_result["stats"]), true)

	return {
		"water_mask": water_mask,
		"water_colored": water_colored,
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

		# Inline the only _neighbor_index() hot-path call. This loop runs once for
		# every land pixel and the helper previously repeated modulo/division plus a
		# GDScript function call for each one.
		var x := index % width
		var y := int(index / width)
		var target_x := x + NEIGHBOR_DX[direction]
		if target_x < 0:
			target_x += width
		elif target_x >= width:
			target_x -= width
		var target_y := y + NEIGHBOR_DY[direction]
		if target_y < 0:
			target_y = 0
		elif target_y >= height:
			target_y = height - 1
		var target := target_y * width + target_x
		downstream[index] = target
		if water_mask[target] == WATER_NONE:
			indegree[target] += 1

		if abs(target_x - x) > 1:
			seam_flow_links += 1

	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var queue_tail := 0
	for index in range(pixel_count):
		if water_mask[index] == WATER_NONE and indegree[index] == 0:
			queue[queue_tail] = index
			queue_tail += 1

	var queue_head := 0
	var processed_land_cells := 0
	while queue_head < queue_tail:
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
				queue[queue_tail] = target
				queue_tail += 1

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
	var queue := PackedInt32Array()
	queue.resize(candidates.size())
	var candidate_components := 0
	var retained_components := 0
	var retained_cells := 0
	var removed_cells := 0

	for start in range(candidates.size()):
		if candidates[start] == 0 or visited[start] != 0:
			continue

		candidate_components += 1
		var head := 0
		var tail := 1
		queue[0] = start
		visited[start] = 1
		while head < tail:
			var current := queue[head]
			head += 1
			var current_x := current % width
			var current_y := current / width
			for direction in range(8):
				var nx := current_x + NEIGHBOR_DX[direction]
				if nx < 0:
					nx += width
				elif nx >= width:
					nx -= width
				var ny := current_y + NEIGHBOR_DY[direction]
				if ny < 0:
					ny = 0
				elif ny >= height:
					ny = height - 1
				var neighbor := ny * width + nx
				if candidates[neighbor] == 0 or visited[neighbor] != 0:
					continue
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1

		if tail >= minimum_size:
			retained_components += 1
			retained_cells += tail
			for queue_index in range(tail):
				water_mask[queue[queue_index]] = WATER_FRESH
		else:
			removed_cells += tail

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
	var queue := PackedInt32Array()
	queue.resize(water_mask.size())
	var salt_components := 0
	var fresh_components := 0
	var total_water_cells := 0
	var largest_component := 0

	for start in range(water_mask.size()):
		if water_mask[start] == WATER_NONE or visited[start] != 0:
			continue

		var head := 0
		var tail := 1
		queue[0] = start
		visited[start] = 1
		var touches_subsea := original_height[start] < sea_level
		while head < tail:
			var current := queue[head]
			head += 1
			var current_x := current % width
			var current_y := current / width
			for direction in range(8):
				var nx := current_x + NEIGHBOR_DX[direction]
				if nx < 0:
					nx += width
				elif nx >= width:
					nx -= width
				var ny := current_y + NEIGHBOR_DY[direction]
				if ny < 0:
					ny = 0
				elif ny >= height:
					ny = height - 1
				var neighbor := ny * width + nx
				if water_mask[neighbor] == WATER_NONE or visited[neighbor] != 0:
					continue
				visited[neighbor] = 1
				if original_height[neighbor] < sea_level:
					touches_subsea = true
				queue[tail] = neighbor
				tail += 1

		var water_type := WATER_FRESH
		if touches_subsea and tail >= saltwater_min_cells:
			water_type = WATER_SALT
			salt_components += 1
		else:
			fresh_components += 1

		total_water_cells += tail
		largest_component = max(largest_component, tail)
		for queue_index in range(tail):
			water_mask[queue[queue_index]] = water_type

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
	var salt_r := int(salt_color[0])
	var salt_g := int(salt_color[1])
	var salt_b := int(salt_color[2])
	var fresh_r := int(fresh_color[0])
	var fresh_g := int(fresh_color[1])
	var fresh_b := int(fresh_color[2])
	var output := PackedByteArray()
	output.resize(water_mask.size() * 4)
	output.fill(0)

	for index in range(water_mask.size()):
		var water_type := int(water_mask[index])
		if water_type == WATER_NONE:
			continue
		var offset := index * 4
		if water_type == WATER_SALT:
			output[offset] = salt_r
			output[offset + 1] = salt_g
			output[offset + 2] = salt_b
		else:
			output[offset] = fresh_r
			output[offset + 1] = fresh_g
			output[offset + 2] = fresh_b
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
		var y := int(index / width)
		if y < 2 or y >= height - 2:
			continue

		var parent := int(routing_parent[index])
		if parent < 0:
			invalid_parents += 1
			continue

		# Inline direction decoding so X/Y modulo/division is performed once per
		# land pixel instead of once in the helper and again for seam statistics.
		var x := index % width
		var parent_x := parent % width
		var parent_y := int(parent / width)
		var dx := parent_x - x
		if dx > 1:
			dx = -1
		elif dx < -1:
			dx = 1
		var dy := parent_y - y
		var direction := -1
		if dy == -1 and dx >= -1 and dx <= 1:
			direction = dx + 1
		elif dy == 0:
			if dx == -1:
				direction = 3
			elif dx == 1:
				direction = 4
		elif dy == 1 and dx >= -1 and dx <= 1:
			direction = dx + 6
		if direction < 0:
			invalid_parents += 1
			continue

		flow_direction[index] = direction
		if abs(parent_x - x) > 1:
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
	var dy := target_y - y
	if dy == -1:
		return dx + 1 if dx >= -1 and dx <= 1 else -1
	if dy == 0:
		if dx == -1:
			return 3
		if dx == 1:
			return 4
		return -1
	if dy == 1:
		return dx + 6 if dx >= -1 and dx <= 1 else -1
	return -1

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
	var nx := x + NEIGHBOR_DX[direction]
	if nx < 0:
		nx += width
	elif nx >= width:
		nx -= width
	var ny := y + NEIGHBOR_DY[direction]
	if ny < 0:
		ny = 0
	elif ny >= height:
		ny = height - 1
	return ny * width + nx

func _heap_push_fixed(
	heap: PackedInt32Array,
	heap_size: int,
	priorities: PackedFloat32Array,
	index: int,
) -> void:
	# 4-ary heap: half the tree depth of the old binary heap. Keep the inserted
	# value in registers and move parents down, instead of swapping/reloading the
	# child at every level. Ordering remains exactly (priority, pixel index).
	var position := heap_size
	var insert_level := priorities[index]
	while position > 0:
		var parent := int((position - 1) / 4)
		var parent_index := heap[parent]
		var parent_level := priorities[parent_index]
		if insert_level > parent_level or (
			insert_level == parent_level and index >= parent_index
		):
			break
		heap[position] = parent_index
		position = parent
	heap[position] = index

func _heap_pop_fixed(
	heap: PackedInt32Array,
	heap_size: int,
	priorities: PackedFloat32Array,
) -> int:
	var result := heap[0]
	if heap_size <= 1:
		return result

	var effective_size := heap_size - 1
	var replacement := heap[effective_size]
	var replacement_level := priorities[replacement]
	var position := 0
	while true:
		var first_child := position * 4 + 1
		if first_child >= effective_size:
			break
		var best := first_child
		var best_index := heap[best]
		var best_level := priorities[best_index]
		var child_end := mini(first_child + 4, effective_size)
		for child in range(first_child + 1, child_end):
			var child_index := heap[child]
			var child_level := priorities[child_index]
			if child_level < best_level or (
				child_level == best_level and child_index < best_index
			):
				best = child
				best_index = child_index
				best_level = child_level

		if best_level > replacement_level or (
			best_level == replacement_level and best_index >= replacement
		):
			break
		heap[position] = best_index
		position = best
	heap[position] = replacement

	return result
