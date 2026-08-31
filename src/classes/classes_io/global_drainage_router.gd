class_name GlobalDrainageRouter
extends RefCounted

## Coarse hierarchical routing between completed hydrology tiles. Each tile may
## publish one or more boundary outlets. The router deterministically connects an
## outlet to the lowest neighbouring outlet and exposes the resulting acyclic
## tile graph to detailed per-tile hydrology.

static func route(outlets_by_tile: Dictionary, tile_grid: Vector2i) -> Dictionary:
	var routes: Dictionary = {}
	var tile_keys := outlets_by_tile.keys()
	tile_keys.sort_custom(func(a, b):
		var av: Vector2i = a
		var bv: Vector2i = b
		return av.y < bv.y or (av.y == bv.y and av.x < bv.x)
	)
	for tile_key in tile_keys:
		var tile: Vector2i = tile_key
		var own: Dictionary = _lowest_outlet(outlets_by_tile.get(tile, []))
		if own.is_empty():
			continue
		var candidates: Array = []
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var ny = tile.y + offset.y
			if ny < 0 or ny >= tile_grid.y:
				continue
			var neighbor := Vector2i(posmod(tile.x + offset.x, tile_grid.x), ny)
			var outlet := _lowest_outlet(outlets_by_tile.get(neighbor, []))
			if not outlet.is_empty():
				candidates.append({"tile": neighbor, "outlet": outlet})
		candidates.sort_custom(func(a, b):
			var ah := float((a["outlet"] as Dictionary).get("spill_height", INF))
			var bh := float((b["outlet"] as Dictionary).get("spill_height", INF))
			if not is_equal_approx(ah, bh):
				return ah < bh
			var at: Vector2i = a["tile"]
			var bt: Vector2i = b["tile"]
			return at.y < bt.y or (at.y == bt.y and at.x < bt.x)
		)
		for candidate in candidates:
			var neighbor_outlet: Dictionary = candidate["outlet"]
			if float(neighbor_outlet.get("spill_height", INF)) < float(own.get("spill_height", INF)):
				routes[tile] = candidate["tile"]
				break
	return _break_cycles(routes)

static func _lowest_outlet(outlets: Array) -> Dictionary:
	var best: Dictionary = {}
	for outlet_value in outlets:
		var outlet: Dictionary = outlet_value
		if best.is_empty() or float(outlet.get("spill_height", INF)) < float(best.get("spill_height", INF)):
			best = outlet
	return best

static func _break_cycles(routes: Dictionary) -> Dictionary:
	var clean := routes.duplicate()
	var starts := clean.keys()
	starts.sort_custom(func(a, b):
		var av: Vector2i = a
		var bv: Vector2i = b
		return av.y < bv.y or (av.y == bv.y and av.x < bv.x)
	)
	for start in starts:
		var seen: Dictionary = {}
		var current = start
		while clean.has(current):
			if seen.has(current):
				# Deterministically remove the edge from the lexicographically largest
				# tile in the cycle so repeated runs produce the same graph.
				var cycle_nodes := seen.keys()
				cycle_nodes.sort_custom(func(a, b):
					var av: Vector2i = a
					var bv: Vector2i = b
					return av.y < bv.y or (av.y == bv.y and av.x < bv.x)
				)
				clean.erase(cycle_nodes[-1])
				break
			seen[current] = true
			current = clean[current]
	return clean
