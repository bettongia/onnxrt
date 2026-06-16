# betto_onnxrt — Release Readiness Review (0.1.0-dev.1)

**Date:** 2026-06-16

**Reviewer:** Release Ninja (QA / release engineering)

**Scope:** Full release-readiness audit for the `0.1.0-dev.1` tag: pub.dev score,
going-public GitHub hygiene, cross-platform coverage, test quality, and CI/CD.

---

## Verdict: NOT READY FOR RELEASE

The pure-Dart `betto_onnxrt` package is in genuinely good shape — code quality is
high, docs are thorough, `dart pub publish --dry-run` passes with one cosmetic
warning, all 83 unit tests pass, and `dart analyze` is clean. But the release
**cannot be cut as specified** because of one hard blocker in the companion package
and several going-public hygiene issues.

The roadmap (Goal 8) mandates that `betto_onnxrt` and `betto_onnxrt_ios` publish
**in lockstep**. `betto_onnxrt_ios` currently cannot be published at all. That
breaks the release as defined.

---

## P0 — Must fix before publish (blockers)

### 1. `betto_onnxrt_ios` is unpublishable — the whole package is hidden from pub

`dart pub publish --dry-run` inside `packages/betto_onnxrt_ios/` fails:

```
* The pubspec is hidden, probably by .gitignore or pubignore.
* You must have a LICENSE file in the root directory.
Total compressed archive size: <1 KB.
```

Root cause: the repo-root `.pubignore` contains a bare `packages/` entry (added to
keep the iOS subpackage out of the main `betto_onnxrt` archive). pub resolves ignore
rules from the enclosing git repo, so when you publish the nested package, that
`packages/` rule hides the nested package's own files — including its `pubspec.yaml`
and `LICENSE`. The files are git-tracked (`git check-ignore` returns nothing), so
this is purely the `.pubignore` interaction.

**Fix:** make `betto_onnxrt_ios` a standalone publishable unit — either move it to
its own git repository, or publish from a clean copy/checkout where the parent
`.pubignore` does not apply. Verify with a fresh `dart pub publish --dry-run` that
the archive contains pubspec + LICENSE + README + lib.

### 2. `betto_onnxrt_ios` version mismatch + missing CHANGELOG

`packages/betto_onnxrt_ios/pubspec.yaml` is `version: 0.1.0`, but `betto_onnxrt` is
`0.1.0-dev.1`. The roadmap pre-publication checklist explicitly requires matching
version numbers. The iOS package also has no `CHANGELOG.md` (pub warns; it costs
pub.dev score).

**Fix:** set iOS version to `0.1.0-dev.1` and add
`packages/betto_onnxrt_ios/CHANGELOG.md`.

### 3. `betto_onnxrt_ios.dart` doc tells users the wrong install method

`packages/betto_onnxrt_ios/lib/betto_onnxrt_ios.dart:27–33` documents installation
via a **git dependency** (`git: url: git@github.com:...`). If you are publishing to
pub.dev, the canonical install is `betto_onnxrt_ios: ^0.1.0`. The README and main
spec already use the pub.dev form; this library doc contradicts them and will confuse
consumers. A git/SSH URL in a published package is also a going-public smell.

**Fix:** rewrite the usage block to the pub.dev dependency form.

---

## P1 — Should fix before publish (pub.dev score / going-public risk)

### 4. Stale, incorrect CHANGELOG entry (factually wrong)

`CHANGELOG.md:13` states: "exposes output shape via vtable slots **31–33**." The
code uses slots **65/61/62** (`lib/src/session.dart:58,322,435–447`). The CHANGELOG
is the first thing many pub.dev visitors read; shipping a wrong technical claim
undermines trust.

**Fix:** correct to slots 65/61/62, or drop the internal slot-number detail from a
user-facing changelog.

### 5. Broken doc references to a non-existent spec file

Three shipped test files reference `docs/spec/28_release_checklist.md`, which does
not exist (the spec is a single `docs/spec/README.md`):

- `test/onnx_session_test.dart:25` and `:151` (the latter is in the user-visible skip
  message)
- `test/hook_smoke_test.dart:33`

These tests are included in the published archive, so the dangling reference goes
public. The skip message at line 151 is printed to anyone running the test suite.

**Fix:** point them at `docs/spec/README.md` §8 (the limitations/testing section)
or remove the reference.

### 6. Example contains a labelled fake checksum that will fail at runtime

`example/example.dart:90–91` hardcodes a `// placeholder` 32-hex-char string as a
SHA-256 (it isn't even 64 chars). pana renders `example/` on the pub.dev page. A
reader who uncomments `downloadModelExample()` gets a checksum-mismatch `StateError`.
The path references `BAAI/bge-small-en-v1.5/.../model_quantized.onnx` — the roadmap
test catalogue has a real checksum for this model (`828e14...`).

**Fix:** use a real model URL + real SHA-256, or make the placeholder obviously
non-runnable with a clear comment so no one expects it to work.

### 7. `.pubignore` warning on every publish

The main-package dry-run warns: `docs/spec/.pandoc` is checked-in but gitignored.
Harmless but it is a validation warning on a release artifact.

**Fix:** add `docs/spec/.pandoc` to `.pubignore`.

### 8. CONTRIBUTING.md stance — confirm before going public

`CONTRIBUTING.md` says "we are not accepting Pull Requests" and "makes no commitment
to respond." That is a legitimate stance, but for a package marketed on pub.dev it
depresses adoption and contributor trust. Not a blocker — flagging as a deliberate
decision to confirm.

### 9. pub.dev discoverability gaps (minor)

- No `screenshots:` or `funding:` in `pubspec.yaml` (screenshots are awkward for a
  headless inference library; reasonable to skip).
- Only 3 `topics:` (`onnx`, `machine-learning`, `native-assets`) — consider adding
  `ffi`, `inference`, `ml`.
- `site.mk` ships in the archive (docs-build Makefile fragment; no consumer value).
  Add to `.pubignore`.
- `dart pub outdated` reports `analyzer`, `_fe_analyzer_shared`, `package_config`
  behind. Not blocking for publish.

---

## P2 — Nice to have / post-publish

- No committed secrets, credentials, keys, or tokens found in tracked files.
- The local `packages/betto_onnxrt_ios/ios/.../.build/` SPM index artefacts are not
  git-tracked. Run `git clean -ndx` before flipping the repo public to confirm
  nothing untracked is inadvertently exposed.
- `docs/reviews/`, `docs/plans/`, and `docs/notebooks/windows_cicd_issue.md` will be
  publicly visible — they read as normal engineering notes, but review them for any
  candid internal language you would rather not publish.
- No `.github/ISSUE_TEMPLATE/` or `CODE_OF_CONDUCT.md`. Given the "no PRs"
  CONTRIBUTING stance, issue templates are the most useful addition.
- Magika example (`example/magika/bin/magika.dart:38–42`) imports via
  `package:magika/src/...` — fine since it's `publish_to: none`.

---

## Platform coverage

| Platform | Declared | Implemented | Automated test | Verdict |
|---|---|---|---|---|
| Linux x64/arm64 | yes | `runtime.dart:253` | `cicd_linux` runs real `dart test` inference | Solid |
| Windows x64/arm64 | yes | `runtime.dart:254–271` (absolute-path DLL, System32 avoidance) | `test-windows` runs real `dart test` inference | Solid |
| macOS arm64 | yes | `runtime.dart:210–251` (multi-strategy framework/dylib probe) | `cicd_macos` runs `macos_test` Flutter integration | Solid; Intel macOS explicitly unsupported |
| Android | yes | `_buildAndroid`, two-level SHA verify | Developer-run only | Acceptable per spec |
| iOS | yes (via shim) | `DynamicLibrary.process()` + SPM shim | Developer-run only | Acceptable per spec; blocked by P0 #1 |
| Web | not supported | Correctly excluded | n/a | Correct |

---

## Test suite assessment

Genuinely good for a v0. `dart analyze` clean, 83 passing tests, real coverage of
tensor types, model downloader (mocked HTTP), the slot guard, and the manifest. Two
caveats:

1. The 11 skipped `OnnxSession` tests skip in plain `dart test` (JIT) by design — the
   real inference is exercised in `cicd_linux`, `cicd_windows`, and `macos_test`. The
   skip is well-engineered: `setUpAll` **fails** (not skips) on Linux/Windows CI if
   the binary is absent, so a misconfigured pipeline is loud.
2. The vtable slot guard (`ort_slot_guard_test.dart`) only checks comment-to-golden
   consistency — it cannot catch a slot that's numerically wrong but consistently
   mislabelled. CLAUDE.md correctly mandates a real `make macos_test`/`linux_test` run
   for any slot change.

---

## CI/CD assessment

`.github/workflows/cicd.yml` builds and runs real inference on Linux, Windows, and
macOS — a strong pipeline that would catch FFI/load regressions on the three desktop
platforms. Gaps:

- No Android or iOS job (documented limitation; developer-run).
- No publish/release workflow. Publication is manual per `docs/releasing.md`. A
  scripted two-step publish would reduce the chance of shipping a half-release.

---

## Recommended action plan (in order)

1. Fix the `betto_onnxrt_ios` publish blocker (P0 #1) — restructure so the nested
   package isn't hidden by the root `.pubignore`.
2. Align iOS package version to `0.1.0-dev.1` and add its `CHANGELOG.md`.
3. Rewrite the iOS library-doc install block to the pub.dev form.
4. Correct CHANGELOG slot numbers 31–33 → 65/61/62.
5. Fix the three `docs/spec/28_release_checklist.md` references in tests.
6. Fix or clearly neuter the example's fake checksum and model path.
7. Add `docs/spec/.pandoc` to `.pubignore`.
8. Confirm the CONTRIBUTING stance is intentional; add issue templates if desired.
9. Run `git clean -ndx` and skim `docs/reviews|plans|notebooks` before making the
   repo public.
10. Re-run `dart pub publish --dry-run` for **both** packages; publish
    `betto_onnxrt` first, `betto_onnxrt_ios` immediately after.
