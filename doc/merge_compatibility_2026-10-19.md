# Map / UI Branch Merge Compatibility Audit

## Branch Lineage

- `main` before merge: `0603f06`
- UI branch merged: `4c495db` (`origin/UI-optimized-version`)
- Common base: `5f9ebbe`
- Merge commit: `0e30da4`

The two branches were not a fast-forward:

- `main` contained the map-branch merges and official-level repairs.
- The UI branch contained the editor architecture split and its own updated maps.
- The merge had content conflicts in canvas/editor files and `扉页.tscn`,
  `第一页.tscn`, and `空白大地图.tscn`.

## Root Causes

### 1. Wrong conflict choice for `第一页.tscn`

Both sides used draft schema `version = 1`, so this was not an editor-document
schema migration failure. The content and body layout were different:

- `main`: player at approximately `(690.49, 213.16)`, no motors/rails in the
  draft.
- UI branch: player at approximately `(239.99, 287.28)`, with motors, rails,
  anchors, and slider pins from the newer map.

Keeping the `main` version preserved an older map-body layout that was not
compatible with the merged runtime. It loaded with support, but the player
moved only about 9 px before losing contact. The UI-branch version moved
normally in the same runtime. The conflict must be resolved by content
compatibility, not by blindly preferring one branch.

### 2. Editor-baked state leaked into exported scenes

The same map behaved differently in the source project and in the PCK:

- In the source project, runtime rebuilding produced static terrain with
  `collision_layer = 1`.
- In the PCK, pre-baked terrain was serialized with `collision_layer = 0`,
  `collision_mask = 0`, and preserved
  `background_original_layer = 1`.
- The exported player body could also start with `frozen = true` and disabled
  input processing.

This is a compatibility break between editor-built scene state and the new
canvas/editor architecture's runtime expectations. `root.gd` now treats level
loading as a transaction:

1. pause player input and physics while staged terrain is baked;
2. restore the player after all bodies/joints are present;
3. wake normal-play player bodies and enable input;
4. restore static terrain layers from `background_original_*` tags.

This normalization is applied only during normal play, not while the editor is
explicitly loading an editing document.

### 3. Export path remapping

PCK directory listing uses `.tscn.remap`. Filtering only `.tscn` made the
exported level directory show four hard-coded pages and omit scanned maps.
The scanner now strips `.remap` before resolving the resource path.

### 4. Incomplete scenes were exposed as player levels

The scanner intentionally finds any scene containing `Player`, which also
found unfinished test scenes. Compatibility testing now distinguishes:

| Level | Result | Evidence |
|---|---|---|
| `新地图1.tscn` | hidden | `SOLID bodies=0`; no generated terrain near spawn |
| `新地图2.tscn` | hidden | only 2 solid bodies; spawn falls over 2300 px |
| `第二关（小怪关）.tscn` | hidden | 68 bodies, but no terrain under spawn; falls |
| `黄色.tscn` | hidden | one large background body remains non-collidable and the player falls |
| `第二关（制作中）.tscn` | hidden | playable, but explicitly a work-in-progress level |
| `空白大地图.tscn` | hidden | test fixture/template, not a player level |

After the runtime compatibility fixes, `第三关·墨泉边.tscn` passes again and
is no longer hidden.

## Shipped Level Matrix

The following 11 levels pass the real-input movement gate in the PCK:

- `扉页.tscn`
- `第一页.tscn`
- `第三页.tscn`
- `peak.tscn`
- `新地图3.tscn`
- `新地图4.tscn`
- `无画布挑战！.tscn`
- `第二关（基本完成）.tscn`
- `蓝色攀升.tscn`
- `黄色2.tscn`
- `第三关·墨泉边.tscn`

## Reusable Verification Scaffolding

- `test/test_level_playability.gd`
  - loads one real level through `root.load_level`;
  - injects real `InputEventKey` events;
  - checks controlled movement and reports player/body state;
  - supports `--inspect` for static terrain and load diagnostics.
- `tools/test_level_playability.ps1`
  - runs every shipped level in a fresh process;
  - source-project mode by default;
  - `-Packaged` runs the same test from the PCK;
  - `-Inspect` keeps detailed failure diagnostics.
- `test/test_level_select.gd`
  - verifies `.tscn.remap` handling, hidden incomplete maps, and playable extras.

Required release gate:

1. run source level playability;
2. force editor reimport;
3. export the PCK;
4. run level selection and all shipped levels with `-Packaged`;
5. run the packaged executable smoke test.

## Known Baseline Debt

These failures were audited separately and are not used as evidence of the map
merge being correct:

- On both `0603f06` and the merged tree, `test_game_control.gd` has 5 failures
  and `test_upright.gd` has 2 failures.
- `test_creative_editor.gd` already fails on the UI branch `4c495db`; it is not
  introduced by the map compatibility changes.
- Older gear tests still assume `gear_tool.finish()` returns a bearing directly;
  current tests use the explicit bearing contract.
