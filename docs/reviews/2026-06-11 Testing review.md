# betto_onnxrt — Testing & Release Readiness Review

**Date:** 2026-06-11

**Reviewer:** Release Ninja (QA / release engineering)

**Scope:** Unit/integration test suite, CI/CD pipeline, cross-platform coverage,
and FFI core risk for the `betto_onnxrt` pure-Dart library.

**Evidence:** `make test`, `make container_test` (with coverage),
`make macos_test`, `make ios_test`, `make android_test` — raw logs captured
under `reviews/2026-06-11 Testing review logs/`.

---

## Release Readiness Verdict

**NOT READY FOR RELEASE.**

The package's entire reason for existing — loading ONNX Runtime over FFI and
running inference — is **0% covered by the gate that decides whether a change
ships**. The merge gate (`dart test` / `make cicd`) and "does ORT actually work"
are two disjoint worlds. On top of that, iOS is broken on-device today, and the
package's headline "SHA-256-verified prebuilt binary" guarantee is silently
disabled on four of six platforms. None of these are style nits. Each one can
put a crashing or silently-wrong build in front of a user with a green CI badge.

There are genuine strengths here — the `ModelDownloader` and `tensor`/
`model_spec` layers are well tested, and macOS and Android integration tests
genuinely exercise real inference and pass. But strengths in the periphery do
not offset a 0%-covered, crash-prone core.

---

## Critical Findings

### 🔴 BLOCKER 1 — The FFI core is 0% covered by the CI gate

**Files:** `lib/src/session.dart` (0 of 171 lines hit), `lib/src/runtime.dart`
(0 of 29), `lib/src/ort_api.dart` (0 of 2).

**Overall coverage: 34.3% (106 of 309 lines).**

**Platforms:** all six.

**Evidence:** `container_test.log` coverage summary; `test.log` shows every
`onnx_session_test.dart` case emitting `Skip: ORT binary not staged`.

Under plain `dart test` (JIT), the native-assets binary is not staged, so
`onnx_session_test.dart` auto-skips all six of its real cases. The result:
`runtime.dart`, `session.dart`, and `ort_api.dart` — the complete FFI core, ~200
of 309 lines — register zero coverage in CI. Real inference is verified only by
`make macos_test` / `android_test` / `ios_test`, which are developer-run and
**present in no CI job**. The CI `build`, `test-macos`, and `test-windows` jobs
all run only `make cicd*` → `prepare test`.

**User impact:** A change that fixes one platform and silently breaks the FFI
path on another passes the gate cleanly and reaches users. The library cannot
crash in the half that is tested; it can only crash in the half that is not.

**Fix:** Stage the ORT binary in CI (run the hook via `dart build` / a native
AOT step before tests) and treat a **skipped** `onnx_session_test` as a CI
failure, not a pass. At minimum, wire `make macos_test` into the existing
`test-macos` runner so at least one platform's real load+inference runs in CI.

### 🔴 BLOCKER 2 — iOS is broken on-device right now

**File:** `packages/betto_onnxrt_ios` (SPM shim) is not wired into
`integration_test_app`.

**Platform:** iOS.

**Evidence:** `ios_test.log`:
`Invalid argument(s): Failed to lookup symbol 'OrtGetApiBase': dlsym(RTLD_DEFAULT, OrtGetApiBase): symbol not found`
in `setUpAll`, followed by a cascading `LateInitializationError` in
`tearDownAll`. Tests fail immediately.

The SPM plugin shim whose job is to statically link ORT into the Runner is
absent from `integration_test_app`'s pubspec, `.flutter-plugins-dependencies`,
and `GeneratedPluginRegistrant.m`. Nothing links ORT, so `OnnxRuntime.load()`'s
`DynamicLibrary.process()` lookup of `OrtGetApiBase` fails. Compare with macOS
and Android, where the identical test suite passes all 12 cases.

A second, unresolved risk sits behind this even once the shim is wired in: it is
unproven that `OrtGetApiBase` survives static linking as a `dlsym`-visible
symbol. The Swift plugin references no ORT symbol, so dead-stripping may hide
it; this may require `-force_load` / `-u _OrtGetApiBase`.

**User impact:** The library does not load at all on iOS. Any iOS consumer
crashes at first use.

**Fix:** Add `betto_onnxrt_ios` as a dependency of `integration_test_app`,
regenerate plugin registrant, and re-run `make ios_test` until green. Then prove
the symbol survives: `nm -gU` on the built Runner binary must show
`_OrtGetApiBase` as an external symbol. Do not call iOS "supported" until both
conditions hold.

### 🔴 BLOCKER 3 — SHA-256 download verification is disabled on 4 of 6 platforms

**File:** `hook/build.dart`, `_sha256Manifest`.

**Platforms:** macOS, Linux, Windows, iOS (Android is the only platform with
real digests).

**Evidence:** Every desktop and the iOS manifest entry is 64 zeros. The hook
treats all-zeros as "not configured": `_isValid()` returns `true` for any
existing file without hashing, and on a download mismatch it warns and proceeds.
The CI workflow comment in `cicd.yml` even documents that the ORT binary cache
depends on this bypass.

**User impact:** This nullifies the package's headline "SHA-256-verified
prebuilt binary" guarantee on four of six platforms. A corrupted, truncated, or
tampered download is accepted and loaded. For a library whose whole value
proposition is safely fetching and running native binaries, this is a
supply-chain hole, not tech debt.

**Fix:** Paste real per-platform digests for v1.22.0 and **remove the all-zeros
bypass** from both `_isValid()` and `_ensureFile()` — not just fill in the
values. Add a test asserting that no manifest entry is all-zeros, so a future
blank entry cannot silently re-disable verification. (Tracked as
`TODO(betto_onnxrt#2)` — treat it as a release gate, not a follow-up.)

### 🟡 HIGH RISK 4 — ORT vtable slots are hand-maintained with no automated guard

**File:** `lib/src/ort_api.dart` (and call sites in `session.dart`,
`runtime.dart`). **Platforms:** all six.

Every ORT call indexes the `OrtApi` struct by a raw integer slot (`Run` = 9,
`CreateSessionFromArray` = 8, `GetTensorTypeAndShape` = 65, etc.). These are
correct for ORT API v22 but are maintained by hand against `onnxruntime_c_api.h`
with **no test pinning the slots to the header**. Comments already drift —
`session.dart` references "slots 31/32/33" where the code correctly uses
65/61/62.

**User impact:** A `VERSION_ONNX` bump that shifts any slot, or a single-digit
typo, calls the wrong C function — a crash or _silently wrong inference output_.
Combined with Blocker 1, such a regression reaches users without tripping CI.

**Fix:** Add a checked-in guard test that validates slot indices against the ORT
header (or against a recorded golden), and treat any PR editing `ort_api.dart`
slot numbers or bumping `VERSION_ONNX` as requiring a real load+inference run,
not just `dart test`.

---

## Platform Coverage Gaps

| Platform | Builds in CI             | Real inference tested in CI | Real inference tested at all                  | Checksum verified         | Status                                   |
| -------- | ------------------------ | --------------------------- | --------------------------------------------- | ------------------------- | ---------------------------------------- |
| Linux    | Yes (`build` job)        | No (skipped)                | **No** (no `linux_test` target)               | No (all-zeros)            | At risk — never load-tested anywhere     |
| Windows  | Yes (`test-windows`)     | No (skipped)                | **No** (no `windows_test` target)             | No (all-zeros)            | At risk — never load-tested anywhere     |
| macOS    | Yes (`test-macos`)       | No (skipped)                | Yes (`macos_test.log`, 12/12 pass, dev-run)   | No (all-zeros)            | Works, but only via developer-run test   |
| Android  | No (dev-run only)        | No                          | Yes (`android_test.log`, 12/12 pass, dev-run) | **Yes** (per-ABI digests) | Best-covered platform; not in CI         |
| iOS      | Builds, fails at runtime | No                          | **No — fails** (`ios_test.log`)               | No (all-zeros)            | Broken on-device                         |
| Web      | N/A                      | N/A                         | N/A                                           | N/A                       | Out of scope (FFI library; dart:io hook) |

The most dangerous cells are **Linux and Windows**: they have _no_ real
load+inference test in CI _or_ in the developer-run suite. There is no
`linux_test` / `windows_test` integration target at all. Their FFI path has
literally never been exercised by an automated test on this codebase — they are
trusted purely by analogy to macOS.

---

## Test Suite Assessment

**What is genuinely good:**

- `model_downloader_test.dart` is thorough and meaningful — success path,
  per-file checksum short-circuit, selective re-download on bad checksum,
  checksum-mismatch error text, HTTP non-2xx handling, `.part"../../reviews"`
  temp-file crash safety, and allowlist accept/reject/permit-all. This is real
  edge-case coverage, not metric padding. `model_downloader.dart` sits at 53/54
  lines.
- `tensor_test.dart` covers element-type round-tripping, named constructors,
  element counts, typed-list accessors with `StateError` on type mismatch, and
  `SessionOptions`. `tensor.dart` is 44/44.
- `model_spec.dart` is 9/9.
- `hook_smoke_test.dart` confirms `native_assets.yaml` is emitted, no stale
  `.part"../../reviews"` artifact remains, and the cache is version-scoped.
- The macOS/Android integration suite is well-designed: it asserts
  identity-model output equals input, multiple runs on one session, zeros, large
  values (overflow), invalid-bytes rejection, and pins the ORT API version to
  v22.

**What is missing or hollow:**

- **The FFI core has no executable coverage in the gate.** `session.dart` (171
  lines) and `runtime.dart` (29 lines) are 0% under `dart test`. The tests that
  would cover them exist but auto-skip. A passing `make test` says nothing about
  whether ORT loads or runs.
- **No CI platform actually runs the integration suite.** The three integration
  targets are all developer-run; CI runs only the skip-prone unit gate.
- **No slot/header guard test** (Blocker 4).
- **No checksum-not-all-zeros test** (Blocker 3).
- **No Linux/Windows inference test of any kind.**
- **No isolate / thread-affinity test.** `OnnxSession` is documented as
  thread-affine (all `run()`/`dispose()` from the creating isolate); nothing
  verifies the contract or the cross-isolate failure mode.

The headline coverage number (34.3%) flatters the situation, because the
_uncovered_ 65% is precisely the dangerous, native, crash-prone code, while the
covered 34% is pure-Dart logic that cannot segfault.

---

## CI/CD Assessment

**Pipeline:** `.github/workflows/cicd.yml` — one `build` job (Ubuntu) plus
`test-macos` and `test-windows`, each running `make cicd*` → `prepare test`,
with an ORT binary cache keyed on `VERSION_ONNX`.

**Would it catch a regression before users?** Largely **no**, for the
regressions that matter most:

- It will catch breakage in `ModelDownloader`, `tensor`, and `model_spec`.
- It will **not** catch a broken FFI load, a wrong vtable slot, a botched
  archive extraction, or a platform-specific link failure, because those paths
  are skipped, not run.
- iOS is not in CI at all — Blocker 2 was found only by a developer running
  `make ios_test` by hand. A pipeline that lets a "library does not load"
  regression through to a manual step is not a safety net.
- Android — the only platform with real checksums and a passing suite — is not
  in CI either.
- The ORT cache step's effectiveness is **explicitly built on the all-zeros
  checksum bypass** (Blocker 3): the cache comment notes `_isValid()` trusts
  existing files. So the supply-chain hole is load-bearing for the CI cache,
  which will make it tempting to leave in place. Resist that.

The pipeline also has no code-signing, notarization, artifact-publishing, or
secrets steps — acceptable for a library at this stage, but worth noting before
any distribution story is built on top of it.

---

## Advisory Issues

- 🔵 `integration_test_app` reports 4 packages pinned below newer available
  versions (`matcher`, `meta`, `test_api`, `vector_math`). Low risk, but worth a
  periodic `flutter pub outdated` pass.
- 🔵 Comment drift in `session.dart` ("slots 31/32/33" vs. actual 65/61/62) will
  mislead the next maintainer during an ORT upgrade. Fix alongside the slot
  guard test.
- 🔵 The `from: "1.22.0"` SPM pin in the iOS shim is loose. An exact pin keeps
  the linked ORT version in lockstep with the hand-maintained vtable slots and
  `VERSION_ONNX`.
- 🔵 No documented manual smoke procedure for Linux/Windows. Until those get an
  automated inference test, a written checklist is the minimum safety measure.

---

## Recommended Action Plan

**Must fix before any release (blockers):**

1. **Wire iOS up and prove it loads.** Add `betto_onnxrt_ios` to
   `integration_test_app`, regenerate the plugin registrant, get `make ios_test`
   green, and confirm `nm -gU` shows `_OrtGetApiBase` external on the Runner.
2. **Make the gate test the core.** Stage the ORT binary in CI so
   `onnx_session_test.dart` runs, and fail CI when those cases skip. Add at
   least one CI job that runs real load+inference (start with `make macos_test`
   on the existing `test-macos` runner).
3. **Restore checksum verification.** Fill in real SHA-256 digests for macOS,
   Linux, Windows, and iOS; remove the all-zeros bypass from `_isValid()` and
   `_ensureFile()`; add a test asserting no manifest entry is all-zeros.

**Must fix before declaring multi-platform support:**

4. Add a `linux_test` and `windows_test` integration target and run them
   (developer-run at minimum, CI ideally) — these platforms have never executed
   inference under test.
5. Add a vtable-slot/header guard test and a policy that any `VERSION_ONNX` bump
   or `ort_api.dart` edit requires a real inference run.

**Should fix before release:**

6. Add an isolate thread-affinity test for `OnnxSession`.
7. Fix the `session.dart` slot comment drift and tighten the SPM pin to an exact
   version.

**Bottom line:** Fix blockers 1–3 and this can move to _Conditionally Ready_.
Until then, a green CI badge on this repo is telling you the download helper and
the tensor structs work — it is _not_ telling you the library loads or runs ONNX
on the platform your user is holding. I would not ship this to a family member
in its current state.

---

_Relevant files:_

- `/Users/gonk/development/bettongia/onnxrt/lib/src/session.dart`
- `/Users/gonk/development/bettongia/onnxrt/lib/src/runtime.dart`
- `/Users/gonk/development/bettongia/onnxrt/lib/src/ort_api.dart`
- `/Users/gonk/development/bettongia/onnxrt/hook/build.dart`
- `/Users/gonk/development/bettongia/onnxrt/.github/workflows/cicd.yml`
- `/Users/gonk/development/bettongia/onnxrt/test/onnx_session_test.dart`
- `/Users/gonk/development/bettongia/onnxrt/packages/betto_onnxrt_ios`
- `/Users/gonk/development/bettongia/onnxrt/integration_test_app/integration_test/onnxrt_test.dart`
- Logs:
  `/Users/gonk/development/bettongia/onnxrt/reviews/2026-06-11 Testing review logs/`
