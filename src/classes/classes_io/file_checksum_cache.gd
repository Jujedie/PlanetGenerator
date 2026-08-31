class_name FileChecksumCache
extends RefCounted

## Milestone 8.1 — bounded SHA-256 cache for files that are hashed repeatedly by
## the export catalog, planet manifest, reloadable project and tiled store.
## Cache keys are guarded by size + modification time, so changed files are
## always rehashed. The cache is bounded to avoid turning long batch runs into a
## new memory leak.

const MAX_ENTRIES := 4096

static var _entries: Dictionary = {}
static var _hits := 0
static var _misses := 0
static var _resets := 0

static func sha256(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var fingerprint := _fingerprint(path)
	if _entries.has(path):
		var cached: Dictionary = _entries[path]
		if int(cached.get("size", -1)) == int(fingerprint["size"]) and int(cached.get("mtime", -1)) == int(fingerprint["mtime"]):
			_hits += 1
			return str(cached.get("sha256", ""))
	_misses += 1
	var hash := FileAccess.get_sha256(path)
	_store(path, hash, fingerprint)
	return hash

static func remember(path: String, hash: String) -> void:
	if path.is_empty() or hash.is_empty() or not FileAccess.file_exists(path):
		return
	_store(path, hash, _fingerprint(path))

static func invalidate(path: String) -> void:
	_entries.erase(path)

static func clear() -> void:
	_entries.clear()

static func reset_metrics() -> void:
	_hits = 0
	_misses = 0
	_resets = 0

static func metrics() -> Dictionary:
	return {
		"entries": _entries.size(),
		"hits": _hits,
		"misses": _misses,
		"resets": _resets,
	}

static func _store(path: String, hash: String, fingerprint: Dictionary) -> void:
	if not _entries.has(path) and _entries.size() >= MAX_ENTRIES:
		# Clearing in one operation is cheaper than maintaining an O(n) FIFO while
		# processing hundreds of thousands of tiled payloads.
		_entries.clear()
		_resets += 1
	_entries[path] = {
		"size": int(fingerprint["size"]),
		"mtime": int(fingerprint["mtime"]),
		"sha256": hash,
	}

static func _fingerprint(path: String) -> Dictionary:
	return {
		"size": int(FileAccess.get_size(path)),
		"mtime": int(FileAccess.get_modified_time(path)),
	}
