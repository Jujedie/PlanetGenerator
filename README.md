# Planet Generator | A World Building Tool

A procedural planet surface generator that creates detailed planetary maps based on customizable parameters.

## Features

### Generation Parameters
- **Planet Name**: Custom name for your generated world
- **Planetary Radius**: Size of the planet (affects map resolution)
- **Average Temperature**: Global climate baseline (-273°C to 200°C)
- **Water Elevation**: Sea level height (-2500m to 2500m)
- **Average Precipitation**: Global moisture level (0.0 to 1.0)
- **Additional Elevation**: Terrain height modifier
- **Cases per Region**: Political/geographical region subdivision
- **Thread Count**: Parallel processing optimization (4-20 threads)
- **Randomize Button**: Instantly randomize all parameters
- And many others ...

### Planet Types
- **Standard**: Earth-like biomes with forests, deserts, oceans
- **Toxic**: Acid oceans, sulfur deserts, fungal forests
- **Volcanic**: Lava fields, magma lakes, ash plains
- **Dead**: Irradiated wastelands, polluted waters
- **No Atmosphere**: Barren surfaces, no clouds or water

### Generated Maps (13 outputs)
| Map | Description |
|-----|-------------|
| Elevation Map | Topographical height data |
| Elevation Map (Alt) | Alternative color scheme |
| Biome Map | Climate and vegetation zones |
| Temperature Map | Heat distribution across the surface |
| Precipitation Map | Rainfall and moisture patterns |
| Water Map | Ocean and sea coverage |
| River Map | Rivers, lakes, and tributaries |
| Ice Cap Map | Frozen water regions |
| Cloud Map | Atmospheric cloud coverage |
| Oil Map | Petroleum deposit locations |
| Resources Map | A map for each Mineral and resource deposits |
| Region Map | Political/geographical subdivisions and a region map for oceanic regions |
| Final Map | Combined rendered view |

### Technical Features
- **Cylindrical Projection**: Seamless horizontal wrapping for realistic globe mapping
- **Modular Architecture**: Each map type uses its own generator class
- **Noise-based Terrain**: FastNoiseLite for realistic procedural generation
- **Tectonic Simulation**: Mountain ranges and canyons along fault lines
- **Hydraulic Erosion**: Realistic but not time consuming hydraulic erosion.
- **River System**: Realistic water flow from mountains to oceans with tributaries (WIP)
- **Computes Shaders**: Computes shaders improving time complexity up 10 times

### Supported Languages
- English
- French (Français)
- German (Deutsch)

## Supported Platforms

- **Windows**: x86_64 architecture (`Planet Generator.exe`)
- **Linux x86_64**: Debian, Ubuntu, and other distributions (`PlanetGenerator.x86_64`)
- **Linux ARM64**: ARM-based systems (`PlanetGenerator.arm64`)

## Output Format

All maps are exported as PNG images in a Mercator-like equirectangular projection, ready for use in:
- Game development
- World-building projects
- 3D sphere mapping
- Tabletop RPG maps

## Architecture

The generator uses a modular class-based architecture:

```
src/
├── planetGenerator.gd      # Main orchestrator
├── shaders/
├── classes/
├── scenes
└── enum.gd
```

## Version

v2.1.1
