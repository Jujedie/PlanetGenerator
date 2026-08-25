extends Node

# M7.2 regression: every exported resource map must resolve to a translation
# key in English/French/German source CSV. Petroleum is exported separately.

func _ready() -> void:
	var csv := FileAccess.get_file_as_string("res://data/translations/base.csv")
	var ids: Array[String] = []
	for name in Exporter.RESOURCE_NAMES:
		ids.append(str(name))
	ids.append("petrole")
	var missing: Array[String] = []
	for id in ids:
		var key := "RESOURCE_" + id.to_upper()
		if not ("\n" + csv).contains("\n" + key + ","):
			missing.append(key)
	if not missing.is_empty():
		push_error("Missing resource UI translations: %s" % str(missing))
	get_tree().quit(0 if missing.is_empty() else 1)
