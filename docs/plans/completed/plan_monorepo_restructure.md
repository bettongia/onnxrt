# Monorepo restructure — move `betto_onnxrt` under `packages/`

**Status**: Complete

**PR link**: https://github.com/bettongia/onnxrt/pull/2

## Problem statement

The P0 blocker identified in the [2026-06-16 release readiness review](../reviews/2026-06-16%20Release%20readiness%20review.md)
is that `betto_onnxrt_ios` is unpublishable. The root-level `.pubignore` contains a
bare `packages/` entry, which pub applies when publishing from
`packages/betto_onnxrt_ios/` — producing an empty archive that fails dry-run.

The deeper cause is structural: the main `betto_onnxrt` package currently owns the
git root, with `betto_onnxrt_ios` nested as a subdirectory. The `.pubignore` trick
was added to keep the iOS companion out of `betto_onnxrt`'s published archive, but
it collides with the nested package's own publish.

The fix is to adopt a proper monorepo layout: both published packages become peers
under `packages/`, the git root becomes a workspace root, and the root `.pubignore`
disappears entirely. Each package carries its own minimal `.pubignore`.

This is the least painful moment to make this structural change — no published
versions exist yet, and there are no downstream consumers.

## Open questions

- [x] **Q1 — Use `dart pub workspace`?**
  _Decision: No for now._ The mixed Dart+Flutter workspace would require `flutter
  pub get` at root and complicates the non-Flutter CI jobs. **Melos** is noted as
  the preferred future enhancement once the package count grows — it provides
  cross-package `melos run` scripts and automated lockstep versioning/CHANGELOG
  generation without requiring a Flutter-aware workspace. Defer to post-v0.

- [x] **Q2 — Where does `integration_test_app` live?**
  _Decision: moves into `packages/betto_onnxrt/`._ It is `betto_onnxrt`'s mobile
  testing infrastructure, not a repo-level concern. Co-locating it with the package
  makes the ownership clear. It is excluded from the published archive via
  `packages/betto_onnxrt/.pubignore`.

## Investigation

### Current layout

```
onnxrt/                               ← git root = betto_onnxrt package root
├── pubspec.yaml                      (name: betto_onnxrt, version: 0.1.0-dev.1)
├── hook/build.dart
├── lib/
├── test/
├── tool/
├── example/magika/                   (publish_to: none)
├── VERSION_ONNX
├── version_onnx.json
├── analysis_options.yaml
├── CHANGELOG.md  /  LICENSE  /  README.md  /  AUTHORS  /  CONTRIBUTING.md
├── .pubignore                        (contains `packages/` — the blocker)
├── Makefile  /  addlicense_config.txt  /  header_template.txt  /  site.mk
├── Containerfile
├── docs/
├── integration_test_app/
│   └── pubspec.yaml                  (path dep: `../` for betto_onnxrt)
└── packages/
    └── betto_onnxrt_ios/
        └── pubspec.yaml              (version: 0.1.0 — also out of sync)
```

### Target layout

```
onnxrt/                               ← git root = monorepo root (no pubspec.yaml)
├── packages/
│   ├── betto_onnxrt/                 ← moved from root
│   │   ├── pubspec.yaml
│   │   ├── hook/build.dart
│   │   ├── lib/
│   │   ├── test/
│   │   ├── tool/
│   │   ├── example/magika/           ← moved from root example/
│   │   ├── integration_test_app/     ← moved from root (betto_onnxrt's test infra)
│   │   ├── VERSION_ONNX
│   │   ├── version_onnx.json
│   │   ├── analysis_options.yaml
│   │   ├── CHANGELOG.md  /  LICENSE  /  README.md  /  AUTHORS  /  CONTRIBUTING.md
│   │   ├── addlicense_config.txt     ← moved
│   │   ├── header_template.txt       ← moved
│   │   └── .pubignore                ← new; excludes integration_test_app/, etc.
│   └── betto_onnxrt_ios/             ← stays, gains CHANGELOG + version fix
│       ├── pubspec.yaml              (version: 0.1.0-dev.1)
│       ├── CHANGELOG.md              ← new
│       └── .pubignore                ← new
├── Makefile                          ← include-only: composes .mk files + cross-package targets
├── CLAUDE.md                         ← updated paths
├── Containerfile
├── site.mk
└── docs/
```

The root `Makefile` becomes a thin compositor:

```makefile
include site.mk
include packages/betto_onnxrt/betto_onnxrt.mk
include packages/betto_onnxrt_ios/betto_onnxrt_ios.mk

# Cross-package targets that span both packages
clean: clean_dart clean_ios
pre_commit: format_check analyze license_check test check_ios_version
```

### Files that move into `packages/betto_onnxrt/`

All package-owned content:
`lib/`, `test/`, `hook/`, `tool/`, `example/`, `integration_test_app/`,
`pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `VERSION_ONNX`,
`version_onnx.json`, `CHANGELOG.md`, `LICENSE`, `README.md`, `AUTHORS`,
`CONTRIBUTING.md`, `addlicense_config.txt`, `header_template.txt`.

The root `.pubignore` is **deleted**. A new `.pubignore` is created inside
`packages/betto_onnxrt/` — no longer needs to exclude `packages/`, but does
exclude the test app and build artefacts:

```
.claude
.dart_tool
build/
coverage/
doc/
downloads/
logs/
site/
integration_test_app/
```

### `hook/build.dart` — no path changes needed

The hook uses `packageRoot` from the build context (the directory containing the
package's `pubspec.yaml`). It resolves `version_onnx.json` and
`.dart_tool/betto_onnxrt/{version}/` against `packageRoot`. Once `version_onnx.json`
and `VERSION_ONNX` move into `packages/betto_onnxrt/` they remain co-located with
the hook — the hook itself needs no edits.

### `integration_test_app/pubspec.yaml` — path changes

`integration_test_app` moves into `packages/betto_onnxrt/integration_test_app/`.
Both path deps simplify:

```yaml
# before (from git root)
betto_onnxrt:
  path: ../
betto_onnxrt_ios:
  path: ../packages/betto_onnxrt_ios

# after (from packages/betto_onnxrt/integration_test_app/)
betto_onnxrt:
  path: ../
betto_onnxrt_ios:
  path: ../../betto_onnxrt_ios
```

### Makefile — run Dart commands from the package subdirectory

All targets that invoke `dart pub get`, `dart test`, `dart analyze`, `dart doc`,
`dart run`, `make coverage`, and `make license_check/license_add` currently run
from the git root. After the move they need to `cd packages/betto_onnxrt &&`.

Targets that `cd integration_test_app` are **not** unaffected — they need
updating too. After `integration_test_app/` moves to
`packages/betto_onnxrt/integration_test_app/`, the following targets break:
`macos_test` (:67), `ios_test` (:105), `android_test` (:118),
`prepare_flutter` (:226), and `clean` (:242). Each `cd integration_test_app`
must become `cd packages/betto_onnxrt/integration_test_app`.

Targets that `cd packages/betto_onnxrt_ios` are genuinely unaffected (that
package stays in place).

`cicd_linux`, `linux_test`, and `windows_test` all use cwd-relative
`VERSION_ONNX`, `version_onnx.json`, and `.dart_tool/` paths. All three need
`cd packages/betto_onnxrt &&` (or equivalent) before they read those files.

### Makefile split into per-package `.mk` files

Following the existing `site.mk` pattern, the Makefile is split into three
included files:

| File | Owns |
|---|---|
| `packages/betto_onnxrt/betto_onnxrt.mk` | All `dart` targets: `prepare_dart`, `format`, `analyze`, `test`, `coverage`, `doc`, `license_check`, `license_add`, `cicd_linux`, `cicd_macos`, `cicd_windows`, `linux_test`, `windows_test`, `macos_test`, `ios_test`, `android_test` |
| `packages/betto_onnxrt_ios/betto_onnxrt_ios.mk` | iOS plugin targets: `prepare_ios`, `clean_ios`, `license_check_ios`, `license_add_ios` |
| `Makefile` (root) | Includes all three `.mk` files; owns cross-package targets: `clean`, `pre_commit`, emulator targets, `container_test` |

Each `.mk` file opens with a path variable so recipes avoid hardcoding:

```makefile
# packages/betto_onnxrt/betto_onnxrt.mk
BETTO_PKG := packages/betto_onnxrt
BETTO_ITA := packages/betto_onnxrt/integration_test_app

test:
    cd $(BETTO_PKG) && dart test
macos_test:
    cd $(BETTO_ITA) && flutter pub get && flutter test …
```

```makefile
# packages/betto_onnxrt_ios/betto_onnxrt_ios.mk
BETTO_IOS := packages/betto_onnxrt_ios

prepare_ios:
    cd $(BETTO_IOS) && flutter pub get
clean_ios:
    cd $(BETTO_IOS) && flutter clean
```

`addlicense_config.txt` moves with `betto_onnxrt` (into `packages/betto_onnxrt/`);
`betto_onnxrt_ios/` needs its own equivalent config or inline addlicense args in
`betto_onnxrt_ios.mk`.

`site.mk` reads `pubspec.yaml` via `awk` (lines 6–9) — it currently resolves
relative to the root, which is where `pubspec.yaml` lives now. After the move,
`pubspec.yaml` is at `packages/betto_onnxrt/pubspec.yaml`, so `site.mk` must
update its `awk` paths accordingly.

### `.github/workflows/cicd.yml` — keep a single file

`betto_onnxrt_ios` has no Dart code and no ORT inference to exercise in CI —
a separate workflow would be empty. The lockstep relationship means CI health
is entirely measured by the main package; the iOS shim is validated manually
via `make ios_test`. One `cicd.yml` covering Linux, macOS, and Windows remains
the right structure.

Changes needed beyond the `hashFiles` and Windows `working-directory` fixes
already listed:

- ORT binary cache path: `path: .dart_tool/betto_onnxrt` →
  `path: packages/betto_onnxrt/.dart_tool/betto_onnxrt`

### `check_ios_version` — dual-root path fix

`check_ios_version` (Makefile:168–169) runs from the repo root and reads two
paths:

- `open('version_onnx.json')` — cwd-relative; this file moves to
  `packages/betto_onnxrt/version_onnx.json`.
- `packages/betto_onnxrt_ios/ios/.../Package.swift` — root-relative; this
  path stays exactly the same (the iOS package doesn't move).

The fix: keep the target running from the repo root (so `pre_commit`, which
depends on it, continues to work from root) and update only the Python snippet
to `open('packages/betto_onnxrt/version_onnx.json')`. The `Package.swift`
grep path needs no change.

### GitHub Actions — changes per job

All three jobs cache on `hashFiles('VERSION_ONNX')` (cicd.yml:35, 61, 86) —
all three must be updated to `hashFiles('packages/betto_onnxrt/VERSION_ONNX')`.

The Linux and macOS jobs delegate to `make cicd_linux` / `make cicd_macos`
respectively, so updating those Makefile targets is sufficient for those jobs.

The **Windows job** is different: it runs `dart pub get`, `dart test`, and
reads `version_onnx.json` directly in a PowerShell `run:` block (cicd.yml:96–99)
without calling a make target. It therefore needs an explicit
`working-directory: packages/betto_onnxrt` added to those steps, and the
`Get-Content version_onnx.json` call must be path-qualified to
`packages/betto_onnxrt/version_onnx.json` (or the working-directory change
makes it resolve correctly automatically).

### `addlicense_config.txt` — adjust ignores

The config moves into `packages/betto_onnxrt/` and runs from that directory,
so the `--ignore="integration_test_app/…"` entries need updating to match the
new location (the test app is now a sibling directory, so
`--ignore="integration_test_app/ios/**"` etc. remain valid relative paths).
`betto_onnxrt_ios/` needs its own license-check step in the Makefile.

### `docs/spec/README.md` and `CLAUDE.md`

Both reference file paths like `hook/build.dart`, `lib/src/runtime.dart`, etc.
These paths are relative to the repo root in prose; update them to
`packages/betto_onnxrt/hook/build.dart`, etc., or make clear they are relative to
the package root (the latter is less surprising for a newcomer reading the spec).

### `betto_onnxrt_ios` companion fixes (from P0 items 2 and 3)

The restructure is the right moment to also fix the other two P0 blockers:

- Bump `packages/betto_onnxrt_ios/pubspec.yaml` version to `0.1.0-dev.1`.
- Add `packages/betto_onnxrt_ios/CHANGELOG.md` with a minimal initial entry.
- Rewrite the library doc install block in
  `packages/betto_onnxrt_ios/lib/betto_onnxrt_ios.dart:27–33` to the pub.dev
  dependency form (`betto_onnxrt_ios: ^0.1.0-dev.1`).

### `.worktrees/` and `.dart_tool/` caches

Both are gitignored. The `.dart_tool/` cache is version-scoped so it will
regenerate automatically after `dart pub get` in the new location. No manual
cleanup is needed beyond running `make clean` before starting.

## Implementation plan

### Phase 1 — Create new package directory and move files

- [x] Run `make clean` from the repo root to clear all generated artefacts.
- [x] Create `packages/betto_onnxrt/` directory.
- [x] Move package-owned files into `packages/betto_onnxrt/`:
  - [x] `lib/`
  - [x] `test/`
  - [x] `hook/`
  - [x] `tool/`
  - [x] `example/` (entire directory, including `magika/`)
  - [x] `integration_test_app/`
  - [x] `pubspec.yaml`
  - [x] `pubspec.lock` (was not tracked — gitignored; skipped)
  - [x] `analysis_options.yaml`
  - [x] `VERSION_ONNX`
  - [x] `version_onnx.json`
  - [x] `CHANGELOG.md`
  - [x] `LICENSE`
  - [x] `README.md`
  - [x] `AUTHORS`
  - [x] `CONTRIBUTING.md`
  - [x] `addlicense_config.txt`
  - [x] `header_template.txt`
- [x] Delete the root `.pubignore`.
- [x] Create `packages/betto_onnxrt/.pubignore` (exclude build artefacts, docs,
  CI files, and non-package top-level items that are no longer in scope anyway).
- [x] Verify `git status` shows all moves as renames (not delete + add).

### Phase 2 — Fix path references

- [x] `packages/betto_onnxrt/integration_test_app/pubspec.yaml`: update both
  path deps — `betto_onnxrt: path: ../` (unchanged relative to old root, now
  one level up within the package) and `betto_onnxrt_ios: path: ../../betto_onnxrt_ios`.
- [x] `example/magika/pubspec.yaml` (now at `packages/betto_onnxrt/example/magika/`):
  update `betto_onnxrt` path dep from `../../` to `../` (one level up within the
  package).
- [x] Create `packages/betto_onnxrt/betto_onnxrt.mk` containing all dart/test/doc
  targets, each prefixed with `BETTO_PKG := packages/betto_onnxrt` and
  `BETTO_ITA := packages/betto_onnxrt/integration_test_app`. Migrate from root
  `Makefile`:
  - [x] `prepare_dart` — `cd $(BETTO_PKG) && dart pub get …`
  - [x] `prepare_flutter` — `cd $(BETTO_ITA) && flutter pub get`
  - [x] `format` / `format_check`
  - [x] `analyze`
  - [x] `test`
  - [x] `coverage`
  - [x] `doc` / `doc_site`
  - [x] `license_check` / `license_add` — run from `$(BETTO_PKG)`
  - [x] `cicd_linux` — update cwd-relative `VERSION_ONNX`, `version_onnx.json`, `.dart_tool/` to use `$(BETTO_PKG)`
  - [x] `cicd_macos` / `cicd_windows`
  - [x] `linux_test` — `cd $(BETTO_PKG)` before `cat VERSION_ONNX` and `.dart_tool/` references
  - [x] `windows_test` — `cd $(BETTO_PKG) && dart test …`
  - [x] `macos_test` — `cd $(BETTO_ITA) && …`
  - [x] `ios_test` — `cd $(BETTO_ITA) && …`
  - [x] `android_test` — `cd $(BETTO_ITA) && …`
  - [x] `check_ios_version` — update Python `open('version_onnx.json')` to
    `open('$(BETTO_PKG)/version_onnx.json')` (keep target at root level via root
    `Makefile`; `Package.swift` grep path unchanged)
- [x] Create `packages/betto_onnxrt_ios/betto_onnxrt_ios.mk` containing:
  - [x] `BETTO_IOS := packages/betto_onnxrt_ios`
  - [x] `prepare_ios` — `cd $(BETTO_IOS) && flutter pub get`
  - [x] `clean_ios` — `cd $(BETTO_IOS) && flutter clean`
  - [x] `license_check_ios` / `license_add_ios` — `addlicense` run from `$(BETTO_IOS)` with inline args or a per-package config
- [x] Rewrite root `Makefile` to:
  - [x] `include site.mk`
  - [x] `include packages/betto_onnxrt/betto_onnxrt.mk`
  - [x] `include packages/betto_onnxrt_ios/betto_onnxrt_ios.mk`
  - [x] Cross-package targets: `clean` (delegates to `clean_dart` + `clean_ios`), `prepare_flutter` (delegates to both), `pre_commit`, `check_ios_version`, emulator targets, `container_test`
- [x] `site.mk`: update `awk` `pubspec.yaml` references (lines 6–9) to
  `packages/betto_onnxrt/pubspec.yaml`
- [x] `.github/workflows/cicd.yml`:
  - [x] All three `hashFiles('VERSION_ONNX')` occurrences (lines 35, 61, 86) →
    `hashFiles('packages/betto_onnxrt/VERSION_ONNX')`
  - [x] All three ORT binary cache paths `path: .dart_tool/betto_onnxrt` →
    `path: packages/betto_onnxrt/.dart_tool/betto_onnxrt`
  - [x] Linux and macOS jobs: no further changes (they delegate to `make cicd_*`)
  - [x] Windows job: add `working-directory: packages/betto_onnxrt` to the
    `dart pub get` and `dart test` steps; update inline `Get-Content
    version_onnx.json` to use the new path
- [x] `addlicense_config.txt` (now in `packages/betto_onnxrt/`): remove the
  `--ignore="integration_test_app/…"` entries (no longer needed — they are kept
  as the integration_test_app is still a sibling and the entries remain valid).
  Added separate `make license_check_ios` Makefile target in `betto_onnxrt_ios.mk`.
- [x] `CLAUDE.md`: update all file-path prose references to use
  `packages/betto_onnxrt/` prefix where appropriate.
- [x] `docs/spec/README.md`: update path references accordingly.

### Phase 3 — `betto_onnxrt_ios` companion fixes

- [x] `packages/betto_onnxrt_ios/pubspec.yaml`: bump `version` to `0.1.0-dev.1`;
  add `homepage`, `issue_tracker`, `topics` fields to match the main package.
- [x] Create `packages/betto_onnxrt_ios/CHANGELOG.md` with an initial entry for
  `0.1.0-dev.1`.
- [x] `packages/betto_onnxrt_ios/lib/betto_onnxrt_ios.dart`: replace the `## Usage`
  git-dependency block (~lines 23–36) with the pub.dev form
  (`betto_onnxrt_ios: ^0.1.0-dev.1`). This is a full block replacement, not a
  line-tweak — the existing block uses a `git: url: git@github.com:…` SSH form.
- [x] Create `packages/betto_onnxrt_ios/.pubignore` (exclude `.build/`, SPM
  derived data, and any non-publishable artefacts).

### Phase 4 — Verification

- [x] `cd packages/betto_onnxrt && dart pub get` — confirm hook runs and ORT
  binary is downloaded.
- [x] `cd packages/betto_onnxrt && dart analyze` — clean (zero issues).
- [x] `cd packages/betto_onnxrt && dart test` — all 83 tests pass (11 skipped;
  ORT binary not staged, expected in plain dart test mode).
- [x] `make license_check` from repo root — passes for main package.
- [x] `make license_check_ios` — passes for iOS package.
- [x] `cd packages/betto_onnxrt && dart pub publish --dry-run` — archive is
  non-empty and contains expected files (including `example/`; excluding
  `integration_test_app/` and `betto_onnxrt.mk`).
- [x] `cd packages/betto_onnxrt_ios && dart pub publish --dry-run` — archive is
  non-empty and contains pubspec + LICENSE + README + lib.
- [ ] `make macos_test` (or equivalent) — integration test passes. (Deferred
  to PR description; requires local Flutter+macOS build environment.)
- [ ] `make container_test` — Linux CI path is clean. (Deferred to CI; requires
  Podman/Docker runtime.)

### Phase 5 — Documentation and roadmap

- [x] Update `docs/roadmap/v0.md`: mark this plan item complete; update the
  "pub.dev delivery" checklist to confirm the `dart pub publish --dry-run` check
  now passes for both packages.
- [x] Update `docs/reviews/2026-06-16 Release readiness review.md`: mark P0 items
  1–3 resolved.
- [x] Move this plan to `docs/plans/complete/`.

## Reviews

### Review 1: 2026-06-16

**Problem Statement Assessment**

The problem is real, well-scoped, and worth solving. I verified the root
`.pubignore` does contain a bare `packages/` entry, and the
[2026-06-16 release readiness review](../reviews/2026-06-16%20Release%20readiness%20review.md)
confirms `betto_onnxrt_ios` produces an empty archive on `dart pub publish
--dry-run`. The structural diagnosis is correct: the `.pubignore` workaround for
keeping the iOS companion out of `betto_onnxrt`'s archive collides with the
nested package's own publish. Roadmap Goal 8 ("publish both packages in
lockstep") is blocked by this, so the work is roadmap-traceable and the plan is
already linked from `docs/roadmap/v0.md`. Doing it now (no published versions, no
consumers) is the right call. No spec contradiction — `docs/spec/README.md`
describes behaviour and API, not repo layout; only its prose path references
need updating, which the plan already covers.

Bundling P0 items 2 and 3 (iOS version bump, CHANGELOG, install-doc rewrite)
into this restructure is sensible — they touch the same files and serve the same
publish-readiness goal.

**Proposed Solution Assessment**

The monorepo layout is the correct fix and the target structure is sound. The
deferral of `dart pub workspace`/Melos (Q1) is well-reasoned given the
mixed Dart+Flutter CI jobs. Most of the investigation is accurate — I confirmed
the iOS pubspec is `version: 0.1.0` with no CHANGELOG, the magika path dep is
`../../`, and the hook's reliance on `packageRoot` means it genuinely needs no
edits.

However, the plan contains **factual errors about the Makefile and CI that will
cause the implementation to break the build** if followed as written. These are
the main blockers to a clean `Investigated` status (details below).

**Architecture Fit**

This is a pure relocation of the package tree — `lib/` internal structure, the
public barrel, layer boundaries, domain models, and storage are all untouched.
The `library-architecture` skill therefore raises no layer-integrity concerns:
nothing moves between Core/Presentation/App, and `betto_onnxrt` remains a
pure-Dart package with no Flutter import introduced. No further architecture
audit is warranted for a move that preserves every file's relative position
within the package.

**Risk & Edge Cases**

1. **(Blocker) The claim that `cd integration_test_app` targets are "unaffected"
   is wrong.** `integration_test_app/` moves to
   `packages/betto_onnxrt/integration_test_app/`, but `macos_test` (Makefile:67),
   `ios_test` (:105), `android_test` (:118), `prepare_flutter` (:226), and
   `clean` (:242) all do `cd integration_test_app` relative to the git root.
   After the move these paths break. Each must either run from the package
   directory or use the new nested path. The plan's investigation section
   explicitly says these are unaffected — that statement must be corrected and
   the targets added to the Phase 2 checklist.

2. **(Blocker) `check_ios_version` cannot simply `cd` into the package.** It
   reads `version_onnx.json` via `open('version_onnx.json')` (cwd-relative, so
   the file moves with the package) **and** greps
   `packages/betto_onnxrt_ios/ios/.../Package.swift` (root-relative). After the
   move these two references resolve against different roots: if you `cd
   packages/betto_onnxrt` for the Python part, the `packages/betto_onnxrt_ios/…`
   path no longer resolves. The plan says check_ios_version needs "no path
   change" — that is incorrect. The target needs the iOS `Package.swift` path
   rewritten to `../betto_onnxrt_ios/…` (or absolute), and the `pre_commit`
   target that depends on it must keep working from the repo root. This couples
   to the existing fragility noted in agent memory around `check_ios_version`.

3. **(Blocker) Windows CI does not delegate to a `make` target.** The plan's
   "prefer delegating to make over explicit cd" approach assumes CI calls
   `make cicd_*`. That holds for Linux (`cicd.yml:40 make cicd_linux`) and macOS
   (`:69 make cicd_macos`), but the **Windows job runs `dart pub get` and `dart
   test` directly in a PowerShell `run:` block** (`cicd.yml:96–99`) and reads
   `version_onnx.json` inline (`:97`). Those commands need an explicit
   `working-directory: packages/betto_onnxrt` (or path-qualified `Get-Content`).
   The plan mentions the Windows `Get-Content` change but frames the broader
   delegation as covering it — it does not.

4. **`hashFiles('VERSION_ONNX')` appears three times** (cicd.yml:35, 61, 86),
   one per OS job. The Phase 2 checklist lists this change once; all three cache-
   key lines must be updated or the cache silently never hits after the move.

5. **`cicd_linux` and `linux_test`/`windows_test` use cwd-relative
   `version_onnx.json`, `VERSION_ONNX`, and `.dart_tool/` paths.** `cicd_linux`
   is listed for update, good — but `linux_test` (Makefile:80, reads
   `VERSION_ONNX`) and `windows_test` are not in the Phase 2 list and will need
   the same `cd` treatment.

6. **`example/example.dart` is not just `example/magika/`.** The top-level
   `example/` directory contains both `example.dart` and `magika/`. Moving
   `example/` wholesale (as the plan says) is fine, but only the magika path dep
   is called out for fixing. Confirm `example.dart` carries no root-relative
   assumptions (it appears to be a standalone snippet, so likely fine — just
   verify in Phase 4).

7. **iOS install-doc line numbers and form are wrong.** The plan says rewrite
   `betto_onnxrt_ios.dart:27–33` to `betto_onnxrt_ios: ^0.1.0-dev.1`. The actual
   install block is the `## Usage` YAML at roughly lines 23–36, and it currently
   uses a **git dependency** (`git: url: git@github.com:…`), which P0 item 3 in
   the release review specifically flags as a going-public smell. The rewrite is
   the right intent, but the line range is off and the change is larger than a
   3-line tweak — it replaces the whole git-dep block with the pub.dev form.

8. **`.pubignore` minor:** The proposed `packages/betto_onnxrt/.pubignore`
   excludes `integration_test_app/` (good) but should also confirm it does not
   exclude `example/` — pub.dev surfaces examples and the magika example is a
   selling point. The current root `.pubignore` does not exclude `example/`, so
   preserve that.

9. **`addlicense` for the iOS package.** The plan adds a `license_check_ios`
   target but the iOS package's Dart/Swift files need a config equivalent. Spell
   out where its addlicense config lives (a second config file in
   `packages/betto_onnxrt_ios/`, or inline args).

**Recommendations**

The strategy is correct and I recommend proceeding with the restructure — but
**not at `Investigated` status yet.** The investigation undersells the CI/
Makefile surface area and contains three statements that are factually wrong
(items 1, 2, 3) and would break the build if implemented verbatim. These are
cheap to fix in the plan:

- Correct the "targets that `cd integration_test_app` … are unaffected"
  statement and add `macos_test`, `ios_test`, `android_test`, `clean`,
  `linux_test`, `windows_test` to the Phase 2 Makefile checklist.
- Rework the `check_ios_version` line to acknowledge the dual-root path problem
  and specify the fix (rewrite the `Package.swift` path to package-relative).
- Add an explicit Windows-CI `working-directory` step to Phase 2; do not rely on
  make-delegation for the Windows job.
- Note all three `hashFiles('VERSION_ONNX')` occurrences.
- Correct the iOS doc line range and clarify it replaces the git-dep block.

Once these are folded in, the plan is ready for `Investigated`. The verification
phase (Phase 4) is thorough and the dual `dart pub publish --dry-run` checks are
exactly the right acceptance gate.

**Open questions**

- [x] **R1.1** — `check_ios_version` stays at the repo root. Only the Python
      `open('version_onnx.json')` call is updated to
      `open('packages/betto_onnxrt/version_onnx.json')`; the `Package.swift` grep
      path (`packages/betto_onnxrt_ios/…`) is unchanged. `pre_commit` continues to
      work from root with no changes.
- [x] **R1.2** — Keep the inline PowerShell and add
      `working-directory: packages/betto_onnxrt` to the Windows job's `dart pub get`
      and `dart test` steps. Refactoring the Windows job into a make target is
      deferred as out of scope for this plan.
- [x] **R1.3** — `example/` is not excluded by the current root `.pubignore` and
      will not be excluded by the new `packages/betto_onnxrt/.pubignore`. Both
      `example/example.dart` and `example/magika/` remain in the published archive.
      Phase 4 verification confirms this via `dart pub publish --dry-run` output.

## Summary

- Restructured the repository into a proper monorepo: `betto_onnxrt` moved
  from the git root into `packages/betto_onnxrt/` using `git mv` (all moves
  tracked as renames, no history lost).
- Deleted the root `.pubignore` (the P0 blocker). Each package now carries its
  own minimal `.pubignore`; `integration_test_app/` and `betto_onnxrt.mk` are
  excluded from the main package archive.
- Split the root `Makefile` into three composed files: `packages/betto_onnxrt/betto_onnxrt.mk`,
  `packages/betto_onnxrt_ios/betto_onnxrt_ios.mk`, and a thin root `Makefile`
  that includes all three and owns cross-package targets. The `BETTO_PKG` and
  `BETTO_ITA` path variables remove all hardcoded paths from recipes.
- Updated `site.mk` to read `pubspec.yaml` from
  `packages/betto_onnxrt/pubspec.yaml`.
- Updated `.github/workflows/cicd.yml`: all three `hashFiles('VERSION_ONNX')`
  cache keys → `hashFiles('packages/betto_onnxrt/VERSION_ONNX')`; all three
  ORT binary cache paths → `packages/betto_onnxrt/.dart_tool/betto_onnxrt`;
  Windows job split into two steps with `working-directory: packages/betto_onnxrt`
  (per R1.2, inline PowerShell kept).
- Updated `check_ios_version` to read `packages/betto_onnxrt/version_onnx.json`
  (R1.1); `Package.swift` grep path unchanged; target stays at repo root so
  `make pre_commit` works from root.
- Fixed path deps in `integration_test_app/pubspec.yaml` (`betto_onnxrt_ios`
  path: `../../betto_onnxrt_ios`) and `example/magika/pubspec.yaml`
  (`betto_onnxrt` path: `../`).
- `betto_onnxrt_ios` P0 companion fixes: version bumped to `0.1.0-dev.1`,
  `CHANGELOG.md` created, `lib/betto_onnxrt_ios.dart` usage block rewritten
  from git-dependency form to `betto_onnxrt_ios: ^0.1.0-dev.1`, `.pubignore`
  added.
- Updated `CLAUDE.md` and `docs/spec/README.md` throughout to use
  `packages/betto_onnxrt/` path prefix for all previously root-relative paths.
- `make pre_commit` passes: format check clean, zero analyzer issues, all 83
  tests pass, license check passes, `check_ios_version` OK.
- `dart pub publish --dry-run` passes for both packages with non-empty archives.
- Deviation from plan: `make macos_test` and `make container_test` were not run
  locally (both require platform-specific runtimes — macOS Flutter build
  environment and Podman respectively). These are covered by CI on the PR.
