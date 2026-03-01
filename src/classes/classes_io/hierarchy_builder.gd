class_name HierarchyBuilder
extends RefCounted

## ============================================================================
## HIERARCHY BUILDER — CPU BFS Administrative Grouping
## ============================================================================
## Porté depuis PlaneteTools.gd (L'Âge Spatial) pour PlanetGenerator.
## Regroupe les départements en régions → pays → continents (terre)
## ou régions-mer → bassins → océans (mer), via BFS hop-distance.
##
## Algorithme :
##   Étape 1 — BFS hop-distance (≤ maxTaille, chaque saut ≤ distMaxBFS)
##   Étape 2 — Absorption par dominance ≥ SEUIL_DOMINANCE (itérée)
##   Étape 3 — Orphelins : fusion ou groupe autonome
##   Post    — _reassigner : réaffecter les unités isolées de leur groupe
## ============================================================================

# ─── Constantes (identiques à PlaneteTools.gd) ────────────────────────────────

const MAX_DEP_PAR_REGION    : int   = 12
const MAX_REG_PAR_PAYS      : int   = 22
const MAX_PAYS_PAR_CONT     : int   = 35

const MAX_DEP_PAR_REGMER    : int   = 12
const MAX_REGMER_PAR_BASSIN : int   = 22
const MAX_BASSIN_PAR_OCEAN  : int   = 20

const DIST_BFS_REGION       : float = 300.0
const DIST_BFS_PAYS         : float = 600.0
const DIST_PONT_CONTINENT   : float = 350.0

const SEUIL_DOMINANCE       : float = 0.70

## Offset pour les IDs de groupes (évite collision avec les IDs département)
const _ID_LAND : int = 10_000_000
const _ID_SEA  : int = 50_000_000

# ─── API Publique ─────────────────────────────────────────────────────────────

## Calcule le merge-map pour le wrapping horizontal (projection équirectangulaire).
## Retourne Dictionary { id_à_fusionner → id_canonique }.
static func compute_merge_map(data: PackedByteArray, w: int, h: int) -> Dictionary:
	var left: Dictionary = {}
	var right: Dictionary = {}
	for y in range(h):
		var lid: int = data.decode_u32((y * w) * 4)
		if lid != 0xFFFFFFFF:
			left[y] = lid
		var rid: int = data.decode_u32((y * w + w - 1) * 4)
		if rid != 0xFFFFFFFF:
			right[y] = rid
	var merge: Dictionary = {}
	for y in right.keys():
		if not left.has(y): continue
		var r: int = right[y]
		var l: int = left[y]
		if r != l and r != 0xFFFFFFFF and l != 0xFFFFFFFF:
			merge[maxi(r, l)] = mini(r, l)
	# Transitivité
	for k in merge.keys():
		var t: int = merge[k]
		while merge.has(t):
			t = merge[t]
		merge[k] = t
	return merge

## Construit la hiérarchie terrestre à 3 niveaux.
## Retourne [dept→région, dept→pays, dept→continent].
static func build_land(data: PackedByteArray, w: int, h: int,
		merge: Dictionary) -> Array:
	var info := _scan(data, w, h, merge)
	var depts: Array = info[0]
	var cref: Dictionary = info[1]
	var adj0: Dictionary = info[2]
	if depts.is_empty():
		return [{}, {}, {}]
	print("    %d départements terrestres" % depts.size())

	var gen := [_ID_LAND]

	# 0→1  Département → Région
	var r1 := _grouper(depts, adj0, cref,
		MAX_DEP_PAR_REGION, true, DIST_BFS_REGION, gen)
	_reassigner(depts, adj0, r1)
	print("    → %d régions" % _unique_values(r1).size())

	# 1→2  Région → Pays
	var rids := _unique_values(r1)
	var rch  := _invert(r1)
	var adj1 := _adj_children(rids, rch, adj0)
	var cr1  := _coord_children(rids, rch, cref)
	var r2   := _grouper(rids, adj1, cr1,
		MAX_REG_PAR_PAYS, true, DIST_BFS_PAYS, gen)
	_reassigner(rids, adj1, r2)
	print("    → %d pays" % _unique_values(r2).size())

	# 2→3  Pays → Continent  (pont distance pour relier îles proches)
	var pids  := _unique_values(r2)
	var pch   := _invert(r2)
	var adj2i := _adj_children(pids, pch, adj1)
	var cr2   := _coord_children(pids, pch, cr1)
	var adj2d := _adj_distance(pids, cr2, DIST_PONT_CONTINENT)
	var adj2  := _adj_union(adj2i, adj2d)
	var r3    := _grouper(pids, adj2, cr2,
		MAX_PAYS_PAR_CONT, false, 0.0, gen)
	_reassigner(pids, adj2, r3)
	print("    → %d continents" % _unique_values(r3).size())

	# Composition : dept → pays, dept → continent
	var d2p: Dictionary = {}
	var d2c: Dictionary = {}
	for d in depts:
		var rg: int = r1.get(d, d)
		var py: int = r2.get(rg, rg)
		d2p[d] = py
		d2c[d] = r3.get(py, py)
	return [r1, d2p, d2c]

## Construit la hiérarchie maritime à 3 niveaux.
## Pas de pont distance (les océans sont naturellement connexes).
## Retourne [dept→région-mer, dept→bassin, dept→océan].
static func build_sea(data: PackedByteArray, w: int, h: int,
		merge: Dictionary) -> Array:
	var info := _scan(data, w, h, merge)
	var depts: Array = info[0]
	var cref: Dictionary = info[1]
	var adj0: Dictionary = info[2]
	if depts.is_empty():
		return [{}, {}, {}]
	print("    %d départements maritimes" % depts.size())

	var gen := [_ID_SEA]

	# 0→1  Dept-mer → Région-mer
	var r1 := _grouper(depts, adj0, cref,
		MAX_DEP_PAR_REGMER, true, DIST_BFS_REGION, gen)
	_reassigner(depts, adj0, r1)
	print("    → %d régions-mer" % _unique_values(r1).size())

	# 1→2  Région-mer → Bassin
	var rids := _unique_values(r1)
	var rch  := _invert(r1)
	var adj1 := _adj_children(rids, rch, adj0)
	var cr1  := _coord_children(rids, rch, cref)
	var r2   := _grouper(rids, adj1, cr1,
		MAX_REGMER_PAR_BASSIN, true, DIST_BFS_PAYS, gen)
	_reassigner(rids, adj1, r2)
	print("    → %d bassins" % _unique_values(r2).size())

	# 2→3  Bassin → Océan (pas de pont distance)
	var bids := _unique_values(r2)
	var bch  := _invert(r2)
	var adj2 := _adj_children(bids, bch, adj1)
	var cr2  := _coord_children(bids, bch, cr1)
	var r3   := _grouper(bids, adj2, cr2,
		MAX_BASSIN_PAR_OCEAN, false, 0.0, gen)
	_reassigner(bids, adj2, r3)
	print("    → %d océans" % _unique_values(r3).size())

	# Composition
	var d2b: Dictionary = {}
	var d2o: Dictionary = {}
	for d in depts:
		var rg: int = r1.get(d, d)
		var bs: int = r2.get(rg, rg)
		d2b[d] = bs
		d2o[d] = r3.get(bs, bs)
	return [r1, d2b, d2o]

## Assigne des couleurs step-17 (système Region.gd) à une liste de group IDs.
## Retourne Dictionary[int, Color].
static func assign_colors(group_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	var cc := [0, 0, 0]
	const STEP := 17
	for gid in group_ids:
		if out.has(gid):
			continue
		out[gid] = Color(cc[0] / 255.0, cc[1] / 255.0, cc[2] / 255.0, 1.0)
		cc[0] += STEP
		if cc[0] > 255:
			cc[0] = cc[0] % 256
			cc[1] += STEP
		if cc[1] > 255:
			cc[1] = cc[1] % 256
			cc[2] += STEP
		if cc[2] > 255:
			cc[2] = cc[2] % 256
	return out

# ─── Helpers internes ─────────────────────────────────────────────────────────

## Scan unique : extrait IDs départements, coordonnées de référence ET adjacence
## en un seul passage O(W×H) sur les données R32UI.
static func _scan(data: PackedByteArray, w: int, h: int,
		merge: Dictionary) -> Array:
	var ids: Array = []
	var cref: Dictionary = {}
	var seen: Dictionary = {}
	var adj: Dictionary = {}
	for y in range(h):
		for x in range(w):
			var raw: int = data.decode_u32((y * w + x) * 4)
			if raw == 0xFFFFFFFF:
				continue
			var a: int = merge.get(raw, raw)
			# Enregistrer le département
			if not seen.has(a):
				seen[a] = true
				ids.append(a)
				cref[a] = Vector2i(x, y)
			if not adj.has(a):
				adj[a] = {}
			# Voisin droit
			if x + 1 < w:
				var rb: int = data.decode_u32((y * w + x + 1) * 4)
				if rb != 0xFFFFFFFF:
					var b: int = merge.get(rb, rb)
					if b != a:
						if not adj.has(b):
							adj[b] = {}
						(adj[a] as Dictionary)[b] = true
						(adj[b] as Dictionary)[a] = true
			# Voisin bas
			if y + 1 < h:
				var rb: int = data.decode_u32(((y + 1) * w + x) * 4)
				if rb != 0xFFFFFFFF:
					var b: int = merge.get(rb, rb)
					if b != a:
						if not adj.has(b):
							adj[b] = {}
						(adj[a] as Dictionary)[b] = true
						(adj[b] as Dictionary)[a] = true
			# Wrap horizontal (projection équirectangulaire)
			if x == w - 1:
				var rb: int = data.decode_u32((y * w) * 4)
				if rb != 0xFFFFFFFF:
					var b: int = merge.get(rb, rb)
					if b != a:
						if not adj.has(b):
							adj[b] = {}
						(adj[a] as Dictionary)[b] = true
						(adj[b] as Dictionary)[a] = true
	return [ids, cref, adj]

## BFS hop-distance grouping (porté de PlaneteTools._grouperSansEnclaves).
## gen[0] est un compteur mutable pour générer des IDs de groupe uniques.
static func _grouper(units: Array, adj: Dictionary, cref: Dictionary,
		max_size: int, merge_orphans: bool, dist_max: float,
		gen: Array) -> Dictionary:
	var vis: Dictionary = {}
	var c2g: Dictionary = {}      # child → group
	var gch: Dictionary = {}      # group → [children]
	var dm2: float = dist_max * dist_max

	# ── Étape 1 : BFS hop-by-hop ─────────────────────────────────────────────
	for seed_id in units:
		if vis.has(seed_id):
			continue
		var gid: int = gen[0]
		gen[0] += 1
		gch[gid] = []
		var sc := Vector2(cref.get(seed_id, Vector2i.ZERO))
		var front: Array = [[seed_id, sc]]
		while front.size() > 0 and (gch[gid] as Array).size() < max_size:
			var item = front.pop_front()
			var cur: int = item[0]
			var inv: Vector2 = item[1]
			if vis.has(cur):
				continue
			# Contrainte hop : distance entre l'unité et son invitant
			if dm2 > 0.0:
				var cc := Vector2(cref.get(cur, Vector2i.ZERO))
				if inv.distance_squared_to(cc) > dm2:
					continue
			vis[cur] = true
			c2g[cur] = gid
			(gch[gid] as Array).append(cur)
			var cv := Vector2(cref.get(cur, Vector2i.ZERO))
			if adj.has(cur):
				for nb in (adj[cur] as Dictionary).keys():
					if not vis.has(nb):
						front.append([nb, cv])

	# ── Étape 2 : Absorption par dominance ≥ SEUIL_DOMINANCE ─────────────────
	var prog := true
	while prog:
		prog = false
		for uid in units:
			if vis.has(uid):
				continue
			if not adj.has(uid):
				continue
			var gc: Dictionary = {}
			var total: int = 0
			for v in (adj[uid] as Dictionary).keys():
				var g: int = c2g.get(v, -1)
				if g != -1:
					gc[g] = gc.get(g, 0) + 1
					total += 1
			if total == 0:
				continue
			var bg: int = -1
			var bc: int = 0
			for g in gc.keys():
				if gc[g] > bc:
					bc = gc[g]
					bg = g
			if bg != -1 and float(bc) / float(total) >= SEUIL_DOMINANCE:
				vis[uid] = true
				c2g[uid] = bg
				if gch.has(bg):
					(gch[bg] as Array).append(uid)
				prog = true

	# ── Étape 3 : Orphelins résiduels ────────────────────────────────────────
	if merge_orphans:
		var p2 := true
		while p2:
			p2 = false
			for uid in units:
				if vis.has(uid):
					continue
				var gc: Dictionary = {}
				if adj.has(uid):
					for v in (adj[uid] as Dictionary).keys():
						var g: int = c2g.get(v, -1)
						if g != -1:
							gc[g] = gc.get(g, 0) + 1
				if gc.is_empty():
					continue
				var bg: int = -1
				var bc: int = -1
				for g in gc.keys():
					if gc[g] > bc:
						bc = gc[g]
						bg = g
				if bg != -1:
					vis[uid] = true
					c2g[uid] = bg
					if gch.has(bg):
						(gch[bg] as Array).append(uid)
					p2 = true

	# Orphelins restants → groupe isolé (propre groupe)
	for uid in units:
		if vis.has(uid):
			continue
		var gid: int = gen[0]
		gen[0] += 1
		c2g[uid] = gid
		gch[gid] = [uid]

	return c2g

## Post-process : réassigne les unités isolées de leur groupe parent
## au groupe voisin le plus représenté.  Répété jusqu'à stabilité.
static func _reassigner(units: Array, adj: Dictionary,
		c2g: Dictionary) -> void:
	var changed := true
	while changed:
		changed = false
		for uid in units:
			var mg: int = c2g.get(uid, -1)
			if mg == -1:
				continue
			var gc: Dictionary = {}
			var same := false
			if adj.has(uid):
				for v in (adj[uid] as Dictionary).keys():
					var vg: int = c2g.get(v, -1)
					if vg == mg:
						same = true
						break
					elif vg != -1:
						gc[vg] = gc.get(vg, 0) + 1
			if not same and not gc.is_empty():
				var bg: int = -1
				var bc: int = -1
				for g in gc.keys():
					if gc[g] > bc:
						bc = gc[g]
						bg = g
				if bg != -1:
					c2g[uid] = bg
					changed = true

## Dérive l'adjacence de niveau parent à partir de l'adjacence enfant.
static func _adj_children(gids: Array, gch: Dictionary,
		child_adj: Dictionary) -> Dictionary:
	# Mapping enfant → parent
	var c2g: Dictionary = {}
	for g in gids:
		if gch.has(g):
			for c in (gch[g] as Array):
				c2g[c] = g
	var adj: Dictionary = {}
	for g in gids:
		adj[g] = {}
	for c in child_adj.keys():
		var ga: int = c2g.get(c, -1)
		if ga == -1:
			continue
		for v in (child_adj[c] as Dictionary).keys():
			var gb: int = c2g.get(v, -1)
			if gb == -1 or gb == ga:
				continue
			if not adj.has(gb):
				adj[gb] = {}
			(adj[ga] as Dictionary)[gb] = true
			(adj[gb] as Dictionary)[ga] = true
	return adj

## Adjacence par distance euclidienne entre coordonnées de référence.
static func _adj_distance(ids: Array, cref: Dictionary,
		dist_max: float) -> Dictionary:
	var adj: Dictionary = {}
	var dm2: float = dist_max * dist_max
	for id in ids:
		adj[id] = {}
	for i in range(ids.size()):
		var ca := Vector2(cref.get(ids[i], Vector2i.ZERO))
		for j in range(i + 1, ids.size()):
			if ca.distance_squared_to(
					Vector2(cref.get(ids[j], Vector2i.ZERO))) <= dm2:
				(adj[ids[i]] as Dictionary)[ids[j]] = true
				(adj[ids[j]] as Dictionary)[ids[i]] = true
	return adj

## Union de deux dictionnaires d'adjacence.
static func _adj_union(a: Dictionary, b: Dictionary) -> Dictionary:
	var adj: Dictionary = {}
	for id in a.keys():
		adj[id] = (a[id] as Dictionary).duplicate()
	for id in b.keys():
		if not adj.has(id):
			adj[id] = {}
		for v in (b[id] as Dictionary).keys():
			(adj[id] as Dictionary)[v] = true
	return adj

## Valeurs uniques d'un mapping (préserve l'ordre d'insertion).
static func _unique_values(m: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for v in m.values():
		if not seen.has(v):
			seen[v] = true
			out.append(v)
	return out

## Inverse child→group en group→[children].
static func _invert(c2g: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for c in c2g.keys():
		var g = c2g[c]
		if not out.has(g):
			out[g] = []
		(out[g] as Array).append(c)
	return out

## Coordonnée de référence d'un groupe = celle de son premier enfant.
static func _coord_children(gids: Array, gch: Dictionary,
		ccref: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for g in gids:
		if gch.has(g) and (gch[g] as Array).size() > 0:
			out[g] = ccref.get((gch[g] as Array)[0], Vector2i.ZERO)
		else:
			out[g] = Vector2i.ZERO
	return out
