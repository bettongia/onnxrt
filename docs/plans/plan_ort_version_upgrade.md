# ORT Version Upgrade Pipeline

**Status**: Investigated

**PR link**: _pending_

## Problem statement

Upgrading `betto_onnxrt` to a new ONNX Runtime release requires coordinated
changes across seven files and a multi-platform integration test run. Currently
the process is entirely undocumented and the SHA-256 archaeology — downloading
seven binary artifacts (five desktop archives, one Android AAR, per-ABI `.so`
extraction) and computing checksums — is done by hand with `curl | sha256sum`.
A misstep produces a broken build or a silent checksum bypass.

This plan closes **Goal #6** of the v0 roadmap by delivering:

1. **`tool/update_ort_version.dart`** — a Dart script that accepts a target
   ORT version tag, discovers the platform binaries from GitHub Releases and
   Maven Central (handling per-platform patch overrides), downloads and
   checksums each, writes `VERSION_ONNX`, and emits a ready-to-merge
   `version_onnx.json`. Eliminates the manual `curl | sha256sum` archaeology.

2. **`tool/check_ort_slots.dart`** — a helper that downloads
   `onnxruntime_c_api.h` for a given release, parses the `OrtApi` struct field
   order, and reports the zero-based slot index for each of the 23 symbols bound
   in `lib/src/ort_api.dart`. Reduces the error-prone manual counting step while
   leaving the final load+inference verification as a human step.

3. **`docs/upgrading_onnxrt.md`** — a human-readable checklist that covers the
   full upgrade ceremony: running the scripts, verifying vtable slot indices
   against the new `onnxruntime_c_api.h`, updating the iOS SPM pin, running the
   integration test matrix, and updating changelogs. Referenced from
   `docs/spec/README.md §9`.

The plan also performs the first real upgrade as a self-test: ORT **v1.22.0 →
v1.26.0**, exercising every step of the documented process.

## Open questions

- [x] Does the ORT API version number always equal the ORT minor version?
  **Yes.** `OrtGetApiBase(N)` returns the API struct for release 1.N.x.
  API version 22 → ORT 1.22.x; API version 26 → ORT 1.26.x.

- [x] Do vtable slot indices change between 1.22.x and 1.26.x?
  **Possibly — must be verified manually.** The `ort_slot_guard_test.dart`
  golden catches drift after a PR lands, but cannot tell us ahead of time
  whether slot numbers shifted. The upgrade guide mandates running
  `tool/check_ort_slots.dart` against the new `onnxruntime_c_api.h` to count
  offsets for all 23 bound symbols. See Investigation §vtable-slot check below.

- [x] Is a Windows patch release needed for 1.26.0?
  **Unknown until build time.** The 1.22.0 cycle needed a Windows-specific
  v1.22.1 patch (optional dxcore.lib loading). The script will probe for a
  Windows patch by HEAD-requesting each candidate URL and choosing the highest
  available patch ≤ `.9`. The user confirms the note to record in
  `version_onnx.json`.

- [x] What SPM tag should the iOS pin use for 1.26.0?
  **Check the SPM repo tags.** The `onnxruntime-swift-package-manager` repo
  previously had no tags between 1.20.0 and 1.24.1. The script fetches the
  list of tags from GitHub's API and identifies the earliest available tag
  ≥ the new baseline version using semver comparison. The SHA-256 is parsed
  from `Package.swift` in that tag. This is a partially-automated step: the
  script reports the candidate tag; the operator confirms before the JSON is
  written. If no tag ≥ baseline exists, the script fails loudly.

- [x] **Q1: Should `ortApiVersion` track the baseline minor version (bump
  22 → 26) or hold at 22?**
  **Track baseline (bump to 26).** `ortApiVersion` will match the ORT minor
  version on every upgrade. Phase 4 therefore re-verifies all 23 slot offsets
  against the 1.26.0 header and updates the golden table to `_expectedSlotsV26`.
  This is the honest policy — the API version constant is a claim about which
  ORT binary we target, not merely the minimum version that would work.

- [x] **Q2: Should `tool/update_ort_version.dart` also write `VERSION_ONNX`?**
  **Yes.** The script writes `VERSION_ONNX` (with `v` prefix, e.g. `v1.26.0`)
  alongside `version_onnx.json` so that `dart run tool/generate_versions.dart`
  is never run against a stale value. The `v`-prefix convention is preserved:
  `VERSION_ONNX` = `v1.26.0`; `version_onnx.json` per-platform `version` =
  bare `1.26.0`; `baseline_ort_version` = bare `1.26.0`.

- [x] **Q3: Is `tool/check_ort_slots.dart` in scope?**
  **Yes.** Added to Phase 2. The helper parses `onnxruntime_c_api.h`, counts
  the zero-based `OrtApi` struct field offsets for the 23 bound symbols, and
  diffs them against the current `// SLOT:Name=N` annotations in
  `lib/src/ort_api.dart`. The final load+inference verification remains a human
  step (`make macos_test`).

## Investigation

### Files changed on every ORT upgrade

| File | Change |
|------|--------|
| `VERSION_ONNX` | Bumped to `v{newver}` (written by `update_ort_version.dart`) |
| `version_onnx.json` | All platform `version`, `url`, `sha256` fields; `baseline_ort_version` and `ort_api_version` at top level |
| `lib/src/generated/versions.g.dart` | Regenerated by `dart run tool/generate_versions.dart` after `VERSION_ONNX` is written |
| `lib/src/ort_api.dart` | `ortApiVersion` constant (tracks baseline minor); SLOT annotations and typedef pairs if slots shifted |
| `test/ort_slot_guard_test.dart` | Golden table (`_expectedSlotsV22` → `_expectedSlotsV{N}`) when API version changes |
| `packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift` | `exact:` SPM version pin |
| `CHANGELOG.md` (both packages) | Release notes |

### Binary artifact catalog

The hook reads `version_onnx.json` for all binary metadata. The `version_onnx.json`
schema has two layers:
- **Top-level** fields: `baseline_ort_version` (the ORT minor-version baseline
  that drives `VERSION_ONNX` and the `ortApiVersion` constant) and
  `ort_api_version` (passed to `OrtGetApiBase()`).
- **Per-platform** fields under `platforms`: `version`, `url`, `sha256` (or
  `sha256_archive` + `sha256_per_abi` for Android).

The script must produce values for all seven platform keys:

| Key | Artifact type | URL template |
|-----|---------------|--------------|
| `macos-arm64` | `.tgz` | `https://github.com/microsoft/onnxruntime/releases/download/v{ver}/onnxruntime-osx-arm64-{ver}.tgz` |
| `linux-aarch64` | `.tgz` | `…/onnxruntime-linux-aarch64-{ver}.tgz` |
| `linux-x64` | `.tgz` | `…/onnxruntime-linux-x64-{ver}.tgz` |
| `windows-arm64` | `.zip` | `…/onnxruntime-win-arm64-{ver}.zip` |
| `windows-x64` | `.zip` | `…/onnxruntime-win-x64-{ver}.zip` |
| `android` | `.aar` (Maven) | `https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/{ver}/onnxruntime-android-{ver}.aar` |
| `ios` | SPM (not downloaded) | `https://github.com/microsoft/onnxruntime-swift-package-manager` |

macOS x86_64 (Intel) is not supported and has no entry.

### Windows patch probe

Historical precedent (v1.22.0 → v1.22.1 Windows) shows that Windows may ship
a patch release that supersedes the baseline. The script probes using HTTP HEAD
requests:

1. Send `HEAD` to the baseline URL (e.g. `v1.26.0/onnxruntime-win-x64-1.26.0.zip`),
   **following redirects** (GitHub release-asset URLs return `302` to a CDN
   before the final `200`).
2. If the final resolved status is `2xx`, the baseline version is used.
3. If `4xx`, try `.1`, `.2`, … `.9` in order (same redirect-following rule).
4. Use the first `2xx` URL found.
5. If baseline and all `.1`–`.9` probes return non-`2xx`, **fail loudly** with
   a clear error message rather than emitting a stale or empty URL.
6. Record the actual version used in the per-platform `version` field and note
   the deviation in the `note` field.

### Android two-level verification

The Android AAR is a zip archive containing one `.so` per ABI under
`jni/{abi}/libonnxruntime.so`. The script:
1. Downloads the AAR to a temp file.
2. Computes SHA-256 of the archive → `sha256_archive`.
3. Cross-checks against Maven Central's `.aar.sha256` sidecar (`{url}.sha256`)
   for independent provenance confirmation.
4. Extracts `jni/{abi}/libonnxruntime.so` for each of the four ABIs
   (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`).
5. Computes SHA-256 of each extracted `.so` → `sha256_per_abi[{abi}]`.
6. **Fails loudly** if any of the four ABIs is absent from the AAR rather than
   emitting a partial `sha256_per_abi` map.

### iOS SPM version lookup

The `onnxruntime-swift-package-manager` repository does not track the same
release cadence as the main ORT repo (e.g. there were no tags between 1.20.0
and 1.24.1). The script:

1. Fetches the tag list via the GitHub API:
   `https://api.github.com/repos/microsoft/onnxruntime-swift-package-manager/tags`
2. Filters to tags whose semver ≥ the new baseline using proper semver
   comparison (not string comparison — `1.9.0` > `1.24.2` lexically but not
   numerically). Selects the earliest qualifying tag.
3. If **no tag ≥ baseline exists**, fails loudly with the message:
   `No SPM tag ≥ {baseline} found. Check https://github.com/microsoft/onnxruntime-swift-package-manager/tags manually.`
   Does not write a placeholder to `version_onnx.json`.
4. Fetches `Package.swift` for the selected tag via raw.githubusercontent.com.
5. Parses the `checksum:` value by **anchoring on the URL substring
   `pod-archive-onnxruntime-c-`**, not on the Swift target name. The upstream
   `Package.swift` has two binary targets in the same conditional block:
   - `onnxruntime` — URL contains `pod-archive-onnxruntime-c-{ver}.zip` — **this is the one we want**
   - `onnxruntime_extensions` — URL contains `pod-archive-onnxruntime-extensions-c-` — must be excluded

   The parser finds the line matching `pod-archive-onnxruntime-c-` and extracts
   the `checksum:` value from the same `.binaryTarget(…)` call.
6. Prints the candidate tag, URL, and SHA-256 for operator confirmation before
   writing to `version_onnx.json`.

The script does **not** download the XCFramework itself (it is never downloaded
by the hook; SPM handles it at build time). The SHA-256 is taken directly from
Microsoft's authoritative `Package.swift`.

### vtable-slot check

`tool/check_ort_slots.dart` partially automates this step. The operator still
performs the final verification:

1. Run:
   ```
   dart run tool/check_ort_slots.dart --version {ver}
   ```
   The tool downloads `onnxruntime_c_api.h` from the macOS arm64 archive,
   parses the `OrtApi` struct field order, and prints a diff table comparing
   the header's zero-based field indices against the `// SLOT:Name=N` annotations
   currently in `lib/src/ort_api.dart`.

2. Review the diff. **Slot numbers are zero-based indices in the `OrtApi` struct
   counting every field in declaration order — including fields we do not bind.**
   For example, `Run` at slot 9 means it is the 10th field in the struct. The
   23 bound symbols are a subset of the ~100+ total struct fields.

3. If any slot changed, update the `// SLOT:Name=N` annotation, the typedef
   pair, and any affected `lib/src/session.dart` call sites.

4. Update `ortApiVersion` in `lib/src/ort_api.dart` (22 → 26 for this upgrade).

5. Update the golden table name and values in `test/ort_slot_guard_test.dart`
   (`_expectedSlotsV22` → `_expectedSlotsV26`, with corrected slot numbers).

6. Run `make macos_test` (or `make linux_test`) and include the result in the
   PR description — this is the only authoritative guard; the slot guard test
   catches comment drift, not real binary mismatch.

### `make update_ort_version` Makefile target

Add a convenience target that wraps the script invocation:

```makefile
update_ort_version:
	dart run tool/update_ort_version.dart --version $(VERSION)
.PHONY: update_ort_version
```

Usage: `make update_ort_version VERSION=1.26.0`

### Self-test: upgrading to ORT v1.26.0

After the scripts and guide are implemented, run the full upgrade to 1.26.0 as
the first real exercise:

1. `make update_ort_version VERSION=1.26.0` — writes `VERSION_ONNX` and
   `version_onnx.json` for all platforms; confirms Windows patch version and iOS
   SPM tag
2. `dart run tool/check_ort_slots.dart --version 1.26.0` — diff slots against
   new header
3. Update `lib/src/ort_api.dart` `ortApiVersion` (22 → 26)
4. Update `// SLOT:Name=N` annotations and typedef pairs if any slot shifted
5. Update `test/ort_slot_guard_test.dart` golden table (`_expectedSlotsV22` →
   `_expectedSlotsV26`)
6. `dart run tool/generate_versions.dart` — regenerates `versions.g.dart` from
   the newly written `v1.26.0` in `VERSION_ONNX`
7. Update `packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift`
   `exact:` pin to the SPM version chosen in step 1
8. `make check_ios_version` — asserts `Package.swift` pin matches
   `version_onnx.json ios.version`
9. `make pre_commit` — format, analyze, license, test
10. `make macos_test` — real ORT load + inference on the new binary (mandatory;
    include output in PR description)
11. `make ios_test` — simulator verification
12. `make android_test` — emulator verification
13. Push branch and confirm `cicd_linux` and `cicd_windows` CI jobs green —
    these are the authoritative Linux/Windows inference checks since there is
    no local `make` target that exercises those platforms with the new binary
14. Update `CHANGELOG.md` for both packages

### Spec reference

`docs/spec/README.md §9 Upgrading ONNX Runtime` is already stubbed in (added
as part of creating this plan). It points to `docs/upgrading_onnxrt.md` and
this plan file.

## Implementation plan

### Phase 1 — Instruction guide

- [ ] Create `docs/upgrading_onnxrt.md` with:
  - Prerequisites (tools required: Dart SDK, `curl`, `tar`/`unzip`)
  - Step-by-step numbered checklist (mirrors Self-test §above)
  - Explanation of the vtable-slot counting rule: offsets are zero-based field
    indices in the full `OrtApi` struct including every unbound field; not the
    index among bound symbols only
  - Recovery notes for common failure modes:
    - SHA mismatch on archive download
    - Windows probe: all `.0`–`.9` return 404
    - Android AAR missing one or more ABI entries
    - SPM: no tag ≥ baseline
    - `check_ios_version` mismatch after updating `Package.swift`

### Phase 2 — Automation scripts

**`tool/update_ort_version.dart`**

- [ ] Create with Apache 2.0 header
- [ ] CLI: `dart run tool/update_ort_version.dart --version <ver> [--dry-run] [--out version_onnx.json]`
- [ ] Write `VERSION_ONNX` with `v` prefix (e.g. `v1.26.0`) alongside JSON output
- [ ] Desktop platforms (macOS arm64, Linux aarch64, Linux x64):
  - [ ] Download to `$TMPDIR/ort_upgrade_{ver}_{platform}.{ext}` with progress
  - [ ] Compute SHA-256; write `version`, `url`, `sha256`
- [ ] Windows (arm64, x64):
  - [ ] Probe baseline then `.1`–`.9` via HEAD with redirect-following
  - [ ] Fail loudly if all probes return non-2xx
  - [ ] Download resolved URL; compute SHA-256; write `note` field if patch used
- [ ] Android:
  - [ ] Download AAR; compute archive SHA-256
  - [ ] Cross-check against Maven `.aar.sha256` sidecar
  - [ ] Extract and hash all four ABI `.so` files; fail if any ABI absent
  - [ ] Write `sha256_archive` and `sha256_per_abi`
- [ ] iOS:
  - [ ] Fetch SPM tag list; semver-compare to find earliest ≥ baseline
  - [ ] Fail loudly if no tag qualifies
  - [ ] Fetch `Package.swift`; parse checksum anchored on `pod-archive-onnxruntime-c-` URL substring
  - [ ] Print candidate tag + SHA-256; prompt for confirmation
  - [ ] Write iOS entry (`version`, `spm_url`, `sha256`, `distribution: "spm"`)
- [ ] Update top-level `baseline_ort_version` and `ort_api_version` in JSON
- [ ] Merge over existing `version_onnx.json` (preserve `note` and other extra fields)
- [ ] `--dry-run`: print diff without writing
- [ ] Print summary of changes vs. previous version

**`tool/check_ort_slots.dart`**

- [ ] Create with Apache 2.0 header
- [ ] CLI: `dart run tool/check_ort_slots.dart --version <ver>`
- [ ] Download macOS arm64 `.tgz` (reuses cache from `update_ort_version` if
  present under `$TMPDIR`), extract `*/include/onnxruntime_c_api.h`
- [ ] Parse `OrtApi` struct field list in declaration order
- [ ] For each of the 23 symbols in the `// SLOT:Name=N` annotations in
  `lib/src/ort_api.dart`, look up the zero-based field offset in the struct
- [ ] Print a comparison table: expected slot (from annotation) vs. header slot
- [ ] Exit non-zero if any discrepancy found

### Phase 3 — Makefile target

- [ ] Add `update_ort_version` target (`dart run tool/update_ort_version.dart --version $(VERSION)`)
- [ ] Add `check_ort_slots` target (`dart run tool/check_ort_slots.dart --version $(VERSION)`)

Note: `docs/spec/README.md §9` was added when the plan was created and does not
need to be created again.

### Phase 4 — Self-test: upgrade to ORT 1.26.0

- [ ] `make update_ort_version VERSION=1.26.0` — writes `VERSION_ONNX` + `version_onnx.json`
- [ ] Confirm printed Windows patch version and iOS SPM tag; approve prompts
- [ ] `dart run tool/check_ort_slots.dart --version 1.26.0` — review slot diff
- [ ] Update `lib/src/ort_api.dart`: `ortApiVersion` 22 → 26; correct any shifted SLOT annotations
- [ ] Update `test/ort_slot_guard_test.dart`: rename `_expectedSlotsV22` → `_expectedSlotsV26`; update any changed slot values
- [ ] `dart run tool/generate_versions.dart` — regenerate `versions.g.dart`
- [ ] Update `packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift` `exact:` pin
- [ ] `make check_ios_version` passes
- [ ] `make pre_commit` passes (format, analyze, license, test)
- [ ] `make macos_test` passes — include output in PR description (mandatory)
- [ ] `make ios_test` passes on simulator
- [ ] `make android_test` passes on emulator
- [ ] Push branch; confirm `cicd_linux` and `cicd_windows` CI jobs green
- [ ] Update `CHANGELOG.md` for both packages

### Phase 5 — Roadmap and plan hygiene

- [ ] Mark Goal #6 complete in `docs/roadmap/v0.md`
- [ ] Move this plan to `docs/plans/completed/`

## Reviews

### Review 1: 2026-06-15

The plan was already marked `Investigated` but carried no review. I have
performed the first review pass and moved it back to `Questions`: there are
several factual errors and one load-bearing design assumption that must be
resolved before this is implementable. The bones are good — this is a
well-scoped plan that closes a real gap — but the detail in a few spots is
wrong enough to send an implementer down a dead end.

#### Problem Statement Assessment

The problem is real and worth solving. Upgrading ORT today is a seven-file,
multi-platform ceremony with hand-run `curl | sha256sum` archaeology and a
silent-bypass failure mode. This maps cleanly to roadmap Goal #6 (0% complete,
under `0.1.0-dev.2`) and the roadmap item's deliverable list matches the plan.
No conflict. Scope is appropriate — a script plus a guide plus a self-test is
exactly the right shape, and folding the first real upgrade (1.22 → 1.26) in as
the self-test is a strong way to validate the process rather than shipping
untested automation.

#### Proposed Solution Assessment

Strengths:

- The five deliverables are concrete and the division between automatable
  (download, checksum, Windows probe, SPM tag lookup) and irreducibly manual
  (vtable-slot verification, integration matrix) is honest and correct.
- `--dry-run` and merge-over-existing-structure (preserving `note` and
  untouched keys) are the right ergonomics.
- The Maven `.aar.sha256` sidecar cross-check is a nice belt-and-braces touch
  that mirrors what the hook already does.

Weaknesses — these are concrete factual errors against the current tree:

1. **"22 bound symbols" is wrong — it is 23.** The plan says "22 bound symbols"
   (Open questions, vtable-slot check) and "each of the 22 symbols". The actual
   count in `lib/src/ort_api.dart` is **23** real `SLOT:Name=N` annotations,
   and `test/ort_slot_guard_test.dart`'s golden table (`_expectedSlotsV22`) has
   **23** entries. (A 24th `SLOT:Name=` substring appears in the file but it is
   the doc-comment template, not a binding.) The "22" almost certainly leaked
   from confusing the *API version* (22) with the *symbol count*. An implementer
   counting "22" offsets will stop one short. Fix every "22 symbols" reference
   to "23".

2. **The iOS SPM checksum-parsing instruction names a target that does not
   exist.** Step 4 of the iOS lookup says to "extract the `checksum:` value from
   the `.binaryTarget` entry for `onnxruntime-c`". The upstream `Package.swift`
   (verified at tag `1.24.2`) has **no** target named `onnxruntime-c`. The
   binary target is named `onnxruntime` and is appended conditionally inside an
   `if/else` (local pod archive vs. remote URL). The remote branch looks like:

   ```swift
   Target.binaryTarget(name: "onnxruntime",
       url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
       checksum: "f7100a99...600b54")
   ```

   There is a sibling `onnxruntime_extensions` binary target with its **own**
   checksum in the same file. A parser matching on the target name `onnxruntime`
   alone risks substring-matching `onnxruntime_extensions`, and a parser keyed
   on `onnxruntime-c` will match nothing. The reliable anchor is the URL
   substring `pod-archive-onnxruntime-c-` (the `-c-` distinguishes the C API
   archive from the extensions archive). The end result is right — the recorded
   `f7100a99...` matches `version_onnx.json` — but the parsing recipe as written
   will fail. This must be corrected in both the Investigation and Phase 2.

3. **The script never updates `VERSION_ONNX`, but the flow depends on it.**
   `tool/generate_versions.dart` reads `VERSION_ONNX` (the repo-root file), not
   `version_onnx.json`, to emit `lib/src/generated/versions.g.dart`. The plan's
   "Files changed" table correctly lists `VERSION_ONNX` as bumped, but neither
   the script spec (Phase 2 only writes `version_onnx.json`) nor the Phase 4
   step list contains an explicit "bump `VERSION_ONNX` to `v1.26.0`" step before
   `dart run tool/generate_versions.dart`. As written, Phase 4 would regenerate
   `versions.g.dart` from the stale `v1.22.0` value. Either have the script bump
   `VERSION_ONNX` too, or add an explicit manual step. Note also the v-prefix
   convention: `VERSION_ONNX` is `v1.26.0`; `version_onnx.json` per-platform
   `version` is bare `1.26.0`.

#### Architecture Fit

Good. The plan respects `version_onnx.json` as the single source of truth for
binary metadata (matches the real schema: top-level `baseline_ort_version` +
`ort_api_version`, per-platform `version`/`url`/`sha256`, Android
`sha256_archive`/`sha256_per_abi`, iOS `distribution`/`spm_url`). Spec §9 is
already stubbed in and points at `docs/upgrading_onnxrt.md`, so the
spec-update-as-part-of-work rule is satisfied. The `make check_ios_version`
gate (greps `exact:` from `Package.swift`, compares to `version_onnx.json`
`ios.version`) is correctly folded into both the guide and Phase 4. This is a
pure-Dart tooling change with no `lib/` layer or public-API impact, so the
library-architecture three-layer boundary is not engaged — no concern there.

One spec nuance to honour: `ort_api.dart`'s own header and the iOS
`Package.swift` comment both record that the **ORT C API is append-only** —
"requesting API version 22 from ORT 1.24.2 returns the same vtable struct as
1.22.x". That has a direct consequence for Phase 4 (see question Q1 below) that
the plan currently glosses over by treating "22 → 26" as automatic.

#### Risk & Edge Cases

- **Windows patch probe (HEAD `.1`–`.9`).** The strategy is sound and matches
  the historical 1.22.0 → 1.22.1 precedent baked into `version_onnx.json`. Two
  gaps: (a) the probe assumes a patch never exceeds `.9` — fine for ORT's
  cadence, but the script should *fail loudly* if baseline and `.1`–`.9` all
  404 rather than silently emitting a stale URL; (b) GitHub release-asset URLs
  return `302` redirects to a CDN, not a bare `200` — a HEAD that does not
  follow redirects may see `302`/`404` semantics that differ from what the plan
  assumes. Specify "treat 2xx-after-redirect as present; follow redirects on
  HEAD" so the implementer does not trip on this.
- **iOS SPM tag gap.** The "earliest tag ≥ baseline" rule is correct and is
  what produced the current `1.24.2` pin for a `1.22.0` baseline. But for the
  1.26.0 self-test this needs a live check: if the SPM repo still has no
  `1.25`/`1.26` tag, the earliest-≥ rule may again select something well ahead
  of the desktop version (or nothing at all). The plan should state what the
  script does when **no** tag ≥ baseline exists (fail and report, do not write a
  placeholder). Tag strings also need semver-aware comparison, not string
  comparison (`1.24.2` vs `1.9.0`).
- **Android two-level verification** is described correctly and matches the
  hook's expectations (archive digest, then per-ABI `.so` under
  `jni/{abi}/libonnxruntime.so` for the four ABIs). No concern, beyond noting
  the script should verify all four ABIs are actually present in the AAR and
  fail if one is missing rather than emitting a partial `sha256_per_abi` map.
- **vtable-slot check precision.** The manual procedure is described well
  enough to execute *except* for the "22 symbols" error (above) and one missing
  detail: the offsets must be counted in the `OrtApi` struct **in declaration
  order including every member you do *not* bind** — the slot number is the
  absolute zero-based field index in the struct, not the index among bound
  symbols only. The current annotations (e.g. `Run=9`, `ReleaseSessionOptions=100`)
  make this obvious to someone who already understands it, but the guide should
  state it explicitly so a first-time upgrader counts correctly.
- **Phase 4 completeness.** Covers `check_ios_version`, `ort_slot_guard_test`
  (via "update golden table to API v26"), `pre_commit`, and the full
  `macos/ios/android_test` matrix. Missing: the explicit `VERSION_ONNX` bump
  (above), and Linux/Windows verification. CI already runs real Linux/Windows
  inference (`cicd_linux`/`cicd_windows`), so the self-test arguably should note
  "push and confirm Linux/Windows CI green" as the evidence for those two
  platforms, since there is no local `make` step that exercises them with the
  new binary the way `macos_test` does.

#### Recommendations

Proceed after resolving the questions below. The structure, scoping, and
roadmap alignment are all sound — the blockers are factual corrections and one
genuine design decision (Q1), not a rethink. Specifically:

1. Correct every "22 symbols" reference to "23" (Investigation + Open
   questions + Phase 4).
2. Rewrite the iOS checksum-parsing step to anchor on the URL substring
   `pod-archive-onnxruntime-c-` and explicitly exclude the
   `onnxruntime_extensions` target; note the conditional `if/else` structure.
3. Add an explicit `VERSION_ONNX` bump step (script-driven or manual) ahead of
   `generate_versions.dart` in Phase 2/Phase 4.
4. Specify redirect-following + loud-failure behaviour for the Windows HEAD
   probe and the iOS "no tag ≥ baseline" case.
5. Resolve Q1 — it changes what Phase 4 actually does.

#### Open questions

- [x] **Q1 (load-bearing): Does this upgrade actually bump `ortApiVersion`
      22 → 26, given the ORT C API is append-only?**
      **Resolved**: Track baseline (bump to 26). `ortApiVersion` matches the ORT
      minor version on every upgrade. Phase 4 re-verifies all 23 slot offsets
      against the 1.26.0 header and updates the golden table to `_expectedSlotsV26`.
- [x] **Q2: Should `tool/update_ort_version.dart` also write `VERSION_ONNX`?**
      **Resolved**: Yes — the script writes `VERSION_ONNX` (with `v` prefix)
      alongside `version_onnx.json` so `generate_versions.dart` is never run
      against a stale value.
- [x] **Q3: Is a `tool/check_ort_slots.dart` header parser in scope?**
      **Resolved**: Yes — added to Phase 2 and Phase 3 Makefile target.

## Summary

_To be completed after implementation._
