# Branch merge verification — 2026-10-18

Merged `origin/UI-optimized-version` (`4073395`) and `origin/地图`
(`157495b`) into local `main`, starting from `fc143eb`. No remote push.

Resolutions and repairs:

- Kept the main branch's embedded blueprint workflow and disabled autosave defaults.
  Explicitly enabling exit snapshots still saves before entering preview.
- Integrated brush, bucket and snapshot extraction while retaining yellow bucket
  fill in the rod layer, stroke synchronization and rail restoration.
- Removed the incoming incomplete respawn-area UI, which called a nonexistent
  layout helper and prevented the editor script from parsing.
- Added the missing palette gear-button synchronization method and action route.
- Restore both player visibility and modulation while packing, then restore the
  live editor appearance; saved players must not retain transparent modulation.
- Used the map branch's conflicting scenes together with their matching snapshots.
- Restored the UI branch's title, first page, third page and Peak scenes because
  the menu and portal routes still reference them. The removed second page stays
  removed. Updated route bounds and route tests for the shorter sequence.

Validation used Godot 4.7.2 headless. Editor import/parsing completed after repairs.
All four map-branch scenes loaded and instantiated successfully.

22 of 23 selected regression scripts passed after repairs:
`ink_brush`, `bucket_fill`, `editor_document`, `editor_autosave_snapshot`,
`editor_exit_snapshot`, `creative_editor`, `editor_layout_tools`,
`editor_control_picking`, `editor_player_absence`, `editor_reload_lifecycle`,
`dialogue_trigger_editor_state`, `blueprints`, `blueprint_ui`, `game_cursor`,
`level_select`, `map_sequence`, `blue_ink`, `yellow_ink`, `gear_lever`,
`spawn_respawn_canvas_layout`, `ui_interactions`, `title_level_entry`.
Names above omit the `test_` prefix and `.gd` suffix.

Remaining issue: `test_ink_machine_pages.gd` reports one failure on the third page:
the gear checkpoint completes but the gate does not rise at least 70 pixels.
The lift checkpoint completes and rises approximately 180 pixels. This physical
gate behavior remains unresolved; no thresholds were relaxed. Some scene tests
also report ObjectDB/resource leaks at shutdown. Full interactive playthrough and
the entire repository test suite were not performed.
