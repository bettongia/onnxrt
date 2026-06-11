# Testing Pipeline: Linux/Windows Targets, Vtable Guard, Isolate Test

**Status**: Implementing

**PR link**: _pending_

## Problem statement

Three open items from the v0 testing pipeline remain:

1. **Linux and Windows `make *_test` targets** — there is no standalone `make
   linux_test` or `make windows_test` Makefile target analogous to `make
   macos_test`. The CI already runs `dart test` (which includes
   `onnx_session_test.dart`) on both platforms via `cicd_linux` and
   `cicd_windows`, but there is no isolated "just run ORT inference" entry
   point. On macOS, `cicd_macos` explicitly calls `make macos_test` to
   separate the quality-gate from the on-device inference step; the same
   separation should exist for Linux and Windows. Additionally, Flutter Desktop
   on Linux and Windows has never had inference exercised under automation, and
   a written manual smoke checklist covering that gap is missing.

2. **ORT vtable-slot guard test** — the slot indices in `lib/src/ort_api.dart`
   are hand-maintained against `onnxruntime_c_api.h` with no automated guard.
   A silent slot drift (e.g. a copy-paste error, or a bump to `ortApiVersion`
   without re-verifying indices) calls the wrong C function and may produce
   wrong output rather than a crash. Additionally, the `session.dart` class
   docstring and inline comments reference "slots 31/32/33" for the
   output-shape readback calls when the actual slot numbers in the code are
   65/61/62.

3. **Isolate thread-affinity test** — `OnnxSession` is documented as
   thread-affine but the same-isolate positive path is not directly unit-tested,
   and the cross-isolate failure mode is undocumented in executable form.

## Open questions

- [x] For the vtable guard: should the golden be a standalone JSON file or a
      Dart const inside the test file?
      **Resolved (superseded):** The regex-based approach was discarded
      entirely (the regex cannot extract symbol names from the real annotation
      format). The chosen design introduces explicit `// SLOT:Name=N` markers
      on every bound slot in `ort_api.dart`; the golden Dart const in the test
      file cross-checks those markers. See Investigation Item 2.

- [x] For the isolate thread-affinity test: is a purely positive test
      sufficient?
      **Resolved:** Yes — same-isolate sequential positive test only. The
      cross-isolate negative path triggers undefined behaviour (ORT internal
      mutex corruption) and is unsafe to automate in CI. A `// KNOWN:
      cross-isolate use is undefined behaviour — not automated` comment is
      added to the test, and the `OnnxSession` class docstring is strengthened
      to name the failure mode explicitly.

- [x] Vtable guard parsing strategy (from Review 1).
      **Resolved:** `// SLOT:Name=N` marker format. Each bound slot in
      `ort_api.dart` gets an unambiguous machine-greppable annotation on its
      own line (e.g. `// SLOT:CreateEnv=3`). The test reads `ort_api.dart`,
      extracts all `SLOT:(\w+)=(\d+)` pairs (trivial regex, no false matches),
      and asserts they equal `_expectedSlotsV22`. This guards the slots the
      code actually declares rather than free-text prose.

- [x] Windows CI step (from Review 1).
      **Resolved:** Drop the separate `make windows_test` CI step. `cicd_windows`
      already runs `dart test` with real ORT inference; the macOS analogy does
      not hold (macOS needs a distinct step because JIT `dart test` skips inference
      there). `windows_test` is kept as a local-convenience Make target only.

- [x] Manual smoke checklist home and depth (from Review 1).
      **Resolved:** New `docs/manual_checks.md` file. Content covers: Flutter
      channel/version, load-verification step, failure signatures (e.g.
      `symbol not found: OrtGetApiBase`), and where to record evidence (PR
      description).

- [x] Spec update confirmed in scope (from Review 1).
      **Resolved:** Yes. `docs/spec/README.md:602-608` ("Windows and Linux
      integration testing") currently states the targets "are not yet defined"
      and "No Windows or Linux machines are currently available." This is
      directly contradicted by the completed "Wire the CI gate to real ORT
      inference" BLOCKER and by this work. The section will be rewritten in
      Phase 5.

## Investigation

### Item 1: Linux and Windows `*_test` targets

**Current state.** `cicd_linux` (line 37–51 of `Makefile`) runs `dart pub get`,
creates the unversioned `libonnxruntime.so` symlink, exports
`LD_LIBRARY_PATH`, then calls `dart test` plus coverage and `dart doc` all in
one shell. `cicd_windows` (line 56) calls `prepare_dart`, the quality gate,
`dart test`, and `doc`. Both include inference coverage, but there is no
way to run *only* the ORT inference step in isolation.

`make macos_test` (line 62–65) is the macOS analogue: it `cd`s into
`integration_test_app`, runs `flutter pub get`, then `flutter test
integration_test/onnxrt_test.dart --device-id macos`. Linux and Windows
run pure Dart tests (not Flutter), so `linux_test` / `windows_test` would
not `cd` into `integration_test_app`; instead they run
`dart test test/onnx_session_test.dart` with the appropriate library path
set up.

**Linux target design.** The `LD_LIBRARY_PATH` trick already works in
`cicd_linux`. `linux_test` should:
1. Read `VERSION_ONNX` and strip the leading `v` (the cache dir is `1.22.0`,
   not `v1.22.0` — the same strip that `cicd_linux` applies on Makefile line 42).
2. Create the unversioned symlink `libonnxruntime.so → libonnxruntime.so.{ver}`.
3. Export `LD_LIBRARY_PATH` to include the cache directory.
4. Run `dart test test/onnx_session_test.dart` in that shell.

This mirrors what `cicd_linux` does, but without the quality gate — just
the ORT load+inference step. Local use: `make linux_test` on a Linux machine
with `dart pub get` already run. In CI, `cicd_linux` continues to exercise
all of the above automatically.

**Windows target design.** `windows_test` is a local-convenience Make target
only. `cicd_windows` already runs `dart test` (including `onnx_session_test.dart`
against the real DLL) once the CI PATH step has run — a separate CI step is
redundant and adds no coverage. The macOS analogy does not hold because macOS
inference can only run via the Flutter/AOT integration test; on Windows plain
`dart test` already does real ORT inference. The Make target assumes `PATH`
already includes the ORT DLL directory (set by the caller), consistent with
how CI sets it up:

```makefile
# Run ORT inference tests on Windows (pure Dart — does not require Flutter).
# Requires dart pub get to have been run and .dart_tool/betto_onnxrt/{ver}/
# to be on PATH so DynamicLibrary.open('onnxruntime.dll') succeeds.
# In CI this PATH is set by the 'Add ORT DLL directory to PATH' step before
# make cicd_windows runs. For local use, set PATH manually first.
windows_test:
	dart test test/onnx_session_test.dart
.PHONY: windows_test
```

**Manual smoke checklist: Flutter Desktop on Linux and Windows.** Flutter
Desktop on Linux and Windows (the `integration_test_app` Flutter build) is out
of scope for v0 automated CI. A new `docs/manual_checks.md` file covers this
gap with the detail needed for a non-automated check to be trustworthy:
- Flutter stable channel and version at time of check
- How to confirm ORT actually loaded (not just that the test runner exited 0)
- Failure signatures (e.g. `Failed to load dynamic library`, `symbol not found:
  OrtGetApiBase` — the same class of failure seen historically on iOS)
- Where to record the result (PR description, with `dart test` exit code and
  last 20 lines of output)

### Item 2: ORT vtable-slot guard test

**Comment drift in `session.dart`.** The `OnnxSession.run()` *method*
docstring at `lib/src/session.dart:320` reads:
```
(vtable slots 31/32/33)
```
and inline comments at lines 425, 430, 435 read:
```
// Read the output shape via GetTensorTypeAndShapeInfo (slot 31).
// GetDimensionsCount (slot 32): number of dimensions.
// GetDimensions (slot 33): dimension sizes as int64 array.
```
The actual `ortSlotPtr` call site numbers at lines 362–373 are 65, 61, 62
respectively — correct per `ort_api.dart` and the ORT v1.22.x header. The
comments are wrong. Note: the *class* docstring at line 57 already correctly
reads `(65 = GetTensorTypeAndShape, 61 = GetDimensionsCount, 62 =
GetDimensions)` — do not touch line 57. Only the method docstring (line 320)
and the three inline comments (lines 425, 430, 435) need fixing.

**Guard test design.** The risk is silent slot drift: an edit to `ort_api.dart`
or a version bump changes a slot constant without a corresponding load+inference
validation. The original regex-based approach was discarded: the real annotation
format (`// slot 0: OrtStatus* CreateStatus(...)`) places the C return type
immediately after the colon, so a `(\w+)` capture extracts the return type
(e.g. `OrtStatus`, `void`) rather than the symbol name, producing garbage.

The chosen design introduces explicit `// SLOT:Name=N` markers in `ort_api.dart`.
Each bound slot gets a machine-greppable annotation on its own line immediately
before the typedef pair:

```dart
// SLOT:CreateEnv=3
typedef CreateEnvC = Pointer<OrtStatus> Function(...);
typedef CreateEnvDart = Pointer<OrtStatus> Function(...);
```

The `test/ort_slot_guard_test.dart` test then:
1. Reads `lib/src/ort_api.dart` as text.
2. Extracts all `SLOT:(\w+)=(\d+)` pairs — this regex is unambiguous: no
   existing comment or code line can produce a false match.
3. Asserts the extracted `Map<String, int>` equals `_expectedSlotsV22`.

This guards the slots the code actually declares (not free-text prose), is
trivially parseable, and makes slot changes visible in `git diff` as a distinct
machine-checkable annotation rather than buried in a prose comment.

The complete list of bound slots in the current `ort_api.dart` is:
| Symbol | Slot |
|--------|------|
| `CreateStatus` | 0 |
| `GetErrorCode` | 1 |
| `GetErrorMessage` | 2 |
| `CreateEnv` | 3 |
| `CreateSession` | 7 |
| `CreateSessionFromArray` | 8 |
| `Run` | 9 |
| `CreateSessionOptions` | 10 |
| `SetIntraOpNumThreads` | 24 |
| `SetInterOpNumThreads` | 25 |
| `CreateTensorWithDataAsOrtValue` | 49 |
| `IsTensor` | 50 |
| `GetTensorMutableData` | 51 |
| `GetDimensionsCount` | 61 |
| `GetDimensions` | 62 |
| `GetTensorTypeAndShape` | 65 |
| `CreateCpuMemoryInfo` | 69 |
| `ReleaseEnv` | 92 |
| `ReleaseStatus` | 93 |
| `ReleaseMemoryInfo` | 94 |
| `ReleaseSession` | 95 |
| `ReleaseValue` | 96 |
| `ReleaseTensorTypeAndShapeInfo` | 99 |
| `ReleaseSessionOptions` | 100 |

The golden was cross-checked against the `OrtApi` struct field order in
`onnxruntime_c_api.h` for API version 22.

**PR enforcement note.** The guard test catches comment drift but cannot
replace a real load+inference run when slot numbers change. A note should be
added to the `ort_api.dart` file-level doc and to `CLAUDE.md` stating that
any PR editing slot indices or bumping `ortApiVersion` must include evidence
of a passing `make macos_test` (or `make linux_test`/`make windows_test`)
run in the PR description.

### Item 3: Isolate thread-affinity test

**Current state.** `OnnxSession` is documented as thread-affine in the class
docstring (`session.dart:44–49`). No test verifies the same-isolate sequential
path works correctly; the `onnx_session_test.dart` tests are session-level
(create, run once, dispose) but do not exercise multiple runs or prove the
isolate contract explicitly.

**Positive test (automated).** A new test group `OnnxSession — thread affinity`
in `onnx_session_test.dart` (or a separate `test/onnx_isolate_test.dart`):

- Creates a session on the current (main) isolate.
- Calls `run()` three times sequentially from the same isolate.
- Asserts all three runs return correct results.
- Documents via a comment that the same-isolate sequential contract is what
  is being verified.

This test uses the existing `identity_float32.onnx` fixture (the model is
deterministic: `run()` on `[1.0, 2.0, 3.0, 4.0]` always returns
`[1.0, 2.0, 3.0, 4.0]`). The test skips when ORT is not staged, mirroring
the existing skip pattern.

**Negative path (documentation only).** The cross-isolate failure case
(`run()` called from isolate B on a session created in isolate A) is undefined
behaviour at the ORT level: ORT's internal thread pool uses mutexes that are
not isolate-aware. In practice this may manifest as a crash or silent corruption
rather than a Dart exception, which makes automated testing unreliable and
potentially unsafe for CI. A `// KNOWN: cross-isolate use is undefined
behaviour — not automated; documented in OnnxSession class docstring` comment
will be added to the test file. The class docstring in `session.dart` should
be strengthened to explicitly name the failure mode.

## Implementation plan

### Phase 1 — Fix comment drift in `session.dart`

- [ ] Fix `OnnxSession.run()` *method* docstring (`session.dart:320`): change
      `(vtable slots 31/32/33)` to `(vtable slots 65/61/62)`.
      (The *class* docstring at line 57 is already correct — do not touch it.)
- [ ] Fix inline comment at line 425: change `(slot 31)` to `(slot 65)`.
- [ ] Fix inline comment at line 430: change `(slot 32)` to `(slot 61)`.
- [ ] Fix inline comment at line 435: change `(slot 33)` to `(slot 62)`.
- [ ] Confirm `make analyze` and `make format_check` pass.

### Phase 2 — Add `// SLOT:Name=N` markers and guard test

- [ ] Add a `// SLOT:Name=N` annotation immediately before each bound typedef
      pair in `lib/src/ort_api.dart` for all 24 slots in the golden table
      (Investigation section). Example:
      ```dart
      // SLOT:CreateEnv=3
      typedef CreateEnvC = Pointer<OrtStatus> Function(...);
      typedef CreateEnvDart = Pointer<OrtStatus> Function(...);
      ```
      Keep the existing `// slot N: OrtStatus* Symbol(...)` prose comments —
      the SLOT marker is an additional machine-readable line, not a replacement.
- [ ] Create `test/ort_slot_guard_test.dart` with the Apache 2.0 header.
- [ ] Declare `const Map<String, int> _expectedSlotsV22` using the table
      from the Investigation section.
- [ ] Read `lib/src/ort_api.dart` as text (use `File` relative to
      `Directory.current`, matching the `_packageRoot()` pattern in
      `onnx_session_test.dart`).
- [ ] Extract `SLOT:(\w+)=(\d+)` pairs with a regex — this is unambiguous
      and cannot produce false matches from existing comments or code.
- [ ] Assert extracted map equals `_expectedSlotsV22`.
- [ ] Confirm `make test`, `make analyze`, `make format_check`, and
      `make license_check` pass.
- [ ] Add a note to the `lib/src/ort_api.dart` file-level docstring: the
      `// SLOT:Name=N` markers are checked by `test/ort_slot_guard_test.dart`;
      any PR editing slot numbers or bumping `ortApiVersion` must include
      evidence of a passing `make macos_test` (or `make linux_test`) run.
- [ ] Add the same guidance to `CLAUDE.md` under "Key conventions".

### Phase 3 — Add isolate thread-affinity test

- [ ] Add a `group('OnnxSession — thread affinity', ...)` block to
      `test/onnx_session_test.dart`.
- [ ] Test calls `session.run()` three times sequentially from the same
      isolate and asserts all outputs match `[1.0, 2.0, 3.0, 4.0]`.
- [ ] Add a `// KNOWN: cross-isolate use is UB — not automated` comment above
      the group.
- [ ] Strengthen the `OnnxSession` class docstring in `session.dart` to name
      the failure mode: "Calling `run()` or `dispose()` from a different
      isolate can corrupt ORT's internal thread-pool mutex state and produce
      undefined behaviour (crash or silent wrong output)."
- [ ] Confirm `make test` passes (test skips gracefully when ORT is not staged).

### Phase 4 — Add `linux_test` and `windows_test` Makefile targets

- [ ] Add `linux_test` to `Makefile` (note the `v`-prefix strip, matching
      `cicd_linux` line 42):
  ```makefile
  # Run ORT inference tests on Linux (pure Dart — does not require Flutter).
  # Requires dart pub get to have been run (ORT binary staged in cache).
  linux_test:
  	@ORT_VER=$$(cat VERSION_ONNX); \
  	  ORT_VER=$${ORT_VER#v}; \
  	  ORT_CACHE=".dart_tool/betto_onnxrt/$$ORT_VER"; \
  	  ln -sf "libonnxruntime.so.$$ORT_VER" "$$ORT_CACHE/libonnxruntime.so"; \
  	  export LD_LIBRARY_PATH="$$(pwd)/$$ORT_CACHE$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"; \
  	  dart test test/onnx_session_test.dart
  .PHONY: linux_test
  ```
- [ ] Add `windows_test` to `Makefile` (local-convenience target only — no
      CI step; `cicd_windows` already runs real inference):
  ```makefile
  # Run ORT inference tests on Windows (pure Dart — does not require Flutter).
  # Requires dart pub get to have been run and .dart_tool/betto_onnxrt/{ver}/
  # to be on PATH so DynamicLibrary.open('onnxruntime.dll') succeeds.
  # Set PATH manually before calling this target (CI does this automatically
  # in the 'Add ORT DLL directory to PATH' step before make cicd_windows).
  windows_test:
  	dart test test/onnx_session_test.dart
  .PHONY: windows_test
  ```
- [ ] No CI workflow change needed for `windows_test` — `cicd_windows` already
      exercises real ORT inference via `dart test`.
- [ ] Create `docs/manual_checks.md` with a Flutter Desktop smoke checklist
      covering: Flutter stable channel and version at time of check;
      prerequisites (`dart pub get` already run, Flutter Desktop toolchain
      installed); commands for Linux (`--device-id linux`) and Windows
      (`--device-id windows`); load-verification step (confirm the ORT library
      name appears in build output, not just that the test runner exits 0);
      failure signatures (`Failed to load dynamic library`,
      `symbol not found: OrtGetApiBase`); and where to record evidence (paste
      `dart test` exit code and last 20 lines into the PR description).

### Phase 5 — Update roadmap and docs

- [ ] Rewrite `docs/spec/README.md:602-608` ("Windows and Linux integration
      testing"): remove the claims that the targets "are not yet defined" and
      "No Windows or Linux machines are currently available." Replace with a
      description of the current state: `make linux_test` and `make windows_test`
      are defined; real ORT inference already runs on both platforms in CI via
      `cicd_linux` and `cicd_windows`; Flutter Desktop automation on both
      platforms remains out of scope for v0 (see `docs/manual_checks.md`).
- [ ] Mark "Linux and Windows integration tests" item complete in
      `docs/roadmap/v0.md` (update `[ ]` to `[x]` and add a Resolved section).
- [ ] Mark "ORT vtable-slot guard test" item complete in `docs/roadmap/v0.md`.
- [ ] Mark "Isolate thread-affinity test" item complete in
      `docs/roadmap/v0.md`.
- [ ] Update Goal 4 completion percentage from 20% to 100% in the roadmap
      summary table.
- [ ] Confirm `make pre_commit` passes end-to-end.

## Reviews

### Review 1: 2026-06-11

This plan tackles three real, well-motivated v0 gaps and the investigation is
mostly sound. However, the review found one **showstopper design flaw** in the
vtable guard (the regex cannot extract symbol names from the real annotation
format), one **broken Makefile recipe** (the `linux_test` target omits the
`v`-prefix strip and will point at a non-existent cache directory), several
**inaccurate line-number references** in the very section whose purpose is to
fix comment drift, and a **missing spec update**. Details below.

#### Problem Statement Assessment

All three items are real and map cleanly to open v0 roadmap entries
(`docs/roadmap/v0.md`: "Linux and Windows integration tests", "ORT vtable-slot
guard test", "Isolate thread-affinity test"). Given the project's history —
inference tests silently skipping in CI, SHA-256 bypassed with placeholder
zeros — hardening the testing pipeline is exactly the right place to spend
effort. No objection to scope.

One framing nuance worth recording: the problem statement (item 1) says Flutter
Desktop on Linux/Windows "has never had inference exercised under automation".
That is true, but the spec section "Windows and Linux integration testing"
(`docs/spec/README.md:602-608`) currently goes further and claims `make
windows_test` / `make linux_test` "are not yet defined" and that "No Windows or
Linux machines are currently available." The CI workflow already runs real ORT
inference via `dart test` on both Linux and Windows runners (the completed
"Wire the CI gate to real ORT inference" BLOCKER). So the spec is *already*
partly stale, and this plan is the natural place to correct it — see Architecture
Fit.

#### Proposed Solution Assessment

**Item 2 (vtable guard) — the regex design is broken and would give false
confidence.** This is the most serious finding. The plan proposes regex
`// slot (\d+): (\w+)` to extract `(symbol, slot)` pairs from `ort_api.dart`.
The real annotations are of the form `// slot 0: OrtStatus* CreateStatus(...)`
— the first word after the colon is the **C return type**, not the symbol. I
ran the exact proposed regex against the current `ort_api.dart`. It extracts
**7 entries**, almost all garbage:

```
IsTensor = 50          (correct, only because [unused] lines have no return type)
OrtErrorCode = 1       (captured the return type)
OrtStatus = 69         (captured the return type — and collides across slots!)
ReleaseCustomOpDomain = 101
ReleaseRunOptions = 97
const = 2              (captured the literal word "const")
void = 100             (captured the return type)
```

Note `OrtStatus` maps to slot 69 — the regex overwrites the key on every
`OrtStatus*`-returning slot, so 12+ distinct functions collapse to a single
bogus entry. The extracted map shares **zero** correct `(symbol, slot)` pairs
with the 24-entry golden table in the plan. As written, the test does not just
fail to catch drift — it cannot be made to pass against the file it is meant to
guard. Additional format mismatches the plan did not account for:

- Line 66 `// slot 0 of OrtApiBase:` — the ` of OrtApiBase` between the number
  and the colon means `// slot (\d+):` never matches; good (we don't want it),
  but it shows the format is more varied than assumed.
- Plural-range lines `// slots 31–48:`, `// slots 4–6:` use `slots` (plural)
  and an en-dash range; the singular `// slot ` prefix correctly skips them,
  but they sit immediately adjacent to real slots and invite off-by-one
  parsing errors.

The guard is salvageable but needs a real redesign, not a regex tweak. Two
viable directions, both raised as open questions below:
  1. Anchor on the Dart typedef declarations (the things actually used:
     `typedef CreateEnvC = ...` preceded by `// slot 3: ...`) and require the
     comment immediately above each bound typedef to carry the matching slot —
     i.e. parse the *symbol from the typedef name* and the *slot from the
     preceding comment*, then assert they agree. This guards what the code
     actually calls.
  2. Change the annotation format itself to a machine-greppable, unambiguous
     marker (e.g. `// SLOT:CreateEnv=3`) on every bound slot and parse that.
     This is a small edit to `ort_api.dart` but makes the contract explicit and
     the regex trivial and robust.

Either way, the test must assert against the slots **the code binds** (the
`ortSlotPtr<...>(api, N)` call sites and their typedefs), not merely against
free-text comments. A guard that only checks comment-to-comment consistency
verifies nothing about the running code — the plan itself admits "It does not
verify the slot is correct per the header", but it is weaker than that: it does
not even verify the slot matches what `session.dart` passes to `ortSlotPtr`.
Consider extracting the call-site slot integers too and cross-checking all
three sources (typedef comment, golden, call site).

**Item 2 (comment-drift fix) — the line references in the plan are themselves
wrong, which is ironic for a plan about fixing comment drift.** Verified against
the live file:

- Phase 1 task 1 says: "Fix `OnnxSession.run()` class docstring
  (`session.dart:57`): change `(vtable slots 31/32/33)` to ...". This is wrong
  on two counts. Line 57 is the **class** docstring and **already reads
  correctly**: `(65 = GetTensorTypeAndShape, 61 = GetDimensionsCount, 62 =
  GetDimensions)`. The stale `(vtable slots 31/32/33)` string is in the
  **`run()` method** docstring at **line 320** (continued from 319). The plan
  conflates the class docstring (line 57, already correct — do not touch) with
  the method docstring (line 320, the actual drift).
- Inline comments: line 425 (`slot 31`) ✓, line **430** (`slot 32`) — the plan
  says line 431 — and line 435 (`slot 33`) ✓.

If the implementer follows the plan literally they will look at line 57, find no
`31/32/33` string, and either skip the fix or get confused. Correct the targets
to: line 320 (method docstring), 425, 430, 435 (inline). Line 57 needs no
change.

**Item 1 (Linux target) — the proposed `linux_test` recipe is broken: it omits
the `v`-prefix strip.** `VERSION_ONNX` contains `v1.22.0` (leading `v`), but the
cache directory is `1.22.0` (no `v`). The working `cicd_linux` recipe strips it
(`ORT_VER=$${ORT_VER#v}`, Makefile line 42) and the Windows CI PATH step strips
it (`-replace '^v',''`, cicd.yml line 95). The plan's proposed `linux_test`
(plan lines 278-282) does **not**:

```makefile
@ORT_VER=$$(cat VERSION_ONNX); \
  ORT_CACHE=".dart_tool/betto_onnxrt/$$ORT_VER"; \   # => .dart_tool/betto_onnxrt/v1.22.0 (does not exist)
```

This points the symlink and `LD_LIBRARY_PATH` at a non-existent directory; the
test would fail to load ORT. The recipe must add `ORT_VER=$${ORT_VER#v};`
exactly as `cicd_linux` does. This is precisely the class of silent
pipeline-config bug the team has been bitten by — flagging it as a blocker for
Phase 4.

**Item 1 (Windows target) — adding a separate `windows_test` step is largely
redundant and the symmetry argument is weak.** `cicd_windows` already runs
`dart test` (Makefile line 58: `prepare_dart test`), which includes
`onnx_session_test.dart` against the real DLL once PATH is set (cicd.yml lines
93-101). The proposed `windows_test` target is just `dart test
test/onnx_session_test.dart` with no setup of its own — it relies entirely on
PATH being set by the caller, which `cicd_windows` already arranged. Adding it
as a second CI step buys near-zero additional coverage and adds a step that
*looks* like it stages ORT but does not. The macOS analogy does not hold:
`macos_test` exists because macOS inference can *only* run via the Flutter/AOT
integration test (JIT `dart test` skips on macOS), so `cicd_macos` genuinely
needs a distinct step. On Windows the plain `dart test` already does the real
inference. Recommend either (a) drop the separate CI `windows_test` step and
keep only the local-convenience Make target, or (b) if symmetry/visibility is
genuinely wanted, make `windows_test` self-contained (set PATH itself) so it is
not a footgun. Raised as an open question.

**Item 3 (isolate test) — the positive-only approach is the right call.** The
recommendation to do a same-isolate sequential positive test plus a documented
(not executed) negative path is correct and consistent with the existing
single-threaded `SetIntraOpNumThreads(1)` design. Spawning a second isolate to
provoke UB in CI would be flaky and dangerous. No objection. One refinement:
the test should also assert that a `dispose()`d session is not reused (the class
docstring at session.dart:476 says "After dispose, run must not be called") —
that contract is currently untested and is cheap to add here. Minor.

#### Architecture Fit

Library architecture: this plan touches `test/`, `Makefile`, `.github/`,
`session.dart` (comments + docstring only), `ort_api.dart` (doc note, and a
format change if option 2 above is chosen), `CLAUDE.md`, the roadmap, and the
spec. No `lib/` structure, storage, domain model, public API surface, or widget
changes — the library-architecture layer boundary is not affected. The
comment-only edits to `session.dart` and the doc-note to `ort_api.dart` keep the
pure-Dart core pure. No concern on this axis.

Spec alignment — **a required spec update is missing from the plan.** Per
CLAUDE.md, behaviour/spec-described changes must update the spec in the same
work. The spec section "Windows and Linux integration testing"
(`docs/spec/README.md:602-608`) currently states the targets "are not yet
defined" and "No Windows or Linux machines are currently available." Defining
`make linux_test` / `make windows_test` and (re)confirming CI inference directly
contradicts that text. Phase 4/5 must include rewriting that spec section to
reflect the new targets and the already-wired CI inference, not merely adding a
manual smoke checklist. The plan's manual-checklist task offers a choice of
"`docs/spec/README.md` (or a new `docs/manual_checks.md`)" — note that
`docs/spec/` is a single `README.md` (no numbered files), so if a separate file
is preferred, `docs/manual_checks.md` is the cleaner home; either way the
existing stale section still needs editing.

Design / inclusivity skills: not applicable. This plan adds no UI — it is
test-harness, Makefile, and doc work only.

#### Risk & Edge Cases

- **False-confidence guard test (highest risk).** As designed, the guard
  green-lights nothing meaningful. If shipped with a hand-tuned regex that
  happens to pass, future maintainers will trust a test that does not actually
  bind-check the call sites. Must be redesigned, not patched.
- **`v`-prefix bug in `linux_test`** — breaks the target on first use.
- **Golden-table maintenance burden.** The 24-entry golden duplicates
  information already in `ort_api.dart`. If the guard only compares
  comment-extracted values to the golden, the golden is a third copy that can
  itself drift. Prefer deriving from the typedef/call-site truth and keeping the
  golden as the single authoritative "this is what API v22 should be" anchor —
  with a clear note in the test explaining the golden is the human-verified
  reference.
- **`identity_float32.onnx` element-type assumption.** The isolate test relies
  on float32 output; fine for this fixture, and consistent with the current
  float32-only `_copyTensorData`. No issue, but worth a one-line comment so it
  is not mistaken for general behaviour.
- **Manual smoke checklist under-specified.** The plan lists prerequisites,
  commands, and "Expected result: all tests pass, no ORT errors". For a
  checklist whose entire reason to exist is that these platforms are *not*
  automated, that is too thin. It should state: which Flutter channel/version,
  how to confirm the ORT binary actually loaded (not just that the test runner
  exited 0), what a *failure* looks like (e.g. the `symbol not found:
  OrtGetApiBase` class of error seen historically on iOS), and where to record
  the result (PR description? a dated log?). Tie it to the same evidence
  requirement the plan proposes for slot changes.
- **PR-evidence enforcement is unenforceable as stated.** Phase 2 adds prose to
  `CLAUDE.md` and `ort_api.dart` asking PRs that change slots to include
  `make macos_test` evidence. That is guidance, not a gate. Acceptable for v0,
  but call it out as advisory so no one assumes CI enforces it. (A cheap real
  gate: have the slot-guard test print a reminder, or fail if `ortApiVersion`
  changed without a corresponding golden update — out of scope to require, but
  worth noting.)

#### Recommendations

Do not proceed to implementation until the open questions below are resolved.
Concretely, before this plan is `Investigated`:

1. **Redesign the vtable guard** to parse the symbol from the bound typedefs /
   `ortSlotPtr` call sites (or introduce an unambiguous `// SLOT:Name=N` marker)
   and cross-check call site ↔ comment ↔ golden. Drop the
   `// slot (\d+): (\w+)` regex entirely. Re-run the chosen parser against the
   real `ort_api.dart` and paste the extracted map into the plan to prove it
   matches the golden before writing the test.
2. **Fix the `linux_test` recipe** to strip the `v` prefix
   (`ORT_VER=$${ORT_VER#v};`) exactly as `cicd_linux` does.
3. **Correct the comment-drift line references** in the Problem statement,
   Investigation, and Phase 1: the stale string is at line **320** (method
   docstring), inline at **425 / 430 / 435**; line 57 is already correct and
   must not be touched.
4. **Add a spec-update task** to rewrite `docs/spec/README.md:602-608` ("Windows
   and Linux integration testing") to reflect the new targets and the
   already-wired CI inference.
5. **Decide the Windows CI step** (drop the redundant separate step, or make
   `windows_test` self-contained).
6. **Flesh out the manual smoke checklist** with load-verification, failure
   signatures, channel/version, and where evidence is recorded.

The isolate test (Item 3) is ready as designed and can proceed once the above
are settled. The overall shape of the plan is good; the failures are in
execution detail, but two of them (guard regex, `v`-prefix) would produce a
test that lies and a target that does not run — unacceptable for a plan whose
whole purpose is to stop regressions slipping behind a green badge.

#### Open questions

- [x] **Vtable guard parsing strategy.** Resolved: `// SLOT:Name=N` marker
      approach. Each bound slot gets an unambiguous machine-readable annotation
      in `ort_api.dart`; the test extracts `SLOT:(\w+)=(\d+)` pairs and asserts
      against the golden. See Investigation Item 2 and Phase 2.
- [x] **Guard scope.** Resolved: two sources (SLOT markers in `ort_api.dart`
      and the golden map). Call-site cross-checking would require parsing
      `session.dart` `ortSlotPtr` integers, which is disproportionate for v0.
      The SLOT markers are on the typedef declarations that `session.dart`
      imports, so a drift in either direction (wrong marker or wrong call site)
      is caught at code-review time and flagged by the guard test for markers.
- [x] **Windows CI step.** Resolved: dropped. `cicd_windows` already runs real
      inference; `windows_test` is a local-convenience Make target only.
- [x] **Manual checklist home + depth.** Resolved: new `docs/manual_checks.md`
      with full detail — Flutter channel, load-verification, failure signatures,
      evidence location. See Phase 4.
- [x] **Spec update confirmed in scope.** Resolved: yes — `docs/spec/README.md:602-608`
      rewritten in Phase 5.

The two open questions already in the plan's top-level `## Open questions`
section (golden as JSON-vs-Dart-const, and isolate positive-only) are sound;
their recommendations are accepted as-is and do not block. The golden-format
question is partly superseded by the parsing-strategy question above — resolve
that first.

## Summary

_To be filled in on completion._
