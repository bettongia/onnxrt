// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Versioned OrtApi vtable-slot FFI binding for ONNX Runtime.
///
/// All function pointers in the `OrtApi` struct are resolved by slot index
/// against the ORT C API version specified by [ortApiVersion]. Each slot
/// constant below is annotated with the ORT symbol name it corresponds to —
/// a version drift in the ORT header (`onnxruntime_c_api.h`) will produce a
/// noticeable mismatch that is easy to diagnose.
///
/// This file is the single source of truth for ORT versioning in
/// `betto_onnxrt`. To upgrade ORT:
/// 1. Update `VERSION_ONNX` and re-run `dart run tool/generate_versions.dart`.
/// 2. Verify the slot indices below still match the new header.
/// 3. Update `ortApiVersion` to the new API version constant.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ── Opaque handle types ───────────────────────────────────────────────────────

/// Opaque handle for the ORT environment.
final class OrtEnv extends Opaque {}

/// Opaque handle for an ORT inference session.
///
/// Note: [OrtSession] is the FFI *handle type*, not the Dart wrapper class.
/// The Dart session wrapper is [OnnxSession] in `session.dart`.
final class OrtSession extends Opaque {}

/// Opaque handle for ORT session configuration options.
final class OrtSessionOptions extends Opaque {}

/// Opaque handle for an ORT tensor value.
final class OrtValue extends Opaque {}

/// Opaque handle for an ORT status (error) object.
final class OrtStatus extends Opaque {}

/// Opaque handle for ORT memory info (allocator descriptor).
final class OrtMemoryInfo extends Opaque {}

/// Opaque handle for ORT tensor type and shape information.
final class OrtTensorTypeAndShapeInfo extends Opaque {}

// ── OrtApiBase: the one real exported symbol ──────────────────────────────────

// OrtApiBase* OrtGetApiBase()
typedef OrtGetApiBaseC = Pointer<Void> Function();
typedef OrtGetApiBaseDart = Pointer<Void> Function();

// slot 0 of OrtApiBase: const OrtApi* GetApi(uint32_t version)
typedef GetApiC = Pointer<Void> Function(Uint32);
typedef GetApiDart = Pointer<Void> Function(int);

// ── OrtApi vtable slot typedefs ───────────────────────────────────────────────
//
// Slot numbers match the field ORDER in `struct OrtApi` in
// `onnxruntime_c_api.h` for ORT API version 22 (ORT v1.22.x). Each slot
// is annotated with its corresponding symbol name. Slots that we do not call
// are noted inline but not bound to Dart typedef pairs.
//
// IMPORTANT: If you change ortApiVersion, re-verify all slot indices against
// the new onnxruntime_c_api.h header.

// slot 0: OrtStatus* CreateStatus(OrtErrorCode, const char*)
typedef CreateStatusC = Pointer<OrtStatus> Function(Int32, Pointer<Utf8>);
typedef CreateStatusDart = Pointer<OrtStatus> Function(int, Pointer<Utf8>);

// slot 1: OrtErrorCode GetErrorCode(const OrtStatus*)  [unused — not bound]
// slot 2: const char* GetErrorMessage(const OrtStatus*)
typedef GetErrorMessageC = Pointer<Utf8> Function(Pointer<OrtStatus>);
typedef GetErrorMessageDart = Pointer<Utf8> Function(Pointer<OrtStatus>);

// slot 3: OrtStatus* CreateEnv(OrtLoggingLevel, const char*, OrtEnv**)
typedef CreateEnvC =
    Pointer<OrtStatus> Function(Int32, Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);
typedef CreateEnvDart =
    Pointer<OrtStatus> Function(int, Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);

// slots 4–6: CreateEnvWithCustomLogger, EnableTelemetryEvents,
//            DisableTelemetryEvents  [all unused]

// slot 7: OrtStatus* CreateSession(const OrtEnv*, const char*, const OrtSessionOptions*, OrtSession**)
typedef CreateSessionC =
    Pointer<OrtStatus> Function(
      Pointer<OrtEnv>,
      Pointer<Utf8>,
      Pointer<OrtSessionOptions>,
      Pointer<Pointer<OrtSession>>,
    );
typedef CreateSessionDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtEnv>,
      Pointer<Utf8>,
      Pointer<OrtSessionOptions>,
      Pointer<Pointer<OrtSession>>,
    );

// slot 8: CreateSessionFromArray  [unused]

// slot 9: OrtStatus* Run(OrtSession*, const OrtRunOptions*, const char* const*, const OrtValue* const*, size_t, const char* const*, size_t, OrtValue**)
typedef RunC =
    Pointer<OrtStatus> Function(
      Pointer<OrtSession>,
      Pointer<Void>, // OrtRunOptions* (null = default)
      Pointer<Pointer<Utf8>>, // input_names
      Pointer<Pointer<OrtValue>>, // inputs
      Size, // input_count
      Pointer<Pointer<Utf8>>, // output_names
      Size, // output_count
      Pointer<Pointer<OrtValue>>, // outputs
    );
typedef RunDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtSession>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<OrtValue>>,
      int,
      Pointer<Pointer<Utf8>>,
      int,
      Pointer<Pointer<OrtValue>>,
    );

// slot 10: OrtStatus* CreateSessionOptions(OrtSessionOptions**)
typedef CreateSessionOptionsC =
    Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);
typedef CreateSessionOptionsDart =
    Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);

// slots 11–23: various functions we don't use

// slot 24: OrtStatus* SetIntraOpNumThreads(OrtSessionOptions*, int)
// Forces single-threaded intra-op execution, avoiding thread-pool teardown
// races when ORT is invoked from a single Dart isolate.
typedef SetIntraOpNumThreadsC =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, Int32);
typedef SetIntraOpNumThreadsDart =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, int);

// slot 25: OrtStatus* SetInterOpNumThreads(OrtSessionOptions*, int)
typedef SetInterOpNumThreadsC =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, Int32);
typedef SetInterOpNumThreadsDart =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, int);

// slots 26–30: various functions we don't use

// ── Output-shape readback slots (added for generic OnnxSession) ──────────────

// slot 31: OrtStatus* GetTensorTypeAndShapeInfo(const OrtValue*, OrtTensorTypeAndShapeInfo**)
// Obtains the type-and-shape info handle for a tensor OrtValue.
typedef GetTensorTypeAndShapeInfoC =
    Pointer<OrtStatus> Function(
      Pointer<OrtValue>,
      Pointer<Pointer<OrtTensorTypeAndShapeInfo>>,
    );
typedef GetTensorTypeAndShapeInfoDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtValue>,
      Pointer<Pointer<OrtTensorTypeAndShapeInfo>>,
    );

// slot 32: OrtStatus* GetDimensionsCount(const OrtTensorTypeAndShapeInfo*, size_t*)
// Returns the number of dimensions of the tensor.
typedef GetDimensionsCountC =
    Pointer<OrtStatus> Function(
      Pointer<OrtTensorTypeAndShapeInfo>,
      Pointer<Size>,
    );
typedef GetDimensionsCountDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtTensorTypeAndShapeInfo>,
      Pointer<Size>,
    );

// slot 33: OrtStatus* GetDimensions(const OrtTensorTypeAndShapeInfo*, int64_t* dim_values, size_t dim_values_length)
// Fills [dim_values] with the size of each dimension.
typedef GetDimensionsC =
    Pointer<OrtStatus> Function(
      Pointer<OrtTensorTypeAndShapeInfo>,
      Pointer<Int64>,
      Size,
    );
typedef GetDimensionsDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtTensorTypeAndShapeInfo>,
      Pointer<Int64>,
      int,
    );

// slot 34: GetSymbolicDimensions  [unused]
// slot 35: GetTensorElementType  [unused — we use the type from OnnxElementType]

// slots 36–48: various functions we don't use

// slot 49: OrtStatus* CreateTensorWithDataAsOrtValue(const OrtMemoryInfo*, void*, size_t, const int64_t*, size_t, ONNXTensorElementDataType, OrtValue**)
typedef CreateTensorC =
    Pointer<OrtStatus> Function(
      Pointer<OrtMemoryInfo>,
      Pointer<Void>,
      Size,
      Pointer<Int64>,
      Size,
      Int32,
      Pointer<Pointer<OrtValue>>,
    );
typedef CreateTensorDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtMemoryInfo>,
      Pointer<Void>,
      int,
      Pointer<Int64>,
      int,
      int,
      Pointer<Pointer<OrtValue>>,
    );

// slot 50: IsTensor  [unused]

// slot 51: OrtStatus* GetTensorMutableData(OrtValue*, void**)
typedef GetTensorMutableDataC =
    Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);
typedef GetTensorMutableDataDart =
    Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);

// slots 52–68: various functions we don't use

// slot 69: OrtStatus* CreateCpuMemoryInfo(enum OrtAllocatorType, enum OrtMemType, OrtMemoryInfo**)
typedef CreateMemoryInfoC =
    Pointer<OrtStatus> Function(Int32, Int32, Pointer<Pointer<OrtMemoryInfo>>);
typedef CreateMemoryInfoDart =
    Pointer<OrtStatus> Function(int, int, Pointer<Pointer<OrtMemoryInfo>>);

// slots 70–91: various functions we don't use

// Release functions (return void, not OrtStatus*)
// slot 92: void ReleaseEnv(OrtEnv*)
typedef ReleaseEnvC = Void Function(Pointer<OrtEnv>);
typedef ReleaseEnvDart = void Function(Pointer<OrtEnv>);

// slot 93: void ReleaseStatus(OrtStatus*)
typedef ReleaseStatusC = Void Function(Pointer<OrtStatus>);
typedef ReleaseStatusDart = void Function(Pointer<OrtStatus>);

// slot 94: void ReleaseMemoryInfo(OrtMemoryInfo*)
typedef ReleaseMemoryInfoC = Void Function(Pointer<OrtMemoryInfo>);
typedef ReleaseMemoryInfoDart = void Function(Pointer<OrtMemoryInfo>);

// slot 95: void ReleaseSession(OrtSession*)
typedef ReleaseSessionC = Void Function(Pointer<OrtSession>);
typedef ReleaseSessionDart = void Function(Pointer<OrtSession>);

// slot 96: void ReleaseValue(OrtValue*)
typedef ReleaseValueC = Void Function(Pointer<OrtValue>);
typedef ReleaseValueDart = void Function(Pointer<OrtValue>);

// slot 97: ReleaseRunOptions  [unused]
// slots 98–99: various functions we don't use

// slot 100: void ReleaseSessionOptions(OrtSessionOptions*)
typedef ReleaseSessionOptionsC = Void Function(Pointer<OrtSessionOptions>);
typedef ReleaseSessionOptionsDart = void Function(Pointer<OrtSessionOptions>);

// slot 101: ReleaseTensorTypeAndShapeInfo — note: OrtTensorTypeAndShapeInfo is
// released differently; call GetTensorTypeAndShapeInfo, use it, then Release.
typedef ReleaseTensorTypeAndShapeInfoC =
    Void Function(Pointer<OrtTensorTypeAndShapeInfo>);
typedef ReleaseTensorTypeAndShapeInfoDart =
    void Function(Pointer<OrtTensorTypeAndShapeInfo>);

// ── ONNX tensor element type constants ───────────────────────────────────────
//
// Values of `ONNXTensorElementDataType` from onnxruntime_c_api.h.
// Used both to construct input tensors and to interpret output tensor types.
// See [OnnxElementType] in tensor.dart for the public Dart enum mapping.

/// ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT (float32).
const int onnxElementTypeFloat32 = 1;

/// ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8.
const int onnxElementTypeUint8 = 2;

/// ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32.
const int onnxElementTypeInt32 = 6;

/// ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64.
const int onnxElementTypeInt64 = 7;

/// ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE (float64).
const int onnxElementTypeFloat64 = 11;

// ── Logging and allocator constants ──────────────────────────────────────────

/// OrtLoggingLevel: ORT_LOGGING_LEVEL_WARNING (suppress info-level noise).
const int ortLoggingWarning = 2;

/// OrtAllocatorType: OrtDeviceAllocator.
const int ortDeviceAllocator = 0;

/// OrtMemType: OrtMemTypeCPUInput.
const int ortMemTypeCpuInput = -2;

// ── API version ───────────────────────────────────────────────────────────────

/// The ORT API version this binding targets.
///
/// This must match the library version downloaded by [hook/build.dart].
/// ORT v1.22.x ships API version 22. Passing this to `OrtApiBase.GetApi`
/// returns the [OrtApi] pointer for the vtable slots above.
const int ortApiVersion = 22; // ORT 1.22.x

// ── Vtable slot helper ────────────────────────────────────────────────────────

/// Reads one function-pointer slot from an OrtApi struct and returns a typed
/// native function pointer.
///
/// [struct] must point to the start of the `OrtApi` vtable.
/// [slotIndex] is the zero-based index of the desired function pointer.
///
/// Slots are resolved lazily at first use rather than eagerly at
/// [OrtSession.create] time so that unused slots carry no cost.
Pointer<NativeFunction<T>> ortSlotPtr<T extends Function>(
  Pointer<Void> struct,
  int slotIndex,
) => (struct.cast<Pointer<NativeFunction<T>>>() + slotIndex).value;
