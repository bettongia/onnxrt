# Output element-type introspection

**Status**: Investigated

**PR link**: —

## Problem statement

`OnnxSession.run()` currently returns all output tensors as `float32` regardless
of the type declared in the model. `_copyTensorData` in `session.dart` always
reads raw bytes as `Float32List`. Any model that emits `int64`, `uint8`, `int32`,
or `float64` outputs silently returns garbage data reinterpreted as floats.

The public API contract (`OnnxTensor.data: TypedData`, the per-type doc table in
`OnnxTensor`'s class docstring, and `OnnxElementType.fromOnnxTypeCode`) already
describes the correct behaviour. The gap is entirely internal: the implementation
does not call `GetTensorElementType` and therefore cannot branch on the actual
type.

This is roadmap Goal 3 (0% complete).

## Open questions

- [x] **Test fixture generator: reuse the existing Dart emitter instead of
      adding Python?** The plan proposes a new `tool/gen_test_fixtures.py`
      (Python 3 + the `onnx` package). But `tool/generate_test_fixture.dart`
      already exists: a pure-Dart, zero-dependency ONNX protobuf emitter that
      produced `identity_float32.onnx`. Its `_typeProto` hardcodes
      `elem_type = 1`; generalising it to take an element-type code is a
      one-parameter change (int64 = `7`). Adding a Python toolchain dependency
      when a Dart generator already does the job is the one clear regression in
      this plan. _See Review 1 — recommend reusing the Dart tool unless there is
      a reason it cannot emit a non-float32 type._
      _Decision: Extend the existing pure-Dart `tool/generate_test_fixture.dart`
      to emit an `int64` fixture (parameterise `_typeProto`'s `elem_type`). Do
      NOT add a Python dependency. Keeps the fixture toolchain single-language
      and zero-dependency, consistent with project conventions._
- [x] **FFI out-param width: `Uint32` vs `Int32`?** The plan specifies
      `Pointer<Uint32>` for the `GetTensorElementType` out parameter. The same C
      enum (`ONNXTensorElementDataType`) is already bound as `Int32` at the
      input side (slot 49, `CreateTensorC`). Pick one and be consistent — `Int32`
      matches the existing binding and the enum is small and non-negative either
      way. _See Review 1._
      _Decision: Use `Pointer<Int32>` for the out-param, matching the existing
      slot-49 binding of the same C enum (`ONNXTensorElementDataType`). One
      consistent convention for the enum across the FFI surface._
- [x] **Coverage of the new non-float32 branches.** The plan adds five branches
      to `_copyTensorData` (float32, uint8, int32, int64, float64) and three new
      accessors (`asUint8`, `asInt32`, `asFloat64`) but the only integration
      test exercises `int64`. The uint8/int32/float64 copy branches and their
      accessors will be uncovered, risking the 90% line-coverage gate. _See
      Review 1 — add unit tests for the new accessors and consider exercising
      more branches._
      _Decision: Add unit-level tests for all new typed accessors (`asUint8`,
      `asInt32`, `asFloat64`) — both success and `StateError` paths — and cover
      all five `_copyTensorData` copy branches, not just `int64`. Coverage must
      stay above 90%._

## Investigation

### Slot number

The roadmap entry and two comments in `session.dart` reference "slot 35" for
`GetTensorElementType`. This is wrong. Cross-checked against
`onnxruntime_c_api.h` v1.22.0 by counting `ORT_API2_STATUS` entries:

| Slot | Symbol |
|------|--------|
| 49   | `CreateTensorWithDataAsOrtValue` ← already bound, confirms offset |
| 51   | `GetTensorMutableData` ← already bound, confirms offset |
| 52–59 | `FillStringTensor` … `SetDimensions` (unused) |
| **60** | **`GetTensorElementType`** ← the slot we need |
| 61   | `GetDimensionsCount` ← already bound, confirms offset |
| 62   | `GetDimensions` ← already bound |
| 65   | `GetTensorTypeAndShape` ← already bound |
| 69   | `CreateCpuMemoryInfo` ← already bound |

The correct slot is **60**. All "slot 35" references in `session.dart` are stale
copy errors and must be corrected.

### C API signature (slot 60)

```c
ORT_API2_STATUS(GetTensorElementType,
    _In_  const OrtTensorTypeAndShapeInfo* info,
    _Out_ enum ONNXTensorElementDataType*  out);
```

`info` is the `OrtTensorTypeAndShapeInfo*` already obtained via
`GetTensorTypeAndShape` (slot 65) in the existing output-extraction loop —
no additional handle is needed. `out` is a 32-bit enum value; use `Pointer<Int32>`
in the Dart FFI typedef, matching the existing slot-49 binding of the same C
enum (`ONNXTensorElementDataType`).

### Current output-extraction flow (session.dart ~line 428)

```
GetTensorTypeAndShape(outVal) → ttasi
GetDimensionsCount(ttasi)     → dimCount
GetDimensions(ttasi)          → shape[]
ReleaseTensorTypeAndShapeInfo(ttasi)
GetTensorMutableData(outVal)  → rawPtr
_copyTensorData(rawPtr, elementCount)  ← always returns float32
```

The fix is to call `GetTensorElementType(ttasi)` **before** `ReleaseTensorTypeAndShapeInfo`,
then pass the element type code into `_copyTensorData` so it can branch.

### Public API impact

None. `OnnxTensor` already carries `elementType: OnnxElementType` and
`data: TypedData`. The class docstring already specifies the correct
`(elementType → data runtime type)` mapping. `OnnxElementType.fromOnnxTypeCode`
already handles all five supported codes. The fix is entirely internal to
`session.dart`.

`_copyTensorData`'s signature changes from
`(Pointer<Void>, int) → (OnnxElementType, TypedData)` to
`(Pointer<Void>, int, int) → (OnnxElementType, TypedData)` where the third
argument is the raw ONNX type code from `GetTensorElementType`.

### Slot guard impact

One new entry must be added to `_expectedSlotsV22` in
`test/ort_slot_guard_test.dart`: `'GetTensorElementType': 60`. The total
count assertion will then require 23 entries instead of 22.

### Test model

The existing fixture (`test/fixtures/identity_float32.onnx`) has a float32
output and cannot exercise the new branches. A second fixture with a non-float32
output is required.

**Chosen approach — extend the existing pure-Dart emitter.** Generalise
`tool/generate_test_fixture.dart` so its `_typeProto` takes an element-type code
instead of hardcoding `elem_type = 1`, then emit `test/fixtures/identity_int64.onnx`:
a single-op identity model whose input and output are `int64` (`elem_type = 7`).
This reuses the zero-dependency Dart ONNX protobuf emitter that already produced
`identity_float32.onnx` — no Python toolchain is introduced. The resulting
`.onnx` binary is checked in so tests run without invoking the generator.

The test case: provide an `int64` identity input `[1, 2, 3, 4]`, assert the
output `elementType == OnnxElementType.int64`, and assert
`tensor.asInt64() == [1, 2, 3, 4]`.

`OnnxTensor` already has `asInt64()` but is missing `asUint8()`, `asInt32()`,
and `asFloat64()` typed accessors. Add them alongside `asInt64()` for
consistency with the documented API contract.

## Implementation plan

- [ ] **Slot 60 typedef** — add `GetTensorElementTypeC` / `GetTensorElementTypeDart`
  to `lib/src/ort_api.dart` with `// SLOT:GetTensorElementType=60` marker. Bind
  the `out` parameter as `Pointer<Int32>`, matching the existing slot-49
  binding of the same C enum (`ONNXTensorElementDataType`) — not `Uint32`.
  Update the slot-range comment ("slots 52–60") to mark `GetTensorElementType`
  as now bound.

- [ ] **Slot guard golden** — add `'GetTensorElementType': 60` to
  `_expectedSlotsV22` in `test/ort_slot_guard_test.dart`. Verify
  `make pre_commit` passes (the count assertion will update automatically).

- [ ] **Fix stale slot-35 comments** — update the three "slot 35" references in
  `session.dart`'s `_copyTensorData` docstring and inline comments to "slot 60".

- [ ] **Wire GetTensorElementType into the output loop** — in `session.dart`'s
  `run()` method, after `GetDimensions` and before `ReleaseTensorTypeAndShapeInfo`,
  call `GetTensorElementType(ttasi)` to obtain the raw type code. Pass it to
  `_copyTensorData`.

- [ ] **Fix `_copyTensorData`** — change the signature to accept the type code
  as a third argument. Use `OnnxElementType.fromOnnxTypeCode` to resolve the
  type, then branch on it to copy raw bytes into the correct `TypedData` subtype
  (`Float32List`, `Uint8List`, `Int32List`, `Int64List`, `Float64List`). Use
  `rawPtr.cast<T>()` and element-wise copy for each branch (same pattern as the
  existing float32 branch).

- [ ] **Add missing typed accessors** — add `asUint8()`, `asInt32()`, and
  `asFloat64()` to `OnnxTensor` in `tensor.dart`, mirroring the existing
  `asFloat32()` and `asInt64()` pattern.

- [ ] **Test fixture** — extend the existing pure-Dart
  `tool/generate_test_fixture.dart` so its `_typeProto` accepts an element-type
  code (parameterise the hardcoded `elem_type = 1`), then run it to emit
  `test/fixtures/identity_int64.onnx` (`int64`, `elem_type = 7`). Check the
  `.onnx` binary in. Do NOT add a Python generator.

- [ ] **Accessor unit tests** — in `test/tensor_test.dart`, add unit tests for
  the three new accessors (`asUint8`, `asInt32`, `asFloat64`), mirroring the
  existing `asFloat32`/`asInt64` tests: cover both the success path and the
  `StateError` path (accessor called on a tensor of the wrong element type).
  These are pure-Dart, run in every CI lane, and keep the new accessors above
  the 90% coverage gate without needing real ORT.

- [ ] **Copy-branch coverage** — ensure all five `_copyTensorData` branches
  (float32, uint8, int32, int64, float64) are exercised by tests, not just
  `int64`. Where a real-ORT inference fixture is impractical for a given type,
  cover the branch via a direct unit test against the copy logic so no branch
  is left uncovered. Coverage must stay above 90%.

- [ ] **Integration test** — add a test group `'OnnxSession — non-float32
  output'` to `test/onnx_session_test.dart`. Test: load `identity_int64.onnx`,
  run with an `int64` input, assert `elementType == OnnxElementType.int64` and
  `asInt64()` returns the correct values. Follows the same skip-if-no-ORT guard
  as existing session tests (so this runs with real ORT only on Linux/Windows
  CI and `make macos_test`, and skips under plain `dart test` on macOS).

- [ ] **Update spec** — edit the three concrete locations in
  `docs/spec/README.md` identified in Review 1:
  - §5.2 (`:218–221`) — the "Output element type (v0.1.0 constraint)"
    paragraph; remove the float32-only caveat and the stale "slot 35" reference,
    and document the full type mapping.
  - §5.3 (`:243–246`) — the typed-accessors code block currently lists only
    `asFloat32()` and `asInt64()`; add `asUint8()`, `asInt32()`, `asFloat64()`.
  - §8 (`:562–568`) — the "Output element type always float32" limitation
    section (also contains a stale "slot 35" reference and a "planned for
    v0.2.0" promise); delete it or rewrite it as resolved.

- [ ] **Update roadmap** — mark Goal 3 as 100% in `docs/roadmap/v0.md`.

- [ ] **Run `make pre_commit`** and verify all tests pass.

- [ ] **Submit PR** — include evidence of a passing `make macos_test` or
  `make linux_test` run in the PR description (new slot binding requires real
  load+inference evidence per CLAUDE.md policy).

## Reviews

### Review 1: 2026-06-12

**Problem Statement Assessment**

The problem is real, correctly diagnosed, and worth solving. I verified every
core claim against the source:

- `_copyTensorData` (`session.dart:558–574`) does unconditionally reinterpret
  raw bytes as `Float32List` and returns a hardcoded `OnnxElementType.float32`.
  Any non-float32 output silently returns garbage. Confirmed.
- The public API (`OnnxTensor`, `OnnxElementType.fromOnnxTypeCode`, the per-type
  doc table) already describes the correct behaviour, so this is purely an
  internal gap, as the plan states. Confirmed.
- This maps cleanly to roadmap Goal 3 (0% → done). Aligned.

This is exactly the kind of correctness bug that should be closed before
pub.dev publication — a model emitting `int64` class indices currently returns
silent wrong data behind a green test suite.

**Proposed Solution Assessment**

The technical core is sound and unusually well-investigated. Specifics I
verified:

- **Slot 60 is correct.** The plan's neighbour-offset argument holds: slots 49,
  51, 61, 62, 65, 69 are all bound and consistent, and the existing comment at
  `ort_api.dart:240–242` already lists `GetTensorElementType` within the unused
  52–60 range. The "slot 35" references the plan calls out are genuinely stale —
  they exist at `session.dart:549`, `557`, and `564`. Good catch; slot 35 is
  actually `SessionGetInputCount`, so the old comments were doubly wrong.
- **Slot guard impact is correctly scoped.** Adding `'GetTensorElementType': 60`
  to `_expectedSlotsV22` and the matching `// SLOT:` marker is all that is
  needed; the count assertion (currently 22) updates automatically to 23. The
  guard's three tests (presence, no-unexpected, count) will all stay green.
- **The call-site wiring is right.** `GetTensorElementType(ttasi)` must be
  called before `releaseTTASI(ttasi)` at `session.dart:444`, while the
  `OrtTensorTypeAndShapeInfo` handle is still live. The plan places it correctly.

Three issues, none fatal but all worth resolving before implementation (raised
as open questions):

1. **Test fixture toolchain — the one real misstep.** The plan proposes a new
   Python generator (`tool/gen_test_fixtures.py`, requiring the `onnx` package).
   But `tool/generate_test_fixture.dart` already exists and is a pure-Dart,
   dependency-free ONNX protobuf emitter — it is what produced
   `identity_float32.onnx`. Its `_typeProto` hardcodes `elem_type = 1`;
   parameterising that single value (int64 = `7`) is a trivial change that lets
   the existing Dart tool emit `identity_int64.onnx`. Introducing a second
   language and an external pip dependency for a job the repo already does in
   Dart is unnecessary tool sprawl and inconsistent with project conventions.
   Strongly recommend extending the Dart generator instead.

2. **FFI out-param width.** The plan specifies `Pointer<Uint32>`. The identical
   C enum is already bound as `Int32` at slot 49 (`CreateTensorC`). Use `Int32`
   for consistency; the value is small and non-negative so behaviour is
   identical, but mixed conventions for the same enum invite confusion.

3. **Coverage of new branches.** Five copy branches and three new accessors
   (`asUint8`, `asInt32`, `asFloat64`) are added, but only the `int64` path is
   exercised by an integration test. The other branches and accessors will be
   uncovered. `tensor_test.dart` already has `asFloat32`/`asInt64` accessor
   tests (including the `StateError` negative path) — mirror those for the three
   new accessors as cheap pure-Dart unit tests that run in every CI lane.

**Architecture Fit**

Excellent fit. No public API change, no new types, no layer-boundary impact —
this is `lib/src` core (pure Dart, no Flutter) throughout, so the
library-architecture layering is untouched. The change rides entirely on
existing patterns: the `(OnnxElementType, TypedData)` return tuple,
`fromOnnxTypeCode`, and `elementSizeInBytes` are all already in place. The
`_copyTensorData` branch can lean on `OnnxElementType.fromOnnxTypeCode` for the
unsupported-code `ArgumentError`, which `run`'s docstring already advertises
("Throws `ArgumentError` if any output tensor has an unsupported element type").

**Spec impact — the plan understates this.** The plan's spec step says "remove
any float32-only caveats", but there are concrete, enumerable locations that all
need editing, and the plan should list them so the implementer does not miss
any:

- §5.2, `docs/spec/README.md:218–221` — the "Output element type (v0.1.0
  constraint)" paragraph, including a stale "slot 35" reference.
- §5.3, `:243–246` — the typed-accessors code block lists only `asFloat32()`
  and `asInt64()`; add `asUint8()`, `asInt32()`, `asFloat64()`.
- §8, `:562–568` — the entire "Output element type always float32" limitation
  section, which also contains a stale "slot 35" reference and an explicit
  "planned for v0.2.0" promise. This section should be deleted (or rewritten as
  resolved), not just trimmed.

**Risk & Edge Cases**

- **CI coverage of the int64 path.** The new integration test inherits the
  existing `skip: ortAvailable ? false : _skipMessage` guard. That means it runs
  with real ORT only on Linux and Windows CI (and `make macos_test`), and skips
  under plain `dart test` on macOS. That is acceptable and consistent with the
  existing session tests, but the plan should state it explicitly so no one
  expects the int64 branch to be covered on a bare macOS `dart test` run.
- **PR evidence requirement.** This adds a slot binding, so CLAUDE.md /
  `ort_api.dart` policy requires evidence of a passing `make macos_test` or
  `make linux_test` in the PR. The plan correctly includes this — good.
- **Endianness / element width.** The element-wise copy loop the plan describes
  (`rawPtr.cast<T>()[i]`) is correct for all five types and matches the existing
  float32 branch. No concern.
- **Scalar / empty-shape outputs.** `elementCount` already handles the
  empty-shape (scalar) case via the `shape.isEmpty ? 1` fold at
  `session.dart:452`; the new branches reuse that count, so scalars are fine.

**Recommendations**

Proceed — the approach is correct and the slot-60 investigation is solid. Before
implementation, resolve the three open questions:

1. Reuse and extend `tool/generate_test_fixture.dart` rather than adding a
   Python generator (strongly recommended).
2. Bind the out-param as `Int32` to match slot 49.
3. Add `tensor_test.dart` unit tests for the three new accessors (both the
   success and `StateError` paths), and enumerate the three specific spec edits
   in the implementation checklist.

These are refinements, not blockers on the core design. I am moving the status
to `Questions` only because of the fixture-toolchain decision — it changes an
implementation step and a checked-in artifact, so it is worth an explicit
answer before work starts rather than discovering it mid-implementation.

**Open questions** (tracked in the top-level `## Open questions` section):

- [ ] Reuse the existing Dart fixture generator instead of adding Python?
- [ ] Bind the `GetTensorElementType` out-param as `Int32` (not `Uint32`)?
- [ ] How will the uint8/int32/float64 branches and new accessors reach the 90%
      coverage gate?

### Review 2: 2026-06-12

All three open questions from Review 1 have been answered by the user. The
answers adopt every Review 1 recommendation, so the plan is now technically
sound and ready for implementation.

**Decisions recorded**

1. **Test fixture toolchain** — extend the existing pure-Dart
   `tool/generate_test_fixture.dart` to emit an `int64` fixture. No Python
   dependency. This removes the one regression Review 1 flagged and keeps the
   fixture toolchain single-language and zero-dependency.
2. **FFI out-param width** — bind the `GetTensorElementType` out-param as
   `Pointer<Int32>`, matching the existing slot-49 binding of the same C enum.
3. **Test coverage** — add unit tests for all three new accessors (`asUint8`,
   `asInt32`, `asFloat64`), including the `StateError` paths, and cover all five
   `_copyTensorData` copy branches, not just `int64`. Coverage stays above 90%.

**Plan changes applied**

- Investigation "C API signature" and "Test model" subsections updated to
  reflect `Int32` and the Dart fixture tool.
- Implementation steps updated: slot-60 typedef now specifies `Int32`; the
  Python fixture step is replaced with a Dart-tool extension step; two new steps
  (accessor unit tests, copy-branch coverage) added; the integration-test step
  now states the skip-on-macOS-`dart test` behaviour explicitly.
- The spec step now enumerates the three concrete `docs/spec/README.md`
  locations (§5.2 `:218–221`, §5.3 `:243–246`, §8 `:562–568`) that must change.

**Recommendation**

Proceed to implementation. The slot-60 investigation was solid in Review 1, the
architecture fit is clean (pure-Dart `lib/src`, no public-API or layer-boundary
impact), and all three refinements are now locked in. No open questions remain.
Status set to `Investigated`.

**Open questions**

- [x] Reuse the existing Dart fixture generator instead of adding Python?
      _Decision: yes — extend `tool/generate_test_fixture.dart`._
- [x] Bind the `GetTensorElementType` out-param as `Int32` (not `Uint32`)?
      _Decision: yes — `Pointer<Int32>`, matching slot 49._
- [x] How will the uint8/int32/float64 branches and new accessors reach the 90%
      coverage gate? _Decision: pure-Dart accessor unit tests (success +
      `StateError`) plus direct coverage of all five copy branches._

## Summary

_To be completed after implementation._
