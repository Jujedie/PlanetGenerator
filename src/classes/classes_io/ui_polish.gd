class_name UIPolish
extends RefCounted

## Milestone 7.7 shared presentation helpers.
## Keep this class UI-only so simulation output cannot depend on it.

static func human_bytes(value: int) -> String:
	var amount: float = float(maxi(value, 0))
	var suffixes: Array[String] = ["B", "KiB", "MiB", "GiB", "TiB"]
	for suffix in suffixes:
		if amount < 1024.0 or suffix == "TiB":
			return "%.2f %s" % [amount, suffix]
		amount /= 1024.0
	return "%d B" % maxi(value, 0)
