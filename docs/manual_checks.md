# Manual Smoke Checklist — Flutter Desktop (Linux and Windows)

Flutter Desktop on Linux and Windows is out of scope for v0 automated CI.
This checklist provides the detail needed for a non-automated check to be
trustworthy.

## Scope

This checklist covers the Flutter Desktop build of `integration_test_app` on
Linux and Windows — the path that exercises:

- ORT dynamic library loading via Flutter's native-assets bundling
- Full inference using the `identity_float32.onnx` fixture

**Pure-Dart inference** (no Flutter) on Linux and Windows is already exercised
automatically in CI via `cicd_linux` / `cicd_windows`. The targets
`make linux_test` and `make windows_test` are available for isolated
local inference runs on these platforms.

## Prerequisites

1. Flutter **stable** channel. Record the exact version:
   ```
   flutter --version
   ```
   Example output to record: `Flutter 3.32.x • channel stable • ...`

2. Desktop toolchain installed and verified:
   - **Linux**: `flutter doctor` shows no issues for Linux Desktop.
   - **Windows**: `flutter doctor` shows no issues for Desktop (Win32).

3. ORT binary staged — run from the repo root:
   ```
   dart pub get
   ```
   This triggers the native-assets hook and downloads the ORT binary to
   `.dart_tool/betto_onnxrt/{version}/`.

## Commands

From the repo root:

**Linux:**
```bash
cd integration_test_app
flutter pub get
flutter test integration_test/onnxrt_test.dart --device-id linux
```

**Windows:**
```powershell
cd integration_test_app
flutter pub get
flutter test integration_test/onnxrt_test.dart --device-id windows
```

## Load-verification step

Passing the test runner is necessary but not sufficient — confirm that ORT
actually loaded and was not silently skipped. Check the test output for:

1. **No skip messages**: lines like `Skip: ORT binary not staged` indicate the
   ORT binary was not found and the inference tests were bypassed. This is a
   failure even if the overall test count shows 0 failures.

2. **Inference assertions ran**: the output should include lines similar to:
   ```
   +N: OnnxSession — identity model run() returns one float32 output tensor ...
   ```
   If those lines are absent (or show as skipped), ORT did not load.

3. **dart test exit code**: record the exit code explicitly:
   ```bash
   echo "exit code: $?"   # Linux/macOS
   echo "exit code: %ERRORLEVEL%"  # Windows cmd
   ```

## Failure signatures

If ORT fails to load, the most common error messages are:

- **Library not found:**
  ```
  Failed to load dynamic library 'libonnxruntime.so': ...
  Failed to load dynamic library 'onnxruntime.dll': ...
  ```
  Cause: the ORT binary was not bundled by the Flutter build.
  Fix: ensure `dart pub get` ran successfully and the hook produced the
  binary in `.dart_tool/betto_onnxrt/{version}/`.

- **Symbol not found:**
  ```
  symbol not found: OrtGetApiBase
  ```
  Cause: a different ORT library version is on the system path and was loaded
  instead of the bundled one, or the bundled binary is corrupt.
  Fix: check `flutter doctor`, clean the build (`flutter clean`), and re-run
  `dart pub get`.

- **API version mismatch:**
  ```
  ONNX Runtime: OrtGetApiBase returned null for API version N
  ```
  Cause: the library loaded but the API version does not match `ortApiVersion`
  in `lib/src/ort_api.dart`. See the `OrtApiVersion` check in
  `lib/src/runtime.dart`.

## Where to record evidence

Paste the following into the PR description under a `## Manual checks` heading:

```
Platform: Linux x86_64 (or Windows x64, etc.)
Flutter channel: stable
Flutter version: 3.x.x
dart test exit code: 0
Last 20 lines of flutter test output:
<paste here>
ORT loaded (not skipped): yes / no
Inference assertion ran: yes / no
```

This evidence is required whenever:
- A PR modifies ORT vtable slot indices in `lib/src/ort_api.dart`
- A PR bumps `VERSION_ONNX` or updates `version_onnx.json`
- A PR changes the native-assets hook (`hook/build.dart`)
- A PR changes `lib/src/runtime.dart` or `lib/src/session.dart`
