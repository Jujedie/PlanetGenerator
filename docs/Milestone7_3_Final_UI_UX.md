# Milestone 7.3 — Final UI / UX functional pass

Generation now exposes phase/tile progress to the application, a visible generation panel, a conservative memory estimate and a Cancel action. Monolithic cancellation is intentionally phase-boundary safe: an in-flight GPU dispatch is never destroyed halfway. Tiled generation retains its existing cancellation token behavior.

The later Milestone 7.7 is reserved for visual polish and adaptive layout; this milestone establishes the functional UI contract only.
