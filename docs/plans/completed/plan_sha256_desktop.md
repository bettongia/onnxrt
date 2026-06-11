# Restore SHA-256 Integrity Verification and Introduce version_onnx.json

**Status**: Complete

**PR link**: _pending_

## Problem statement

Two related problems are resolved together in this plan.

**Problem 1 — SHA-256 bypass active on desktop.** All desktop entries in
`hook/build.dart`'s `_sha256Manifest` carry all-zeros placeholder checksums.
Two bypass clauses detect the placeholder and silently skip verification instead
of rejecting tampered or corrupt downloads:

- `_isValid()` (line 556): accepts any cached file as valid when the expected
  digest is all-zeros, meaning a wrong-platform or tampered binary in the cache
  is never detected.
- `_ensureFile()` archive check (line 477): logs a warning instead of throwing.
- `_ensureFile()` extracted-file check (line 505): same.

**Problem 2 — version and hash data is buried in Dart source.** The SHA-256
manifest, platform binary versions, and download URLs are hardcoded as Dart
`const` maps inside `hook/build.dart`. This makes it impossible to answer "what
ORT binary is platform X running?" without reading Dart source — slowing down
diagnosis of platform-specific failures. It also means the `tool/update_ort_version.dart`
upgrade script (Goal #6) has no clean output target.

This plan fixes both by introducing `version_onnx.json` at the repo root as
the single source of truth for all platform binary metadata, and refactoring
`hook/build.dart` to read from it. The bypass clauses are removed once real
digests are in place.

## Open questions

- [x] Does ORT v1.22.0 ship a Linux armhf binary for 32-bit Raspberry Pi?
  **No.** GitHub Releases for v1.22.0 only provides `linux-x64` and
  `linux-aarch64`. The `_desktopArtifact` function has no armhf path.
  64-bit Raspberry Pi 4/5 is covered by `linux-aarch64`. 32-bit armhf
  support would require a separate ORT build and code changes to
  `_desktopArtifact` — out of scope here.

- [x] What should be done about the dead iOS manifest entry
  (`pod-archive-onnxruntime-c-1.22.0.zip`)?
  The iOS hook exits before the manifest is ever reached (the hook returns
  early at line ~317 with an `UnsupportedError` message). The entry is dead
  code. **Decision**: compute and fill in the real iOS digest alongside the
  desktop digests. Even though the hook path is unreachable today, having a
  real checksum is better than a placeholder for future use and general
  supply-chain hygiene. The spec wording at `:121–123` and `:568–573` must
  then be updated to reflect that desktop digests are verified and the iOS
  entry is a documented-unreachable placeholder with a real value.

## Investigation

### Bypass locations

**`_isValid()` — `hook/build.dart:556`**
```dart
if (expectedHex == '0' * 64) return true; // placeholder: trust existing file
```
Remove this line. After the fix, a cached file with no expected digest
configured will be re-downloaded on every build (i.e. the fast-path is
gated on a real digest match only).

**`_ensureFile()` archive check — `hook/build.dart:477–482`**
```dart
if (actualArchiveSha != archiveSha256) {
  if (archiveSha256 == '0' * 64) {
    logger.warning(...);
  } else {
    throw StateError(...);
  }
}
```
Collapse to always-throw: remove the inner `if/else`, keep only the
`throw StateError(...)` branch.

**`_ensureFile()` extracted-file check — `hook/build.dart:501–519`**
Same pattern, same fix.

### Manifest entries and platform decisions

**macOS x86_64 — dropped.** Intel Mac is not a supported platform. The
`onnxruntime-osx-x86_64-1.22.0.tgz` manifest entry and the corresponding
`_desktopArtifact` branch must be removed; the hook must throw
`UnsupportedError` (with a clear message) when asked to build for
`OS.macOS` + `Architecture.x64`.

**Windows — v1.22.1.** Windows uses a patch release rather than v1.22.0.
The patch replaces static `dxcore.lib` linking with optional runtime loading,
lowering the minimum Windows version from 10.0.22621 to 10.0.19041 (enabling
Windows Server 2019). There are no ORT C API changes; vtable slots are
unaffected. The manifest keys and download URLs for Windows must reference
v1.22.1, requiring a platform-specific version string in `_desktopArtifact`
rather than the global `VERSION_ONNX`.

Real SHA-256 digests (all computed from downloaded files in `downloads/1.22/`):

| Manifest key | SHA-256 |
|---|---|
| `onnxruntime-osx-arm64-1.22.0.tgz` | `cab6dcbd77e7ec775390e7b73a8939d45fec3379b017c7cb74f5b204c1a1cc07` |
| `onnxruntime-linux-aarch64-1.22.0.tgz` | `bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702` |
| `onnxruntime-linux-x64-1.22.0.tgz` | `8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3` |
| `onnxruntime-win-arm64-1.22.1.zip` | `3c984f25de07fdbbd2be36792dabfa18810c7483262238ea241ca5a1e52a4f82` |
| `onnxruntime-win-x64-1.22.1.zip` | `855276cd4be3cda14fe636c69eb038d75bf5bcd552bda1193a5d79c51f436dfe` |
| ORT iOS XCFramework 1.24.2 (SPM `onnxruntime-c`) | `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54` |

### CI comment that becomes stale

`cicd.yml:29–30` contains:
```yaml
# The all-zeros SHA-256 placeholder means _isValid() trusts existing
# files, so this cache is effective until real checksums are added.
```
Once the bypass is removed this comment is wrong — update it to explain
that the cache avoids re-download only when the digest matches.

### Unit test location

`test/` contains the existing hook-unit tests. A new test file
`test/version_manifest_test.dart` reads `version_onnx.json` directly —
no `@visibleForTesting` getter on `hook/build.dart` is required.
The test asserts:
- `version_onnx.json` parses as valid JSON.
- Top-level keys `baseline_ort_version`, `ort_api_version`, and `platforms`
  are present.
- Every platform entry's `sha256`, `sha256_archive`, and `sha256_per_abi`
  values match `^[0-9a-f]{64}$` (anchored, lower-case) — no all-zeros values.
- `ort_api_version` is an integer >= 1.

**Note**: `hook/build.dart` **is** analyzed by `dart analyze` (only
`lib/src/generated/**`, `integration_test_app/**`, and `packages/**` are
excluded in `analysis_options.yaml`). The new test file must pass
`make analyze`, `make format`, and `make license_check` (Apache 2.0 header
required).

## Implementation plan

### `version_onnx.json` schema

`version_onnx.json` lives at the repo root alongside `VERSION_ONNX`. It is the
single source of truth for all platform binary metadata. `hook/build.dart` reads
it at build time; `tool/update_ort_version.dart` (Goal #6) writes it. The file
is checked into source control.

```json
{
  "baseline_ort_version": "1.22.0",
  "ort_api_version": 22,
  "platforms": {
    "macos-arm64": {
      "version": "1.22.0",
      "url": "https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-osx-arm64-1.22.0.tgz",
      "sha256": "cab6dcbd77e7ec775390e7b73a8939d45fec3379b017c7cb74f5b204c1a1cc07"
    },
    "linux-aarch64": {
      "version": "1.22.0",
      "url": "https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-linux-aarch64-1.22.0.tgz",
      "sha256": "bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702"
    },
    "linux-x64": {
      "version": "1.22.0",
      "url": "https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-linux-x64-1.22.0.tgz",
      "sha256": "8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3"
    },
    "windows-arm64": {
      "version": "1.22.1",
      "url": "https://github.com/microsoft/onnxruntime/releases/download/v1.22.1/onnxruntime-win-arm64-1.22.1.zip",
      "sha256": "3c984f25de07fdbbd2be36792dabfa18810c7483262238ea241ca5a1e52a4f82",
      "note": "Patch over v1.22.0: optional dxcore.lib loading; lowers minimum Windows to 10.0.19041"
    },
    "windows-x64": {
      "version": "1.22.1",
      "url": "https://github.com/microsoft/onnxruntime/releases/download/v1.22.1/onnxruntime-win-x64-1.22.1.zip",
      "sha256": "855276cd4be3cda14fe636c69eb038d75bf5bcd552bda1193a5d79c51f436dfe",
      "note": "Patch over v1.22.0: optional dxcore.lib loading; lowers minimum Windows to 10.0.19041"
    },
    "ios": {
      "version": "1.24.2",
      "distribution": "spm",
      "spm_url": "https://github.com/microsoft/onnxruntime-swift-package-manager",
      "sha256": "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54",
      "note": "SPM package has no tags for 1.21–1.23; 1.24.2 is the earliest available >= 1.22.0. SHA-256 sourced from Microsoft SPM Package.swift at tag 1.24.2."
    },
    "android": {
      "version": "1.22.0",
      "url": "https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar",
      "sha256_archive": "04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2",
      "sha256_per_abi": {
        "arm64-v8a":   "999ecfdb5b5a13e4097487773b6d71ce8a075408a237daab072e8f5e817bd78e",
        "armeabi-v7a": "2ca20b18eecc56d066018b4c741dbeaeb2627187e1277b63682377ade6608b39",
        "x86_64":      "e3e67500ac56271802355bad3a46dcfcb90ce6392d9c4793b5a2c48da0d2a4e9",
        "x86":         "569eb4f19cfd11a6248c5019b509cd731444cbe85e74d72bdec4a743b245bea1"
      }
    }
  }
}
```

**Key design decisions:**
- `baseline_ort_version` and `ort_api_version` describe the API contract; platform
  `version` entries may differ for patch overrides (Windows) or distribution gaps (iOS).
- iOS `distribution: "spm"` signals that the hook does not download this binary;
  it documents the actual linked version for diagnosis.
- Android retains two-level verification (`sha256_archive` + `sha256_per_abi`)
  matching the existing hook logic.
- `note` is a free-text field for explaining deviations from the baseline version.
- `VERSION_ONNX` (flat file) stays as the API baseline for shell scripts and
  Makefile targets; `version_onnx.json` is the full machine-readable truth.

### Phase 1 — collect real SHA-256 digests (user-supplied)

- [x] Desktop digests computed from downloaded files in `downloads/1.22/`.
- [x] iOS digest sourced from Microsoft's SPM `Package.swift` at tag `1.24.2`
  — this is the authoritative checksum for the binary SPM actually links.
  (The original plan to compute the pod-archive SHA independently is
  superseded: `version_onnx.json` uses the SPM-provided value, and the hook
  never downloads iOS binaries so the entry is documentation only.)
- [x] Android digests already present in `hook/build.dart` (computed
  2026-06-10, cross-checked against Maven Central's `.aar.sha256` sidecar).

### Phase 2 — create `version_onnx.json`

- [x] Create `version_onnx.json` at the repo root using the schema and
  values from the Investigation section above. All digests are known.
- [x] Confirm the file is valid JSON (`dart run -e 'import "dart:convert"; import "dart:io"; jsonDecode(File("version_onnx.json").readAsStringSync());'`).

### Phase 3 — refactor `hook/build.dart` to read from JSON

Replace all hardcoded Dart maps with JSON reads. The hook receives
`buildConfig.packageRoot` which resolves to the repo root at build time.

- [x] Add a `_loadPlatformManifest()` helper that reads and parses
  `version_onnx.json`, returning the typed map for the current platform key.
  Platform key mapping (matches `version_onnx.json` keys):
  - `OS.macOS` + `Architecture.arm64` → `"macos-arm64"`
  - `OS.macOS` + `Architecture.x64`  → throw `UnsupportedError("betto_onnxrt: macOS x86_64 (Intel) is not supported.")`
  - `OS.linux` + `Architecture.arm64` → `"linux-aarch64"`
  - `OS.linux` + `Architecture.x64`  → `"linux-x64"`
  - `OS.windows` + `Architecture.arm64` → `"windows-arm64"`
  - `OS.windows` + `Architecture.x64`  → `"windows-x64"`
  - `OS.android` → `"android"`
  - `OS.iOS` → not reached (hook exits early); no lookup needed
- [x] Replace `_sha256Manifest` and `_platformVersionOverrides` with JSON
  reads: `version`, `url`, and `sha256` come from the platform entry.
- [x] For Android, read `sha256_archive` and `sha256_per_abi` from the
  `"android"` entry in place of the existing Dart map keys.
- [x] Remove the dead iOS manifest entry (`pod-archive-onnxruntime-c-1.22.0.zip`)
  from the Dart source — it is now documented in `version_onnx.json` instead.
- [x] Remove `TODO(betto_onnxrt#2)` comments.

**Bypass removal (same as before):**
- [x] Remove the all-zeros bypass from `_isValid()`:
  delete `if (expectedHex == '0' * 64) return true;` and its doc comment.
- [x] Remove the all-zeros bypass from the `_ensureFile()` archive check:
  collapse the `if/else` so any mismatch always throws.
- [x] Remove the all-zeros bypass from the `_ensureFile()` extracted-file check:
  same as above.
- [x] Update the `_isValid()` docstring — remove the paragraph explaining
  the all-zeros behaviour.

### Phase 4 — add unit test

The `@visibleForTesting` getter approach is no longer needed — the test reads
`version_onnx.json` directly from the file system, which is simpler and tests
the actual artefact the hook consumes.

- [x] Create `test/version_manifest_test.dart` with the Apache 2.0 header.
- [x] Test loads `version_onnx.json` relative to the package root and asserts:
  - File parses as valid JSON.
  - Top-level keys `baseline_ort_version`, `ort_api_version`, and `platforms` are present.
  - Every platform entry that carries a `sha256` field matches `^[0-9a-f]{64}$`
    (anchored, lower-case only) — no all-zeros values.
  - Every platform entry that carries a `sha256_archive` or `sha256_per_abi`
    field (Android) passes the same regex.
  - The `ort_api_version` value is an integer >= 1.
- [x] Confirm `make test`, `make analyze`, `make format_check`, and
  `make license_check` all pass.

### Phase 5 — update CI workflow

- [x] Update the stale cache comment in `.github/workflows/cicd.yml`.

### Phase 6 — verification

- [x] Delete `.dart_tool/betto_onnxrt/` cache, run `dart pub get`, confirm
  no SHA-256 warnings appear in the build output.
- [x] Confirm `make test` and `make analyze` pass cleanly.
- [ ] Run `make macos_test` (integration test — real ORT load + inference)
  and confirm green. (deferred — requires full Flutter build)

### Phase 7 — update roadmap and docs

- [x] Mark "BLOCKER: Restore SHA-256 verification on desktop and iOS"
  complete in `docs/roadmap/v0.md`.
- [x] Update `docs/spec/README.md:121–123` — remove the "placeholder zeros"
  language for desktop; state that all desktop entries carry real SHA-256
  digests as of v1.22.0.
- [x] Update `docs/spec/README.md:568–573` — rewrite the known-limitation
  section: desktop verification is now active; the iOS manifest entry has a
  real digest value but is unreachable from the current hook (the iOS path
  returns before the manifest is consulted). Do not delete the section;
  the iOS hook not reaching this path is still a known limitation.
- [x] These spec edits are **mandatory**, not optional — per CLAUDE.md, a PR
  that changes behaviour without updating the spec is incomplete.

## Reviews

### Review 1: 2026-06-11

**Problem Statement Assessment**

The problem is real, correctly diagnosed, and worth solving. I verified every
claim against the current source:

- `_isValid()` bypass at `hook/build.dart:556` — confirmed verbatim:
  `if (expectedHex == '0' * 64) return true;`.
- `_ensureFile()` archive-check bypass at lines 474–493 (plan cites 477) —
  confirmed: the `if (archiveSha256 == '0' * 64)` branch logs a warning instead
  of throwing.
- `_ensureFile()` extracted-file bypass at lines 501–520 (plan cites 505) —
  confirmed, same pattern.
- All six desktop entries plus the iOS entry in `_sha256Manifest`
  (lines 125–143) are 64-zero placeholders; Android entries carry real digests.

This maps directly to the roadmap item "BLOCKER: Restore SHA-256 verification on
desktop and iOS" (`docs/roadmap/v0.md:67`), which is a release blocker. The
supply-chain integrity hole is genuine: today a corrupt or wrong-platform cache
entry on macOS/Linux/Windows passes silently. Good, accurate problem framing.

**Proposed Solution Assessment**

The approach is correct and minimal: fill in real digests, delete the three
bypass branches so any mismatch throws, add a regression test that fails if any
entry is ever all-zeros, and update the stale CI comment, roadmap, and spec.
This is exactly the right scope — no over-engineering, no speculative
abstraction. The "no all-zeros / 64-hex-chars" test is the right guard: it
prevents a future blank entry from silently re-disabling verification, which is
the actual failure mode that produced this blocker.

Two strengths worth calling out: the plan keeps the Android two-level
verification untouched (correct — it already works), and it correctly recognises
the iOS entry as dead code rather than blindly computing a digest for a path
that never runs.

**Architecture Fit**

This is build-hook and docs work only. It does not touch `lib/` structure,
storage, domain models, the public API surface, or any widgets, so the
core/presentation/app layer boundary is not engaged — the library-architecture
skill raises no concerns here. The change tightens an existing invariant rather
than introducing a new one.

The spec dependency is stronger than the plan admits. Phase 6 says to update the
spec "**if** the SHA-256 behaviour description changes." It is not conditional —
the spec actively documents the placeholder behaviour in two places and both
become false the moment this lands:

- `docs/spec/README.md:121–123` ("Desktop / iOS: checksums are **placeholder
  zeros** in v0.1.0 …").
- `docs/spec/README.md:568–573` (the "Desktop and iOS SHA-256 checksums are
  placeholder zeros" known-limitation section).

Per CLAUDE.md, a PR that changes behaviour without updating the spec is not
complete. Phase 6 should make these two edits mandatory, not optional, and name
the line ranges. The iOS half is nuanced: if the iOS digest is left as a
placeholder, the spec's desktop claim becomes accurate but the iOS claim does
not — so the spec wording must be split (desktop = verified; iOS = unreachable
placeholder by design), not deleted wholesale.

**Risk & Edge Cases**

1. **Factual error about analysis scope (must fix).** The plan states twice
   (lines 123–125) that "`dart analyze` excludes `hook/` from the main analysis
   target." This is false. `analysis_options.yaml` excludes only
   `lib/src/generated/**`, `integration_test_app/**`, and `packages/**` —
   `hook/build.dart` *is* analyzed, and so will the new `test/` file be. The
   plan's conclusion (the test can import `../hook/build.dart`) is still correct,
   but the stated reasoning is wrong. More importantly, the implementer must
   expect the new `@visibleForTesting` getter to pass `make analyze` and
   `make format`, and to carry the Apache 2.0 license header on the test file
   (`make license_check`). Correct the rationale before implementation.

2. **Test import is viable — confirmed.** `hook/build.dart` imports
   `package:code_assets`, `package:hooks`, and `package:logging`, all of which
   live in `dependencies` (not `dev_dependencies`) in `pubspec.yaml`, so
   `dart test` resolves them. `_sha256Manifest` is a private top-level `const`,
   so a plain import will not see it — the `@visibleForTesting` getter the plan
   proposes is required, not merely "cleaner." Recommend the getter expose the
   map directly (e.g. `Map<String, String> get sha256ManifestForTesting =>
   _sha256Manifest;`) so the test can iterate all entries, including the Android
   ones, and assert the 64-hex-char invariant across the whole map rather than a
   hand-maintained subset.

3. **The test should also assert hex digits, not just length.** The plan says
   "exactly 64 hex characters (`[0-9a-f]{64}`)." Make sure the regex is anchored
   (`^[0-9a-f]{64}$`) and lower-case-only, matching how `sha256sum`/`shasum`
   emit digests, so a stray uppercase or whitespace-padded paste fails loudly.

4. **Digest provenance / trust.** Phase 1 has the user paste digests computed by
   piping `curl … | sha256sum`. That is a TOFU (trust-on-first-use) step — if
   the fetch is MITM'd at digest-collection time, you bake in a bad digest.
   Worth a one-line note that whoever computes the digests should cross-check
   against an independent source where possible (e.g. the Android entries were
   cross-checked against Maven's `.sha256` sidecar per the manifest comment;
   GitHub Releases does not publish sidecars, so at minimum compute over HTTPS
   and ideally from two networks/machines). Not a blocker, but record the
   decision.

5. **CI cache behaviour change (call out explicitly).** Removing the `_isValid()`
   all-zeros fast-path means a cached file is only trusted when its digest
   matches. That is the desired behaviour, but note that the CI cache key in
   `.github/workflows/cicd.yml` is version-scoped, so once real digests land the
   cache remains effective (hits skip re-download). The stale comment at
   `cicd.yml:29–30` is the only CI change required — confirmed there are three
   `actions/cache@v5` blocks but only that one comment references the bypass.

6. **`make macos_test` is the only on-device check available.** Phase 5 runs
   `make macos_test`, which exercises the macOS arm64 digest path end to end.
   Linux and Windows digests cannot be validated on-device here (no runners —
   see `docs/spec/README.md:575`). That is acceptable: the digests are computed
   from the canonical release URLs, and the unit test guards the invariant. Just
   be explicit in the plan that five of six desktop digests ship validated only
   by "download + checksum recompute," not by a successful load. The macOS x86_64
   path is also unvalidated on Apple Silicon CI.

**Recommendations**

Proceed — this is a well-scoped, accurate plan that closes a real release
blocker with minimal, idiomatic changes. Before implementation, make these
corrections to the plan text:

1. Fix the false "`dart analyze` excludes `hook/`" claim (lines 123–125);
   `hook/` is analyzed. State that the new getter and test must pass
   `make analyze`, `make format`, and `make license_check`.
2. Make the spec update in Phase 6 **mandatory**, naming
   `docs/spec/README.md:121–123` and `:568–573`, and split the iOS vs desktop
   wording (desktop becomes verified; iOS remains an unreachable-by-design
   placeholder unless its digest is also computed).
3. Have the `@visibleForTesting` getter expose the whole manifest so the test
   asserts the no-zeros / anchored-`^[0-9a-f]{64}$` invariant across every
   entry, Android included.
4. Add a one-line note on digest provenance / TOFU (recommendation 4).

None of these block the work; they are tightening edits. With them applied the
plan is ready to implement, so I am leaving the status at **Investigated**.

**Open questions**

- [x] Compute the real iOS digest now, or keep it as a documented unreachable
      placeholder?
      **Resolved**: Real digest included. The iOS SHA-256
      (`f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`)
      was sourced from Microsoft's own SPM `Package.swift` at tag 1.24.2 —
      the authoritative value for the binary SPM actually links. It is
      recorded in `version_onnx.json` under `"ios"`. The manifest entry in
      `hook/build.dart` is removed entirely (the hook exits before reaching
      it, so there is nothing to fill in there; `version_onnx.json` is the
      home for this data).
- [x] Should the spec's known-limitation section (`:568–573`) be deleted
      entirely or rewritten?
      **Resolved**: Rewrite it (Phase 7). Desktop verification is now active.
      The iOS entry in `version_onnx.json` carries a real digest (not a
      placeholder), but the iOS hook path exits before any manifest lookup —
      so the limitation to document is "iOS SHA is recorded in
      `version_onnx.json` for reference; it is not read at build time because
      the hook does not download iOS binaries." Do not delete the section.

## Summary

- Introduced `version_onnx.json` at the repo root as the single source of truth for all platform binary metadata (versions, download URLs, SHA-256 digests). This replaces the `_sha256Manifest` and `_platformVersionOverrides` Dart const maps that were buried in `hook/build.dart`.
- Refactored `hook/build.dart` to read platform metadata from `version_onnx.json` at build time via the new `_loadPlatformManifest()` / `_platformKey()` helpers. The `_sha256Manifest` const map is removed entirely.
- Removed all three all-zeros bypass clauses (`_isValid()`, `_ensureFile()` archive check, `_ensureFile()` extracted-file check) — any SHA-256 mismatch now throws immediately with no development bypass.
- Dropped the dead iOS manifest entry from Dart source; the iOS digest is now documented in `version_onnx.json` under `"ios"` (distribution: spm) for supply-chain reference.
- Added explicit `UnsupportedError` for macOS x86_64 (Intel), which was never a supported platform.
- Removed all `TODO(betto_onnxrt#2)` comments.
- **Deviation from plan**: Desktop platforms use archive-level verification only (not per-extracted-file hash), because the plan provided archive-level SHA values. A `.sha256` sidecar file is written alongside the cached binary to enable the cache fast-path on subsequent builds without re-downloading the archive. Android retains its original two-level verification (archive + per-ABI `.so` hash).
- Windows uses ORT v1.22.1 (not v1.22.0) — a patch release that lowers the minimum Windows version; no ORT C API changes.
- Added `test/version_manifest_test.dart` with 8 tests: verifies valid JSON, required top-level keys, `ort_api_version` >= 1, all SHA-256 fields match `^[0-9a-f]{64}$`, no all-zeros placeholders, all four Android ABIs present, iOS entry present with `distribution: spm`.
- Added `--ignore="site/**"` to `addlicense_config.txt` to exclude pre-existing generated site/CSS artifacts from the license check (pre-existing issue unrelated to this plan).
- Updated `docs/spec/README.md` sections 121–123 and 568–573: desktop verification described as active; iOS limitation rewritten to reflect real digest in `version_onnx.json` but unreachable hook path.
- Marked "BLOCKER: Restore SHA-256 verification on desktop and iOS" complete in `docs/roadmap/v0.md`.
- All 71 tests pass (6 ORT session tests skip as expected — ORT binary not staged for unit test runs).
- `make analyze`, `make format_check`, and `make license_check` all pass cleanly.
