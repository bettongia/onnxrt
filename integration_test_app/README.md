# betto_onnxrt_test_app

On-device integration test harness for [`betto_onnxrt`](../README.md).

This app is **not published** (`publish_to: none`). It exists to verify that
the native-assets build hook correctly stages the ORT binary and that
`OnnxRuntime.load()` and `OnnxSession.run()` produce correct output on real
platform targets. Unit tests in the main package cover the Dart layer; these
tests cover the full stack including native linking.

## Running the tests

All commands are run from the **repo root** via Make:

```sh
make macos_test    # macOS — no simulator needed
make ios_test      # iOS simulator (boots ios-emulator automatically)
make android_test  # Android emulator (requires a running AVD)
```

See the repo-root `Makefile` for emulator setup targets (`emulator_ios_create`,
`emulator_android_create`) and simulator/emulator variables you can override.

## Test coverage

`integration_test/onnxrt_test.dart` exercises:

- `OnnxRuntime.load()` — library opens without error
- `OnnxSession` creation from in-memory bytes and from a file path
- `OnnxSession.run()` with a bundled identity model (`assets/identity_float32.onnx`)
- Tensor round-trip for `float32` inputs and outputs
- Session and runtime disposal
