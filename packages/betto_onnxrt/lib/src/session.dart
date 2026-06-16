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

/// [OnnxSession] — generalised ONNX Runtime inference session.
///
/// Wraps the OrtApi C vtable via numeric slot indices. Each slot index is
/// annotated with the ORT symbol name so that version drift is detectable.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ort_api.dart';
import 'tensor.dart';

/// A thin FFI wrapper around an ONNX Runtime inference session.
///
/// Supports arbitrary input/output names and element types — unlike the
/// BGE-specific `OrtInferenceSession` it replaces in `kmdb_inferencing`,
/// this class is not shaped for a particular model.
///
/// ## Lifecycle
///
/// 1. Obtain an [OnnxSession] via [OnnxRuntime.createSession] or
///    [OnnxRuntime.createSessionFromFile] — do not call [create] directly.
/// 2. Call [run] one or more times.
/// 3. Call [dispose] exactly once when finished.
///
/// ## Thread safety
///
/// **Thread-affine.** All calls to [run] and [dispose] must come from the
/// same Dart isolate that created the session. Calling [run] or [dispose] from
/// a different isolate can corrupt ORT's internal thread-pool mutex state and
/// produce undefined behaviour (crash or silent wrong output). If you need
/// isolate-based parallelism, create a fresh [OnnxRuntime] (and therefore a
/// fresh ORT environment) inside each isolate.
///
/// ## Input / output model
///
/// [run] accepts a `Map<String, OnnxTensor>` of named inputs and a
/// `List<String>` of requested output names. It returns a `List<OnnxTensor>`
/// in the same order as [outputNames]. Each output tensor's [OnnxTensor.shape]
/// is read from the native OrtValue using the output-shape-readback slots
/// (65 = GetTensorTypeAndShape, 61 = GetDimensionsCount, 62 = GetDimensions)
/// in `ort_api.dart`.
final class OnnxSession {
  final Pointer<OrtSession> _session;
  final Pointer<OrtMemoryInfo> _memInfo;
  final Pointer<OrtEnv> _env;

  /// Retained pointer to the OrtApi vtable for deferred function binding.
  final Pointer<Void> _api;

  OnnxSession._(this._session, this._memInfo, this._env, this._api);

  // ── Factory ────────────────────────────────────────────────────────────────

  /// Creates an ORT inference session from [modelBytes].
  ///
  /// [api] must be the OrtApi vtable pointer from [OnnxRuntime.ortApi].
  /// [modelBytes] must be the binary content of a valid `.onnx` file.
  /// [options] controls thread-pool sizing (defaults: both counts = 1).
  ///
  /// Throws [Exception] if the ORT API version is incompatible or the model
  /// cannot be parsed.
  ///
  /// Internal — callers should use [OnnxRuntime.createSession].
  static OnnxSession createFromBytes(
    Pointer<Void> api,
    Uint8List modelBytes, {
    SessionOptions? options,
  }) {
    final opts = options ?? const SessionOptions();
    return using((arena) {
      // ── Step 1: error-handling helpers ─────────────────────────────────────
      final getErrorMessage = ortSlotPtr<GetErrorMessageC>(
        api,
        2,
      ).asFunction<GetErrorMessageDart>();
      final releaseStatus = ortSlotPtr<ReleaseStatusC>(
        api,
        93,
      ).asFunction<ReleaseStatusDart>();
      final releaseEnv = ortSlotPtr<ReleaseEnvC>(
        api,
        92,
      ).asFunction<ReleaseEnvDart>();
      final releaseOpts = ortSlotPtr<ReleaseSessionOptionsC>(
        api,
        100,
      ).asFunction<ReleaseSessionOptionsDart>();

      var env = nullptr.cast<OrtEnv>();
      var sessionOpts = nullptr.cast<OrtSessionOptions>();

      void check(Pointer<OrtStatus> status) {
        if (status == nullptr) return;
        final msg = getErrorMessage(status).toDartString();
        releaseStatus(status);
        if (sessionOpts != nullptr) releaseOpts(sessionOpts);
        if (env != nullptr) releaseEnv(env);
        throw Exception('ONNX Runtime: $msg');
      }

      // ── Step 2: create ORT environment (slot 3: CreateEnv) ─────────────────
      final createEnv = ortSlotPtr<CreateEnvC>(
        api,
        3,
      ).asFunction<CreateEnvDart>();
      final envPtr = arena<Pointer<OrtEnv>>();
      check(
        createEnv(
          ortLoggingWarning,
          'betto_onnxrt'.toNativeUtf8(allocator: arena),
          envPtr,
        ),
      );
      env = envPtr.value;

      // ── Step 3: create session options (slot 10: CreateSessionOptions) ─────
      final createOpts = ortSlotPtr<CreateSessionOptionsC>(
        api,
        10,
      ).asFunction<CreateSessionOptionsDart>();
      final optsPtr = arena<Pointer<OrtSessionOptions>>();
      check(createOpts(optsPtr));
      sessionOpts = optsPtr.value;

      // Apply thread-pool sizing from SessionOptions.
      // Defaulting to 1 preserves teardown-safe behaviour per Q6 in the plan.
      final setIntra = ortSlotPtr<SetIntraOpNumThreadsC>(
        api,
        24,
      ).asFunction<SetIntraOpNumThreadsDart>();
      final setInter = ortSlotPtr<SetInterOpNumThreadsC>(
        api,
        25,
      ).asFunction<SetInterOpNumThreadsDart>();
      check(setIntra(sessionOpts, opts.intraOpNumThreads));
      check(setInter(sessionOpts, opts.interOpNumThreads));

      // ── Step 4: load model from bytes (slot 8: CreateSessionFromArray) ─────
      // Using CreateSessionFromArray avoids writing a temp file and prevents
      // any platform-specific issues with file lifecycle vs. ORT model loading
      // (e.g. lazy mmap on Android).
      final createSessionFromArray = ortSlotPtr<CreateSessionFromArrayC>(
        api,
        8,
      ).asFunction<CreateSessionFromArrayDart>();
      final nativeBytes = arena<Uint8>(modelBytes.length);
      for (var i = 0; i < modelBytes.length; i++) {
        nativeBytes[i] = modelBytes[i];
      }
      final sessPtr = arena<Pointer<OrtSession>>();
      check(
        createSessionFromArray(
          env,
          nativeBytes.cast<Void>(),
          modelBytes.length,
          sessionOpts,
          sessPtr,
        ),
      );

      // ── Step 5: create CPU memory info (slot 69: CreateCpuMemoryInfo) ──────
      // This allocator descriptor is reused for every input tensor in run().
      final createMem = ortSlotPtr<CreateMemoryInfoC>(
        api,
        69,
      ).asFunction<CreateMemoryInfoDart>();
      final memPtr = arena<Pointer<OrtMemoryInfo>>();
      check(createMem(ortDeviceAllocator, ortMemTypeCpuInput, memPtr));

      // Release session options — no longer needed after CreateSessionFromArray.
      releaseOpts(sessionOpts);
      sessionOpts = nullptr.cast<OrtSessionOptions>();

      return OnnxSession._(sessPtr.value, memPtr.value, env, api);
    });
  }

  /// Opens [modelPath] and creates an ORT inference session.
  ///
  /// [api] must be the OrtApi vtable pointer from [OnnxRuntime.ortApi].
  /// [modelPath] must be the absolute path to a valid `.onnx` file.
  /// [options] controls thread-pool sizing (defaults: both counts = 1).
  ///
  /// Throws [Exception] if the ORT API version is incompatible or the model
  /// file cannot be loaded.
  ///
  /// Internal — callers should use [OnnxRuntime.createSessionFromFile].
  static OnnxSession create(
    Pointer<Void> api,
    String modelPath, {
    SessionOptions? options,
  }) {
    final opts = options ?? const SessionOptions();
    return using((arena) {
      // ── Step 1: error-handling helpers ─────────────────────────────────────
      final getErrorMessage = ortSlotPtr<GetErrorMessageC>(
        api,
        2,
      ).asFunction<GetErrorMessageDart>();
      final releaseStatus = ortSlotPtr<ReleaseStatusC>(
        api,
        93,
      ).asFunction<ReleaseStatusDart>();
      final releaseEnv = ortSlotPtr<ReleaseEnvC>(
        api,
        92,
      ).asFunction<ReleaseEnvDart>();
      final releaseOpts = ortSlotPtr<ReleaseSessionOptionsC>(
        api,
        100,
      ).asFunction<ReleaseSessionOptionsDart>();

      var env = nullptr.cast<OrtEnv>();
      var sessionOpts = nullptr.cast<OrtSessionOptions>();

      void check(Pointer<OrtStatus> status) {
        if (status == nullptr) return;
        final msg = getErrorMessage(status).toDartString();
        releaseStatus(status);
        if (sessionOpts != nullptr) releaseOpts(sessionOpts);
        if (env != nullptr) releaseEnv(env);
        throw Exception('ONNX Runtime: $msg');
      }

      // ── Step 2: create ORT environment (slot 3: CreateEnv) ─────────────────
      final createEnv = ortSlotPtr<CreateEnvC>(
        api,
        3,
      ).asFunction<CreateEnvDart>();
      final envPtr = arena<Pointer<OrtEnv>>();
      check(
        createEnv(
          ortLoggingWarning,
          'betto_onnxrt'.toNativeUtf8(allocator: arena),
          envPtr,
        ),
      );
      env = envPtr.value;

      // ── Step 3: create session options (slot 10: CreateSessionOptions) ─────
      final createOpts = ortSlotPtr<CreateSessionOptionsC>(
        api,
        10,
      ).asFunction<CreateSessionOptionsDart>();
      final optsPtr = arena<Pointer<OrtSessionOptions>>();
      check(createOpts(optsPtr));
      sessionOpts = optsPtr.value;

      final setIntra = ortSlotPtr<SetIntraOpNumThreadsC>(
        api,
        24,
      ).asFunction<SetIntraOpNumThreadsDart>();
      final setInter = ortSlotPtr<SetInterOpNumThreadsC>(
        api,
        25,
      ).asFunction<SetInterOpNumThreadsDart>();
      check(setIntra(sessionOpts, opts.intraOpNumThreads));
      check(setInter(sessionOpts, opts.interOpNumThreads));

      // ── Step 4: load model file (slot 7: CreateSession) ────────────────────
      final createSession = ortSlotPtr<CreateSessionC>(
        api,
        7,
      ).asFunction<CreateSessionDart>();
      final sessPtr = arena<Pointer<OrtSession>>();
      check(
        createSession(
          env,
          Platform.isWindows
              ? modelPath.toNativeUtf16(allocator: arena).cast<Void>()
              : modelPath.toNativeUtf8(allocator: arena).cast<Void>(),
          sessionOpts,
          sessPtr,
        ),
      );

      // ── Step 5: create CPU memory info (slot 69: CreateCpuMemoryInfo) ──────
      final createMem = ortSlotPtr<CreateMemoryInfoC>(
        api,
        69,
      ).asFunction<CreateMemoryInfoDart>();
      final memPtr = arena<Pointer<OrtMemoryInfo>>();
      check(createMem(ortDeviceAllocator, ortMemTypeCpuInput, memPtr));

      releaseOpts(sessionOpts);
      sessionOpts = nullptr.cast<OrtSessionOptions>();

      return OnnxSession._(sessPtr.value, memPtr.value, env, api);
    });
  }

  // ── Inference ──────────────────────────────────────────────────────────────

  /// Runs inference and returns the requested output tensors.
  ///
  /// [inputs] maps input tensor names to [OnnxTensor] values. Each tensor
  /// must have the element type and shape expected by the loaded model.
  ///
  /// [outputNames] lists the names of tensors to return, in order. The
  /// returned list has the same length and ordering as [outputNames].
  ///
  /// Each output [OnnxTensor] has its [OnnxTensor.shape] populated from the
  /// native output via `GetTensorTypeAndShapeInfo` / `GetDimensionsCount` /
  /// `GetDimensions` (vtable slots 65/61/62). This allows callers to reshape
  /// output data without knowing the model's output shape in advance.
  ///
  /// All native [OrtValue] handles are released before returning.
  ///
  /// Throws [Exception] if any ORT call fails.
  /// Throws [ArgumentError] if any output tensor has an unsupported element type.
  List<OnnxTensor> run({
    required Map<String, OnnxTensor> inputs,
    required List<String> outputNames,
  }) {
    return using((arena) {
      // ── Bind vtable slots used in this call ─────────────────────────────────
      final getErrorMessage = ortSlotPtr<GetErrorMessageC>(
        _api,
        2,
      ).asFunction<GetErrorMessageDart>();
      final releaseStatus = ortSlotPtr<ReleaseStatusC>(
        _api,
        93,
      ).asFunction<ReleaseStatusDart>();

      void check(Pointer<OrtStatus> s) {
        if (s == nullptr) return;
        final msg = getErrorMessage(s).toDartString();
        releaseStatus(s);
        throw Exception('ONNX Runtime: $msg');
      }

      final createTensor = ortSlotPtr<CreateTensorC>(
        _api,
        49,
      ).asFunction<CreateTensorDart>();
      final runFn = ortSlotPtr<RunC>(_api, 9).asFunction<RunDart>();
      final getTensorData = ortSlotPtr<GetTensorMutableDataC>(
        _api,
        51,
      ).asFunction<GetTensorMutableDataDart>();
      final releaseValue = ortSlotPtr<ReleaseValueC>(
        _api,
        96,
      ).asFunction<ReleaseValueDart>();
      // Output-shape readback slots (verified against ORT v1.22.0 header).
      final getTypeShape = ortSlotPtr<GetTensorTypeAndShapeC>(
        _api,
        65,
      ).asFunction<GetTensorTypeAndShapeDart>();
      final getDimCount = ortSlotPtr<GetDimensionsCountC>(
        _api,
        61,
      ).asFunction<GetDimensionsCountDart>();
      final getDims = ortSlotPtr<GetDimensionsC>(
        _api,
        62,
      ).asFunction<GetDimensionsDart>();
      final releaseTTASI = ortSlotPtr<ReleaseTensorTypeAndShapeInfoC>(
        _api,
        99,
      ).asFunction<ReleaseTensorTypeAndShapeInfoDart>();
      // GetTensorElementType (slot 60): reads the ONNXTensorElementDataType
      // from an OrtTensorTypeAndShapeInfo handle. Must be called before
      // ReleaseTensorTypeAndShapeInfo while the handle is still live.
      final getElementType = ortSlotPtr<GetTensorElementTypeC>(
        _api,
        60,
      ).asFunction<GetTensorElementTypeDart>();

      final inputNames = inputs.keys.toList();
      final inputTensors = inputs.values.toList();

      // ── Build input OrtValues ────────────────────────────────────────────────
      final inputValPtrs = arena<Pointer<OrtValue>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        final tensor = inputTensors[i];
        _createOrtValue(
          arena: arena,
          createTensor: createTensor,
          check: check,
          tensor: tensor,
          outPtr: inputValPtrs + i,
        );
      }

      // ── Build C-string arrays for names ──────────────────────────────────────
      final inNamePtrs = arena<Pointer<Utf8>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        inNamePtrs[i] = inputNames[i].toNativeUtf8(allocator: arena);
      }
      final outNamePtrs = arena<Pointer<Utf8>>(outputNames.length);
      for (var i = 0; i < outputNames.length; i++) {
        outNamePtrs[i] = outputNames[i].toNativeUtf8(allocator: arena);
      }

      // ── Run inference (slot 9: Run) ──────────────────────────────────────────
      final outputValPtrs = arena<Pointer<OrtValue>>(outputNames.length);
      check(
        runFn(
          _session,
          nullptr, // OrtRunOptions — null means use defaults
          inNamePtrs,
          inputValPtrs,
          inputNames.length,
          outNamePtrs,
          outputNames.length,
          outputValPtrs,
        ),
      );

      // ── Extract output tensors ───────────────────────────────────────────────
      final results = <OnnxTensor>[];
      for (var i = 0; i < outputNames.length; i++) {
        final outVal = outputValPtrs[i];

        // Read the output shape via GetTensorTypeAndShapeInfo (slot 65).
        final ttasiPtr = arena<Pointer<OrtTensorTypeAndShapeInfo>>();
        check(getTypeShape(outVal, ttasiPtr));
        final ttasi = ttasiPtr.value;

        // GetDimensionsCount (slot 61): number of dimensions.
        final dimCountPtr = arena<Size>();
        check(getDimCount(ttasi, dimCountPtr));
        final dimCount = dimCountPtr.value;

        // GetDimensions (slot 62): dimension sizes as int64 array.
        final dimBuf = arena<Int64>(dimCount);
        check(getDims(ttasi, dimBuf, dimCount));
        final shape = List<int>.generate(dimCount, (d) => dimBuf[d]);

        // GetTensorElementType (slot 60): read the element type before
        // releasing the type-shape handle (ttasi must still be live).
        final typeCodePtr = arena<Int32>();
        check(getElementType(ttasi, typeCodePtr));
        final onnxTypeCode = typeCodePtr.value;

        // Release the type-shape info handle.
        releaseTTASI(ttasi);

        // GetTensorMutableData (slot 51): pointer to raw tensor bytes.
        final rawPtr = arena<Pointer<Void>>();
        check(getTensorData(outVal, rawPtr));

        // Copy data from native memory into a Dart TypedData.
        // We must copy (not view) because the OrtValue will be released.
        final elementCount = shape.isEmpty ? 1 : shape.fold(1, (a, b) => a * b);
        final tensorData = _copyTensorData(
          rawPtr.value,
          elementCount,
          onnxTypeCode,
        );

        results.add(
          OnnxTensor(
            elementType: tensorData.$1,
            shape: shape,
            data: tensorData.$2,
          ),
        );

        releaseValue(outVal);
      }

      // Release input OrtValues.
      for (var i = 0; i < inputNames.length; i++) {
        releaseValue(inputValPtrs[i]);
      }

      return results;
    });
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  /// Releases the native ORT session, memory info, and environment handles.
  ///
  /// Must be called exactly once. After [dispose], [run] must not be called.
  void dispose() {
    final releaseSession = ortSlotPtr<ReleaseSessionC>(
      _api,
      95,
    ).asFunction<ReleaseSessionDart>();
    final releaseMem = ortSlotPtr<ReleaseMemoryInfoC>(
      _api,
      94,
    ).asFunction<ReleaseMemoryInfoDart>();
    final releaseEnv = ortSlotPtr<ReleaseEnvC>(
      _api,
      92,
    ).asFunction<ReleaseEnvDart>();

    releaseSession(_session);
    releaseMem(_memInfo);
    releaseEnv(_env);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Allocates and populates an OrtValue from [tensor] into [outPtr].
  ///
  /// The native buffer is allocated via [arena] and remains valid for the
  /// duration of the `using` block that owns the arena.
  void _createOrtValue({
    required Arena arena,
    required CreateTensorDart createTensor,
    required void Function(Pointer<OrtStatus>) check,
    required OnnxTensor tensor,
    required Pointer<Pointer<OrtValue>> outPtr,
  }) {
    final data = tensor.data;
    final elementCount = tensor.elementCount;
    final byteCount = elementCount * tensor.elementType.elementSizeInBytes;

    // Allocate native memory and copy tensor data into it.
    final nativeData = arena<Uint8>(byteCount);
    final srcBytes = data.buffer.asUint8List(data.offsetInBytes, byteCount);
    for (var b = 0; b < byteCount; b++) {
      nativeData[b] = srcBytes[b];
    }

    // Build the shape array.
    final shapePtr = arena<Int64>(tensor.shape.length);
    for (var d = 0; d < tensor.shape.length; d++) {
      shapePtr[d] = tensor.shape[d];
    }

    check(
      createTensor(
        _memInfo,
        nativeData.cast<Void>(),
        byteCount,
        shapePtr,
        tensor.shape.length,
        tensor.elementType.onnxTypeCode,
        outPtr,
      ),
    );
  }

  /// Reads [elementCount] elements from [rawPtr] and returns a
  /// `(OnnxElementType, TypedData)` pair.
  ///
  /// [onnxTypeCode] is the raw `ONNXTensorElementDataType` value obtained from
  /// `GetTensorElementType` (slot 60) on the output tensor's
  /// `OrtTensorTypeAndShapeInfo`. The code is resolved to an [OnnxElementType]
  /// via [OnnxElementType.fromOnnxTypeCode], then the raw bytes are copied into
  /// the appropriate [TypedData] subtype.
  ///
  /// The data is **copied** from native memory into a Dart [TypedData] buffer
  /// before the OrtValue handle is released.
  ///
  /// Throws [ArgumentError] (propagated from [OnnxElementType.fromOnnxTypeCode])
  /// if [onnxTypeCode] is not one of the five supported element types.
  (OnnxElementType, TypedData) _copyTensorData(
    Pointer<Void> rawPtr,
    int elementCount,
    int onnxTypeCode,
  ) {
    // Resolve the raw ORT type code to the Dart enum. fromOnnxTypeCode throws
    // ArgumentError for unsupported codes — run() propagates this to the caller.
    final elementType = OnnxElementType.fromOnnxTypeCode(onnxTypeCode);

    // Copy raw native memory into the appropriate Dart TypedData subtype.
    // Element-wise copy (rawPtr.cast<T>()[i]) is safe for all five types and
    // matches the endianness of the native ORT output buffer (host byte order).
    switch (elementType) {
      case OnnxElementType.float32:
        final src = rawPtr.cast<Float>();
        final result = Float32List(elementCount);
        for (var i = 0; i < elementCount; i++) {
          result[i] = src[i];
        }
        return (OnnxElementType.float32, result);

      case OnnxElementType.uint8:
        final src = rawPtr.cast<Uint8>();
        final result = Uint8List(elementCount);
        for (var i = 0; i < elementCount; i++) {
          result[i] = src[i];
        }
        return (OnnxElementType.uint8, result);

      case OnnxElementType.int32:
        final src = rawPtr.cast<Int32>();
        final result = Int32List(elementCount);
        for (var i = 0; i < elementCount; i++) {
          result[i] = src[i];
        }
        return (OnnxElementType.int32, result);

      case OnnxElementType.int64:
        final src = rawPtr.cast<Int64>();
        final result = Int64List(elementCount);
        for (var i = 0; i < elementCount; i++) {
          result[i] = src[i];
        }
        return (OnnxElementType.int64, result);

      case OnnxElementType.float64:
        final src = rawPtr.cast<Double>();
        final result = Float64List(elementCount);
        for (var i = 0; i < elementCount; i++) {
          result[i] = src[i];
        }
        return (OnnxElementType.float64, result);
    }
  }
}
