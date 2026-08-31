extends Node

func _ready() -> void:
	var overlay := PlanetMapCrosshair.new()
	add_child(overlay)
	overlay.set_point(Vector2(80, 40))
	assert(overlay.has_point)
	var world := PlanetGridContract.global_cell_to_world(Vector2i(50, 25), Vector2i(100, 50))
	assert(absf(rad_to_deg(world.x)) < 2.0)

	# Every biome must expose a stable localization key and remain recoverable
	# from the exact RGBA8 color written to biome_map / river_map.
	assert(Enum.BIOME_TRANSLATION_KEYS.size() == Enum.BIOMES.size())
	for biome_value in Enum.BIOMES:
		var biome := biome_value as Biome
		assert(biome != null)
		var key := Enum.get_biome_translation_key(biome)
		assert(key.begins_with("BIOME_"))
		assert(not Enum.get_biome_display_name(biome).is_empty())
		var river_filter := 1 if biome.isRiver() else 0
		var matched: Biome = Enum.find_biome_by_map_color(
			biome.get_couleur(), int(biome.get_type_planete()[0]), river_filter
		)
		assert(matched == biome)
	print("Milestone 7.4 advanced viewer regression: PASS")
	get_tree().quit()
