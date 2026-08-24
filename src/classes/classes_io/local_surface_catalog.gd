class_name LocalSurfaceCatalog
extends RefCounted

## Compact authoritative identifiers used by Milestone 7 local-zone layers.
## These IDs are data contracts, not display colors.

enum SoilType {
	ROCK = 0,
	GRAVEL = 1,
	SAND = 2,
	DIRT = 3,
	CLAY = 4,
	SILT = 5,
	PEAT = 6,
	VOLCANIC = 7,
	REGOLITH = 8,
	SALT = 9,
}

enum RockType {
	SEDIMENTARY = 0,
	IGNEOUS = 1,
	METAMORPHIC = 2,
	VOLCANIC = 3,
	REGOLITH = 4,
	ICE = 5,
}

enum SurfaceMaterial {
	BARE_ROCK = 0,
	GRAVEL = 1,
	SAND = 2,
	DIRT = 3,
	MUD = 4,
	GRASS = 5,
	FOREST_FLOOR = 6,
	PEAT = 7,
	SALT_CRUST = 8,
	SNOW = 9,
	ICE = 10,
	SHALLOW_WATER = 11,
	DEEP_WATER = 12,
}

static func soil_name(value: int) -> String:
	return SoilType.keys()[clampi(value, 0, SoilType.size() - 1)]

static func rock_name(value: int) -> String:
	return RockType.keys()[clampi(value, 0, RockType.size() - 1)]

static func surface_name(value: int) -> String:
	return SurfaceMaterial.keys()[clampi(value, 0, SurfaceMaterial.size() - 1)]
