# Milestone 7.3 — Final UI / UX functional pass

Generation exposes phase/tile progress to the application, a permanently visible generation status panel, a conservative memory estimate and a Cancel action.

## Non-blocking execution contract

The scene tree and all UI controls remain on Godot's main thread. Monolithic Vulkan compute, tiled generation, GPU readbacks and the automatic PNG export run on one persistent `GPUGenerationWorker` thread. This worker owns/reuses the local `RenderingDevice`, so the application can continue drawing frames and processing input throughout generation.

Progress callbacks are bounced back to the main loop with `call_deferred()`. Monolithic cancellation is phase-boundary safe: clicking Cancel is handled immediately by the UI, while the GPU worker stops at the next safe phase boundary instead of destroying an in-flight compute dispatch. Tiled generation retains its cancellation-token behavior.

`getMaps()` no longer performs PNG export. The worker exports before emitting `finished`, then the UI only loads the already-written map files. This prevents the former second freeze that occurred after simulation while more than one hundred PNGs were generated.

The later Milestone 7.7 is reserved for visual polish and adaptive layout; this milestone establishes the functional and threading UI contract.
