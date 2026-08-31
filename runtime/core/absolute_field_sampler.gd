class_name PGAbsoluteFieldSampler
extends RefCounted

## Small deterministic absolute-coordinate sampler used by tiled infrastructure,
## LOD previews and regression tests. Production phases may use their own GPU
## implementation, but must derive randomness from these same absolute inputs.

static func hash_u32(x: int) -> int:
	var value := x & 0xFFFFFFFF
	value ^= value >> 16
	value = int((value * 0x7FEB352D) & 0xFFFFFFFF)
	value ^= value >> 15
	value = int((value * 0x846CA68B) & 0xFFFFFFFF)
	value ^= value >> 16
	return value & 0xFFFFFFFF

static func hash_cell(global_cell: Vector2i, seed: int, channel: int = 0) -> int:
	var value := int(global_cell.x * 73856093) ^ int(global_cell.y * 19349663)
	value ^= int(seed * 83492791) ^ int(channel * 2654435761)
	return hash_u32(value)

static func unit_noise(global_cell: Vector2i, seed: int, channel: int = 0) -> float:
	return float(hash_cell(global_cell, seed, channel)) / 4294967295.0

static func sample_wrapped(global_cell: Vector2i, dimensions: Vector2i,
		seed: int, channel: int = 0) -> float:
	return unit_noise(PGPlanetGridContract.wrapped_global_cell(global_cell, dimensions), seed, channel)

static func smooth_noise(global_cell: Vector2i, dimensions: Vector2i,
		seed: int, scale_cells: int, channel: int = 0) -> float:
	var scale := maxi(scale_cells, 1)
	var gx := floori(float(global_cell.x) / float(scale))
	var gy := floori(float(global_cell.y) / float(scale))
	var fx := fposmod(float(global_cell.x), float(scale)) / float(scale)
	var fy := fposmod(float(global_cell.y), float(scale)) / float(scale)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var coarse_dimensions := Vector2i(
		maxi(1, ceili(float(dimensions.x) / float(scale))),
		maxi(1, ceili(float(dimensions.y) / float(scale)))
	)
	var n00 := sample_wrapped(Vector2i(gx, gy), coarse_dimensions, seed, channel)
	var n10 := sample_wrapped(Vector2i(gx + 1, gy), coarse_dimensions, seed, channel)
	var n01 := sample_wrapped(Vector2i(gx, gy + 1), coarse_dimensions, seed, channel)
	var n11 := sample_wrapped(Vector2i(gx + 1, gy + 1), coarse_dimensions, seed, channel)
	return lerpf(lerpf(n00, n10, fx), lerpf(n01, n11, fx), fy)
