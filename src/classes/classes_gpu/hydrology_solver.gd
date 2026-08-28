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
	for index in range(pixel_count):
		original[index] = geo_values[index * 4]
		# Priority-Flood's comparison heap is monotone: every terrain cell sent to
		# the open set keeps its original float32 elevation as key and newly queued
		# keys are strictly above the current spill level.  Pre-sort all cells once
		# in native code, then walk this order forward to recover the exact same
		# (elevation, pixel index) pop order without O(log N) GDScript heap work.
		var raw_bits := int(geo_bits[index * 4]) & 0xFFFFFFFF
		# -0.0 and +0.0 compare equal in the previous heap, so normalize both to
		# the same sortable representation before applying the index tie-break.
		if (raw_bits & 0x7FFFFFFF) == 0:
			raw_bits = 0
		var ordered_bits: int
		if (raw_bits & 0x80000000) != 0:
			ordered_bits = (~raw_bits) & 0xFFFFFFFF
		else:
			ordered_bits = raw_bits ^ 0x80000000
		var signed_order := ordered_bits - 0x80000000
		priority_keys[index] = (signed_order << 32) | index
	var filled := original.duplicate()
	geo_values = PackedFloat32Array()
	geo_bits = PackedInt32Array()
	var decode_ms: float = float(Time.get_ticks_usec() - solve_start_usec) / 1000.0

	var flood_start_usec: int = Time.get_ticks_usec()
	priority_keys.sort()
	var priority_sort_ms: float = float(Time.get_ticks_usec() - flood_start_usec) / 1000.0
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
				if visited[index] != 0:
					continue
				var left := left_x[x]
				var right := right_x[x]
				var outlet: int

				outlet = row_up + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row_up + x
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row_up + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row_down + left
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row_down + x
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
				outlet = row_down + right
				if visited[outlet] != 0 and queued[outlet] == 0:
					queued[outlet] = 1
					pending_count += 1
	else:
		for y in range(height):
			var row := y * width
			var row_up := up_row[y]
			var row_down := down_row[y]
			for x in range(width):
				var index := row + x
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

	var outlet_frontier_cells := pending_count

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
			while priority_cursor < pixel_count:
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
		var current_x := current % width
		var current_y := int(current / width)
		var row_base := current - current_x
		var left := left_x[current_x]
		var right := right_x[current_x]
		var row_up := up_row[current_y]
		var row_down := down_row[current_y]
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

	var candidate_start_usec: int = Time.get_ticks_usec()
	var candidate_mask := PackedByteArray()
	candidate_mask.resize(pixel_count)
	candidate_mask.fill(0)
	var filled_cell_count := 0
	var lake_candidate_cells := 0
	var lake_depth_threshold: float = maxf(min_lake_depth_m, MIN_ROUTING_EPSILON_M)

	var climate_values := climate_data.to_float32_array()
	for index in range(pixel_count):
		var fill_depth := filled[index] - original[index]
		if fill_depth > MIN_ROUTING_EPSILON_M:
			filled_cell_count += 1

		if initial_water_mask[index] != WATER_NONE:
			continue
		var temperature := climate_values[index * 4]
		var liquid_temperature := temperature >= WATER_MIN_TEMP and temperature <= WATER_MAX_TEMP
		if liquid_temperature and fill_depth >= lake_depth_threshold:
			candidate_mask[index] = 1
			lake_candidate_cells += 1
	climate_values = PackedFloat32Array()
	var candidate_ms: float = float(Time.get_ticks_usec() - candidate_start_usec) / 1000.0

	var water_mask := initial_water_mask.duplicate()
	var lake_components_start_usec: int = Time.get_ticks_usec()
	var lake_component_stats := _retain_lake_components(
		candidate_mask,
		water_mask,
		width,
		height,
		max(min_lake_cells, 1),
		left_x, right_x, up_row, down_row,
		routing_parent, routing_child_count, flow_direction,
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
		left_x, right_x, up_row, down_row,
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

func _retain_lake_components(
	candidates: PackedByteArray,
	water_mask: PackedByteArray,
	width: int,
	height: int,
	minimum_size: int,
	left_x: PackedInt32Array,
	right_x: PackedInt32Array,
	up_row: PackedInt32Array,
	down_row: PackedInt32Array,
	routing_parent: PackedInt32Array,
	routing_child_count: PackedInt32Array,
	flow_direction: PackedByteArray,
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
			var current_y := int(current / width)
			var row_base := current - current_x
			var left := left_x[current_x]
			var right := right_x[current_x]
			var row_up := up_row[current_y]
			var row_down := down_row[current_y]
			var neighbor: int

			neighbor = row_up + left
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_up + current_x
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_up + right
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_base + left
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_base + right
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + left
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + current_x
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + right
			if candidates[neighbor] != 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue[tail] = neighbor
				tail += 1

		if tail >= minimum_size:
			retained_components += 1
			retained_cells += tail
			for queue_index in range(tail):
				var cell := queue[queue_index]
				water_mask[cell] = WATER_FRESH
				flow_direction[cell] = DIR_SINK
			# Child counts were built while the Priority-Flood forest was discovered.
			# Retained lake cells leave the land-only Kahn graph, so remove their edge
			# from a land parent exactly once. All cells in this retained component are
			# marked as water before the parent test, making the result order-independent.
			for queue_index in range(tail):
				var cell := queue[queue_index]
				var parent := int(routing_parent[cell])
				if parent >= 0 and water_mask[parent] == WATER_NONE:
					routing_child_count[parent] -= 1
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
	left_x: PackedInt32Array,
	right_x: PackedInt32Array,
	up_row: PackedInt32Array,
	down_row: PackedInt32Array,
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
			var current_y := int(current / width)
			var row_base := current - current_x
			var left := left_x[current_x]
			var right := right_x[current_x]
			var row_up := up_row[current_y]
			var row_down := down_row[current_y]
			var neighbor: int

			neighbor = row_up + left
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_up + current_x
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_up + right
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_base + left
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_base + right
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + left
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + current_x
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
				queue[tail] = neighbor
				tail += 1
			neighbor = row_down + right
			if water_mask[neighbor] != WATER_NONE and visited[neighbor] == 0:
				visited[neighbor] = 1
				touches_subsea = touches_subsea or original_height[neighbor] < sea_level
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
