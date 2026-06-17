# Releasing betto_onnxrt to pub.dev

`betto_onnxrt` and `betto_onnxrt_ios` are released in lockstep. Both must carry
the same version number at the point of publication, and `betto_onnxrt` must be
published before `betto_onnxrt_ios`.

---

## 1. Pre-release checklist

Work through every item before running the publish commands.

### Code and tests

- [ ] All v0 roadmap blockers are resolved (see `docs/roadmap/v0.md`).
- [ ] `make` passes (full quality gate: format, analyze, license, test,
      coverage, doc).
- [ ] `make check_ios_version` passes — SPM exact-version pin in
      `packages/betto_onnxrt_ios/ios/Package.swift` matches `version_onnx.json`
      `ios.version`.
- [ ] `make macos_test` passes — real ORT load and inference on macOS (AOT).
- [ ] `make linux_test` passes — real ORT inference on Linux (pure Dart, JIT).
- [ ] `make android_test` passes — real ORT inference on Android emulator.
- [ ] `make ios_test` passes — real ORT load and inference on iOS simulator.
- [ ] `nm -gU packages/betto_onnxrt/integration_test_app/build/ios/iphonesimulator/Runner.app/Runner.debug.dylib | grep OrtGetApiBase`
      confirms `_OrtGetApiBase` is present after the iOS simulator build. (Run
      from the repo root. In debug builds Flutter splits app code into
      `Runner.debug.dylib`; `Runner` itself is just a stub loader.)
- [ ] Manual smoke check on Linux Flutter Desktop and Windows Flutter Desktop
      completed per `docs/manual_checks.md`.
- [ ] `packages/betto_onnxrt/version_onnx.json` has real (non-zero) SHA-256
      digests for every platform. `make test` (which runs
      `test/version_manifest_test.dart`) enforces this.

### Documentation

- [ ] `make doc` succeeds and the generated docs look complete — all public
      types in `OnnxRuntime`, `OnnxSession`, `OnnxTensor`, `OnnxElementType`,
      `SessionOptions`, `ModelDownloader`, `ModelSpec`, `ModelFile`,
      `ResolvedModel`, and `AllowlistProvider` have doc comments.
- [ ] The package-level doc in `lib/betto_onnxrt.dart` gives a clear overview
      suitable for the pub.dev landing page.
- [ ] `docs/spec/README.md` reflects the published API exactly; update it if any
      behaviour changed since the last spec edit.

---

## 2. Align versions

Both packages must carry the same version string. `betto_onnxrt_ios` is tightly
coupled to the ORT vtable baked into `betto_onnxrt` via `VERSION_ONNX`, so they
are always released together.

1. Decide the release version (e.g. `0.1.0`).
2. Update `version:` in `packages/betto_onnxrt/pubspec.yaml`.
3. Update `version:` in `packages/betto_onnxrt_ios/pubspec.yaml`.

The version in both files must be identical and must not carry a `-dev` or
`-pre` suffix for a stable release.

---

## 3. Update CHANGELOG.md files

Both changelogs follow the same convention: the version heading is the section
for that release; bullet points go beneath it. There is no `## Unreleased`
section — the topmost heading is always the in-progress version.

### betto_onnxrt (`packages/betto_onnxrt/CHANGELOG.md`)

Add a release date to the heading and ensure all notable changes are listed:

```markdown
## 0.1.0 — 2026-MM-DD

- ...items added during the dev cycle...
```

Then add a new empty heading above it for the next version:

```markdown
## 0.1.1

## 0.1.0 — 2026-MM-DD
...
```

### betto_onnxrt_ios (`packages/betto_onnxrt_ios/CHANGELOG.md`)

Apply the same pattern — add a release date to the heading and populate it with
any notable changes since the previous release.

pub.dev requires a `CHANGELOG.md`; publishing without one will produce a warning
and a lower pub score.

---

## 4. Dry run

Run `dart pub publish --dry-run` for both packages and confirm there are no
errors or unexpected warnings.

```bash
# betto_onnxrt:
cd packages/betto_onnxrt
dart pub publish --dry-run
cd ../..

# betto_onnxrt_ios:
cd packages/betto_onnxrt_ios
dart pub publish --dry-run
cd ../..
```

Common things to check in the dry-run output:

- No files are accidentally excluded that should be included (check the "Files
  to be published" list against `lib/`, `hook/`, `CHANGELOG.md`, `LICENSE`,
  `README.md`, and `pubspec.yaml`).
- No files with secrets or build artefacts are included. The `.dart_tool/` cache
  directory must not appear in the list.
- No `CHANGELOG.md` warning (pub.dev requires a changelog).
- No `README.md` warning (pub.dev strongly recommends one).

---

## 5. Publish

### 5a. Publish betto_onnxrt

```bash
cd packages/betto_onnxrt
dart pub publish
cd ../..
```

Follow the authentication prompts if this is the first publish from this
machine; `dart pub` opens a browser for Google account sign-in. Confirm the
package name and version shown in the confirmation prompt before proceeding.

After the command returns, wait ~60 seconds and verify the package appears at
`https://pub.dev/packages/betto_onnxrt`.

### 5b. Publish betto_onnxrt_ios

Once `betto_onnxrt` is visible on pub.dev, publish the iOS shim:

```bash
cd packages/betto_onnxrt_ios
dart pub publish
cd ../..
```

The iOS plugin depends on the Flutter SDK, not on a pub.dev version of
`betto_onnxrt`, so there is no strict ordering dependency between them beyond
convention. However, always publish `betto_onnxrt` first so that any consumer
who adds both packages simultaneously resolves to versions known to work
together.

---

## 6. Post-publication

- [ ] Verify `https://pub.dev/packages/betto_onnxrt` shows the new version, and
      that the pub score (likes, pub points, popularity) looks reasonable. Aim
      for 140+ pub points. A low score typically indicates missing doc comments,
      a missing `README.md`, or a missing `CHANGELOG.md`.
- [ ] Verify `https://pub.dev/packages/betto_onnxrt_ios` shows the new version.
- [ ] Tag the commit in git:

  ```bash
  git tag v0.1.0
  git push origin v0.1.0
  ```

- [ ] Mark the `pub.dev delivery` item in `docs/roadmap/v0.md` as complete.

---

## Re-publishing after a patch

If a bug is found after publication, increment only the patch component (e.g.
`0.1.0` → `0.1.1`). Always bump both packages together, repeat steps 2–6 above,
and add a `## 0.1.1` section to both changelogs describing the fix. pub.dev does
not allow re-publishing the same version; a new version number is always
required.
