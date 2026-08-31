# Planet Generator addon tests

The development bundle contains three complementary tests.

## 1. Contract smoke test (no real planet generation)

Open and run:

`res://addons/planet_generator/tests/addon_contract_test.tscn`

This test validates the public `PlanetGeneratorService` API, runtime autoload,
template round-tripping, shader/resource paths, typed runtime-query helpers,
and standalone `.planetGeneratorParam` importing.

It also loads and compiles the **exact** bundled preset fixture:

`res://addons/planet_generator/tests/fixtures/test.planetGeneratorParam`

The fixture is the user-provided standalone preset dated 2026-08-31. The smoke
test checks its real values (`planet_radius=150`, `avg_temperature=21`, Terran,
`ocean_ratio=55`, seed request `0`, export preset `standard`) and verifies that
it compiles to the canonical `752x376` grid. It deliberately does not start GPU
generation.

Expected final line:

```text
[Planet Generator Addon] contract smoke test: PASS
```

## 2. Real preset GPU integration test

Open and run:

`res://addons/planet_generator/tests/preset_integration_test.tscn`

This is the **default main scene of the DEV/TEST project**, so pressing **F5**
runs it directly.

This test uses the exact same bundled `test.planetGeneratorParam`, then:

1. imports it through `PlanetGeneratorService.load_preset()`;
2. checks the standalone values and `_ui.export_preset` policy;
3. compiles it through `PlanetGenerationSpec`;
4. launches a real asynchronous GPU generation through
   `PlanetGeneratorService.generate_planet()`;
5. checks the generated `planet_project.json` and `752x376` grid;
6. checks that exact runtime query datasets were persisted;
7. samples height, temperature, precipitation, biome, water and region data;
8. reloads the generated planet from disk and repeats runtime queries;
9. verifies `PlanetGeneratorService.query_planet_cell()` against the saved
   output.

Generated test planets are written under:

`user://planet_generator/preset_integration_test/`

The preset has `seed=0`, so each full integration run intentionally receives a
new concrete random seed at compilation/generation time.

### Renderer requirement

The full integration test requires a usable Godot `RenderingDevice`. Use
**Forward+** or **Mobile**. The Compatibility renderer cannot execute the
compute-shader generation pipeline.

Expected final line after a successful real generation:

```text
[Planet Generator Addon] real-preset integration test: PASS
```


## 3. Upstream 3.1 airless/resource GPU regression

Open and run:

`res://addons/planet_generator/tests/upstream_3_1_airless_resource_test.tscn`

This regression specifically covers the standalone 3.1.0 core synchronization.
It verifies canonical disabled-hydrology values on an airless planet, complete
land administration, absence of petroleum, non-trivial irregular mineral
morphology, dry-world export behavior, and a passing integrity report.

Expected final line:

```text
[Planet Generator Addon] upstream 3.1 airless/resource regression: PASS
```
