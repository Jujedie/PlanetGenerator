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
	# Bulk conversion is implemented in native code and is substantially cheaper
	# than one decode_float() call per pixel. Geo is RGBA32F, so elevation is the
	# first float in every four-float texel.
	var geo_values := geo_data.to_float32_array()
	var geo_bits := geo_data.to_int32_array()
	var original := PackedFloat32Array()
	var routing_parent := PackedInt32Array()
	var routing_child_count := PackedInt32Array()
	var flow_direction := PackedByteArray()
	var priority_keys := PackedInt64Array()
	original.resize(pixel_count)
	routing_parent.resize(pixel_count)
	routing_child_count.resize(pixel_count)
	flow_direction.resize(pixel_count)
	priority_keys.resize(pixel_count)
	routing_parent.fill(-1)
	routing_child_count.fill(0)
	flow_direction.fill(DIR_SINK)
	var priority_key_count := 0
	for index in range(pixel_count):
		original[index] = geo_values[index * 4]
		# Initial ocean cells are already visited outlets and can never enter the
		# open set unless they lie on its frontier. Sort all land up front; frontier
		# water keys are appended below before the single native sort. This halves
		# sort/scanning work on ocean-heavy worlds without changing queue order.
		if initial_water_mask[index] == WATER_NONE:
			var raw_bits := int(geo_bits[index * 4]) & 0xFFFFFFFF
			if (raw_bits & 0x7FFFFFFF) == 0:
				raw_bits = 0
			var ordered_bits: int
			if (raw_bits & 0x80000000) != 0:
				ordered_bits = (~raw_bits) & 0xFFFFFFFF
			else:
				ordered_bits = raw_bits ^ 0x80000000
			var signed_order := ordered_bits - 0x80000000
			priority_keys[priority_key_count] = (signed_order << 32) | index
			priority_key_count += 1
	var filled := original.duplicate()
	geo_values = PackedFloat32Array()
	var decode_ms: float = float(Time.get_ticks_usec() - solve_start_usec) / 1000.0

	var flood_start_usec: int = Time.get_ticks_usec()
	var visited := PackedByteArray()
	visited.resize(pixel_count)
	visited.fill(0)
	var visited_count := 0

	# Cylindrical X and clamped Y lookup tables are shared by Priority-Flood,
	# shoreline discovery, and both component flood-fills. Building four tiny
	# arrays once removes millions of modulo/clamp branches on large maps.
	var left_x := PackedInt32Array()
	var right_x := PackedInt32Array()
	left_x.resize(width)
	right_x.resize(width)
	for x in range(width):
		left_x[x] = x - 1 if x > 0 else width - 1
		right_x[x] = x + 1 if x + 1 < width else 0
	var up_row := PackedInt32Array()
	var down_row := PackedInt32Array()
	up_row.resize(height)
	down_row.resize(height)
	for y in range(height):
		up_row[y] = maxi(y - 1, 0) * width
		down_row[y] = mini(y + 1, height - 1) * width

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
	# The open set is represented by one byte per cell. `priority_keys` provides
	# the global exact order and `priority_cursor` only moves forward because a
	# later discovery can never have a key below the current spill elevation.
	var queued := PackedByteArray()
	queued.resize(pixel_count)
	queued.fill(0)
	# The frontier scan already visits every pixel. Cache X there so Priority-Flood
	# avoids one integer modulo and one integer division for every processed cell.
	var x_by_index := PackedInt32Array()
	x_by_index.resize(pixel_count)
	var pending_count := 0
	# Scan whichever side of the visited/unvisited boundary is smaller. Both
	# branches produce exactly the same set of outlet frontier pixels. On
	# ocean-heavy planets this avoids probing eight neighbors for every ocean
	# pixel just to recover a shoreline-sized frontier.
	if visited_count * 2 > pixel_count:
		for y in range(height):
			var row := y * width
			var row_up := up_row[y]
			var row_down := down_row[y]
			for x in range(width):
				var index := row + x
				x_by_index[index] = x
				if visited[index] != 0:
					continue
				var left := left_x[x]
				var right := right_x[x]
				var outlet: int

				outlet = row_up + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row_up + x
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row_up + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row_down + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row_down + x
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
				outlet = row_down + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
					if initial_water_mask[outlet] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[outlet * 4]), outlet
						)
						priority_key_count += 1
	else:
		for y in range(height):
			var row := y * width
			var row_up := up_row[y]
			var row_down := down_row[y]
			for x in range(width):
				var index := row + x
				x_by_index[index] = x
				if visited[index] == 0:
					continue
				var left := left_x[x]
				var right := right_x[x]
				if (
					visited[row_up + left] == 0
					or visited[row_up + x] == 0
					or visited[row_up + right] == 0
					or visited[row + left] == 0
					or visited[row + right] == 0
					or visited[row_down + left] == 0
					or visited[row_down + x] == 0
					or visited[row_down + right] == 0
				):
					queued[index] = 1
					pending_count += 1
					if initial_water_mask[index] != WATER_NONE:
						priority_keys[priority_key_count] = _priority_key_from_bits(
							int(geo_bits[index * 4]), index
						)
						priority_key_count += 1

	var outlet_frontier_cells := pending_count
	priority_keys.resize(priority_key_count)
	var priority_sort_start_usec := Time.get_ticks_usec()
	priority_keys.sort()
	var priority_sort_ms: float = float(
		Time.get_ticks_usec() - priority_sort_start_usec
	) / 1000.0
	geo_bits = PackedInt32Array()

	# Optimized Priority-Flood (Barnes-style pit queue): cells lying at or below
	# the current spill elevation belong to the same depression and can be
	# processed FIFO. A preallocated PackedInt32Array keeps this queue numeric and
	# allocation-free. Terrain rising above the spill level stays in the monotone
	# pre-sorted open set. The result preserves the previous heap's exact order.
	var pit_queue := PackedInt32Array()
	pit_queue.resize(pixel_count)
	var pit_head := 0
	var pit_tail := 0
	var heap_pop_count := 0
	var pit_pop_count := 0
	var priority_cursor := 0
	var priority_scanned_cells := 0
	var seam_children := PackedInt32Array()
	var deep_fill_cells := PackedInt32Array()
	deep_fill_cells.resize(pixel_count)
	var deep_fill_count := 0
	var filled_cell_count := 0
	var lake_depth_threshold: float = maxf(min_lake_depth_m, MIN_ROUTING_EPSILON_M)
	while pending_count > 0 or pit_head < pit_tail:
		var current: int
		if pit_head < pit_tail:
			current = pit_queue[pit_head]
			pit_head += 1
			pit_pop_count += 1
		else:
			# The queue storage is reused rather than cleared/reallocated.
			pit_head = 0
			pit_tail = 0
			current = -1
			while priority_cursor < priority_key_count:
				var candidate := int(priority_keys[priority_cursor] & 0xFFFFFFFF)
				priority_cursor += 1
				priority_scanned_cells += 1
				if queued[candidate] == 0:
					continue
				queued[candidate] = 0
				pending_count -= 1
				current = candidate
				break
			if current < 0:
				push_error("[Hydrology] Monotone priority cursor exhausted before open set")
				break
			heap_pop_count += 1

		var current_level := filled[current]
		var current_x := int(x_by_index[current])
		var row_base := current - current_x
		var left := left_x[current_x]
		var right := right_x[current_x]
		var row_up := row_base - width if row_base >= width else row_base
		var row_down := row_base + width if row_base + width < pixel_count else row_base
		var neighbor: int
		var neighbor_level: float

		neighbor = row_up + left
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 7
			if current_x == 0:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_up + current_x
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 6
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_up + right
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 5
			if current_x + 1 == width:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_base + left
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 4
			if current_x == 0:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_base + right
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 3
			if current_x + 1 == width:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_down + left
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 2
			if current_x == 0:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_down + current_x
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 1
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

		neighbor = row_down + right
		if visited[neighbor] == 0:
			visited[neighbor] = 1
			visited_count += 1
			routing_parent[neighbor] = current
			routing_child_count[current] += 1
			flow_direction[neighbor] = 0
			if current_x + 1 == width:
				seam_children.append(neighbor)
			neighbor_level = original[neighbor]
			if neighbor_level <= current_level:
				filled[neighbor] = current_level
				var fill_depth := current_level - neighbor_level
				if fill_depth > MIN_ROUTING_EPSILON_M:
					filled_cell_count += 1
				if fill_depth >= lake_depth_threshold:
					deep_fill_cells[deep_fill_count] = neighbor
					deep_fill_count += 1
				pit_queue[pit_tail] = neighbor
				pit_tail += 1
			else:
				filled[neighbor] = neighbor_level
				queued[neighbor] = 1
				pending_count += 1

	if visited_count != pixel_count:
		push_error("[Hydrology] Priority flood did not visit the complete map")
	var priority_flood_ms: float = float(Time.get_ticks_usec() - flood_start_usec) / 1000.0
	priority_keys = PackedInt64Array()
	queued = PackedByteArray()
	x_by_index = PackedInt32Array()
	left_x = PackedInt32Array()
	right_x = PackedInt32Array()
	up_row = PackedInt32Array()
	down_row = PackedInt32Array()

	var candidate_start_usec: int = Time.get_ticks_usec()
	var candidate_mask := PackedByteArray()
	candidate_mask.resize(pixel_count)
	candidate_mask.fill(0)
	var lake_candidate_cells := 0

	# Only cells that were actually raised above the lake-depth threshold can be
	# candidates. Priority-Flood records them while visiting the depression, so
	# climate filtering no longer rescans the complete map.
	var climate_values := climate_data.to_float32_array()
	for candidate_index in range(deep_fill_count):
		var index := int(deep_fill_cells[candidate_index])
		var temperature := climate_values[index * 4]
		if temperature >= WATER_MIN_TEMP and temperature <= WATER_MAX_TEMP:
			candidate_mask[index] = 1
			lake_candidate_cells += 1
	climate_values = PackedFloat32Array()
	deep_fill_cells = PackedInt32Array()
	var candidate_ms: float = float(Time.get_ticks_usec() - candidate_start_usec) / 1000.0

	var water_mask := initial_water_mask.duplicate()
	var lake_components_start_usec: int = Time.get_ticks_usec()
	var lake_component_stats := _retain_lake_components(
		candidate_mask, water_mask, width, height, max(min_lake_cells, 1),
		routing_parent, routing_child_count, flow_direction,
	)
	var lake_components_ms: float = float(Time.get_ticks_usec() - lake_components_start_usec) / 1000.0

	var water_components_start_usec: int = Time.get_ticks_usec()
	var water_stats := _classify_water_components(
		water_mask, original, width, height, sea_level,
		max(saltwater_min_cells, 1),
	)
	var water_components_ms: float = float(Time.get_ticks_usec() - water_components_start_usec) / 1000.0

	# Routing directions and child counts were materialized while the exact
	# Priority-Flood forest was discovered. This removes a later full-map graph
	# reconstruction pass before conservative topological accumulation.
	var surface_total_ms: float = float(Time.get_ticks_usec() - solve_start_usec) / 1000.0
	var routing_seam_links := 0
	for child in seam_children:
		if water_mask[child] == WATER_NONE:
			routing_seam_links += 1

	var stats := {
		"priority_flood_visited_cells": visited_count,
		"priority_flood_outlet_frontier_cells": outlet_frontier_cells,
		"priority_flood_heap_pops": heap_pop_count,
		"priority_flood_pit_pops": pit_pop_count,
		"depression_filled_cells": filled_cell_count,
		"lake_candidate_cells": lake_candidate_cells,
		"surface_decode_ms": decode_ms,
		"priority_sort_ms": priority_sort_ms,
		"priority_sorted_cells": priority_key_count,
		"priority_flood_ms": priority_flood_ms,
		"priority_scanned_cells": priority_scanned_cells,
		"lake_candidate_ms": candidate_ms,
		"lake_components_ms": lake_components_ms,
		"water_components_ms": water_components_ms,
		"surface_total_ms": surface_total_ms,
	}
	stats.merge(lake_component_stats, true)
	stats.merge(water_stats, true)

	# On width 1-2 maps the wrapped left/right neighbors alias each other, so the
	# unrolled discovery direction is not a unique geometric D8 direction. These
	# tiny diagnostic resolutions use the compatibility reconstruction path.
	if width < 3:
		routing_child_count = PackedInt32Array()
		flow_direction = PackedByteArray()

	return {
		"water_mask": water_mask,
		"routing_parent": routing_parent,
		"routing_child_count": routing_child_count,
		"flow_direction": flow_direction,
		"routing_seam_links": routing_seam_links,
		"stats": stats,
	}

## Accumulates each land cell's local precipitation exactly once along an
## acyclic D8 graph. Kahn's algorithm makes the result independent of a
## propagation-pass count and exposes any residual cycle as an invariant error.
func accumulate_flow(
	routing_parent: PackedInt32Array,
	water_mask: PackedByteArray,
	local_flux_data: PackedByteArray,
	width: int,
	height: int,
	precomputed_child_count: PackedInt32Array = PackedInt32Array(),
	precomputed_flow_direction: PackedByteArray = PackedByteArray(),
	precomputed_seam_links: int = -1,
) -> Dictionary:
	var pixel_count := width * height
	if (
		routing_parent.size() != pixel_count
		or water_mask.size() != pixel_count
		or local_flux_data.size() != pixel_count * 4
	):
		push_error("[Hydrology] Invalid input sizes for flow accumulation")
		return {}

	# R32F -> PackedFloat32Array is a native bulk conversion; the final upload
	# uses the inverse native conversion instead of N encode_float() calls.
	var flux := local_flux_data.to_float32_array()
	var use_precomputed := (
		precomputed_child_count.size() == pixel_count
		and precomputed_flow_direction.size() == pixel_count
	)
	var indegree := PackedInt32Array()
	var flow_direction := PackedByteArray()
	if use_precomputed:
		# Priority-Flood discovers every child from an already-visited parent. Its
		# child counts are therefore already the exact Kahn indegrees after retained
		# lake edges are removed in _retain_lake_components().
		indegree = precomputed_child_count.duplicate()
		flow_direction = precomputed_flow_direction
	else:
		indegree.resize(pixel_count)
		indegree.fill(0)
		flow_direction.resize(pixel_count)
		flow_direction.fill(DIR_SINK)

	var land_cells := 0
	var local_precipitation := 0.0
	var terminal_flux := 0.0
	var max_land_flux := 0.0
	var seam_flow_links := maxi(precomputed_seam_links, 0) if use_precomputed else 0
	var routing_seam_links := seam_flow_links
	var routing_invalid_parents := 0
	var nonpolar_land_sinks := 0
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var queue_tail := 0

	for index in range(pixel_count):
		var local_flux: float = maxf(flux[index], 0.0)
		if local_flux != flux[index]:
			flux[index] = local_flux
		if water_mask[index] != WATER_NONE:
			# Preserve any local water contribution in the mass-balance statistic.
			# Land inflow is added when its finalized Kahn node reaches this sink.
			terminal_flux += local_flux
			continue

		land_cells += 1
		local_precipitation += local_flux
		if use_precomputed:
			var parent := int(routing_parent[index])
			if parent < 0:
				# Only deliberately open polar rows are valid land sinks.
				var sink_y := int(index / width)
				if sink_y >= 2 and sink_y < height - 2:
					routing_invalid_parents += 1
					nonpolar_land_sinks += 1
			elif parent >= pixel_count or flow_direction[index] == DIR_SINK:
				routing_invalid_parents += 1
				nonpolar_land_sinks += 1
			if indegree[index] == 0:
				queue[queue_tail] = index
				queue_tail += 1
			continue

		# Compatibility/reference path used by direct callers that do not provide
		# the forest metadata computed by solve_surface_and_water().
		var y := int(index / width)
		if y < 2 or y >= height - 2:
			continue
		var parent := int(routing_parent[index])
		if parent < 0 or parent >= pixel_count:
			routing_invalid_parents += 1
			nonpolar_land_sinks += 1
			continue
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
			routing_invalid_parents += 1
			nonpolar_land_sinks += 1
			continue
		flow_direction[index] = direction
		if water_mask[parent] == WATER_NONE:
			indegree[parent] += 1
		if abs(parent_x - x) > 1:
			routing_seam_links += 1
			seam_flow_links += 1

	if not use_precomputed:
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

		# Kahn only releases a node after every land child has contributed, so its
		# flux is final here. Collect statistics in this same pass instead of
		# scanning the complete map a third time after accumulation.
		max_land_flux = maxf(max_land_flux, flux[current])
		var target := int(routing_parent[current])
		if target < 0 or target >= pixel_count:
			terminal_flux += flux[current]
			continue

		flux[target] += flux[current]
		if water_mask[target] == WATER_NONE:
			indegree[target] -= 1
			if indegree[target] == 0:
				queue[queue_tail] = target
				queue_tail += 1
		else:
			terminal_flux += flux[current]

	var unresolved_land_cells := land_cells - processed_land_cells
	var mass_error: float = absf(terminal_flux - local_precipitation)
	var relative_mass_error: float = mass_error / maxf(local_precipitation, 0.000001)

	return {
		"flux_data": flux.to_byte_array(),
		"flow_direction": flow_direction,
		"max_land_flux": max_land_flux,
		"stats": {
			"land_cells": land_cells,
			"processed_land_cells": processed_land_cells,
			"unresolved_land_cells": unresolved_land_cells,
			"nonpolar_land_sinks": nonpolar_land_sinks,
			"seam_flow_links": seam_flow_links,
			"routing_invalid_parents": routing_invalid_parents,
			"routing_seam_links": routing_seam_links,
			"local_precipitation": local_precipitation,
			"terminal_flux": terminal_flux,
			"mass_error": mass_error,
			"relative_mass_error": relative_mass_error,
		},
	}

func _priority_key_from_bits(raw_bits_signed: int, index: int) -> int:
	var raw_bits := raw_bits_signed & 0xFFFFFFFF
	# -0.0 and +0.0 compared equal in the previous heap.
	if (raw_bits & 0x7FFFFFFF) == 0:
		raw_bits = 0
	var ordered_bits: int
	if (raw_bits & 0x80000000) != 0:
		ordered_bits = (~raw_bits) & 0xFFFFFFFF
	else:
		ordered_bits = raw_bits ^ 0x80000000
	var signed_order := ordered_bits - 0x80000000
	return (signed_order << 32) | index

func _retain_lake_components(
	candidates: PackedByteArray,
	water_mask: PackedByteArray,
	width: int,
	height: int,
	minimum_size: int,
	routing_parent: PackedInt32Array,
	routing_child_count: PackedInt32Array,
	flow_direction: PackedByteArray,
) -> Dictionary:
	var runs := _build_binary_runs_8(candidates, width, height)
	var run_starts: PackedInt32Array = runs["starts"]
	var run_ends: PackedInt32Array = runs["ends"]
	var run_rows: PackedInt32Array = runs["rows"]
	var root_by_run: PackedInt32Array = runs["root_by_run"]
	var root_sizes: PackedInt32Array = runs["root_sizes"]
	var run_count := run_starts.size()
	var candidate_components := int(runs["component_count"])
	var retained_root := PackedByteArray()
	retained_root.resize(run_count)
	retained_root.fill(0)
	var retained_components := 0
	var retained_cells := 0
	var removed_cells := 0

	for root in range(run_count):
		var size := int(root_sizes[root])
		if size <= 0:
			continue
		if size >= minimum_size:
			retained_root[root] = 1
			retained_components += 1
			retained_cells += size
		else:
			removed_cells += size

	# First materialize every retained lake cell as water. Then detach its edge
	# from a remaining land parent. This is the same two-phase ordering as the BFS
	# implementation and therefore preserves Kahn indegrees exactly.
	for run_index in range(run_count):
		if retained_root[root_by_run[run_index]] == 0:
			continue
		var row := run_rows[run_index] * width
		for x in range(run_starts[run_index], run_ends[run_index] + 1):
			var cell := row + x
			water_mask[cell] = WATER_FRESH
			flow_direction[cell] = DIR_SINK
	for run_index in range(run_count):
		if retained_root[root_by_run[run_index]] == 0:
			continue
		var row := run_rows[run_index] * width
		for x in range(run_starts[run_index], run_ends[run_index] + 1):
			var cell := row + x
			var parent := int(routing_parent[cell])
			if parent >= 0 and water_mask[parent] == WATER_NONE:
				routing_child_count[parent] -= 1

	return {
		"lake_candidate_components": candidate_components,
		"lake_components_retained": retained_components,
		"lake_cells_retained": retained_cells,
		"lake_cells_removed": removed_cells,
		"lake_component_runs": run_count,
	}

func _classify_water_components(
	water_mask: PackedByteArray,
	original_height: PackedFloat32Array,
	width: int,
	height: int,
	sea_level: float,
	saltwater_min_cells: int,
) -> Dictionary:
	var runs := _build_binary_runs_8(water_mask, width, height)
	var run_starts: PackedInt32Array = runs["starts"]
	var run_ends: PackedInt32Array = runs["ends"]
	var run_rows: PackedInt32Array = runs["rows"]
	var root_by_run: PackedInt32Array = runs["root_by_run"]
	var root_sizes: PackedInt32Array = runs["root_sizes"]
	var run_count := run_starts.size()
	var root_touches_subsea := PackedByteArray()
	root_touches_subsea.resize(run_count)
	root_touches_subsea.fill(0)

	# Once a component has one original cell below sea level, no further height
	# probes are required for its later runs. Large oceans therefore usually pay
	# only a handful of comparisons instead of one per water cell.
	for run_index in range(run_count):
		var root := int(root_by_run[run_index])
		if root_touches_subsea[root] != 0:
			continue
		var row := run_rows[run_index] * width
		for x in range(run_starts[run_index], run_ends[run_index] + 1):
			if original_height[row + x] < sea_level:
				root_touches_subsea[root] = 1
				break

	var root_water_type := PackedByteArray()
	root_water_type.resize(run_count)
	root_water_type.fill(WATER_NONE)
	var salt_components := 0
	var fresh_components := 0
	var total_water_cells := 0
	var largest_component := 0
	for root in range(run_count):
		var size := int(root_sizes[root])
		if size <= 0:
			continue
		var water_type := WATER_FRESH
		if root_touches_subsea[root] != 0 and size >= saltwater_min_cells:
			water_type = WATER_SALT
			salt_components += 1
		else:
			fresh_components += 1
		root_water_type[root] = water_type
		total_water_cells += size
		largest_component = maxi(largest_component, size)

	# Classification itself must touch every water pixel once to materialize the
	# authoritative mask, but it is now a contiguous run write with no BFS queue,
	# visited map, modulo, clamp, or eight-neighbor probes.
	for run_index in range(run_count):
		var water_type := int(root_water_type[root_by_run[run_index]])
		var row := run_rows[run_index] * width
		for x in range(run_starts[run_index], run_ends[run_index] + 1):
			water_mask[row + x] = water_type

	return {
		"water_components": salt_components + fresh_components,
		"saltwater_components": salt_components,
		"freshwater_components": fresh_components,
		"total_water_cells": total_water_cells,
		"largest_water_component": largest_component,
		"water_component_runs": run_count,
	}

## Run-length 8-connected component labeler on a cylindrical X / clamped-Y map.
## Horizontal runs remove the queue + eight-neighbor inner loop that dominated
## water-component classification at multi-megapixel resolutions.
func _build_binary_runs_8(mask: PackedByteArray, width: int, height: int) -> Dictionary:
	var run_starts := PackedInt32Array()
	var run_ends := PackedInt32Array()
	var run_rows := PackedInt32Array()
	var run_parent := PackedInt32Array()
	var row_run_begin := PackedInt32Array()
	var row_run_end := PackedInt32Array()
	row_run_begin.resize(height)
	row_run_end.resize(height)

	for y in range(height):
		var row := y * width
		var row_begin := run_starts.size()
		row_run_begin[y] = row_begin
		var x := 0
		while x < width:
			while x < width and mask[row + x] == WATER_NONE:
				x += 1
			if x >= width:
				break
			var start_x := x
			x += 1
			while x < width and mask[row + x] != WATER_NONE:
				x += 1
			var run_index := run_starts.size()
			run_starts.append(start_x)
			run_ends.append(x - 1)
			run_rows.append(y)
			run_parent.append(run_index)
		var row_end := run_starts.size()
		row_run_end[y] = row_end

		# Same-row X seam is an 8-neighbor contact too.
		if row_end - row_begin >= 2 and run_starts[row_begin] == 0 and run_ends[row_end - 1] == width - 1:
			_run_union_smallest(run_parent, row_begin, row_end - 1)

		if y == 0 or row_begin >= row_end:
			continue
		var previous_begin := int(row_run_begin[y - 1])
		var previous_end := int(row_run_end[y - 1])
		var previous_cursor := previous_begin
		for current_run in range(row_begin, row_end):
			var start_x := int(run_starts[current_run])
			var end_x := int(run_ends[current_run])
			while previous_cursor < previous_end and run_ends[previous_cursor] < start_x - 1:
				previous_cursor += 1
			var candidate_run := previous_cursor
			while candidate_run < previous_end and run_starts[candidate_run] <= end_x + 1:
				if run_ends[candidate_run] >= start_x - 1:
					_run_union_smallest(run_parent, current_run, candidate_run)
				candidate_run += 1
			# Diagonal seam contacts are outside the ordinary interval overlap.
			if start_x == 0 and previous_end > previous_begin and run_ends[previous_end - 1] == width - 1:
				_run_union_smallest(run_parent, current_run, previous_end - 1)
			if end_x == width - 1 and previous_end > previous_begin and run_starts[previous_begin] == 0:
				_run_union_smallest(run_parent, current_run, previous_begin)

	var run_count := run_starts.size()
	var root_by_run := PackedInt32Array()
	var root_sizes := PackedInt32Array()
	root_by_run.resize(run_count)
	root_sizes.resize(run_count)
	root_sizes.fill(0)
	var component_count := 0
	for run_index in range(run_count):
		var root := _run_find_root(run_parent, run_index)
		root_by_run[run_index] = root
		if root_sizes[root] == 0:
			component_count += 1
		root_sizes[root] += run_ends[run_index] - run_starts[run_index] + 1

	return {
		"starts": run_starts,
		"ends": run_ends,
		"rows": run_rows,
		"root_by_run": root_by_run,
		"root_sizes": root_sizes,
		"component_count": component_count,
	}

func _run_find_root(parent: PackedInt32Array, value: int) -> int:
	var root := value
	while parent[root] != root:
		root = parent[root]
	var current := value
	while parent[current] != current:
		var next := int(parent[current])
		parent[current] = root
		current = next
	return root

func _run_union_smallest(parent: PackedInt32Array, a: int, b: int) -> void:
	var root_a := _run_find_root(parent, a)
	var root_b := _run_find_root(parent, b)
	if root_a == root_b:
		return
	if root_a < root_b:
		parent[root_b] = root_a
	else:
		parent[root_a] = root_b

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
