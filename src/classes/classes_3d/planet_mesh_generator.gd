extends Node3D
class_name PlanetMeshGenerator

## ============================================================================
## PLANET MESH GENERATOR - CubeSphere with GPU Texture Integration
## ============================================================================
## Generates high-quality sphere mesh using cube projection
## Uses Texture2DRD for direct GPU compute texture access (zero CPU readback)
## ============================================================================

var mesh_instance: MeshInstance3D
var material: ShaderMaterial
var planet_mesh: ArrayMesh

# Mesh parameters
var planet_radius: float = 1.0
var mesh_resolution: int = 128
var is_generated: bool = false

func _init():
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)
	
	# Create shader material
	material = ShaderMaterial.new()
	var shader = load("res://shader/visual/planet_surface.gdshader")
	if not shader:
		push_error("[PlanetMeshGenerator] Failed to load shader!")
		return
	
	material.shader = shader
	
	# Set default shader parameters
	material.set_shader_parameter("planet_radius", planet_radius)
	material.set_shader_parameter("min_height", -12000.0)
	material.set_shader_parameter("max_height", 8800.0)
	material.set_shader_parameter("displacement_scale", 0.05)
	
	print("[PlanetMeshGenerator] Initialized")

func generate_sphere(resolution: int = 128) -> void:
	"""
	Generate a CubeSphere mesh (6 subdivided cube faces projected to sphere)
	Better UV distribution and less polar distortion than UV sphere
	
	Args:
		resolution: Subdivisions per cube face (total vertices ≈ 6 * resolution²)
	"""
	mesh_resolution = resolution
	planet_mesh = ArrayMesh.new()
	
	# CubeSphere: Generate 6 cube faces
	var faces = [
		Vector3(1, 0, 0),   # +X (Right)
		Vector3(-1, 0, 0),  # -X (Left)
		Vector3(0, 1, 0),   # +Y (Top)
		Vector3(0, -1, 0),  # -Y (Bottom)
		Vector3(0, 0, 1),   # +Z (Front)
		Vector3(0, 0, -1)   # -Z (Back)
	]
	
	for face_normal in faces:
		_generate_cube_face(face_normal, resolution)
	
	mesh_instance.mesh = planet_mesh
	mesh_instance.material_override = material
	is_generated = true
	
	var vertex_count = 6 * (resolution + 1) * (resolution + 1)
	var triangle_count = 6 * resolution * resolution * 2
	print("[PlanetMeshGenerator] Sphere generated:")
	print("  Resolution: ", resolution, "x", resolution, " per face")
	print("  Vertices: ", vertex_count)
	print("  Triangles: ", triangle_count)

func _generate_cube_face(normal: Vector3, subdivisions: int) -> void:
	"""
	Generate one face of the cube and project vertices to sphere
	
	Args:
		normal: Face direction (+/- X/Y/Z)
		subdivisions: Grid resolution
	"""
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	
	# Determine tangent vectors for this face
	var right: Vector3
	var up: Vector3
	
	if abs(normal.y) < 0.9:
		# Most faces: use world UP for reference
		right = Vector3.UP.cross(normal).normalized()
	else:
		# Top/Bottom faces: use RIGHT for reference
		right = Vector3.RIGHT.cross(normal).normalized()
	
	up = normal.cross(right).normalized()
	
	# Generate grid of vertices
	for y in range(subdivisions + 1):
		for x in range(subdivisions + 1):
			# Normalize to [0, 1]
			var u = float(x) / float(subdivisions)
			var v = float(y) / float(subdivisions)
			
			# Map to [-1, 1] range (cube face)
			var pu = (u - 0.5) * 2.0
			var pv = (v - 0.5) * 2.0
			
			# Calculate position on cube face
			var cube_pos = normal + right * pu + up * pv
			
			# Project to unit sphere
			var sphere_pos = cube_pos.normalized() * planet_radius
			
			vertices.append(sphere_pos)
			normals.append(sphere_pos.normalized())
			uvs.append(Vector2(u, v))  # Face-local UVs
	
	# Generate triangle indices (two triangles per quad)
	for y in range(subdivisions):
		for x in range(subdivisions):
			var i0 = y * (subdivisions + 1) + x
			var i1 = i0 + 1
			var i2 = i0 + (subdivisions + 1)
			var i3 = i2 + 1
			
			# Triangle 1
			indices.append(i0)
			indices.append(i2)
			indices.append(i1)
			
			# Triangle 2
			indices.append(i1)
			indices.append(i2)
			indices.append(i3)
	
	# Assign arrays
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	# Add surface to mesh
	planet_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func update_maps(geo_texture_rid: RID, atmo_texture_rid: RID) -> void:
	"""
	Update shader textures with GPU compute results
	
	CRITICAL: Uses Texture2DRD for DIRECT GPU memory access
	- No CPU readback required (zero latency)
	- Textures remain on GPU throughout pipeline
	- Compute Shader → Visual Shader seamless integration
	
	Args:
		geo_texture_rid: RID of geophysical state texture (from GPUContext)
		atmo_texture_rid: RID of atmospheric state texture
	"""
	
	if not is_generated:
		push_error("[PlanetMeshGenerator] Sphere not generated yet! Call generate_sphere() first")
		return
	
	if not geo_texture_rid.is_valid() or not atmo_texture_rid.is_valid():
		push_error("[PlanetMeshGenerator] Invalid texture RIDs")
		return
	
	# Create Texture2DRD wrappers (GPU-side textures)
	var geo_texture = Texture2DRD.new()
	geo_texture.texture_rd_rid = geo_texture_rid
	
	var atmo_texture = Texture2DRD.new()
	atmo_texture.texture_rd_rid = atmo_texture_rid
	
	# Update shader parameters
	material.set_shader_parameter("geo_map", geo_texture)
	material.set_shader_parameter("atmo_map", atmo_texture)
	
	print("[PlanetMeshGenerator] GPU textures updated (zero CPU transfer)")

func set_planet_radius(radius: float) -> void:
	"""Set planet base radius (affects displacement scale)"""
	planet_radius = radius
	material.set_shader_parameter("planet_radius", radius)

func set_displacement_scale(scale: float) -> void:
	"""
	Set height displacement multiplier
	- 0.05 = Subtle relief (default)
	- 0.1 = Pronounced mountains
	- 0.2 = Exaggerated terrain
	"""
	material.set_shader_parameter("displacement_scale", scale)

func set_height_range(min_h: float, max_h: float) -> void:
	"""Set expected height range for normalization"""
	material.set_shader_parameter("min_height", min_h)
	material.set_shader_parameter("max_height", max_h)

func get_mesh_instance() -> MeshInstance3D:
	"""Get the internal MeshInstance3D for camera setup"""
	return mesh_instance