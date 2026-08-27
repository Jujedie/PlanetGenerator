# Milestone 7.7 — Final UI polish

The final polish pass now targets the modular UI architecture rather than the retired monolithic `master.tscn` tree. `ParameterWorkspace` owns parameter presentation, templates, batch controls and export-policy selection; `ReferenceViewerWorkspace` owns the map display and viewer controls; `Master` remains the orchestration layer between both workspaces and generation.

The parameter screen now exposes the M7.2 export preset directly, hides categories that do not make physical sense for the selected planet type, preserves the export choice in saved parameter presets, and adds contextual tooltips. Keyboard shortcuts are global but remain thin orchestration: `V` switches between parameters and viewer, `B` toggles Batch from the parameter screen, Left/Right changes the viewer base map, `Ctrl+0` resets the view, and `Esc` closes the Batch panel.

The workspaces remain responsive and non-overlapping, so M7.7 does not reintroduce floating legacy panels over the map. This milestone changes presentation and export policy selection only; generation physics are unchanged.

The standalone reference viewport is 1600×900 so the parameter header and bottom action bar fit without changing their one-row/two-column composition. Window maximization remains available for larger displays; the workspaces continue to lay themselves out from the actual visible viewport.
