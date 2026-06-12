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

_None — investigation complete._

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
no additional handle is needed. `out` is a 32-bit enum value; use `Pointer<Uint32>`
in the Dart FFI typedef.

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

**Chosen approach — check in a pre-built binary, document it with a generator
script.** Create `tool/gen_test_fixtures.py` (Python 3, requires `onnx`
package) that generates `test/fixtures/identity_int64.onnx`: a single-op
identity model whose input and output are `int64`. The script is checked in
as documentation. The resulting `.onnx` binary (~500 bytes) is also checked in
so tests run without Python.

The test case: provide an `int64` identity input `[1, 2, 3, 4]`, assert the
output `elementType == OnnxElementType.int64`, and assert
`tensor.asInt64() == [1, 2, 3, 4]`.

`OnnxTensor` already has `asInt64()` but is missing `asUint8()`, `asInt32()`,
and `asFloat64()` typed accessors. Add them alongside `asInt64()` for
consistency with the documented API contract.

## Implementation plan

- [ ] **Slot 60 typedef** — add `GetTensorElementTypeC` / `GetTensorElementTypeDart`
  to `lib/src/ort_api.dart` with `// SLOT:GetTensorElementType=60` marker.
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

- [ ] **Test fixture** — create `tool/gen_test_fixtures.py` and run it to
  produce `test/fixtures/identity_int64.onnx`. Check both files in.

- [ ] **Integration test** — add a test group `'OnnxSession — non-float32
  output'` to `test/onnx_session_test.dart`. Test: load `identity_int64.onnx`,
  run with an `int64` input, assert `elementType == OnnxElementType.int64` and
  `asInt64()` returns the correct values. Follows the same skip-if-no-ORT guard
  as existing session tests.

- [ ] **Update spec** — update `docs/spec/README.md` output-tensor section to
  document the full type mapping and remove any "float32 only" caveats.

- [ ] **Update roadmap** — mark Goal 3 as 100% in `docs/roadmap/v0.md`.

- [ ] **Run `make pre_commit`** and verify all tests pass.

- [ ] **Submit PR** — include evidence of a passing `make macos_test` or
  `make linux_test` run in the PR description (new slot binding requires real
  load+inference evidence per CLAUDE.md policy).

## Reviews

_None yet._

## Summary

_To be completed after implementation._
