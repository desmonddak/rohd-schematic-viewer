# Developer Notes

## VS Code tasks and dependency sources

The tasks in [`.vscode/tasks.json`](../.vscode/tasks.json) do not select
dependency sources. They build or run using the dependency configuration that
is already present in the workspace.

This is intentional. An application may depend on several independently
developed components. For example, a debugger application could use the
schematic viewer and wave viewer from local checkouts while using hosted ROHD
packages. Modeling this as one `hosted`/`git`/`local` choice would create an
unhelpful cross-product of combinations.

### Default: hosted packages

The release dependencies in [`pubspec.yaml`](../pubspec.yaml) are hosted on
pub.dev. If `pubspec_overrides.yaml` does not exist, `flutter pub get` uses
those manifest dependencies. This is the default and requires no setup.

Use the **Use Manifest Dependencies** task to disable the generated override
and return to this default. The file is moved aside rather than deleted so
local edits can be recovered:

```bash
./scripts/schematic_dev_mode.sh manifest
flutter pub get
```

The backup is named `pubspec_overrides.yaml.disabled` (with a numeric suffix
if needed) and is ignored by Git.

### Assumed local development directories

Local dependency mode assumes that the ROHD monorepo is checked out at:

```text
~/release/rohd
```

This checkout should contain the ROHD package at its root and the companion
packages under `packages/`. The path is used by
[`scripts/schematic_dev_mode.sh`](../scripts/schematic_dev_mode.sh) when a
package is configured as `local`.

If the checkout is elsewhere, set `ROHD_LOCAL_PATH` before configuring local
dependencies:

```bash
ROHD_LOCAL_PATH=/path/to/rohd \
  ./scripts/schematic_dev_mode.sh configure rohd local
```

The path is not required when using hosted or Git sources.

### Selecting sources independently

Development overrides are generated only when a package needs a source other
than the manifest source. Configure each package explicitly by passing package
and source pairs:

```bash
./scripts/schematic_dev_mode.sh configure \
  rohd local \
  rohd_hierarchy local \
  rohd_devtools_widgets git
flutter pub get
```

Supported sources are:

- `hosted`: use the package's pub.dev constraint.
- `git`: use `ROHD_GIT_URL` and `ROHD_GIT_REF`.
- `local`: use the checkout selected by `ROHD_LOCAL_PATH`, or
  `~/release/rohd` by default.

Only the listed packages are overridden. Unlisted packages continue to use
the dependencies in `pubspec.yaml`. This makes the same command shape
usable for larger applications with more component dependencies.

The run tasks then use the selected configuration without prompting:

- **ROHD Schematic Viewer: Web Debug**
- **ROHD Schematic Viewer: Web Release WASM**
- **ROHD Schematic Viewer: Linux Debug**
- **ROHD Schematic Viewer: Linux Release**

Use **Show Schematic Viewer Dependency Mode** to inspect the generated
configuration. The generated `pubspec_overrides.yaml` is ignored and must
not be committed.

The older `local-rohd`, `local-extension`, and `local-all` tasks remain as
convenience shortcuts for this repository's common combinations. New
applications should prefer the individual package-pair form above.
