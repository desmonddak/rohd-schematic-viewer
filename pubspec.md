# Pubspec Notes

This file documents non-obvious dependency choices in [pubspec.yaml](pubspec.yaml).

## ROHD Dependencies

The release `pubspec.yaml` uses hosted ROHD packages from pub.dev:

- `rohd` `^0.6.11`
- `rohd_devtools_widgets`
- `rohd_hierarchy`
- `rohd_source_navigator`

Development-only Git and local modes remain available through
`scripts/schematic_dev_mode.sh` and the ignored `pubspec_overrides.yaml`; the
release manifest itself contains no dependency overrides.

## Dependency Modes

The VS Code run tasks use the dependency source already configured in the
workspace; they do not prompt during every build:

- `hosted`: resolve ROHD and companion packages from pub.dev. This is the
  release/default mode.
- `git`: resolve an explicitly selected package from the configured Git
  repository and tag or branch.
- `local`: resolve an explicitly selected package from the local checkout.

Sources can be selected independently because larger applications may depend
on several viewers or tools. This avoids a cross-product of all possible
dependency-mode combinations.

The modes are handled outside `pubspec.yaml` by
`scripts/schematic_dev_mode.sh`, which writes an ignored
`pubspec_overrides.yaml` file.

For example:

```bash
bash scripts/schematic_dev_mode.sh configure \
  rohd git \
  rohd_hierarchy hosted \
  rohd_devtools_widgets local
flutter pub get
```

If no override file is present, the manifest dependencies are used and hosted
pub.dev packages are the default.

Git mode defaults to the `v0.6.11` tag to match the hosted ROHD baseline. Set
`ROHD_GIT_URL` and `ROHD_GIT_REF` to test another ROHD repository or branch;
the selected ref is applied consistently to every Git-sourced ROHD package.

The default local checkout is `~/release/rohd`. Configure local package
sources from it with:

```bash
bash scripts/schematic_dev_mode.sh local-all
flutter pub get
```

Set `ROHD_LOCAL_PATH=/path/to/rohd` to use a different checkout. The generated,
ignored `pubspec_overrides.yaml` points directly to the external checkout; no
repository-local symlink is created.

To return to the manifest dependencies:

```bash
bash scripts/schematic_dev_mode.sh manifest
flutter pub get
```

If a generated override file exists, `manifest` moves it to the ignored
`pubspec_overrides.yaml.disabled` backup (adding a numeric suffix when needed)
instead of deleting it.
