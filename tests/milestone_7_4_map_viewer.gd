extends Node

func _ready() -> void:
	var overlay := PlanetMapCrosshair.new()
	add_child(overlay)
	overlay.size = Vector2(200, 100)
	overlay.set_point(Vector2(80, 40))
	assert(overlay.has_point)
	var world := PlanetGridContract.global_cell_to_world(Vector2i(50, 25), Vector2i(100, 50))
	assert(absf(rad_to_deg(world.x)) < 2.0)
	print("Milestone 7.4 advanced viewer regression: PASS")
	get_tree().quit()
