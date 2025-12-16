shader_type spatial;

// ============================================================================
// PLANET SURFACE SHADER - GPU Compute Integration
// ============================================================================
// Direct visualization of geophysical and atmospheric textures
// Vertex displacement + Fragment terrain/water coloring
// ============================================================================

// Texture inputs from GPU compute
uniform sampler2D geo_map : hint_default_white;
uniform sampler2D atmo_map : hint_default_white;

// Height displacement parameters
uniform float min_height = -12000.0;
uniform float max_height = 8800.0;
uniform float displacement_scale = 0.05;

// Planet parameters
uniform float planet_radius = 1.0;

varying vec2 sphere_uv;
varying float height_value;
varying float water_level;

// ============================================================================
// VERTEX SHADER: Height Displacement
// ============================================================================

void vertex() {
	// Convert sphere position to equirectangular UV
	vec3 normalized_pos = normalize(VERTEX);
	
	// Calculate UV coordinates (equirectangular projection)
	// Longitude: atan(z, x) mapped to [0, 1]
	// Latitude: asin(y) mapped to [0, 1]
	float lat = asin(clamp(normalized_pos.y, -1.0, 1.0));
	float lon = atan(normalized_pos.z, normalized_pos.x);
	
	sphere_uv = vec2(
		(lon / PI + 1.0) * 0.5,  // Wrap horizontally
		lat / PI + 0.5           // Clamp vertically (poles)
	);
	
	// Sample height from geo_map
	// R = Lithosphere, G = Water, B = Sediment, A = Hardness
	vec4 geo_data = texture(geo_map, sphere_uv);
	float lithosphere = geo_data.r;
	float water = geo_data.g;
	float sediment = geo_data.b;
	
	// Total height = Lithosphere + Sediment
	height_value = lithosphere + sediment;
	water_level = water;
	
	// Normalize height to [0, 1] range
	float normalized_height = (height_value - min_height) / (max_height - min_height);
	normalized_height = clamp(normalized_height, 0.0, 1.0);
	
	// Displace vertex along normal
	float displacement = normalized_height * displacement_scale;
	VERTEX += NORMAL * displacement * planet_radius;
}

// ============================================================================
// FRAGMENT SHADER: Terrain & Water Coloring
// ============================================================================

void fragment() {
	// Sample texture data
	vec4 geo_data = texture(geo_map, sphere_uv);
	vec4 atmo_data = texture(atmo_map, sphere_uv);
	
	float lithosphere = geo_data.r;
	float water = geo_data.g;
	float sediment = geo_data.b;
	float hardness = geo_data.a;
	
	float temperature = atmo_data.r; // Kelvin
	float humidity = atmo_data.g;    // 0-1
	float pressure = atmo_data.b;
	float clouds = atmo_data.a;
	
	// Determine if underwater
	bool is_water = water > 0.01;
	
	if (is_water) {
		// === WATER RENDERING ===
		
		// Depth-based coloring
		float water_depth = clamp(water * 0.001, 0.0, 1.0);
		vec3 shallow_water = vec3(0.3, 0.7, 0.95);
		vec3 deep_water = vec3(0.05, 0.15, 0.35);
		
		ALBEDO = mix(shallow_water, deep_water, water_depth);
		ROUGHNESS = 0.05; // Very smooth
		SPECULAR = 0.9;   // Highly reflective
		METALLIC = 0.0;
		
		// Ice (frozen water)
		if (temperature < 273.0) {
			ALBEDO = vec3(0.85, 0.9, 0.95);
			ROUGHNESS = 0.3;
			SPECULAR = 0.6;
		}
		
	} else {
		// === TERRAIN RENDERING ===
		
		vec3 terrain_color;
		
		// Height-based base color
		if (height_value < -2000.0) {
			// Deep trenches
			terrain_color = vec3(0.15, 0.1, 0.08);
		} else if (height_value < 0.0) {
			// Below sea level (coastal lowlands)
			terrain_color = vec3(0.35, 0.3, 0.2);
		} else if (height_value < 500.0) {
			// Plains
			terrain_color = vec3(0.5, 0.5, 0.35);
		} else if (height_value < 2000.0) {
			// Hills
			terrain_color = vec3(0.55, 0.45, 0.3);
		} else if (height_value < 4000.0) {
			// Mountains
			terrain_color = vec3(0.65, 0.6, 0.55);
		} else {
			// High peaks
			terrain_color = vec3(0.75, 0.7, 0.7);
		}
		
		// === CLIMATE MODULATION ===
		
		// Temperature influence
		if (temperature < 273.0) {
			// Frozen (snow/ice)
			float snow_factor = clamp((273.0 - temperature) / 20.0, 0.0, 1.0);
			terrain_color = mix(terrain_color, vec3(0.95, 0.95, 1.0), snow_factor);
		} else if (temperature > 313.0) {
			// Very hot (desert)
			float desert_factor = clamp((temperature - 313.0) / 30.0, 0.0, 1.0);
			terrain_color = mix(terrain_color, vec3(0.85, 0.65, 0.4), desert_factor);
		}
		
		// Humidity influence (vegetation)
		if (humidity > 0.5 && temperature > 273.0 && temperature < 313.0) {
			// Temperate + humid = vegetation
			float veg_factor = (humidity - 0.5) * 2.0; // 0-1
			vec3 vegetation_color = vec3(0.2, 0.6, 0.3);
			terrain_color = mix(terrain_color, vegetation_color, veg_factor * 0.6);
		}
		
		// Sediment layer (darker brown)
		if (sediment > 10.0) {
			float sediment_factor = clamp(sediment / 100.0, 0.0, 0.5);
			terrain_color = mix(terrain_color, vec3(0.4, 0.3, 0.2), sediment_factor);
		}
		
		ALBEDO = terrain_color;
		ROUGHNESS = 0.85;
		SPECULAR = 0.15;
		METALLIC = 0.0;
	}
	
	// === CLOUD OVERLAY ===
	if (clouds > 0.15) {
		float cloud_alpha = clamp((clouds - 0.15) * 1.5, 0.0, 0.8);
		ALBEDO = mix(ALBEDO, vec3(1.0, 1.0, 1.0), cloud_alpha);
		ROUGHNESS = mix(ROUGHNESS, 0.7, cloud_alpha);
	}
	
	// === ATMOSPHERIC SCATTERING (Simplified) ===
	// Add slight blue tint to atmosphere-facing surfaces
	float atmosphere_factor = max(0.0, dot(NORMAL, VIEW)) * 0.15;
	ALBEDO += vec3(0.3, 0.5, 0.7) * atmosphere_factor;
}