# GPU Shader Implementation Guide - Planet Generator

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Texture Layout & Data Structures](#texture-layout--data-structures)
3. [Shader Implementation Details](#shader-implementation-details)
4. [Pipeline Execution Order](#pipeline-execution-order)
5. [Testing & Validation](#testing--validation)

---

## Architecture Overview

### Current State
- ✅ **Hydraulic Erosion Shader** - Fully implemented
- ✅ **Orogeny Shader** - Implemented with UBO
- ⚠️ **Tectonic Shader** - Partially implemented
- ⚠️ **Atmosphere Shader** - Partially implemented
- ⚠️ **Region Shader** - Basic Voronoi implementation
- ❌ **Biome Shader** - Not implemented
- ❌ **River Shader** - Not implemented
- ❌ **Cloud Shader** - Not implemented
- ❌ **Ice Sheet Shader** - Not implemented

### GPU Texture System
```glsl
// Geophysical State (RGBA32F)
layout(set = 0, binding = 0) uniform image2D geophysical_state;
// R: Lithosphere height (meters)
// G: Water depth (meters)
// B: Sediment amount (kg/m²)
// A: Rock hardness (0-1)

// Atmospheric State (RGBA32F)
layout(set = 0, binding = 1) uniform image2D atmospheric_state;
// R: Temperature (Kelvin)
// G: Humidity (0-1)
// B: Wind velocity magnitude (m/s)
// A: Cloud density (0-1)
```

---

## Texture Layout & Data Structures

### 1. Geophysical State Texture
```glsl
struct GeophysicalPixel {
    float lithosphere_height;  // R: -25000 to +25000 meters
    float water_depth;         // G: 0 to depth in meters
    float sediment_amount;     // B: 0 to 100+ kg/m²
    float rock_hardness;       // A: 0.0 (soft) to 1.0 (hard)
};
```

**Usage Patterns:**
- **Elevation Map**: Use `lithosphere_height` directly
- **Water Map**: Check `water_depth > 0.01`
- **Is Land**: `water_depth < 0.01`
- **Terrain Stability**: Use `rock_hardness` for erosion resistance

### 2. Atmospheric State Texture
```glsl
struct AtmosphericPixel {
    float temperature;      // R: 200-400 Kelvin (typical)
    float humidity;         // G: 0.0 to 1.0
    float wind_velocity;    // B: 0-50 m/s
    float cloud_density;    // A: 0.0 to 1.0
};
```

**Usage Patterns:**
- **Temperature Map**: Convert Kelvin to Celsius: `temp_c = temperature - 273.15`
- **Precipitation Map**: Use `humidity` directly
- **Cloud Map**: Use `cloud_density > 0.15` threshold
- **Wind Patterns**: Use `wind_velocity` for erosion and weather

### 3. Flux/Velocity Helper Textures
```glsl
// Flux Map (RGBA32F) - Used for hydraulic erosion
// R: Flux left
// G: Flux right
// B: Flux top
// C: Flux bottom

// Velocity Map (RGBA32F) - Used for sediment transport
// R: Velocity X
// G: Velocity Y
// B: Sediment capacity
// A: Current flow rate
```

---

## Shader Implementation Details

## 1. ✅ Hydraulic Erosion Shader (COMPLETE)

**File:** `shader/compute/hydraulic_erosion_shader.glsl`

**Current Implementation:**
- 4-step pipeline (Rain → Flux → Water Update → Erosion/Deposition)
- Pipe model water simulation
- Sediment transport with capacity calculations
- Evaporation and precipitation

**Reference CPU Code:** `src/legacy_generators/ElevationMapGenerator.gd`

**Algorithm:**
```
Step 0: Rain Addition
  water += rain_rate * delta_time
  
Step 1: Flux Calculation
  for each neighbor:
    height_diff = (height[current] + water[current]) - (height[neighbor] + water[neighbor])
    flux[neighbor] = max(0, flux[neighbor] + delta_time * pipe_area * gravity * height_diff / pipe_length)
  
Step 2: Water Update
  total_outflow = sum(flux[neighbors])
  water -= min(water, total_outflow * delta_time)
  
Step 3: Erosion & Deposition
  sediment_capacity = k * velocity
  if sediment > capacity:
    deposition = deposition_rate * (sediment - capacity)
    height += deposition
    sediment -= deposition
  else:
    erosion = erosion_rate * (capacity - sediment)
    height -= erosion
    sediment += erosion
```

**Parameters (via UBO):**
```glsl
layout(std140, set = 1, binding = 0) uniform ErosionParams {
    float step;                    // 0-3 for pipeline step
    float delta_time;              // 0.016 (60 FPS)
    float pipe_area;               // 1.0 m²
    float pipe_length;             // 1.0 m
    float gravity;                 // 9.81 m/s²
    float rain_rate;               // 0.001 m/iteration
    float evaporation_rate;        // 0.0001
    float sediment_capacity_k;     // 0.1
    float erosion_rate;            // 0.01
    float deposition_rate;         // 0.01
    float min_height_delta;        // 0.001 m
};
```

**Status:** ✅ Working correctly, produces realistic erosion patterns

---

## 2. ✅ Orogeny Shader (COMPLETE)

**File:** `shader/compute/orogeny_shader.glsl`

**Current Implementation:**
- Mountain building along tectonic boundaries
- Rift valley formation
- Gradual erosion smoothing

**Reference CPU Code:** `src/legacy_generators/ElevationMapGenerator.gd` (lines 52-57, 59-61)

**Algorithm:**
```glsl
// Detect tectonic boundaries using noise
float tectonic_mountain = abs(tectonic_mountain_noise(coords));
if (tectonic_mountain > 0.45 && tectonic_mountain < 0.55) {
    float strength = 1.0 - abs(tectonic_mountain - 0.5) * 20.0;
    height += mountain_strength * strength;
}

float tectonic_canyon = abs(tectonic_canyon_noise(coords));
if (tectonic_canyon > 0.45 && tectonic_canyon < 0.55) {
    float strength = 1.0 - abs(tectonic_canyon - 0.5) * 20.0;
    height -= rift_strength * strength;
}

// Gradual erosion
height *= erosion_factor; // 0.98
```

**Parameters (via UBO):**
```glsl
layout(std140, set = 1, binding = 0) uniform OrogenyParams {
    float mountain_strength;  // 2500.0 meters
    float rift_strength;      // -1500.0 meters
    float erosion_factor;     // 0.98
    float delta_time;         // 0.016
};
```

**Status:** ✅ Implemented and working

---

## 3. ⚠️ Tectonic Shader (NEEDS EXPANSION)

**File:** `shader/compute/tectonic_shader.glsl`

**Current State:** Basic structure exists, needs full plate simulation

**Reference CPU Code:** None (new feature, but inspired by elevation generation)

**Required Implementation:**

### A. Plate Initialization
```glsl
// Generate tectonic plates using Voronoi
vec2 closest_seed = vec2(0.0);
float min_dist = 1e10;

for (int i = 0; i < num_plates; i++) {
    vec2 seed = plate_seeds[i];
    float dist = distance(uv, seed);
    if (dist < min_dist) {
        min_dist = dist;
        closest_seed = seed;
    }
}

plate_id = hash(closest_seed); // Unique ID per plate
```

### B. Plate Motion
```glsl
// Each plate has velocity vector
vec2 plate_velocity = plate_velocities[plate_id];

// Move height data based on plate motion
vec2 prev_pos = uv - plate_velocity * delta_time;
float prev_height = sample_bilinear(geophysical_state, prev_pos).r;
```

### C. Collision Detection
```glsl
// Check if neighboring pixels belong to different plates
bool is_boundary = false;
for (int dx = -1; dx <= 1; dx++) {
    for (int dy = -1; dy <= 1; dy++) {
        ivec2 neighbor = pos + ivec2(dx, dy);
        int neighbor_plate = get_plate_id(neighbor);
        if (neighbor_plate != current_plate) {
            is_boundary = true;
        }
    }
}

if (is_boundary) {
    // Convergent boundary: mountains
    if (dot(plate_velocity, neighbor_velocity) < 0) {
        height += convergent_uplift;
    }
    // Divergent boundary: rifts
    else if (dot(plate_velocity, neighbor_velocity) > 0) {
        height -= divergent_subsidence;
    }
}
```

**Parameters Needed:**
```glsl
layout(std140, set = 1, binding = 0) uniform TectonicParams {
    int num_plates;              // 8-15 plates
    float convergent_uplift;     // 500 m/My
    float divergent_subsidence;  // -200 m/My
    float transform_shear;       // Lateral motion
    float simulation_years;      // Millions of years
};
```

**Status:** ⚠️ Needs full implementation

---

## 4. ⚠️ Atmosphere Shader (NEEDS COMPLETION)

**File:** `shader/compute/atmosphere_shader.glsl`

**Reference CPU Code:** 
- `TemperatureMapGenerator.gd`
- `PrecipitationMapGenerator.gd`

**Required Simulations:**

### A. Temperature Calculation
```glsl
// From TemperatureMapGenerator.gd lines 48-71

float calculate_temperature(ivec2 pos, vec2 uv) {
    float lat_normalized = abs(uv.y - 0.5) * 2.0; // 0 at equator, 1 at poles
    
    // Base temperature from latitude
    float equator_offset = 8.0;
    float pole_offset = 35.0;
    float lat_curve = pow(lat_normalized, 1.5);
    float base_temp = avg_temperature + equator_offset * (1.0 - lat_normalized) 
                      - pole_offset * lat_curve;
    
    // Climate zones (noise-based)
    float climate_variation = simplex_noise(uv * 3.0) * 8.0;
    float secondary_variation = perlin_noise(uv * 1.5) * 5.0;
    float local_variation = cellular_noise(uv * 6.0) * 3.0;
    
    // Elevation effects
    float elevation = geophysical_state[pos].r;
    bool is_water = geophysical_state[pos].g > 0.01;
    
    float altitude_temp = 0.0;
    if (!is_water) {
        float altitude_above_sea = max(0.0, elevation - sea_level);
        altitude_temp = -6.5 * (altitude_above_sea / 1000.0); // Lapse rate
        
        if (elevation < sea_level) {
            float depth_below_sea = sea_level - elevation;
            altitude_temp = 2.0 * (depth_below_sea / 1000.0);
        }
    }
    
    float temp = base_temp + climate_variation + secondary_variation 
                 + local_variation + altitude_temp;
    
    // Water moderates temperature
    if (is_water) {
        temp = temp * 0.8 + avg_temperature * 0.2;
    }
    
    return clamp(temp, -80.0, 60.0);
}
```

### B. Precipitation Calculation
```glsl
// From PrecipitationMapGenerator.gd lines 43-68

float calculate_precipitation(ivec2 pos, vec2 uv) {
    float latitude = abs(uv.y - 0.5) * 2.0;
    
    // Multiple noise layers
    float main_value = (simplex_noise(uv * 2.5) + 1.0) / 2.0;
    float detail_value = (perlin_noise(uv * 6.0) + 1.0) / 2.0;
    float cell_value = (cellular_noise(uv * 4.0) + 1.0) / 2.0;
    
    // Combine organically
    float base_precip = main_value * 0.6 + detail_value * 0.25 + cell_value * 0.15;
    
    // Latitude influence
    float lat_influence = 1.0;
    if (latitude < 0.2) {
        // Tropical belt - more rain
        lat_influence = 1.0 + 0.15 * (1.0 - latitude / 0.2);
    } else if (latitude > 0.25 && latitude < 0.4) {
        // Subtropical dry belt
        float t = (latitude - 0.25) / 0.15;
        lat_influence = 1.0 - 0.2 * sin(t * 3.14159);
    } else if (latitude > 0.85) {
        // Polar regions - less precipitation
        lat_influence = 1.0 - 0.3 * (latitude - 0.85) / 0.15;
    }
    
    float value = base_precip * lat_influence;
    value = value * (0.4 + avg_precipitation * 0.6);
    
    return clamp(value, 0.0, 1.0);
}
```

### C. Wind Simulation (NEW)
```glsl
// Based on atmospheric circulation cells

vec2 calculate_wind(vec2 uv, float temperature) {
    float latitude = abs(uv.y - 0.5) * 2.0;
    
    // Trade winds (0-30°)
    // Westerlies (30-60°)
    // Polar easterlies (60-90°)
    
    vec2 wind = vec2(0.0);
    
    if (latitude < 0.3) {
        // Trade winds - eastward
        wind.x = -15.0;
        wind.y = (uv.y < 0.5) ? 5.0 : -5.0; // Toward equator
    } else if (latitude < 0.6) {
        // Westerlies - westward
        wind.x = 20.0;
        wind.y = (uv.y < 0.5) ? -3.0 : 3.0; // Toward poles
    } else {
        // Polar easterlies
        wind.x = -10.0;
        wind.y = (uv.y < 0.5) ? -8.0 : 8.0; // Toward poles
    }
    
    // Coriolis effect and local variations
    wind += simplex_noise_2d(uv * 5.0) * 8.0;
    
    return wind;
}
```

**Parameters Needed:**
```glsl
layout(std140, set = 1, binding = 0) uniform AtmosphereParams {
    float avg_temperature;      // Base planetary temperature (°C)
    float avg_precipitation;    // 0.0 to 1.0
    float sea_level;            // Elevation of water
    int atmosphere_type;        // 0=normal, 1=toxic, 2=volcanic, 3=none
    float simulation_hours;     // Time to simulate
};
```

**Status:** ⚠️ Partially implemented, needs completion

---

## 5. ❌ Biome Shader (NOT IMPLEMENTED)

**File:** `shader/compute/biome_shader.glsl` (to be created)

**Reference CPU Code:** `BiomeMapGenerator.gd`

**Algorithm:**

### A. Biome Classification
```glsl
// Based on Whittaker diagram + planet type

struct BiomeConditions {
    vec2 temperature_range;  // Min/Max °C
    vec2 precipitation_range; // Min/Max 0-1
    vec2 elevation_range;     // Min/Max meters
    bool needs_water;
    int planet_type;
};

// Load biome database (from enum.gd)
// Total: ~60 biomes across 5 planet types

int classify_biome(float elevation, float temperature, float precipitation,
                   bool is_water, int planet_type) {
    int best_biome = -1;
    float best_score = -1.0;
    
    for (int i = 0; i < NUM_BIOMES; i++) {
        BiomeConditions cond = biome_conditions[i];
        
        // Check planet type
        if (cond.planet_type != planet_type) continue;
        
        // Check water requirement
        if (cond.needs_water != is_water) continue;
        
        // Check ranges
        if (temperature < cond.temperature_range.x || 
            temperature > cond.temperature_range.y) continue;
        if (precipitation < cond.precipitation_range.x || 
            precipitation > cond.precipitation_range.y) continue;
        if (elevation < cond.elevation_range.x || 
            elevation > cond.elevation_range.y) continue;
        
        // Calculate fit score
        float temp_center = (cond.temperature_range.x + cond.temperature_range.y) / 2.0;
        float precip_center = (cond.precipitation_range.x + cond.precipitation_range.y) / 2.0;
        
        float score = 1.0 - abs(temperature - temp_center) / 100.0
                    - abs(precipitation - precip_center);
        
        if (score > best_score) {
            best_score = score;
            best_biome = i;
        }
    }
    
    return best_biome;
}
```

### B. Biome Smoothing
```glsl
// From BiomeMapGenerator.gd _smooth_biome_map()

// Multi-pass smoothing for natural boundaries
for (int pass = 0; pass < 2; pass++) {
    int histogram[MAX_BIOMES];
    memset(histogram, 0);
    
    // Sample 8 neighbors
    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            if (dx == 0 && dy == 0) continue;
            ivec2 neighbor = wrap(pos + ivec2(dx, dy));
            int neighbor_biome = biome_map[neighbor];
            histogram[neighbor_biome]++;
        }
    }
    
    // Find most common neighbor
    int max_count = 0;
    int most_common = current_biome;
    for (int i = 0; i < MAX_BIOMES; i++) {
        if (histogram[i] > max_count) {
            max_count = histogram[i];
            most_common = i;
        }
    }
    
    // If 5+ neighbors agree, blend toward that biome
    if (max_count >= 5) {
        current_biome = most_common;
    }
}
```

### C. Border Irregularity
```glsl
// From BiomeMapGenerator.gd _add_border_irregularity()

bool is_border = false;
int neighbor_biomes[8];
int num_neighbors = 0;

for (int i = -1; i <= 1; i++) {
    for (int j = -1; j <= 1; j++) {
        if (i == 0 && j == 0) continue;
        ivec2 neighbor = wrap(pos + ivec2(i, j));
        int n_biome = biome_map[neighbor];
        if (n_biome != current_biome) {
            is_border = true;
            neighbor_biomes[num_neighbors++] = n_biome;
        }
    }
}

if (is_border && num_neighbors > 0) {
    float detail_noise = simplex_noise(uv * 25.0);
    if (detail_noise > 0.4) {
        // Select neighbor based on noise
        int index = int((detail_noise + 1.0) / 2.0 * num_neighbors) % num_neighbors;
        current_biome = neighbor_biomes[index];
    }
}
```

**Data Structure (SSBO):**
```glsl
struct Biome {
    vec4 color;                  // Display color
    vec4 vegetation_color;       // For final map
    vec2 temperature_range;
    vec2 precipitation_range;
    vec2 elevation_range;
    int needs_water;             // Boolean
    int planet_type;
    int river_lake_only;         // For river/lake-exclusive biomes
    int padding;
};

layout(std430, set = 1, binding = 0) buffer BiomeDatabase {
    Biome biomes[];
};
```

**Status:** ❌ Not implemented

---

## 6. ❌ River Shader (NOT IMPLEMENTED)

**File:** `shader/compute/river_shader.glsl` (to be created)

**Reference CPU Code:** `RiverMapGenerator.gd`

**Algorithm:**

### A. River Source Detection
```glsl
// From RiverMapGenerator.gd lines 41-78

bool is_valid_river_source(ivec2 pos) {
    float elevation = geophysical_state[pos].r;
    float temperature = atmospheric_state[pos].r - 273.15;
    float precipitation = atmospheric_state[pos].g;
    bool is_water = geophysical_state[pos].g > 0.01;
    
    // Not in water
    if (is_water) return false;
    
    // Not too cold
    if (temperature <= -10.0) return false;
    
    // High enough elevation
    if (elevation < sea_level + 100.0) return false;
    
    // Use noise to scatter sources
    float source_noise = simplex_noise(vec2(pos) * 6.0);
    if (source_noise < 0.25) return false;
    
    // Calculate score
    float altitude_score = (elevation - sea_level) / 1000.0;
    float score = altitude_score * (precipitation + 0.3) * (source_noise + 0.5);
    
    return score > 0.5; // Threshold
}
```

### B. River Flow (Downhill)
```glsl
// From RiverMapGenerator.gd _trace_river_to_ocean()

ivec2 trace_river_step(ivec2 current_pos) {
    float current_height = geophysical_state[current_pos].r;
    float current_water = geophysical_state[current_pos].g;
    
    // Check if reached ocean
    if (current_water > 0.01) {
        return ivec2(-1); // Terminate
    }
    
    // Find lowest neighbor
    ivec2 directions[8] = {
        ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1),
        ivec2(-1, -1), ivec2(1, -1), ivec2(-1, 1), ivec2(1, 1)
    };
    
    float best_score = -1e10;
    ivec2 best_direction = ivec2(0);
    
    for (int i = 0; i < 8; i++) {
        ivec2 neighbor = wrap(current_pos + directions[i]);
        float n_height = geophysical_state[neighbor].r;
        float descent = current_height - n_height;
        
        // Prefer downhill, but allow slight uphill with tolerance
        if (descent >= -20.0) { // 20m tolerance
            float score = descent * 2.0; // Favor steep descent
            
            // Add meandering via noise
            float meander = simplex_noise(vec2(neighbor) * 25.0) * 5.0;
            score += meander;
            
            if (score > best_score) {
                best_score = score;
                best_direction = directions[i];
            }
        }
    }
    
    return current_pos + best_direction;
}
```

### C. Tributary Generation
```glsl
// From RiverMapGenerator.gd _trace_tributary()

// When main river splits (based on precipitation and slope)
bool should_spawn_tributary(ivec2 pos, float precipitation, int steps) {
    if (steps < 5) return false; // Not too early
    
    float split_chance = 0.03 + precipitation * 0.05;
    return random(vec2(pos)) < split_chance;
}
```

### D. River Width/Type
```glsl
// From RiverMapGenerator.gd lines 71-76

int calculate_river_size(float elevation, float precipitation, float temperature) {
    int size = 0; // Default: Affluent
    
    if (elevation > 2000.0 && precipitation > 0.5) {
        size = 2; // Fleuve (large river)
    } else if (elevation > 500.0 || precipitation > 0.4) {
        size = 1; // Rivière (medium river)
    }
    
    return size;
}
```

**Parameters:**
```glsl
layout(std140, set = 1, binding = 0) uniform RiverParams {
    int max_rivers;             // 40 - max(40, circumference / 25)
    float min_river_distance;   // 10 - max(10, circumference / 60)
    float sea_level;
    int atmosphere_type;
};
```

**Status:** ❌ Not implemented

---

## 7. ❌ Cloud Shader (NOT IMPLEMENTED)

**File:** `shader/compute/cloud_shader.glsl` (to be created)

**Reference CPU Code:** `NuageMapGenerator.gd`

**Algorithm:**

```glsl
// From NuageMapGenerator.gd lines 18-55

float generate_clouds(vec2 uv, int atmosphere_type) {
    // No clouds for no-atmosphere or volcanic planets
    if (atmosphere_type == 2 || atmosphere_type == 3) {
        return 0.0;
    }
    
    // Cellular noise for circular cloud formations
    float cell_val = cellular_noise(uv * 6.0);
    cell_val = 1.0 - abs(cell_val);
    
    // Shape noise for variety
    float shape_val = simplex_noise(uv * 4.0);
    shape_val = (shape_val + 1.0) / 2.0;
    
    // Detail for irregular edges
    float detail_val = perlin_noise(uv * 15.0) * 0.15;
    
    // Combine
    float cloud_val = cell_val * 0.6 + shape_val * 0.4 + detail_val;
    
    // Threshold
    float threshold = 0.55;
    return (cloud_val > threshold) ? 1.0 : 0.0;
}
```

**Integration with Atmosphere:**
```glsl
// Clouds form where:
// - High humidity (> 0.6)
// - Rising air (thermal updrafts)
// - Wind convergence

float cloud_probability(vec2 uv) {
    float humidity = atmospheric_state[pos].g;
    float temperature = atmospheric_state[pos].r - 273.15;
    
    // More clouds over water (evaporation)
    bool over_water = geophysical_state[pos].g > 0.01;
    float water_bonus = over_water ? 0.2 : 0.0;
    
    // More clouds in humid regions
    return cloud_base_pattern(uv) * humidity + water_bonus;
}
```

**Status:** ❌ Not implemented

---

## 8. ❌ Ice Sheet Shader (NOT IMPLEMENTED)

**File:** `shader/compute/ice_sheet_shader.glsl` (to be created)

**Reference CPU Code:** `BanquiseMapGenerator.gd`

**Algorithm:**

```glsl
// From BanquiseMapGenerator.gd lines 12-17

bool generate_ice(ivec2 pos) {
    bool is_water = geophysical_state[pos].g > 0.01;
    if (!is_water) return false;
    
    float temperature = atmospheric_state[pos].r - 273.15;
    if (temperature >= 0.0) return false;
    
    // 90% chance of ice in freezing water
    float random_val = random(vec2(pos));
    return random_val < 0.9;
}
```

**Expansion for Glaciers:**
```glsl
// Land ice (glaciers) for extreme cold
bool is_glacier = false;
if (!is_water && temperature < -20.0) {
    float elevation = geophysical_state[pos].r;
    // High altitude or polar regions
    if (elevation > 2000.0 || abs(uv.y - 0.5) > 0.4) {
        is_glacier = true;
    }
}
```

**Status:** ❌ Not implemented

---

## 9. ❌ Region Shader (BASIC VORONOI ONLY)

**File:** `shader/compute/region_voronoi_shader.glsl`

**Reference CPU Code:** `RegionMapGenerator.gd`

**Current Implementation:** Basic Voronoi distance calculation

**Required Algorithm (Region Growing):**

```glsl
// From RegionMapGenerator.gd _region_creation()

// Multi-pass region growing with frontier expansion
// Pass 1: Initialize random seed points
// Pass 2-N: Expand from frontier with noise-based selection

struct RegionCell {
    int region_id;
    int cases_left;
    bool is_complete;
};

// Use priority queue (simulated via sorting)
void expand_region(int region_id, ivec2 start_pos, int target_size) {
    RegionCell region;
    region.region_id = region_id;
    region.cases_left = target_size;
    region.is_complete = false;
    
    // Frontier = cells to explore
    ivec2 frontier[MAX_FRONTIER];
    int frontier_size = 1;
    frontier[0] = start_pos;
    
    while (frontier_size > 0 && !region.is_complete) {
        // Sort frontier by distance + noise
        // (deterministic using position as seed)
        sort_frontier(frontier, frontier_size, start_pos);
        
        // Pop closest
        ivec2 current = frontier[0];
        frontier_size--;
        
        // Skip if water
        if (geophysical_state[current].g > 0.01) continue;
        
        // Claim cell
        region_map[current] = region_id;
        region.cases_left--;
        
        if (region.cases_left == 0) {
            region.is_complete = true;
            break;
        }
        
        // Add neighbors to frontier
        for each valid neighbor:
            if (not claimed and not in frontier):
                frontier[frontier_size++] = neighbor;
    }
}
```

**Merge Small Regions:**
```glsl
// From RegionMapGenerator.gd lines 54-84

if (region.cases_left <= 10) {
    // Find largest neighboring region
    int target_region = -1;
    int max_neighbors = 0;
    
    for each cell in region:
        for each neighbor:
            int neighbor_region = region_map[neighbor];
            if (neighbor_region != region_id) {
                count_neighbors[neighbor_region]++;
            }
    
    // Merge into target
    for each cell in region:
        region_map[cell] = target_region;
}
```

**Status:** ⚠️ Only basic Voronoi, needs full region growing

---

## Pipeline Execution Order

### Recommended Execution Sequence

```
1. [INIT] Terrain Initialization
   - Generate base heightmap (Perlin/Simplex noise)
   - Set rock hardness based on geology
   ↓
2. [TECTONIC] Plate Simulation (100M years)
   - Generate plates
   - Simulate collisions → mountains
   - Simulate rifts → valleys
   ↓
3. [OROGENY] Mountain Building
   - Accentuate tectonic boundaries
   - Add volcanic features (if type == 2)
   ↓
4. [EROSION] Hydraulic Erosion (100 iterations)
   - Rain → Water flow → Sediment transport
   - Carve valleys and smooth peaks
   ↓
5. [ATMOSPHERE] Climate Simulation
   - Calculate temperature (latitude + elevation)
   - Calculate precipitation (wind + water)
   - Generate wind patterns
   ↓
6. [WATER] Sea Level Application
   - Fill areas below sea_level with water
   ↓
7. [RIVERS] River Generation
   - Find sources (high elevation + precipitation)
   - Trace downhill paths to ocean
   - Generate tributaries
   ↓
8. [ICE] Ice Sheet Formation
   - Freeze water below 0°C
   - Generate glaciers in mountains
   ↓
9. [CLOUDS] Cloud Generation
   - Cellular noise for cloud formations
   - Based on humidity and altitude
   ↓
10. [BIOMES] Biome Classification
    - Apply Whittaker diagram
    - Smooth boundaries
    - Add irregularity
    ↓
11. [REGIONS] Political Regions
    - Voronoi-based region growing
    - Avoid water, merge small regions
    ↓
12. [EXPORT] Final Rendering
    - Composite all layers
    - Apply vegetation colors
    - Generate preview sphere
```

---

## Testing & Validation

### Unit Tests per Shader

#### Erosion Shader Tests
```
✓ Rain adds water uniformly
✓ Water flows downhill
✓ Sediment transport follows velocity
✓ No negative heights after erosion
✓ Total mass conserved (height + sediment)
```

#### Atmosphere Shader Tests
```
✓ Temperature decreases with latitude
✓ Altitude lapse rate (-6.5°C/km)
✓ Water moderates temperature
✓ Precipitation follows climate zones
```

#### River Shader Tests
```
✓ Rivers start at high elevation
✓ Rivers flow to lowest neighbor
✓ Rivers terminate at ocean
✓ No rivers flow uphill > tolerance
✓ River size increases with watershed
```

### Integration Tests

```glsl
// Test Case: Desert Planet
atmosphere_type = 0
avg_temperature = 35.0
avg_precipitation = 0.1
sea_level = -2000

Expected:
- Sparse rivers
- Desert biomes dominate
- No ice sheets
- Minimal clouds

// Test Case: Water World
avg_temperature = 15.0
sea_level = 2000 // Most land submerged

Expected:
- Few land areas
- Ocean biomes dominate
- Coastal regions only
- Rivers rare

// Test Case: Volcanic Planet
atmosphere_type = 2
avg_temperature = 50.0

Expected:
- Lava rivers (type 2)
- Volcanic biomes
- No clouds (atmosphere_type check)
- Ash plains
```

---

## Performance Optimization

### Compute Group Sizes

```glsl
// Optimal for most GPUs
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Large textures (1024x512+)
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
```

### Memory Access Patterns

```glsl
// ✓ GOOD: Coalesced reads
vec4 data = imageLoad(texture, ivec2(gl_GlobalInvocationID.xy));

// ✗ BAD: Random access in loop
for (int i = 0; i < 100; i++) {
    ivec2 random_pos = hash(i);
    vec4 data = imageLoad(texture, random_pos); // Cache misses
}

// ✓ BETTER: Local caching
vec4 cache[9];
for (int i = -1; i <= 1; i++) {
    for (int j = -1; j <= 1; j++) {
        cache[(i+1)*3 + (j+1)] = imageLoad(texture, pos + ivec2(i,j));
    }
}
```

### Barrier Synchronization

```glsl
// After each major pass
barrier();
memoryBarrierImage();

// Example in erosion:
// Step 0: Rain
dispatch_compute(...);
rd.submit();
rd.sync(); // ← Critical!

// Step 1: Flux
dispatch_compute(...);
```

---

## Debugging Tools

### Shader Debug Outputs

```glsl
// Visualize intermediate values
if (DEBUG_MODE) {
    // Output raw data to debug texture
    vec4 debug = vec4(
        sediment_amount / 100.0,  // R
        water_depth / 10.0,        // G
        velocity / 50.0,           // B
        1.0                        // A
    );
    imageStore(debug_texture, pos, debug);
}
```

### CPU Validation

```gdscript
# Compare GPU vs CPU output
func validate_erosion():
    var gpu_img = gpu_orchestrator.export_geo_state_to_image()
    var cpu_img = ElevationMapGenerator.new(planet).generate()
    
    var diff = compare_images(gpu_img, cpu_img)
    assert(diff < TOLERANCE, "GPU/CPU mismatch: " + str(diff))
```

---

## Migration Roadmap

### Phase 1: Core Simulation ✅
- [x] Erosion shader
- [x] Orogeny shader
- [x] Basic texture management

### Phase 2: Atmosphere & Water (Current)
- [ ] Complete atmosphere shader (temperature, precipitation, wind)
- [ ] Implement river shader
- [ ] Implement ice sheet shader

### Phase 3: Surface Features
- [ ] Complete biome shader
- [ ] Implement cloud shader
- [ ] Complete region shader

### Phase 4: Polish & Optimization
- [ ] Multi-threaded export
- [ ] Incremental generation (view updates during simulation)
- [ ] GPU → 3D Globe binding
- [ ] Parameter hot-reloading

---

## Shader Template

Use this template for new shaders:

```glsl
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Texture bindings
layout(set = 0, binding = 0, rgba32f) uniform image2D geophysical_state;
layout(set = 0, binding = 1, rgba32f) uniform image2D atmospheric_state;

// Parameters (if needed)
layout(std140, set = 1, binding = 0) uniform Params {
    float param1;
    float param2;
    // ... pad to 16-byte alignment
};

// Helper functions
vec2 wrap_uv(ivec2 pos, ivec2 size) {
    return vec2(
        float(pos.x % size.x) / float(size.x),
        float(pos.y) / float(size.y)
    );
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(geophysical_state);
    
    if (pos.x >= size.x || pos.y >= size.y) return;
    
    vec2 uv = wrap_uv(pos, size);
    
    // Load current state
    vec4 geo = imageLoad(geophysical_state, pos);
    vec4 atmo = imageLoad(atmospheric_state, pos);
    
    // [YOUR ALGORITHM HERE]
    
    // Write results
    imageStore(geophysical_state, pos, geo);
    imageStore(atmospheric_state, pos, atmo);
}
```

---

## References

- **CPU Implementation**: `src/legacy_generators/*.gd`
- **GPU Context**: `src/classes/classes_gpu/gpu_context.gd`
- **Orchestrator**: `src/classes/classes_gpu/orchestrator.gd`
- **Exporter**: `src/classes/classes_io/exporter.gd`
- **Biome Database**: `src/enum.gd`

---

**Last Updated:** 2025-12-22  
**Version:** 2.0  
**Status:** Living Document - Update as shaders are implemented