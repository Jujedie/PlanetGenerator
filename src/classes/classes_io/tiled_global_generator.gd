class_name TiledGlobalGenerator
extends RefCounted

signal tile_completed(phase: String, tile: Vector2i, completed: int, total: int)
signal generation_cancelled(reason: String)

const HARD_VRAM_BUDGET_BYTES := 5 * 1024 * 1024 * 1024
const PREFERRED_VRAM_BUDGET_BYTES := 4 * 1024 * 1024 * 1024
const DEFAULT_WORKING_BYTES_PER_CELL := 160
const MAX_TILE_SAMPLE_EDGE := 8192

var dimensions: Vector2i
var tile_size := PlanetGridContract.DEFAULT_TILE_SIZE
var hard_vram_budget_bytes := HARD_VRAM_BUDGET_BYTES
var preferred_vram_budget_bytes := PREFERRED_VRAM_BUDGET_BYTES
var cancel_token := GenerationCancelToken.new()
var last_report: Dictionary = {}

func _init(global_dimensions: Vector2i,
		configured_tile_size: int = PlanetGridContract.DEFAULT_TILE_SIZE) -> void:
	dimensions = global_dimensions
	tile_size = maxi(configured_tile_size, 64)

func build_tile_plan(halo: int = 0) -> Array:
	var plan: Array = []
	var grid := PlanetGridContract.tile_grid_dimensions(dimensions, tile_size)
	for ty in range(grid.y):
		for tx in range(grid.x):
			var tile := Vector2i(tx, ty)
			var geometry := PlanetGridContract.tile_rect_with_halo(tile, dimensions, halo, tile_size)
			plan.append({
				"tile": tile,
				"core": geometry["core"],
				"sample_origin": geometry["sample_origin"],
				"sample_size": geometry["sample_size"],
				"crop_offset": geometry["crop_offset"],
				"global_dimensions": dimensions,
				"horizontal_wrap": true,
			})
	return plan

func estimate_active_vram_bytes(halo: int,
		working_bytes_per_cell: int = DEFAULT_WORKING_BYTES_PER_CELL) -> int:
	var sample_edge := tile_size + maxi(halo, 0) * 2
	return sample_edge * sample_edge * maxi(working_bytes_per_cell, 1)

func validate_budget(halo: int,
		working_bytes_per_cell: int = DEFAULT_WORKING_BYTES_PER_CELL) -> Dictionary:
	var estimate := estimate_active_vram_bytes(halo, working_bytes_per_cell)
	var sample_edge := tile_size + maxi(halo, 0) * 2
	return {
		"estimated_bytes": estimate,
		"sample_edge": sample_edge,
		"within_texture_limit": sample_edge <= MAX_TILE_SAMPLE_EDGE,
		"hard_budget_bytes": hard_vram_budget_bytes,
		"preferred_budget_bytes": preferred_vram_budget_bytes,
		"within_hard_budget": estimate <= hard_vram_budget_bytes and sample_edge <= MAX_TILE_SAMPLE_EDGE,
		"within_preferred_budget": estimate <= preferred_vram_budget_bytes and sample_edge <= MAX_TILE_SAMPLE_EDGE,
	}

## Runs one phase tile-by-tile. generator receives a tile descriptor and the
## cancellation token, and returns {layer_name: PackedByteArray}. Only core tile
## payloads are stored; the generator is responsible for cropping its halo.
func run_phase(phase_name: String, output_dir: String, halo: int,
		working_bytes_per_cell: int, generator: Callable, lod: int = 0,
		expected_layers: Array = []) -> Dictionary:
	var budget := validate_budget(halo, working_bytes_per_cell)
	if not bool(budget["within_hard_budget"]):
		push_error("Tiled phase '%s' rejected: estimated active VRAM %d exceeds budget %d" % [
			phase_name, budget["estimated_bytes"], hard_vram_budget_bytes
		])
		return {"ok": false, "reason": "vram_budget", "budget": budget}

	var store := PlanetTileStore.new(output_dir)
	store.remove_incomplete_files()
	var plan := build_tile_plan(halo)
	var completed := 0
	var skipped := 0
	var layer_checksums: Dictionary = {}
	for descriptor_value in plan:
		if cancel_token.is_cancelled():
			emit_signal("generation_cancelled", cancel_token.reason)
			last_report = {
				"ok": false, "cancelled": true, "reason": cancel_token.reason,
				"completed_tiles": completed, "total_tiles": plan.size(),
				"budget": budget,
			}
			return last_report
		var descriptor: Dictionary = descriptor_value
		var tile: Vector2i = descriptor["tile"]
		if not expected_layers.is_empty():
			var already_complete := true
			for expected_layer in expected_layers:
				already_complete = already_complete and store.has_complete_tile(str(expected_layer), lod, tile)
			if already_complete:
				skipped += 1
				emit_signal("tile_completed", phase_name, tile, completed + skipped, plan.size())
				continue
		var generated = generator.call(descriptor, cancel_token)
		if not generated is Dictionary:
			return {"ok": false, "reason": "invalid_generator_result", "tile": tile}
		for layer_name in generated.keys():
			var payload = generated[layer_name]
			if not payload is PackedByteArray:
				continue
			var write_result := store.write_tile(str(layer_name), lod, tile, payload, {
				"phase": phase_name,
				"core": _rect_to_array(descriptor["core"]),
				"global_dimensions": [dimensions.x, dimensions.y],
				"projection": PlanetGridContract.PROJECTION_ID,
			})
			if not bool(write_result.get("ok", false)):
				return {"ok": false, "reason": "tile_write", "detail": write_result, "tile": tile}
			layer_checksums["%s:%d:%d" % [str(layer_name), tile.x, tile.y]] = write_result["sha256"]
		completed += 1
		emit_signal("tile_completed", phase_name, tile, completed, plan.size())

	last_report = {
		"ok": true,
		"cancelled": false,
		"phase": phase_name,
		"completed_tiles": completed,
		"skipped_tiles": skipped,
		"total_tiles": plan.size(),
		"budget": budget,
		"checksums": layer_checksums,
	}
	return last_report

func cancel(reason: String = "user") -> void:
	cancel_token.cancel(reason)

static func absolute_cell_from_sample(descriptor: Dictionary,
		local_sample: Vector2i) -> Vector2i:
	var origin: Vector2i = descriptor["sample_origin"]
	var dimensions_value: Vector2i = descriptor["global_dimensions"]
	return PlanetGridContract.wrapped_global_cell(origin + local_sample, dimensions_value)

static func _rect_to_array(rect: Rect2i) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
