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
const CARDINAL_DX: Array[int] = [-1, 1, 0, 0]
const CARDINAL_DY: Array[int] = [0, 0, -1, 1]


static func build_surface_mask(
	water_data: PackedByteArray,
	w: int,
	h: int,
	select_water: bool = false,
) -> Dictionary:
	# Build the authoritative administrative mask and count active cells in one
	# pass. This avoids a second full-map count in both land and maritime phases.
	var pixel_count := w * h
	var result := PackedByteArray()
	if water_data.size() != pixel_count:
		return {"mask": result, "active_cells": 0}
	result.resize(pixel_count)
	result.fill(0)
	var active_cells := 0
	for index in range(pixel_count):
		var active: bool = water_data[index] > 0 if select_water else water_data[index] == 0
		if active:
			result[index] = 1
			active_cells += 1
	return {"mask": result, "active_cells": active_cells}


static func build_land_mask(water_data: PackedByteArray,
		_geo_data: PackedByteArray, w: int, h: int,
		_sea_level: float) -> PackedByteArray:
	# Compatibility wrapper retained for existing tests/callers. The hydrology
	# result is the authoritative surface mask; altitude is intentionally ignored.
	var result: Dictionary = build_surface_mask(water_data, w, h, false)
	return PackedByteArray(result["mask"])


static func normalize(region_data: PackedByteArray,
		land_mask: PackedByteArray, w: int, h: int,
		target_cells: float, minimum_ratio: float = 0.45,
		maximum_ratio: float = 1.85,
		discard_isolated_undersized: bool = false,
		enforce_global_minimum: bool = false,
		assume_complete_gpu_map: bool = false) -> Dictionary:
	var pixel_count := w * h
	if region_data.size() != pixel_count * 4 or land_mask.size() != pixel_count:
		return {}
	var normalization_start_usec := Time.get_ticks_usec()

	# R32UI administrative IDs are pixel-derived and therefore stay below
	# pixel_count before CPU normalization. Bulk reinterpretation maps the
	# 0xFFFFFFFF sentinel directly to -1.
	var region_ids := region_data.to_int32_array()
	var next_id := pixel_count
	var removed_non_land := 0
	var initial_unassigned := 0
	var active_cells := -1
	var unassigned_cells := PackedInt32Array()

	# When the final GPU cleanup/convergence pass has already proven complete
	# coverage, do not spend another O(N) GDScript pass rediscovering that fact.
	# The shaders also write INVALID_ID outside their authoritative mask. Direct
	# callers/tests keep the defensive scan by leaving the hint at its default.
	if not assume_complete_gpu_map:
		active_cells = 0
		for index in range(pixel_count):
			var region_id := int(region_ids[index])
			if land_mask[index] == 0:
				if region_id >= 0:
					removed_non_land += 1
				region_ids[index] = -1
				continue
			active_cells += 1
			if region_id >= 0:
				next_id = maxi(next_id, region_id + 1)
			else:
				initial_unassigned += 1
				unassigned_cells.append(index)

	# X lookup tables are only needed by the rare CPU repair path. The normal
	# component path below is run-based and performs no modulo/wrap per pixel.
	var left_x := PackedInt32Array()
	var right_x := PackedInt32Array()
	var queue := PackedInt32Array()
	var filled_land := 0
	var head := 0
	if initial_unassigned > 0:
		left_x.resize(w)
		right_x.resize(w)
		for x in range(w):
			left_x[x] = x - 1 if x > 0 else w - 1
			right_x[x] = x + 1 if x + 1 < w else 0
		queue.resize(pixel_count)
		# Exact multi-source repair does not need millions of assigned interior
		# seeds. Only assigned pixels touching an initial hole can ever expand into
		# it. Mark that frontier from the sparse hole list, then native-sort it so
		# seed processing retains the old row-major order and therefore tie-breaking.
		var boundary_mark := PackedByteArray()
		boundary_mark.resize(pixel_count)
		boundary_mark.fill(0)
		var boundary_seeds := PackedInt32Array()
		for hole in unassigned_cells:
			var x := int(hole) % w
			var y := int(int(hole) / w)
			var row := int(hole) - x
			var neighbor := row + left_x[x]
			if land_mask[neighbor] != 0 and region_ids[neighbor] >= 0 and boundary_mark[neighbor] == 0:
				boundary_mark[neighbor] = 1
				boundary_seeds.append(neighbor)
			neighbor = row + right_x[x]
			if land_mask[neighbor] != 0 and region_ids[neighbor] >= 0 and boundary_mark[neighbor] == 0:
				boundary_mark[neighbor] = 1
				boundary_seeds.append(neighbor)
			if y > 0:
				neighbor = int(hole) - w
				if land_mask[neighbor] != 0 and region_ids[neighbor] >= 0 and boundary_mark[neighbor] == 0:
					boundary_mark[neighbor] = 1
					boundary_seeds.append(neighbor)
			if y + 1 < h:
				neighbor = int(hole) + w
				if land_mask[neighbor] != 0 and region_ids[neighbor] >= 0 and boundary_mark[neighbor] == 0:
					boundary_mark[neighbor] = 1
					boundary_seeds.append(neighbor)
		boundary_mark = PackedByteArray()
		boundary_seeds.sort()
		var assigned_tail := boundary_seeds.size()
		for seed_index in range(assigned_tail):
			queue[seed_index] = boundary_seeds[seed_index]
		boundary_seeds = PackedInt32Array()
		while head < assigned_tail:
			var current := queue[head]
			head += 1
			var current_id := int(region_ids[current])
			var x := current % w
			var y := int(current / w)
			var row := current - x
			var neighbor := row + left_x[x]
			if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
				region_ids[neighbor] = current_id
				filled_land += 1
				queue[assigned_tail] = neighbor
				assigned_tail += 1
			neighbor = row + right_x[x]
			if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
				region_ids[neighbor] = current_id
				filled_land += 1
				queue[assigned_tail] = neighbor
				assigned_tail += 1
			if y > 0:
				neighbor = current - w
				if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
					region_ids[neighbor] = current_id
					filled_land += 1
					queue[assigned_tail] = neighbor
					assigned_tail += 1
			if y + 1 < h:
				neighbor = current + w
				if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
					region_ids[neighbor] = current_id
					filled_land += 1
					queue[assigned_tail] = neighbor
					assigned_tail += 1

	unassigned_cells = PackedInt32Array()

	# A connected mask component with no seed becomes one department rather than
	# unrelated minima. This path is normally empty after GPU cleanup, but remains
	# as the exact compatibility/safety fallback for direct normalizer callers.
	var seedless_components := 0
	if initial_unassigned > filled_land:
		for start in range(pixel_count):
			if land_mask[start] == 0 or region_ids[start] >= 0:
				continue
			var component_id := next_id
			next_id += 1
			seedless_components += 1
			head = 0
			var tail := 1
			queue[0] = start
			region_ids[start] = component_id
			while head < tail:
				var current := queue[head]
				head += 1
				var x := current % w
				var y := int(current / w)
				var row := current - x
				var neighbor := row + left_x[x]
				if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
					region_ids[neighbor] = component_id
					filled_land += 1
					queue[tail] = neighbor
					tail += 1
				neighbor = row + right_x[x]
				if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
					region_ids[neighbor] = component_id
					filled_land += 1
					queue[tail] = neighbor
					tail += 1
				if y > 0:
					neighbor = current - w
					if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
						region_ids[neighbor] = component_id
						filled_land += 1
						queue[tail] = neighbor
						tail += 1
				if y + 1 < h:
					neighbor = current + w
					if land_mask[neighbor] != 0 and region_ids[neighbor] < 0:
						region_ids[neighbor] = component_id
						filled_land += 1
						queue[tail] = neighbor
						tail += 1
	var fill_done_usec := Time.get_ticks_usec()

	# -----------------------------------------------------------------------
	# Run-length 4-connected component labeling
	# -----------------------------------------------------------------------
	# Administrative departments are compact mosaics with target sizes of only
	# tens/hundreds of pixels. Processing maximal horizontal runs therefore cuts
	# component work from O(active pixels) queue/neighbor operations to O(runs),
	# while preserving exactly the same cylindrical 4-connectivity.
	var run_starts := PackedInt32Array()
	var run_ends := PackedInt32Array()
	var run_rows := PackedInt32Array()
	var run_raw_ids := PackedInt32Array()
	var run_parent := PackedInt32Array()
	var row_run_begin := PackedInt32Array()
	var row_run_end := PackedInt32Array()
	row_run_begin.resize(h)
	row_run_end.resize(h)

	for y in range(h):
		var row := y * w
		var row_begin := run_starts.size()
		row_run_begin[y] = row_begin
		var x := 0
		while x < w:
			var index := row + x
			if land_mask[index] == 0 or region_ids[index] < 0:
				x += 1
				continue
			var raw_id := int(region_ids[index])
			var start_x := x
			x += 1
			while x < w:
				index = row + x
				if land_mask[index] == 0 or int(region_ids[index]) != raw_id:
					break
				x += 1
			var run_index := run_starts.size()
			run_starts.append(start_x)
			run_ends.append(x - 1)
			run_rows.append(y)
			run_raw_ids.append(raw_id)
			run_parent.append(run_index)
		var row_end := run_starts.size()
		row_run_end[y] = row_end

		# Same-row cylindrical seam. Union-to-smallest-run preserves the earliest
		# row-major representative used by the previous scanline CCL.
		if row_end - row_begin >= 2:
			var first_run := row_begin
			var last_run := row_end - 1
			if (
				run_starts[first_run] == 0
				and run_ends[last_run] == w - 1
				and run_raw_ids[first_run] == run_raw_ids[last_run]
			):
				var first_root := first_run
				while run_parent[first_root] != first_root:
					first_root = run_parent[first_root]
				var last_root := last_run
				while run_parent[last_root] != last_root:
					last_root = run_parent[last_root]
				if first_root != last_root:
					if first_root < last_root:
						run_parent[last_root] = first_root
					else:
						run_parent[first_root] = last_root

		# Vertical contacts are the only cross-row connection for 4-connectivity.
		# Two pointers enumerate only geometrically overlapping runs.
		if y > 0 and row_begin < row_end:
			var previous_begin := row_run_begin[y - 1]
			var previous_end := row_run_end[y - 1]
			var previous_cursor := previous_begin
			for current_run in range(row_begin, row_end):
				var start_x := run_starts[current_run]
				var end_x := run_ends[current_run]
				while previous_cursor < previous_end and run_ends[previous_cursor] < start_x:
					previous_cursor += 1
				var candidate_run := previous_cursor
				while candidate_run < previous_end and run_starts[candidate_run] <= end_x:
					if (
						run_ends[candidate_run] >= start_x
						and run_raw_ids[candidate_run] == run_raw_ids[current_run]
					):
						var current_root := current_run
						while run_parent[current_root] != current_root:
							current_root = run_parent[current_root]
						var previous_root := candidate_run
						while run_parent[previous_root] != previous_root:
							previous_root = run_parent[previous_root]
						if current_root != previous_root:
							if current_root < previous_root:
								run_parent[previous_root] = current_root
							else:
								run_parent[current_root] = previous_root
					candidate_run += 1

	var run_count := run_starts.size()
	var root_by_run := PackedInt32Array()
	root_by_run.resize(run_count)
	for run_index in range(run_count):
		var root := run_index
		while run_parent[root] != root:
			root = run_parent[root]
		root_by_run[run_index] = root
		var current := run_index
		while run_parent[current] != current:
			var next := run_parent[current]
			run_parent[current] = root
			current = next

	# Keep the exact v3 centroid summation order. Precompute trigonometry once per
	# column, then add values in row-major pixel order inside each run. Grouping
	# these sums via prefix subtraction can move symmetric centroid ties by a few
	# ulps and change an otherwise deterministic merge target.
	var longitude_cos := PackedFloat64Array()
	var longitude_sin := PackedFloat64Array()
	longitude_cos.resize(w)
	longitude_sin.resize(w)
	var longitude_denominator := float(maxi(w, 1))
	for x in range(w):
		var angle := TAU * (float(x) + 0.5) / longitude_denominator
		longitude_cos[x] = cos(angle)
		longitude_sin[x] = sin(angle)

	var component_ids := PackedInt32Array()
	var component_areas := PackedInt32Array()
	var component_min_y := PackedInt32Array()
	var component_max_y := PackedInt32Array()
	var component_sum_y := PackedFloat64Array()
	var component_sum_cos := PackedFloat64Array()
	var component_sum_sin := PackedFloat64Array()
	var component_for_root := PackedInt32Array()
	component_for_root.resize(run_count)
	component_for_root.fill(-1)
	var run_component := PackedInt32Array()
	run_component.resize(run_count)
	var completed_raw_ids := PackedByteArray()
	completed_raw_ids.resize(pixel_count)
	completed_raw_ids.fill(0)
	var completed_large_ids: Dictionary = {}
	var split_fragments := 0
	var represented_active_cells := 0

	for run_index in range(run_count):
		var root := root_by_run[run_index]
		var component_index := component_for_root[root]
		var raw_id := int(run_raw_ids[run_index])
		if component_index < 0:
			var effective_id := raw_id
			var already_completed := false
			if raw_id >= 0 and raw_id < pixel_count:
				already_completed = completed_raw_ids[raw_id] != 0
				completed_raw_ids[raw_id] = 1
			else:
				already_completed = completed_large_ids.has(raw_id)
				completed_large_ids[raw_id] = true
			if already_completed:
				effective_id = next_id
				next_id += 1
				split_fragments += 1
			component_index = component_ids.size()
			component_for_root[root] = component_index
			component_ids.append(effective_id)
			component_areas.append(0)
			component_min_y.append(h)
			component_max_y.append(-1)
			component_sum_y.append(0.0)
			component_sum_cos.append(0.0)
			component_sum_sin.append(0.0)
		run_component[run_index] = component_index
		var start_x := run_starts[run_index]
		var end_x := run_ends[run_index]
		var y := run_rows[run_index]
		var run_length := end_x - start_x + 1
		represented_active_cells += run_length
		component_areas[component_index] += run_length
		component_min_y[component_index] = mini(component_min_y[component_index], y)
		component_max_y[component_index] = maxi(component_max_y[component_index], y)
		component_sum_y[component_index] += float(y * run_length)
		for x in range(start_x, end_x + 1):
			component_sum_cos[component_index] += longitude_cos[x]
			component_sum_sin[component_index] += longitude_sin[x]
	var components_done_usec := Time.get_ticks_usec()

	var component_count := component_ids.size()
	if component_count == 0:
		var empty_ids := PackedInt32Array()
		empty_ids.resize(pixel_count)
		empty_ids.fill(-1)
		var empty_output := empty_ids.to_byte_array()
		return {
			"data": empty_output,
			"partition_sizes": [],
			"unassigned_active_cells": maxi(active_cells, 0),
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
	var areas := component_areas.duplicate()
	var min_ys := component_min_y.duplicate()
	var max_ys := component_max_y.duplicate()
	var sum_ys := component_sum_y.duplicate()
	var sum_cosines := component_sum_cos.duplicate()
	var sum_sines := component_sum_sin.duplicate()
	var adjacency: Array[Dictionary] = []
	for index in range(component_count):
		parent[index] = index
		adjacency.append({})

	# -----------------------------------------------------------------------
	# Run-boundary adjacency
	# -----------------------------------------------------------------------
	# Horizontal contacts occur only where two consecutive active runs touch.
	# Vertical contacts are interval overlaps; add the whole overlap length at
	# once instead of one Dictionary update per touching pixel.
	for y in range(h):
		var row_begin := row_run_begin[y]
		var row_end := row_run_end[y]
		for run_index in range(row_begin, row_end - 1):
			var next_run := run_index + 1
			if run_ends[run_index] + 1 == run_starts[next_run]:
				_add_contact_count(
				run_component[run_index], run_component[next_run], 1, adjacency
			)
		if row_end > row_begin and w > 1:
			var first_run := row_begin
			var last_run := row_end - 1
			if run_starts[first_run] == 0 and run_ends[last_run] == w - 1:
				_add_contact_count(
					run_component[first_run], run_component[last_run], 1, adjacency
				)
		if y + 1 >= h:
			continue
		var next_begin := row_run_begin[y + 1]
		var next_end := row_run_end[y + 1]
		var next_cursor := next_begin
		for run_index in range(row_begin, row_end):
			var start_x := run_starts[run_index]
			var end_x := run_ends[run_index]
			while next_cursor < next_end and run_ends[next_cursor] < start_x:
				next_cursor += 1
			var next_run := next_cursor
			while next_run < next_end and run_starts[next_run] <= end_x:
				var overlap_start := maxi(start_x, run_starts[next_run])
				var overlap_end := mini(end_x, run_ends[next_run])
				if overlap_start <= overlap_end:
					_add_contact_count(
						run_component[run_index], run_component[next_run],
						overlap_end - overlap_start + 1, adjacency
					)
				next_run += 1
	var adjacency_done_usec := Time.get_ticks_usec()

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
			var required_minimum := minimum_cells if enforce_global_minimum else _local_minimum(
				root, neighbors, areas, minimum_cells
			)
			if areas[root] >= required_minimum:
				continue
			var target := _select_merge_target(
				root, neighbors, parent, areas, min_ys, max_ys,
				sum_ys, sum_cosines, sum_sines, adjacency,
				w, h, target_cells, maximum_cells, false
			)
			if target < 0 and (enforce_global_minimum or areas[root] <= maxi(int(floor(minimum_cells * 0.5)), 2)):
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
	var merge_done_usec := Time.get_ticks_usec()

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
		if areas[component] < minimum_cells:
			var neighbors := _canonical_neighbors(component, parent, adjacency)
			if neighbors.is_empty():
				isolated_undersized += 1
			elif enforce_global_minimum or areas[component] < _local_minimum(
					component, neighbors, areas, minimum_cells
			):
				undersized_nonisolated += 1
			else:
				locally_consistent_undersized += 1
		if areas[component] > maximum_cells:
			oversized += 1
		if areas[component] > int(ceil(float(maximum_cells) * 1.5)):
			extreme_oversized += 1

	var discarded_roots: Dictionary = {}
	var discarded_cells := 0
	if discard_isolated_undersized:
		for component in range(component_count):
			if parent[component] != component or areas[component] >= minimum_cells:
				continue
			var neighbors := _canonical_neighbors(component, parent, adjacency)
			if neighbors.is_empty():
				discarded_roots[component] = true
				discarded_cells += areas[component]

	var retained_partition_sizes: Array[int] = []
	for component in range(component_count):
		if parent[component] != component or discarded_roots.has(component):
			continue
		retained_partition_sizes.append(areas[component])

	# Final materialization is now the only unavoidable per-active-pixel CPU pass
	# in the common complete-map path. Runs make it branch-free and contiguous.
	region_ids = PackedInt32Array()
	queue = PackedInt32Array()
	var output_ids := PackedInt32Array()
	output_ids.resize(pixel_count)
	output_ids.fill(-1)
	var root_by_component := PackedInt32Array()
	root_by_component.resize(component_count)
	for component in range(component_count):
		root_by_component[component] = _find_root(parent, component)

	for run_index in range(run_count):
		var root := root_by_component[run_component[run_index]]
		if discarded_roots.has(root):
			continue
		var output_id := component_ids[root]
		var row := run_rows[run_index] * w
		for x in range(run_starts[run_index], run_ends[run_index] + 1):
			output_ids[row + x] = output_id

	var unresolved_active_cells := 0
	if not assume_complete_gpu_map:
		unresolved_active_cells = maxi(active_cells - represented_active_cells, 0)
	var unassigned_active_cells := unresolved_active_cells + discarded_cells
	var output := output_ids.to_byte_array()
	var finalize_done_usec := Time.get_ticks_usec()

	return {
		"data": output,
		"partition_sizes": retained_partition_sizes,
		"unassigned_active_cells": unassigned_active_cells,
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
		"discarded_isolated_undersized": discarded_roots.size(),
		"discarded_isolated_cells": discarded_cells,
		"final_count": retained_partition_sizes.size(),
		"run_count": run_count,
		"timing_fill_ms": float(fill_done_usec - normalization_start_usec) / 1000.0,
		"timing_components_ms": float(components_done_usec - fill_done_usec) / 1000.0,
		"timing_adjacency_ms": float(adjacency_done_usec - components_done_usec) / 1000.0,
		"timing_merge_ms": float(merge_done_usec - adjacency_done_usec) / 1000.0,
		"timing_finalize_ms": float(finalize_done_usec - merge_done_usec) / 1000.0,
		"timing_total_internal_ms": float(finalize_done_usec - normalization_start_usec) / 1000.0,
	}


## Consolidate departments that are still below the configured minimum only
## because their water component is physically disconnected from every other
## water component.  Such pieces cannot be enlarged contiguously without
## painting land, so nearby small components are grouped under one shared
## administrative ID until the group's total area approaches target_cells.
##
## Geometry is never invented: only active pixels are relabelled.  Water type is
## used as a grouping class so freshwater fragments preferentially stay with
## freshwater and saltwater with saltwater.  X wraps; Y never wraps.
static func consolidate_disconnected_undersized(region_data: PackedByteArray,
		active_mask: PackedByteArray, class_mask: PackedByteArray,
		w: int, h: int, target_cells: float,
		minimum_ratio: float = 0.45,
		maximum_ratio: float = 1.85) -> Dictionary:
	var pixel_count := w * h
	if region_data.size() != pixel_count * 4 or active_mask.size() != pixel_count:
		return {}
	var valid_class_mask := class_mask.size() == pixel_count

	var output := region_data.duplicate()
	var minimum_cells := maxi(
		int(ceil(target_cells * clampf(minimum_ratio, 0.0, 1.0))), 2
	)
	var maximum_cells := maxi(
		int(ceil(target_cells * maxf(maximum_ratio, minimum_ratio + 0.05))),
		minimum_cells + 1
	)
	var target_int := maxi(int(round(target_cells)), minimum_cells)

	var counts: Dictionary = {}
	var sum_x: Dictionary = {}
	var sum_y: Dictionary = {}
	var id_class: Dictionary = {}
	for index in range(pixel_count):
		if active_mask[index] == 0:
			continue
		var region_id := int(output.decode_u32(index * 4))
		if region_id == INVALID_ID:
			continue
		counts[region_id] = int(counts.get(region_id, 0)) + 1
		sum_x[region_id] = float(sum_x.get(region_id, 0.0)) + float(index % w)
		sum_y[region_id] = float(sum_y.get(region_id, 0.0)) + float(int(index / w))
		if not id_class.has(region_id):
			id_class[region_id] = int(class_mask[index]) if valid_class_mask else 0

	if counts.is_empty():
		return {
			"data": output,
			"minimum_cells": minimum_cells,
			"maximum_cells": maximum_cells,
			"grouped_departments": 0,
			"grouped_cells": 0,
			"compound_departments": 0,
			"forced_overflow_groups": 0,
			"cross_class_fallbacks": 0,
			"unassigned_mask_cells": _count_unassigned(output, active_mask),
			"unavoidable_undersized": 0,
		}

	var small_by_class: Dictionary = {}
	var valid_by_class: Dictionary = {}
	var all_valid_ids: Array[int] = []
	for raw_id in counts.keys():
		var region_id := int(raw_id)
		var cls := int(id_class.get(region_id, 0))
		if int(counts[region_id]) < minimum_cells:
			if not small_by_class.has(cls):
				small_by_class[cls] = []
			var small_list: Array = small_by_class[cls]
			small_list.append(region_id)
			small_by_class[cls] = small_list
		else:
			if not valid_by_class.has(cls):
				valid_by_class[cls] = []
			var valid_list: Array = valid_by_class[cls]
			valid_list.append(region_id)
			valid_by_class[cls] = valid_list
			all_valid_ids.append(region_id)

	if small_by_class.is_empty():
		return {
			"data": output,
			"minimum_cells": minimum_cells,
			"maximum_cells": maximum_cells,
			"grouped_departments": 0,
			"grouped_cells": 0,
			"compound_departments": 0,
			"forced_overflow_groups": 0,
			"cross_class_fallbacks": 0,
			"unassigned_mask_cells": _count_unassigned(output, active_mask),
			"unavoidable_undersized": 0,
		}

	var remap: Dictionary = {}
	var grouped_departments := 0
	var grouped_cells := 0
	var compound_departments := 0
	var forced_overflow_groups := 0
	var cross_class_fallbacks := 0
	var unavoidable_undersized := 0
	var band_height := maxi(int(round(sqrt(maxf(target_cells, 1.0)) * 2.0)), 1)

	for raw_class in small_by_class.keys():
		var cls := int(raw_class)
		var ordered_ids: Array = (small_by_class[cls] as Array).duplicate()
		# Serpentine geographic order keeps compound departments local without an
		# O(n²) nearest-neighbour pass when a map contains thousands of tiny lakes.
		ordered_ids.sort_custom(func(a_raw, b_raw) -> bool:
			var a := int(a_raw)
			var b := int(b_raw)
			var ay := float(sum_y[a]) / float(maxi(int(counts[a]), 1))
			var by := float(sum_y[b]) / float(maxi(int(counts[b]), 1))
			var aband := int(floor(ay / float(band_height)))
			var bband := int(floor(by / float(band_height)))
			if aband != bband:
				return aband < bband
			var ax := float(sum_x[a]) / float(maxi(int(counts[a]), 1))
			var bx := float(sum_x[b]) / float(maxi(int(counts[b]), 1))
			if absf(ax - bx) > 0.000001:
				return ax < bx if (aband % 2) == 0 else ax > bx
			if absf(ay - by) > 0.000001:
				return ay < by
			return a < b
		)

		var groups: Array[Dictionary] = []
		var current_ids: Array[int] = []
		var current_cells := 0
		for raw_id in ordered_ids:
			var region_id := int(raw_id)
			var size := int(counts[region_id])
			# Once a group is already legal, do not push it past the target simply
			# to absorb another component.  Start a new local compound department.
			if (
				not current_ids.is_empty()
				and current_cells >= minimum_cells
				and current_cells + size > target_int
			):
				groups.append({"ids": current_ids, "cells": current_cells})
				current_ids = []
				current_cells = 0
			current_ids.append(region_id)
			current_cells += size
		if not current_ids.is_empty():
			groups.append({"ids": current_ids, "cells": current_cells})

		# A final remainder below the minimum is merged into the preceding local
		# compound group when possible.  With the default 45%-185% window this
		# remains comfortably below the upper bound in normal cases.
		if groups.size() >= 2 and int(groups[groups.size() - 1]["cells"]) < minimum_cells:
			var tail: Dictionary = groups.pop_back()
			var previous: Dictionary = groups[groups.size() - 1]
			var combined := int(previous["cells"]) + int(tail["cells"])
			if combined > maximum_cells:
				forced_overflow_groups += 1
			(previous["ids"] as Array).append_array(tail["ids"] as Array)
			previous["cells"] = combined
			groups[groups.size() - 1] = previous

		for group_index in range(groups.size()):
			var group: Dictionary = groups[group_index]
			var ids: Array = group["ids"]
			var cells := int(group["cells"])
			if ids.is_empty():
				continue

			# If this water class contains too little isolated area to reach the
			# minimum, attach the remainder to the nearest already-valid department
			# of the same water class.  Crossing the other class is a last resort.
			if cells < minimum_cells:
				var receivers: Array = valid_by_class.get(cls, [])
				var cross_class := false
				if receivers.is_empty():
					receivers = all_valid_ids
					cross_class = not receivers.is_empty()
				if not receivers.is_empty():
					var receiver := _nearest_region_id(
						ids, receivers, counts, sum_x, sum_y, w
					)
					if receiver >= 0:
						for raw_id in ids:
							var region_id := int(raw_id)
							remap[region_id] = receiver
							grouped_departments += 1
							grouped_cells += int(counts[region_id])
						if cross_class:
							cross_class_fallbacks += 1
						continue
				unavoidable_undersized += 1

			var root := int(ids[0])
			if ids.size() > 1:
				compound_departments += 1
			for raw_id in ids:
				var region_id := int(raw_id)
				remap[region_id] = root
				if region_id != root:
					grouped_departments += 1
					grouped_cells += int(counts[region_id])

	for index in range(pixel_count):
		if active_mask[index] == 0:
			continue
		var region_id := int(output.decode_u32(index * 4))
		if remap.has(region_id):
			output.encode_u32(index * 4, int(remap[region_id]))

	return {
		"data": output,
		"minimum_cells": minimum_cells,
		"maximum_cells": maximum_cells,
		"grouped_departments": grouped_departments,
		"grouped_cells": grouped_cells,
		"compound_departments": compound_departments,
		"forced_overflow_groups": forced_overflow_groups,
		"cross_class_fallbacks": cross_class_fallbacks,
		"unassigned_mask_cells": _count_unassigned(output, active_mask),
		"unavoidable_undersized": unavoidable_undersized,
	}


static func _nearest_region_id(source_ids: Array, receiver_ids: Array,
		counts: Dictionary, sum_x: Dictionary, sum_y: Dictionary, w: int) -> int:
	var source_cells := 0
	var source_x := 0.0
	var source_y := 0.0
	for raw_id in source_ids:
		var region_id := int(raw_id)
		var cells := maxi(int(counts.get(region_id, 0)), 1)
		source_cells += cells
		source_x += float(sum_x.get(region_id, 0.0))
		source_y += float(sum_y.get(region_id, 0.0))
	if source_cells <= 0:
		return -1
	var sx := source_x / float(source_cells)
	var sy := source_y / float(source_cells)
	var best := -1
	var best_distance := INF
	for raw_id in receiver_ids:
		var region_id := int(raw_id)
		var cells := maxi(int(counts.get(region_id, 0)), 1)
		var rx := float(sum_x.get(region_id, 0.0)) / float(cells)
		var ry := float(sum_y.get(region_id, 0.0)) / float(cells)
		var dx := absf(sx - rx)
		dx = minf(dx, float(w) - dx)
		var distance := dx * dx + (sy - ry) * (sy - ry)
		if distance < best_distance - 0.000001 or (
			absf(distance - best_distance) <= 0.000001 and region_id < best
		):
			best = region_id
			best_distance = distance
	return best


static func _count_unassigned(region_data: PackedByteArray,
		active_mask: PackedByteArray) -> int:
	var count := 0
	for index in range(active_mask.size()):
		if active_mask[index] != 0 and int(region_data.decode_u32(index * 4)) == INVALID_ID:
			count += 1
	return count


static func _add_contact(a: int, b: int,
		adjacency: Array[Dictionary]) -> void:
	if a < 0 or b < 0 or a == b:
		return
	adjacency[a][b] = int(adjacency[a].get(b, 0)) + 1
	adjacency[b][a] = int(adjacency[b].get(a, 0)) + 1


static func _add_contact_count(a: int, b: int, count: int,
		adjacency: Array[Dictionary]) -> void:
	if a < 0 or b < 0 or a == b or count <= 0:
		return
	adjacency[a][b] = int(adjacency[a].get(b, 0)) + count
	adjacency[b][a] = int(adjacency[b].get(a, 0)) + count


static func _find_root(parent: PackedInt32Array, component: int) -> int:
	var root := component
	while parent[root] != root:
		root = parent[root]
	# Path compression keeps repeated adjacency/merge lookups effectively O(1)
	# without changing the selected root or any deterministic tie-break.
	var current := component
	while parent[current] != current:
		var next := parent[current]
		parent[current] = root
		current = next
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
