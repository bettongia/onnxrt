# Windows CICD issue

## Problem statement

The [`test-windows` job in the CICD pipeline](../../.github/workflows/cicd.yml)
continues to fail with errors such as those below, despite multiple attempts to
fix it.

```
  CI: ORT binary not found on the dynamic-linker search path. Ensure LD_LIBRARY_PATH (Linux) or PATH (Windows) includes .dart_tool/betto_onnxrt/<version>/ before running dart test. See .github/workflows/cicd.yml for the setup steps.
  package:matcher                    fail
  test\onnx_session_test.dart 132:7  main.<fn>
```

```
2026-06-11T05:49:42.4470646Z ##[group]❌ test/onnx_session_test.dart: (setUpAll) (failed)
2026-06-11T05:49:42.4475514Z CI: ORT binary not found on the dynamic-linker search path. Ensure LD_LIBRARY_PATH (Linux) or PATH (Windows) includes .dart_tool/betto_onnxrt/<version>/ before running dart test. See .github/workflows/cicd.yml for the setup steps.
2026-06-11T05:49:42.4496424Z package:matcher                    fail
2026-06-11T05:49:42.4497248Z test/onnx_session_test.dart 132:7  main.<fn>
2026-06-11T05:49:42.4498578Z ##[endgroup]
```

Example pipeline runs include:

- [#27](https://github.com/bettongia/onnxrt/actions/runs/27377463246)
- [#26](https://github.com/bettongia/onnxrt/actions/runs/27331071832)
- [#25](https://github.com/bettongia/onnxrt/actions/runs/27330509619)

## Background

The failure is reported by the `setUpAll` CI enforcement added to
`test/onnx_session_test.dart`. On CI, if `_ortLibraryAvailable()` returns
`false` on Linux or Windows, the test suite fails loudly rather than silently
skipping. `_ortLibraryAvailable()` tries `DynamicLibrary.open('onnxruntime.dll')`
and catches all exceptions, returning `false` on any failure — so the error
message does not distinguish between "file not found" and "file found but failed
to load". This made the root cause harder to identify.

On Linux, `cicd_linux` is self-contained: it sets `LD_LIBRARY_PATH` to the
cache directory within the same shell subcommand that runs `dart test`, and the
CI has been stable. On Windows, a separate step was used to add the DLL
directory to `PATH`, which introduced the fragility being investigated here.

The ORT Windows version (`1.22.1`) differs from the Linux/macOS baseline
version (`1.22.0`) because Windows uses a patch release. The cache directory is
keyed by the platform version (`1.22.1`), not `VERSION_ONNX`.

## Solution attempts

### Attempt 1 — `python3` → PowerShell JSON; PATH in same step as `make` (commit `bf24be2`)

**Hypothesis.** The original workflow had three separate steps: `dart pub get`,
an "Add ORT DLL directory to PATH" step using `python3`, and `make cicd_windows`.
Writing to `$GITHUB_PATH` propagates PATH changes to subsequent steps, but this
cross-step mechanism is less reliable than setting `$env:PATH` in the same shell
session. Additionally, `python3` on Windows runners may not be reliably available
or may produce unexpected output (e.g. Microsoft Store redirect). Combining the
PATH setup and `make cicd_windows` into one PowerShell step, and using
PowerShell's native `ConvertFrom-Json` instead of `python3`, should fix it.

**Changes.** `.github/workflows/cicd.yml` only. Replaced three steps with one:

```yaml
- name: Run cicd_windows
  run: |
    $ORT_VER = (Get-Content version_onnx.json | ConvertFrom-Json).platforms.'windows-x64'.version
    $ORT_CACHE = Join-Path (Get-Location).Path ".dart_tool\betto_onnxrt\$ORT_VER"
    $env:PATH = "$ORT_CACHE;$env:PATH"
    make cicd_windows
  shell: pwsh
```

**Result.** Same failure. The `$env:PATH` modification did propagate into the
PowerShell child processes, but `make cicd_windows` spawns `sh.exe` (from Git
for Windows) to execute Makefile recipes. The path translation between PowerShell
and Git Bash's Unix-style PATH handling was suspected of dropping the Windows
DLL directory, leaving `onnxruntime.dll` unfindable.

---

### Attempt 2 — Bypass `make`; run `dart test` directly from PowerShell (commit `da09902`)

**Hypothesis.** The PowerShell → `make` → `sh.exe` → `dart` subprocess chain
may silently drop the Windows DLL path entry during shell translation. Running
`dart test` directly from the PowerShell step eliminates every intermediate
shell hop, so `dart.exe` inherits `$env:PATH` directly from the PowerShell
process with no translation.

**Changes.** `.github/workflows/cicd.yml` only. Inlined the equivalent of
`cicd_windows` into the PowerShell step:

```yaml
- name: Run cicd_windows
  run: |
    dart pub global activate coverage
    dart pub get
    $ORT_VER = (Get-Content version_onnx.json | ConvertFrom-Json).platforms.'windows-x64'.version
    $env:PATH = "$(Join-Path (Get-Location).Path ".dart_tool\betto_onnxrt\$ORT_VER");$env:PATH"
    dart test
  shell: pwsh
```

**Result.** Same failure. With both PATH hypotheses exhausted and the PATH
modification now as direct as possible (same process, same shell, no
intermediaries), the working theory shifted: the DLL directory IS on PATH and
`onnxruntime.dll` IS found, but `LoadLibrary` fails because a required DLL
dependency is missing. The `catch (_)` in `_ortLibraryAvailable()` swallows the
error and returns `false`, producing the same symptom regardless of cause.

---

### Attempt 3 — Extract companion DLL `onnxruntime_providers_shared.dll` from the hook (commit `d73e183`)

**Hypothesis.** `onnxruntime.dll` on Windows v1.22.x has a hard import
dependency on `onnxruntime_providers_shared.dll`. Windows `LoadLibrary` returns
error 126 ("The specified module could not be found") when this companion DLL
is absent from the search path. The build hook (`hook/build.dart`) was only
extracting `onnxruntime.dll` from the ZIP archive; `onnxruntime_providers_shared.dll`
(also in `onnxruntime-win-x64-1.22.1/lib/`) was never staged. As a result,
`DynamicLibrary.open('onnxruntime.dll')` always threw, `_ortLibraryAvailable()`
always returned `false`, and no amount of PATH manipulation would help.

The same error would have been present from the very first Windows CI run. It
went undetected previously because the `setUpAll` CI enforcement (which turns the
silent skip into a loud failure) was itself added as part of the testing pipeline
plan that preceded this debugging work.

**Changes.** `hook/build.dart` only. Added `_ensureWindowsDesktopDlls`, a new
function that downloads the ORT Windows ZIP once, verifies its SHA-256, then
extracts both `onnxruntime.dll` and `onnxruntime_providers_shared.dll` to the
cache directory in a single pass. The existing `_buildDesktop` function now routes
Windows through `_ensureWindowsDesktopDlls` instead of `_ensureFileFromArchive`.

Key design points:
- Single download for both DLLs (the archive is ~30 MB; re-downloading just to
  get the companion DLL would double the cold-start cost).
- Fast path: if both DLLs and the sidecar `.sha256` are present and the sidecar
  matches the expected archive hash, skip the download entirely.
- The companion DLL extraction is wrapped in `on StateError catch` so that future
  ORT releases that unify or remove `onnxruntime_providers_shared.dll` do not
  break the hook.
- The CI workflow step from Attempt 2 (direct `dart test` from PowerShell with
  `$env:PATH` prepended) is retained — it is correct and eliminates unnecessary
  subprocess indirection regardless of the DLL issue.

**Result.** Failed — same error. The companion DLL fix did not resolve it. The
CI log showed no new output from the hook (no "downloading…" or "staged:" lines),
which suggests either the hook did not run at all on this invocation, or ran
with `buildCodeAssets = false` and exited early at line 92 before attempting
the download. The root cause remains unknown because `_ortLibraryAvailable()`
was still silently swallowing the exception.

---

### Attempt 4 — Diagnostic instrumentation (current)

**Hypothesis.** Three failed attempts with identical symptoms and no useful
output means the next step is not another fix — it is visibility. The key
unknowns are:

1. *Does `DynamicLibrary.open('onnxruntime.dll')` throw because the file is not
   found, or because it is found but fails to load?* `catch (_)` in
   `_ortLibraryAvailable()` silences everything.
2. *Are the DLL files actually present in the cache directory when tests run?*
   If the hook never ran (or ran with `buildCodeAssets = false`), neither DLL
   exists and no amount of PATH manipulation helps.
3. *Is the cache directory on PATH?* Unlikely to be wrong after Attempt 2, but
   worth confirming.

**Changes.** `test/onnx_session_test.dart` only. No workflow changes.

- `_ortLibraryAvailable()`: hoisted `libName` out of the `try` block so the
  `catch (e, st)` can reference it; prints the full exception and stack trace
  on CI.
- `setUpAll`: before calling `fail()`, lists every file under
  `.dart_tool/betto_onnxrt/` and prints `PATH` (Windows only).

Expected output in the CI job log (one of):

```
[betto_onnxrt diag] DynamicLibrary.open(onnxruntime.dll) failed: <actual error>
[betto_onnxrt diag]   .dart_tool/betto_onnxrt/1.22.1/onnxruntime.dll
[betto_onnxrt diag]   .dart_tool/betto_onnxrt/1.22.1/onnxruntime_providers_shared.dll
[betto_onnxrt diag] PATH=...\.dart_tool\betto_onnxrt\1.22.1;...
```
or:
```
[betto_onnxrt diag] DynamicLibrary.open(onnxruntime.dll) failed: <actual error>
[betto_onnxrt diag]   (cache root does not exist)
```

The first pattern means the DLLs are present but the load fails (dependency or
other OS error). The second means the hook never ran and the root cause is in
the build-asset plumbing.

**Result.** Pending CI run.
