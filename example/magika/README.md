# magika

A command-line tool that detects file types using Google's
[Magika](https://github.com/google/magika) v3.3 ONNX model and
[`betto_onnxrt`](../../README.md).

On first run the tool downloads and caches the Magika model in
`~/.cache/betto_onnxrt/` (Linux/macOS) or
`%LOCALAPPDATA%\betto_onnxrt\cache\` (Windows).

## Installation

```bash
# From inside this directory:
dart build cli
# The binary is at: build/cli/macos_arm64/bundle/bin/magika
```

Or run directly without compiling:

```bash
dart run bin/magika.dart <file>
```

## Usage

```
magika <file>
```

Outputs a JSON array to stdout that mirrors the Python Magika `--json` format:

```json
[
  {
    "path": "/absolute/path/to/file.pdf",
    "result": {
      "status": "ok",
      "value": {
        "dl": {
          "label": "pdf",
          "description": "PDF document",
          "extensions": ["pdf"],
          "group": "document",
          "is_text": false,
          "mime_type": "application/pdf"
        },
        "output": {
          "label": "pdf",
          "description": "PDF document",
          "extensions": ["pdf"],
          "group": "document",
          "is_text": false,
          "mime_type": "application/pdf"
        },
        "score": 0.999
      }
    }
  }
]
```

If the file cannot be read, the output is:

```json
[
  {
    "path": "/absolute/path/to/file",
    "result": {
      "status": "error",
      "value": { "error": "<message>" }
    }
  }
]
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | Success — inference completed normally |
| 1    | File not found / unreadable, or missing argument |

## Known limitations

- **Reads the entire file into memory** (v1 limitation). Detection only uses the
  first 512 bytes, middle 512 bytes, and last 512 bytes of the file, but the
  full file is loaded via `File.readAsBytesSync()`. May be slow or fail on very
  large files (> ~100 MB).
- **`output` is always equal to `dl`** — in the full Magika reference
  implementation (Python/Rust), `output` is a post-processed label that may
  differ from `dl` when rule-based overrides apply. For example, a file that is
  too small for the model to classify reliably would have `dl` set to whatever
  the neural network predicted, but `output` overridden to `unknown`. In this
  v1 implementation those overrides are not applied, so `output` is always a
  copy of `dl`.

## Developer workflow notes

### Native-assets hook and ORT binary discovery

`betto_onnxrt` uses a [native-assets build hook](../../hook/build.dart) to
download and stage the ONNX Runtime binary. The `magika` package depends on
`betto_onnxrt` via a `path: ../../` dependency, so the hook is triggered
**transitively** by both `dart run` and `dart build cli`.

**Verified behaviour (macOS arm64, Dart 3.x):**

- `dart run bin/magika.dart` — works directly; Dart's JIT runner invokes the
  build hooks from the transitive path dependency before starting the program.
  The ORT binary is placed at `.dart_tool/lib/libonnxruntime.{ver}.dylib`
  inside the package directory and is found automatically by
  `OnnxRuntime.load()`.

- `dart build cli` — AOT-compiles to a native binary; hook runs as part of the
  build and bundles the ORT dylib at `bundle/lib/libonnxruntime.{ver}.dylib`
  alongside the executable at `bundle/bin/magika`. `OnnxRuntime.load()` finds
  the dylib via the `bundle/bin/../lib/` relative path.

- `dart compile exe` — **not supported** when the dependency graph contains
  build hooks (Dart prints an error directing you to use `dart build cli`
  instead).

**No manual step required.** You do not need to run `dart pub get` at the
repository root first — `dart run` and `dart build cli` from inside
`example/magika/` trigger everything automatically.

### Model checksum updates

The SHA-256 checksums in `lib/src/magika_spec.dart` correspond to the
`standard_v3_3` model files as downloaded from the GitHub `main` branch on
2026-06-11. If Google updates the model, the checksums will change and
`ModelDownloader` will reject the cached files with a `StateError`. To update:

1. Delete `~/.cache/betto_onnxrt/magika_standard_v3_3/` (or its Windows
   equivalent).
2. Download the new files manually and compute their SHA-256:
   ```bash
   curl -fsSL https://github.com/google/magika/raw/main/assets/models/standard_v3_3/model.onnx | shasum -a 256
   curl -fsSL https://github.com/google/magika/raw/main/assets/models/standard_v3_3/config.min.json | shasum -a 256
   ```
3. Update the `kModelOnnxSha256` and `kModelConfigSha256` constants in
   `lib/src/magika_spec.dart`.
