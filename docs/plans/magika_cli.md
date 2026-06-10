# Magika CLI — filetype detection using betto_onnxrt

**Status**: Investigated

**PR link**: _(pending)_

## Problem statement

`betto_onnxrt` provides a generalised ONNX inference API and model-download
infrastructure, but has no real-world consumer that exercises all three
concerns end-to-end (model download, preprocessing, inference,
postprocessing). A standalone CLI tool named `magika` that detects file types
using Google's Magika v3.3 model would serve as a high-quality reference
consumer and a genuinely useful developer utility.

The tool must:
- Accept a single file path as its only argument.
- Download the Magika `standard_v3_3` ONNX model and its `config.json` on
  first run, caching them in `~/.cache/betto_onnxrt/`.
- Produce output matching the Magika JSON schema used by the Python reference
  implementation (see example session in the problem statement).
- Compile to a native binary via `dart compile exe`.

## Open questions

- [x] Should the model URLs be pinned to a tagged git ref or specific commit SHA
      rather than `raw/main/`? If Google does not publish stable tagged raw URLs,
      what is the fallback strategy?
      **Decision**: Accept floating `raw/main/` URLs — Google is reliable and
      this is a demo tool. Document the checksum-update procedure in
      `magika_spec.dart` so a model bump is a one-liner.
- [x] Has the native-assets hook been verified to trigger correctly when
      `dart compile exe` runs inside `example/magika/`? If not, what is the
      recommended development workflow (e.g. must run `dart pub get` at the repo
      root first)?
      **Decision**: Treat as an unknown; investigate during Phase 1 and record
      findings in the `example/magika/README.md` as developer workflow notes.
      This is also useful documentation for other consumers of `betto_onnxrt`.
- [x] What is the exact mid-segment algorithm for files in the range
      `(block_size, 2 * block_size)`? Specifically: is the start computed as
      `(file_len - block_size) ~/ 2`, and is any remaining padding applied at the
      start or end of the mid buffer?
      **Decision**: Algorithm pinned from the Python Magika source (see updated
      Preprocessing section). Validated empirically using PDF fixtures at
      `/Users/gonk/development/bettongia/pdfart/test/fixtures` during Phase 9.

## Investigation

### Model assets

The Magika `standard_v3_3` model is hosted at:

```
https://github.com/google/magika/raw/main/assets/models/standard_v3_3/model.onnx
https://github.com/google/magika/raw/main/assets/models/standard_v3_3/config.json
```

Both files must be specified in the `ModelSpec`. The SHA-256 checksums are
not known at plan time and must be fetched and recorded during implementation
(see implementation step 2).

### ONNX input/output format

Based on the Magika Python source and model metadata:

| Property | Value |
|---|---|
| Input name | `bytes` |
| Input shape | `[1, 1536]` |
| Input dtype | `int32` |
| Byte encoding | raw byte values 0–255; out-of-range value `256` used as padding token |
| Output name | `target_label_scores` |
| Output shape | `[1, N_LABELS]` where N_LABELS comes from `config.json` |
| Output dtype | `float32` (softmax probabilities) |

These names and shapes **must be verified** against the live model during
implementation step 3 (run `dart run bin/inspect_model.dart` or equivalent).

### Preprocessing (`bytes` tensor construction)

Given `block_size = 512` and `padding_token = 256` (both sourced from
`config.json`), and `n = fileBytes.length`:

**beg** (right-padded):
```
beg = fileBytes[0 : min(n, block_size)]
      + [padding_token] * max(0, block_size - n)
```

**end** (left-padded):
```
end_start = max(0, n - block_size)
end = [padding_token] * max(0, block_size - (n - end_start))
      + fileBytes[end_start : n]
```

**mid** (right-padded, centre-aligned within available bytes):
```
mid_start = max(0, n ~/ 2 - block_size ~/ 2)
mid = fileBytes[mid_start : min(n, mid_start + block_size)]
      + [padding_token] * max(0, block_size - (min(n, mid_start + block_size) - mid_start))
```

Concatenate `[beg, mid, end]` → int32 list of length 1536, then wrap as
`OnnxTensor.fromInt32([1, 1536], Int32List.fromList(concat))`.

Key padding asymmetries (from the Python Magika source):
- **beg**: padding appended at the right.
- **end**: padding prepended at the left (so actual file bytes are always at
  the end of the buffer).
- **mid**: padding appended at the right.

For very short files (n < block_size) all three segments overlap on the same
bytes, but the padding positions differ — the padding strategy is still
correct because padding is deterministic per-segment regardless of overlap.

### Postprocessing

1. Read `target_label_scores` output tensor as `Float32List`.
2. Find the argmax index `i`.
3. Look up `config.json`'s `target_labels_space[i]` which has the shape:
   ```json
   {
     "name": "pdf",
     "mime_type": "application/pdf",
     "group": "document",
     "extensions": ["pdf"],
     "is_text": false,
     "description": "PDF document"
   }
   ```
4. The score is `scores[i]`.

### JSON output schema

Mirrors the Python Magika CLI `--json` format:

```json
[
  {
    "path": "<absolute path>",
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
        "output": { /* identical to dl in v1 */ },
        "score": 0.999
      }
    }
  }
]
```

In the Python implementation `output` can differ from `dl` when rule-based
overrides apply (e.g. a very small file is declared `unknown`). This v1
implementation sets `output == dl` always and defers rule-based overrides to
a future plan.

Error cases (file not found, unreadable) produce:

```json
[
  {
    "path": "<path>",
    "result": {
      "status": "error",
      "value": { "error": "<message>" }
    }
  }
]
```

### Package placement

A new `example/magika/` directory containing a self-contained Dart package.
This is the standard Dart convention for standalone examples that depend on
the parent package, and it keeps `betto_onnxrt`'s own `pubspec.yaml` clean.

```
example/magika/
  pubspec.yaml          # package: magika; path dep on ../../
  analysis_options.yaml # inherit project lints
  bin/
    magika.dart         # CLI entrypoint
  lib/
    src/
      magika_spec.dart        # ModelSpec + SHA-256 constants for standard_v3_3
      magika_config.dart      # parse config.json → MagikaConfig + ContentType
      magika_preprocess.dart  # File → OnnxTensor
      magika_postprocess.dart # OnnxTensor + MagikaConfig → MagikaResult
      magika_result.dart      # MagikaResult data class + toJson()
  test/
    magika_preprocess_test.dart
    magika_postprocess_test.dart
    magika_result_test.dart
```

### Caching

The cache directory follows XDG conventions: `~/.cache/betto_onnxrt/` on
Linux/macOS, `%LOCALAPPDATA%\betto_onnxrt\cache\` on Windows. A small helper
in `magika_spec.dart` resolves this from `Platform.environment`.

### Dependencies

The `magika` package will need only:
- `betto_onnxrt: {path: ../../}` — inference + download
- No additional pub dependencies; `dart:convert`, `dart:io`, `dart:typed_data`
  cover JSON, file I/O, and tensor construction.

## Implementation plan

### Phase 1 — scaffold

- [ ] Create `example/magika/` directory and `pubspec.yaml` with path
      dependency on `../..`.
- [ ] Copy `analysis_options.yaml` from the root; add `addlicense` config if
      needed.
- [ ] Create `bin/magika.dart` stub that prints `"not implemented"`.
- [ ] Run `dart pub get` inside `example/magika/` and confirm it succeeds.
- [ ] Investigate and document the native-assets hook workflow: does
      `dart compile exe` inside `example/magika/` trigger the ORT binary
      staging hook from the parent package transitively? Does `dart run` work
      if the root package has previously been `dart pub get`'d? Record
      findings in `example/magika/README.md` as a developer workflow section.

### Phase 2 — model spec and download verification

- [ ] Fetch `model.onnx` and `config.json` from GitHub raw URLs and compute
      their SHA-256 checksums.
- [ ] Write `lib/src/magika_spec.dart` with `kMagikaModelSpec` (`ModelSpec`)
      and the cache-dir helper.
- [ ] Smoke-test that `ModelDownloader.ensure` downloads and verifies both
      files correctly.

### Phase 3 — model I/O verification

- [ ] Load the session and call `session.inputInfo` / `session.outputInfo` (or
      print metadata) to confirm:
      - Input name is `bytes`, shape `[1, 1536]`, dtype int32.
      - Output name is `target_label_scores`, shape `[1, N]`, dtype float32.
- [ ] Record confirmed names in `magika_spec.dart` as constants.

### Phase 4 — config parsing

- [ ] Write `lib/src/magika_config.dart`:
      - `ContentType` data class matching the `target_labels_space` entry shape.
      - `MagikaConfig.fromJson(Map<String, dynamic>)` parsing `block_size`,
        `padding_token`, and `target_labels_space`.

### Phase 5 — preprocessing

- [ ] Write `lib/src/magika_preprocess.dart`:
      - `buildInputTensor(Uint8List fileBytes, MagikaConfig config) → OnnxTensor`
      - Extract beg / mid / end segments with the padding strategy from the
        investigation section.
- [ ] Write `test/magika_preprocess_test.dart`:
      - Empty file → all padding tokens.
      - File shorter than `block_size` (e.g. 100 bytes) → beg/mid right-padded,
        end left-padded, all three share the same bytes.
      - File exactly `block_size` (512 bytes) → beg = full content, end = full
        content, mid starts at index 0 with no padding.
      - File in the range `(block_size, 2 * block_size)` (e.g. 700 bytes) →
        mid window is centre-aligned with no padding; confirm start index =
        `(700 ~/ 2) - 256 = 94`.
      - File larger than `3 * block_size` → no padding anywhere; beg, mid, end
        are disjoint (or near-disjoint) slices.

### Phase 6 — postprocessing and result types

- [ ] Write `lib/src/magika_result.dart`:
      - `LabelDetail` data class (label, description, extensions, group,
        is_text, mime_type).
      - `MagikaResult` (dl, output, score).
      - `toJson()` producing the nested structure from the investigation.
- [ ] Write `lib/src/magika_postprocess.dart`:
      - `postprocess(OnnxTensor scores, MagikaConfig config) → MagikaResult`
      - Argmax + label lookup + score extraction.
- [ ] Write `test/magika_postprocess_test.dart`:
      - Known probability vector → correct label + score.

### Phase 7 — CLI entrypoint

- [ ] Implement `bin/magika.dart`:
      - Parse single positional file-path argument; print usage and exit 1 on
        missing/extra args.
      - Resolve cache dir; call `ModelDownloader.ensure`.
      - Open `OnnxRuntime` and load session; wrap all inference work in
        `try/finally` so `session.dispose()` and `runtime.dispose()` are
        guaranteed to run even if postprocessing throws.
      - Build input tensor, run inference, postprocess.
      - Print pretty-printed JSON array to stdout; exit 0.
      - On file-not-found / read error: emit the error JSON format, exit 1.
      - On missing argument: print usage to stderr, exit 1.
      - Cache-dir helper: fall back to `Directory.systemTemp` if
        `HOME` / `LOCALAPPDATA` are absent (guards against unusual
        environments).

### Phase 8 — documentation and changelog

- [ ] Add `example/magika/README.md` covering installation
      (`dart compile exe`), usage, and the JSON output format.
- [ ] Update root `CHANGELOG.md` to record the new example.
- [ ] Ensure Apache 2.0 headers on all new `.dart` files
      (`make license_add` from the root).

### Phase 9 — final quality gate

- [ ] Run `dart analyze` and `dart test` inside `example/magika/`.
- [ ] Run `make pre_commit` from the root to confirm the main package is
      unaffected.
- [ ] Smoke-test the compiled binary against several files from
      `/Users/gonk/development/bettongia/pdfart/test/fixtures` (PDFs of
      varying sizes covering the beg/mid/end edge cases) and confirm the
      `label` and `mime_type` fields match the Python Magika reference output.
- [ ] Note in the README that the tool reads the entire file into memory
      (v1 limitation) and may be slow on very large files (> ~100 MB).

## Summary

_(to be filled in on completion)_

## Reviews

### Review 1: 2026-06-10

**Problem Statement Assessment**

The motivation is solid. `betto_onnxrt` currently has no end-to-end real-world consumer, and a Magika CLI neatly exercises model download, preprocessing, inference, and postprocessing in one coherent artefact. Scoping v1 to a single file-path argument with Python-compatible JSON output is an appropriate boundary. The decision to place it under `example/magika/` as a separate Dart package is correct — it keeps the library's own `pubspec.yaml` clean and follows Dart conventions for standalone examples. No concerns with the problem statement.

**Proposed Solution Assessment**

The plan is generally well thought-out and the investigation section is detailed. However, there are three technical correctness issues and two structural gaps that must be resolved before implementation begins.

**Critical: `_copyTensorData` always returns float32 regardless of element type**

The current `OnnxSession._copyTensorData` implementation (session.dart:426–442) unconditionally casts the output pointer to `float32` and returns `OnnxElementType.float32`. This is correct for the Magika `target_label_scores` output (which is float32), but it is worth noting explicitly in the plan because the postprocessing step calls `session.run(outputs: ['target_label_scores'])` and the caller must use `.asFloat32()` — not a dynamic cast — or risk a `StateError`. The plan should call this out in the Phase 6 implementation notes so the implementer does not write defensive type-switching code that is currently not supported by the API.

**Critical: native-assets hook inheritance in sub-packages**

The `magika` example package is a separate `pubspec.yaml` under `example/magika/`. When `dart pub get` runs inside that package, it inherits the `betto_onnxrt` path dependency but **the native-assets build hook in `hook/build.dart` is only triggered when the package that declares the `hooks` dependency runs its build step**. A separate package with a `path: ../../` dep will trigger the hook transitively through `dart compile exe`, but this must be verified. If `dart run bin/magika.dart` (interpreted mode) does not trigger hook resolution — which is likely, since the hook is defined on the parent package — Phase 7's development loop will silently fail to find the ORT library until a full `dart compile exe` build is done. The plan should note this constraint and clarify that development testing must either use `dart compile exe` or rely on the parent package having already staged the ORT binary (i.e. `dart pub get` at the root, then running the binary from the root's `.dart_tool/` cache location). This could significantly slow the development iteration cycle.

**Critical: `mid` segment extraction algorithm is underspecified**

The plan describes the mid extraction as: "centre-aligned 512 bytes; pad symmetrically with the padding token." For the edge case of files between 512 and 1024 bytes, the centre calculation `bytes.length ~/ 2` will produce a mid-start index such that the 512-byte window extends beyond the file. The plan says "pad the remainder" but does not specify whether the padding goes at the start, the end, or both sides of the mid window. The Python Magika implementation places the mid window by taking `(file_len - block_size) ~/ 2` as the start offset for files longer than `block_size` (centre-aligning in the available file bytes), and using pure padding when the file is shorter than `block_size`. The plan's description is ambiguous for files in the 513–1023 byte range: the test cases in Phase 5 do not cover this range explicitly. A test case for "file between `block_size` and `2 * block_size`" must be added to ensure mid extraction is correct.

**Moderate: `output == dl` divergence from Python reference**

The plan explicitly defers rule-based overrides (the `output != dl` case in small-file detection) to a future plan. This is a deliberate scope decision, which is fine. However, the plan does not specify what exit code the CLI should use when it produces the error JSON variant. The Python Magika CLI exits 1 on file errors and 0 on successful inference even for low-confidence results. Phase 7 mentions "exit 1" for file-not-found/read errors, which is correct, but omits the exit code for the success path — this should be made explicit (exit 0).

**Moderate: no `asInt32()` helper on `OnnxTensor`**

The plan (Phase 5) constructs the input tensor with `OnnxTensor.fromInt32(...)`, which is correct and already available in `tensor.dart`. No gap here for the input side. On the output side, the output tensor for Magika is float32, so `asFloat32()` suffices. No new API surface is needed — but this should be confirmed in the plan.

**Minor: SHA-256 deferred to implementation**

The plan states "checksums are not known at plan time and must be fetched and recorded during implementation." This is acceptable for an example tool (unlike a library with released checksums), but Phase 2 should explicitly specify that checksums are computed from the files as downloaded from the tagged commit ref in the URL, not `main`, to prevent non-reproducibility from GitHub's `main` branch moving. The URLs currently point to `raw/main/assets/models/...` — this is a floating ref and the SHA-256 will change whenever Google updates their model. The plan should either pin to a tagged commit (e.g. `raw/refs/tags/v3.3.0/...`) or acknowledge that the checksum must be re-computed on each model update.

**Architecture Fit**

This is a pure-Dart CLI in `example/magika/`. The library-architecture skill's checks are not applicable here (no `lib/<package>.dart` barrel for a CLI tool, no Flutter dependency, no widgets). The tool correctly uses only the Core API surface (`OnnxRuntime`, `OnnxSession`, `ModelDownloader`, `ModelSpec`), all of which are public and well-documented. Placement as an example sub-package is consistent with how Dart ecosystem examples are structured.

The `design` and `inclusivity` skills do not apply — this is a non-interactive CLI that writes JSON to stdout.

**Risk & Edge Cases**

1. **Floating model URL (rated: high).** The GitHub raw `main` URL means the SHA-256 in `magika_spec.dart` will silently fail verification the moment Google pushes a new model to `main`. Fix: pin to a tagged commit ref.

2. **Very large files (rated: moderate).** The preprocessing step reads the entire file into `Uint8List` via `File.readAsBytesSync()` (implied by the plan). Only 1536 bytes are ever used. For a 4 GB ISO image this allocates 4 GB in one shot. The plan should limit file reads to a streaming approach: read the first 512 bytes, seek to the midpoint for 512 bytes, and seek to the last 512 bytes — or at least document the current "read everything" behaviour as a known limitation.

3. **Session dispose on error path (rated: moderate).** Phase 7 says "dispose session and runtime before exit." If postprocessing throws (e.g. argmax on an empty tensor) the current plan's implied structure (`try/catch` at the top level) should ensure dispose still runs. The plan should require that dispose is in a `try/finally` block, not merely described as "before exit."

4. **Windows cache dir (rated: low).** The plan uses `%LOCALAPPDATA%\betto_onnxrt\cache\`. On some Windows configurations `LOCALAPPDATA` is unset. The cache-dir helper should fall back to `%APPDATA%` or `Directory.systemTemp` rather than throwing a `NullPointerException`.

5. **The `asFloat32()` helper will throw a `StateError` if the model is upgraded to output int32.** This is not a risk for Magika v3.3 (confirmed float32 output) but should be documented in `magika_postprocess.dart`.

**Recommendations**

1. **Pin the model URL to a tagged commit or a specific commit SHA** rather than `raw/main/`. Add a comment in `magika_spec.dart` explaining how to update the URLs and recompute checksums on a model upgrade.

2. **Document the native-assets hook constraint** in Phase 1 and 2: add a note that `dart run` from inside `example/magika/` requires the ORT binary to already be staged (by running `dart pub get` at the repository root), and that `dart compile exe` handles this automatically. Alternatively, add a `Makefile` target in `example/magika/` that does the right thing.

3. **Add a test case for files in the 513–1023 byte range** in `magika_preprocess_test.dart` to verify mid-segment centre-alignment, and write out the exact algorithm (start index computation) in the plan's investigation section rather than the ambiguous prose currently there.

4. **Specify exit codes explicitly** for all three exit paths in Phase 7: success (0), file-not-found/read-error (1), missing argument (1).

5. **Add a large-file note** to the Phase 5 investigation. If full-file reads are intentional for v1, document the limitation. If streaming is preferred, add a Phase 5 sub-task for it.

6. **Wrap dispose in `try/finally`** in the Phase 7 CLI entrypoint description.

The plan is close to implementation-ready but these issues — particularly the floating URL / SHA-256 problem, the native-assets hook inheritance ambiguity, and the underspecified mid-segment algorithm — need resolution first. The plan should not proceed to `Implemented` until those three items are addressed.

**Open questions**

- [ ] Should the model URLs be pinned to a tagged git ref or specific commit SHA rather than `raw/main/`? If Google does not publish tagged releases with stable raw URLs, what is the fallback strategy (bundle known-good URLs with a documented update procedure)?
- [ ] Has the native-assets hook been verified to trigger correctly when `dart compile exe` is run inside `example/magika/` (i.e. the hook on the transitive path dependency resolves the ORT binary)? If not, what is the recommended development workflow?
- [ ] What is the exact mid-segment algorithm for files in the range `(block_size, 2 * block_size)`? Specifically: is the mid window start computed as `(file_len - block_size) ~/ 2`, and is padding applied at the start or end of the mid buffer when the window is smaller than `block_size`?
