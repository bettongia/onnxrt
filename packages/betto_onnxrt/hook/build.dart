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

/// Native-assets build hook for `betto_onnxrt`.
///
/// Downloads the ONNX Runtime prebuilt binary for the target platform/arch
/// from GitHub Releases, verifies the SHA-256 checksum, and emits it as a
/// [CodeAsset] with [DynamicLoadingBundled] link mode so the Dart/Flutter
/// build system bundles it alongside the executable.
///
/// ## Design
///
/// ORT is a large (~80 MB) prebuilt binary — too large to compile from source
/// in a hook. This hook uses a **download-prebuilt** model (as opposed to the
/// compile-from-source model used by `betto_zstd`).
///
/// The hook follows the same crash-safe write discipline as
/// `kmdb_inferencing/lib/src/model_downloader.dart`:
/// - Download to a `.part` temp file alongside the final path.
/// - Verify SHA-256 before renaming.
/// - Atomic rename on success.
/// - Present-file SHA short-circuit: if the final file already exists and its
///   SHA-256 matches, skip the download entirely.
/// - Concurrent invocations use last-writer-wins on the atomic rename — both
///   writers produce byte-identical, checksum-verified output.
///
/// ## Platform manifest
///
/// All platform binary metadata (versions, download URLs, SHA-256 digests) is
/// stored in `version_onnx.json` at the package root. The hook reads this file
/// at build time via [_loadPlatformManifest]. The JSON is the single source of
/// truth; `VERSION_ONNX` (flat file) tracks the API baseline for shell scripts
/// and Makefile targets.
///
/// ## iOS
///
/// iOS is NOT supported via the native-assets hook. The ORT iOS XCFramework
/// (`pod-archive-onnxruntime-c-{ver}.zip`) ships static `.a` archives:
///   - `ios-arm64/onnxruntime.a`                   — physical device
///   - `ios-arm64_x86_64-simulator/onnxruntime.a`  — simulator
///
/// Flutter's iOS native-assets system enforces `linkModePreference = dynamic`
/// and rejects both `StaticLinking` and `DynamicLoadingBundled` modes when the
/// artifact is an `ar archive` rather than a dylib. Both modes were tried and
/// rejected during the Q1 2026 spike (see `plan_betto_onnxrt_extraction.md`).
///
/// iOS support requires the `betto_onnxrt_ios` Flutter plugin, which declares
/// an SPM dependency on `microsoft/onnxruntime-swift-package-manager`
/// (`onnxruntime-c`), causing Xcode to statically link ORT into the host app.
/// `OnnxRuntime.load()` then uses `DynamicLibrary.process()` to resolve ORT
/// C API symbols from the process image. `_buildIos` logs a warning and emits
/// no CodeAsset. The iOS SHA-256 digest is recorded in `version_onnx.json` for
/// reference; it is not read at build time because the hook exits before any
/// manifest lookup on iOS.
///
/// ## Provenance waiver
///
/// The v0.05 roadmap requirement that "developers should be able to locally
/// build the required binaries" is satisfied for `betto_onnxrt` by an explicit
/// waiver: ORT is consumed as a Microsoft-signed prebuilt, and this hook
/// verifies the SHA-256 at download time. This provides stronger provenance
/// than a local compile. No `binaries.mk`-equivalent is authored.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

// ── Hook entry point ──────────────────────────────────────────────────────────

void main(List<String> args) async {
  await build(args, _buildHook);
}

Future<void> _buildHook(BuildInput input, BuildOutputBuilder output) async {
  // No-op if the invoker does not need code assets from this hook.
  if (!input.config.buildCodeAssets) return;

  hierarchicalLoggingEnabled = true;
  final logger = Logger('betto_onnxrt')
    ..level = Level.ALL
    ..onRecord.listen((r) => print(r.message));

  final os = input.config.code.targetOS;
  final arch = input.config.code.targetArchitecture;
  final packageRoot = input.packageRoot;

  logger.info('betto_onnxrt hook: os=$os arch=$arch');

  // Web is excluded — semantic search is not supported on web.
  if (os == OS.iOS) {
    await _buildIos(input, output, logger, arch, packageRoot);
  } else if (os == OS.android) {
    await _buildAndroid(input, output, logger, arch, packageRoot);
  } else {
    await _buildDesktop(input, output, logger, os, arch, packageRoot);
  }
}

// ── Desktop (macOS, Linux, Windows) ──────────────────────────────────────────

Future<void> _buildDesktop(
  BuildInput input,
  BuildOutputBuilder output,
  Logger logger,
  OS os,
  Architecture arch,
  Uri packageRoot,
) async {
  final platformEntry = _loadPlatformManifest(os, arch, packageRoot);
  final version = platformEntry['version'] as String;
  final url = platformEntry['url'] as String;
  // sha256 is the archive-level digest. Desktop uses single-level archive
  // verification; the extracted binary is cached with a `.sha256` sidecar
  // that records the archive hash so subsequent builds skip re-download.
  final archiveSha = platformEntry['sha256'] as String;

  final cacheDir = _cacheDirectory(packageRoot, version);

  final (archiveName, libPathInArchive, libFileName) = _desktopArtifact(
    os,
    arch,
    version,
  );

  final libFile = File('${cacheDir.path}/$libFileName');

  if (os == OS.windows) {
    // Windows requires onnxruntime.dll AND onnxruntime_providers_shared.dll —
    // the main DLL has a hard import on the shared DLL, so LoadLibrary fails
    // if only onnxruntime.dll is present. Download the archive once and
    // extract both in a single pass.
    await _ensureWindowsDesktopDlls(
      cacheDir: cacheDir,
      archiveName: archiveName,
      archiveSha256: archiveSha,
      version: version,
      arch: arch,
      logger: logger,
      downloadUrl: url,
    );
  } else {
    await _ensureFileFromArchive(
      dest: libFile,
      archiveName: archiveName,
      innerPath: libPathInArchive,
      archiveSha256: archiveSha,
      version: version,
      logger: logger,
      downloadUrl: url,
    );
  }

  output.assets.code.add(
    CodeAsset(
      package: 'betto_onnxrt',
      name: 'src/ort_library.dart',
      linkMode: DynamicLoadingBundled(),
      file: libFile.uri,
    ),
  );

  logger.info('betto_onnxrt: emitted CodeAsset ${libFile.path}');
}

/// Extracts the Windows ORT DLLs from the distribution ZIP in a single download.
///
/// `onnxruntime.dll` has a hard import dependency on
/// `onnxruntime_providers_shared.dll`; Windows `LoadLibrary` fails with
/// error 126 ("module not found") if only the main DLL is present. Both files
/// must live in the same directory, which must be on `PATH` at runtime.
///
/// Downloads [downloadUrl] once, verifies against [archiveSha256], then
/// extracts both DLLs to [cacheDir]. A sidecar `onnxruntime.dll.sha256`
/// records the verified archive hash so subsequent hook invocations skip the
/// download.
///
/// The companion DLL extraction is wrapped in a try-catch: future ORT releases
/// may fold `onnxruntime_providers_shared.dll` into the main DLL, in which
/// case the file will not be present in the archive. Log a warning and continue
/// so the hook does not break on future ORT updates.
Future<void> _ensureWindowsDesktopDlls({
  required Directory cacheDir,
  required String archiveName,
  required String archiveSha256,
  required String version,
  required Architecture arch,
  required Logger logger,
  required String downloadUrl,
}) async {
  final dartArch = _dartArchString(arch);
  final mainDll = File('${cacheDir.path}/onnxruntime.dll');
  final sharedDll = File('${cacheDir.path}/onnxruntime_providers_shared.dll');
  final sidecar = File('${mainDll.path}.sha256');

  // Fast path: main DLL, companion DLL, and sidecar all present and verified.
  if (mainDll.existsSync() &&
      sharedDll.existsSync() &&
      sidecar.existsSync() &&
      sidecar.readAsStringSync().trim() == archiveSha256) {
    logger.info('  cached: ${mainDll.path}');
    logger.info('  cached: ${sharedDll.path}');
    return;
  }

  logger.info('  downloading $archiveName ...');
  final archiveBytes = await _download(downloadUrl, logger);

  final actualSha = _sha256PureDart(Uint8List.fromList(archiveBytes));
  if (actualSha != archiveSha256) {
    throw StateError(
      'Archive SHA-256 mismatch for $archiveName.\n'
      '  Expected : $archiveSha256\n'
      '  Got      : $actualSha\n'
      'The download may be corrupt or tampered. Delete the cache and retry, '
      'or update version_onnx.json.',
    );
  }

  await cacheDir.create(recursive: true);

  // Extract onnxruntime.dll.
  final mainInner = 'onnxruntime-win-$dartArch-$version/lib/onnxruntime.dll';
  logger.info('  extracting onnxruntime.dll ...');
  final mainBytes = _extractFromArchive(archiveBytes, archiveName, mainInner);
  final mainTemp = File('${mainDll.path}.part');
  await mainTemp.writeAsBytes(mainBytes, flush: true);
  await mainTemp.rename(mainDll.path);
  logger.info('  staged: ${mainDll.path}');

  // Extract onnxruntime_providers_shared.dll.
  final sharedInner =
      'onnxruntime-win-$dartArch-$version/lib/onnxruntime_providers_shared.dll';
  try {
    logger.info('  extracting onnxruntime_providers_shared.dll ...');
    final sharedBytes = _extractFromArchive(
      archiveBytes,
      archiveName,
      sharedInner,
    );
    final sharedTemp = File('${sharedDll.path}.part');
    await sharedTemp.writeAsBytes(sharedBytes, flush: true);
    await sharedTemp.rename(sharedDll.path);
    logger.info('  staged: ${sharedDll.path}');
  } on StateError catch (e) {
    // Not present in this release — future ORT versions may unify the DLLs.
    logger.warning(
      '  onnxruntime_providers_shared.dll not found in archive '
      '(may not be required in this ORT version): $e',
    );
  }

  // Write sidecar after successful main DLL extraction.
  await sidecar.writeAsString(archiveSha256, flush: true);
}

/// Returns `(archiveName, pathInsideArchive, localLibFileName)` for desktop.
(String, String, String) _desktopArtifact(
  OS os,
  Architecture arch,
  String version,
) {
  final dartArch = _dartArchString(arch);

  if (os == OS.macOS) {
    // macOS x86_64 (Intel) is not a supported platform.
    if (arch == Architecture.x64) {
      throw UnsupportedError(
        'betto_onnxrt: macOS x86_64 (Intel) is not supported.',
      );
    }
    // GitHub Releases uses 'arm64' for Apple Silicon.
    final archive = 'onnxruntime-osx-$dartArch-$version.tgz';
    final inner =
        'onnxruntime-osx-$dartArch-$version/lib/libonnxruntime.$version.dylib';
    return (archive, inner, 'libonnxruntime.$version.dylib');
  }
  if (os == OS.linux) {
    // ORT Linux archives use 'aarch64' for arm64, 'x64' for x64.
    final linuxArch = arch == Architecture.arm64 ? 'aarch64' : 'x64';
    final archive = 'onnxruntime-linux-$linuxArch-$version.tgz';
    final inner =
        'onnxruntime-linux-$linuxArch-$version/lib/libonnxruntime.so.$version';
    return (archive, inner, 'libonnxruntime.so.$version');
  }
  if (os == OS.windows) {
    final archive = 'onnxruntime-win-$dartArch-$version.zip';
    // Windows zip inner path uses the archive directory prefix.
    final inner = 'onnxruntime-win-$dartArch-$version/lib/onnxruntime.dll';
    return (archive, inner, 'onnxruntime.dll');
  }
  throw UnsupportedError('Unsupported OS for betto_onnxrt desktop build: $os');
}

// ── iOS ───────────────────────────────────────────────────────────────────────

/// Builds for iOS: extracts the per-SDK Mach-O binary from the ORT XCFramework.
///
/// The hook exits early here — iOS is not supported via native-assets.
/// iOS ORT support is provided by the `betto_onnxrt_ios` SPM plugin shim.
/// The iOS SHA-256 digest is recorded in `version_onnx.json` for reference.
Future<void> _buildIos(
  BuildInput input,
  BuildOutputBuilder output,
  Logger logger,
  Architecture arch,
  Uri packageRoot,
) async {
  // Q1 spike verdict (2026-06-10): iOS native-assets cannot be used for ORT.
  //
  // The ORT iOS XCFramework ships a static library (Mach-O ar archive), not a
  // dylib. Flutter's iOS native-assets system enforces linkModePreference =
  // dynamic and rejects StaticLinking CodeAssets with:
  //   "link mode 'static' is not allowed by the input link mode preference 'dynamic'"
  //
  // iOS support requires the SPM plugin shim approach. No CodeAsset is emitted
  // here; OnnxRuntime.load() will throw an UnsupportedError on iOS until the
  // shim is implemented. See plan_betto_onnxrt_extraction.md Q1 for details.
  logger.warning(
    'betto_onnxrt: iOS native-assets not supported — ORT XCFramework is a '
    'static library; Flutter iOS requires dynamic link mode. '
    'iOS ORT requires the SPM plugin shim. No CodeAsset emitted.',
  );
}

// ── Android ───────────────────────────────────────────────────────────────────

/// Builds for Android: resolves per-ABI `.so` from the Maven AAR.
///
/// The ORT Android AAR is a ZIP archive with `.so` files under `jni/{abi}/`.
/// ABI mapping:
///   arm64  → jni/arm64-v8a/libonnxruntime.so
///   x64    → jni/x86_64/libonnxruntime.so
///   arm    → jni/armeabi-v7a/libonnxruntime.so
///   ia32   → jni/x86/libonnxruntime.so
Future<void> _buildAndroid(
  BuildInput input,
  BuildOutputBuilder output,
  Logger logger,
  Architecture arch,
  Uri packageRoot,
) async {
  final platformEntry = _loadPlatformManifest(OS.android, arch, packageRoot);
  final version = platformEntry['version'] as String;
  final mavenUrl = platformEntry['url'] as String;
  final archiveSha = platformEntry['sha256_archive'] as String;
  final perAbiMap = platformEntry['sha256_per_abi'] as Map<String, dynamic>;

  final cacheDir = _cacheDirectory(packageRoot, version);
  final versionedArchiveName = 'onnxruntime-android-$version.aar';

  final abiDir = _androidAbiDir(arch);
  final expectedSoSha = perAbiMap[abiDir] as String?;
  if (expectedSoSha == null) {
    throw StateError(
      'No per-ABI SHA-256 entry for "$abiDir" in version_onnx.json. '
      'Add the checksum to version_onnx.json.',
    );
  }

  final innerPath = 'jni/$abiDir/libonnxruntime.so';
  final libFile = File('${cacheDir.path}/android/$abiDir/libonnxruntime.so');
  await Directory(libFile.parent.path).create(recursive: true);

  await _ensureFile(
    dest: libFile,
    archiveName: versionedArchiveName,
    innerPath: innerPath,
    expectedSha256: expectedSoSha,
    version: version,
    logger: logger,
    downloadUrl: mavenUrl,
    archiveSha256: archiveSha,
  );

  output.assets.code.add(
    CodeAsset(
      package: 'betto_onnxrt',
      name: 'src/ort_library.dart',
      linkMode: DynamicLoadingBundled(),
      file: libFile.uri,
    ),
  );

  logger.info('betto_onnxrt: Android emitted CodeAsset ${libFile.path}');
}

String _androidAbiDir(Architecture arch) {
  if (arch == Architecture.arm64) return 'arm64-v8a';
  if (arch == Architecture.x64) return 'x86_64';
  if (arch == Architecture.arm) return 'armeabi-v7a';
  if (arch == Architecture.ia32) return 'x86';
  throw UnsupportedError('Unsupported Android arch: $arch');
}

// ── Platform manifest ─────────────────────────────────────────────────────────

/// Loads and returns the platform entry from `version_onnx.json` for the given
/// [os] and [arch].
///
/// The JSON file at `{packageRoot}/version_onnx.json` is the single source of
/// truth for all platform binary metadata (versions, URLs, SHA-256 digests).
///
/// Platform key mapping:
///   - macOS arm64   → `"macos-arm64"`
///   - macOS x64     → throws [UnsupportedError] (Intel Mac not supported)
///   - Linux arm64   → `"linux-aarch64"`
///   - Linux x64     → `"linux-x64"`
///   - Windows arm64 → `"windows-arm64"`
///   - Windows x64   → `"windows-x64"`
///   - Android       → `"android"` (any arch; per-ABI SHAs are inside the entry)
///   - iOS           → not reached (hook exits early; no manifest lookup needed)
Map<String, dynamic> _loadPlatformManifest(
  OS os,
  Architecture arch,
  Uri packageRoot,
) {
  final manifestFile = File.fromUri(packageRoot.resolve('version_onnx.json'));
  if (!manifestFile.existsSync()) {
    throw StateError(
      'version_onnx.json not found at ${manifestFile.path}. '
      'This file must exist in the betto_onnxrt package root.',
    );
  }

  final decoded =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final platforms = decoded['platforms'] as Map<String, dynamic>;

  final key = _platformKey(os, arch);
  final entry = platforms[key] as Map<String, dynamic>?;
  if (entry == null) {
    throw StateError(
      'No entry for platform key "$key" in version_onnx.json. '
      'Add the platform entry to version_onnx.json.',
    );
  }
  return entry;
}

/// Maps [os] and [arch] to the platform key used in `version_onnx.json`.
///
/// Throws [UnsupportedError] for explicitly unsupported combinations (macOS
/// x86_64 / Intel).
String _platformKey(OS os, Architecture arch) {
  if (os == OS.macOS) {
    if (arch == Architecture.x64) {
      throw UnsupportedError(
        'betto_onnxrt: macOS x86_64 (Intel) is not supported.',
      );
    }
    return 'macos-arm64';
  }
  if (os == OS.linux) {
    return arch == Architecture.arm64 ? 'linux-aarch64' : 'linux-x64';
  }
  if (os == OS.windows) {
    return arch == Architecture.arm64 ? 'windows-arm64' : 'windows-x64';
  }
  if (os == OS.android) {
    return 'android';
  }
  throw UnsupportedError('Unsupported OS for betto_onnxrt: $os');
}

// ── File acquisition helpers ──────────────────────────────────────────────────

/// Returns the hook cache directory: `{packageRoot}/.dart_tool/betto_onnxrt/{version}/`.
///
/// Using `.dart_tool/` ensures the directory is gitignored and version-scoped
/// so a version bump causes a fresh download.
Directory _cacheDirectory(Uri packageRoot, String version) {
  return Directory.fromUri(
    packageRoot.resolve('.dart_tool/betto_onnxrt/$version/'),
  );
}

/// Ensures [dest] exists, verifying integrity against the archive SHA-256.
///
/// Used for **desktop** platforms (macOS, Linux, Windows) where `version_onnx.json`
/// carries an archive-level digest (`sha256`) rather than a per-extracted-file
/// digest.
///
/// ## Fast path (cache hit)
///
/// [dest] and a companion sidecar `{dest.path}.sha256` are both present and
/// the sidecar content equals [archiveSha256] — the cached binary was produced
/// from a verified archive and is trusted without re-downloading.
///
/// ## Cold start
///
/// Downloads the archive from [downloadUrl], verifies it against [archiveSha256],
/// extracts [innerPath], writes [dest] atomically via a `.part` temp file, and
/// writes the sidecar so future invocations hit the fast path.
///
/// ## Crash safety
///
/// Downloads use a `.part` temp file — a partial download never passes the
/// sidecar check. The sidecar is written only after [dest] is in place.
/// Last-writer-wins on the atomic rename is safe because concurrent writers
/// verify the same archive and produce byte-identical output.
Future<void> _ensureFileFromArchive({
  required File dest,
  required String archiveName,
  required String innerPath,
  required String archiveSha256,
  required String version,
  required Logger logger,
  required String downloadUrl,
}) async {
  // Fast path: dest and sidecar exist and sidecar records the expected archive
  // SHA. This means the binary was previously extracted from a verified archive.
  final sidecar = File('${dest.path}.sha256');
  if (dest.existsSync() && sidecar.existsSync()) {
    final storedSha = sidecar.readAsStringSync().trim();
    if (storedSha == archiveSha256) {
      logger.info('  cached: ${dest.path}');
      if (Platform.isMacOS) await _stripXattrs(dest, logger);
      return;
    }
  }

  await dest.parent.create(recursive: true);

  logger.info('  downloading $archiveName ...');
  final archiveBytes = await _download(downloadUrl, logger);

  // Archive-level integrity check: verify before extracting.
  // Any mismatch throws immediately — no bypass.
  final actualArchiveSha = _sha256PureDart(Uint8List.fromList(archiveBytes));
  if (actualArchiveSha != archiveSha256) {
    throw StateError(
      'Archive SHA-256 mismatch for $archiveName.\n'
      '  Expected : $archiveSha256\n'
      '  Got      : $actualArchiveSha\n'
      'The download may be corrupt or tampered. Delete the cache and retry, '
      'or update version_onnx.json.',
    );
  }

  logger.info('  extracting $innerPath ...');
  final fileBytes = _extractFromArchive(archiveBytes, archiveName, innerPath);

  // Write to a .part temp file, then atomically rename.
  final tempFile = File('${dest.path}.part');
  await tempFile.writeAsBytes(fileBytes, flush: true);
  await tempFile.rename(dest.path);
  if (Platform.isMacOS) await _stripXattrs(dest, logger);

  // Write the sidecar so subsequent builds hit the fast path.
  await sidecar.writeAsString(archiveSha256, flush: true);
  logger.info('  staged: ${dest.path}');
}

/// Ensures [dest] exists and its SHA-256 matches [expectedSha256].
///
/// Used for **Android** where `version_onnx.json` carries both an
/// archive-level digest (`sha256_archive`) and a per-ABI extracted-file
/// digest (`sha256_per_abi`). Two-level verification is applied.
///
/// If [dest] is already present and its SHA-256 matches [expectedSha256],
/// returns immediately (fast path). Otherwise downloads the archive from
/// [downloadUrl], verifies it against [archiveSha256], extracts [innerPath],
/// verifies the extracted file, and atomically renames to [dest].
///
/// ## Two-level verification
///
/// When [archiveSha256] is provided, the downloaded archive bytes are
/// checksummed before extraction begins. This guards against a substituted or
/// tampered archive (e.g. a man-in-the-middle AAR that contains the expected
/// `.so` alongside additional malicious entries). Any checksum mismatch throws
/// immediately — there is no bypass.
///
/// ## Crash safety
///
/// Downloads use a `.part` temp file — a partial download can never pass the
/// existence+checksum check on a subsequent run. Last-writer-wins on the
/// atomic rename is safe because concurrent writers produce byte-identical,
/// SHA-256-verified output.
Future<void> _ensureFile({
  required File dest,
  required String archiveName,
  required String innerPath,
  required String expectedSha256,
  required String version,
  required Logger logger,
  String? downloadUrl,
  String? archiveSha256,
}) async {
  // Fast path: file already present and checksum valid.
  if (await _isValid(dest, expectedSha256)) {
    logger.info('  cached: ${dest.path}');
    if (Platform.isMacOS) await _stripXattrs(dest, logger);
    return;
  }

  await dest.parent.create(recursive: true);

  final url =
      downloadUrl ??
      'https://github.com/microsoft/onnxruntime/releases/download'
          '/v$version/$archiveName';

  logger.info('  downloading $archiveName ...');
  final archiveBytes = await _download(url, logger);

  // Archive-level integrity check (two-level verification, first gate).
  // When archiveSha256 is provided, verify the downloaded archive before
  // extracting. Any mismatch throws immediately.
  if (archiveSha256 != null) {
    final actualArchiveSha = _sha256PureDart(Uint8List.fromList(archiveBytes));
    if (actualArchiveSha != archiveSha256) {
      throw StateError(
        'Archive SHA-256 mismatch for $archiveName.\n'
        '  Expected : $archiveSha256\n'
        '  Got      : $actualArchiveSha\n'
        'The download may be corrupt or tampered. Delete the cache and retry, '
        'or update version_onnx.json.',
      );
    }
  }

  logger.info('  extracting $innerPath ...');
  final fileBytes = _extractFromArchive(archiveBytes, archiveName, innerPath);

  // Extracted-file integrity check (two-level verification, second gate).
  // Verify SHA-256 before writing. Any mismatch throws immediately.
  final actualSha = _sha256PureDart(Uint8List.fromList(fileBytes));
  if (actualSha != expectedSha256) {
    throw StateError(
      'SHA-256 mismatch for $archiveName ($innerPath).\n'
      '  Expected : $expectedSha256\n'
      '  Got      : $actualSha\n'
      'The download may be corrupt. Delete the cache and retry, or update '
      'version_onnx.json.',
    );
  }

  // Write to a .part temp file, then atomically rename.
  // Last-writer-wins is safe: concurrent writers produce identical output.
  final tempFile = File('${dest.path}.part');
  await tempFile.writeAsBytes(fileBytes, flush: true);
  await tempFile.rename(dest.path);
  if (Platform.isMacOS) await _stripXattrs(dest, logger);
  logger.info('  staged: ${dest.path}');
}

/// Returns `true` if [file] is present and its SHA-256 matches [expectedHex].
///
/// Strips all extended attributes from [file] on macOS.
///
/// macOS sets `com.apple.provenance` (and sometimes `com.apple.quarantine`)
/// on any file that was written by a process that downloaded it from the
/// network. `install_name_tool`, which Dart's native-assets bundler runs when
/// packaging dylibs for test/run, refuses to modify files carrying those
/// attributes — producing "cannot rename … XXXXXX: No such file or directory".
Future<void> _stripXattrs(File file, Logger logger) async {
  final result = await Process.run('xattr', ['-c', file.path]);
  if (result.exitCode != 0) {
    logger.warning('  xattr -c failed for ${file.path}: ${result.stderr}');
  }
}

/// Returns `true` if [file] is present and its SHA-256 matches [expectedHex].
///
/// Returns `false` if the file does not exist or if the digest check fails.
/// There is no bypass for placeholder values — a real digest must be present
/// for the cached file to be trusted.
Future<bool> _isValid(File file, String expectedHex) async {
  if (!file.existsSync()) return false;
  try {
    final bytes = await file.readAsBytes();
    return _sha256PureDart(bytes) == expectedHex;
  } catch (_) {
    return false;
  }
}

/// Downloads [url] and returns the raw bytes.
Future<List<int>> _download(String url, Logger logger) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(url);
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Failed to download ORT (HTTP ${response.statusCode}): $url',
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.toBytes();
  } finally {
    client.close();
  }
}

/// Extracts a single file ([innerPath]) from an archive byte array.
///
/// Supports `.tgz` / `.tar.gz` and `.zip` / `.aar` archives.
/// [archiveName] is used only to determine archive type.
List<int> _extractFromArchive(
  List<int> archiveBytes,
  String archiveName,
  String innerPath,
) {
  if (archiveName.endsWith('.zip') || archiveName.endsWith('.aar')) {
    return _extractFromZip(archiveBytes, innerPath, archiveName);
  }
  if (archiveName.endsWith('.tgz') || archiveName.endsWith('.tar.gz')) {
    return _extractFromTar(archiveBytes, innerPath, archiveName);
  }
  throw UnsupportedError('Unknown archive format: $archiveName');
}

/// Extracts [innerPath] from a ZIP/AAR [archiveBytes].
///
/// This is a minimal ZIP reader that handles the central directory and local
/// file headers. It supports DEFLATE (method 8) and stored (method 0) entries.
/// ORT archives use standard ZIP with DEFLATE compression.
List<int> _extractFromZip(
  List<int> archiveBytes,
  String innerPath,
  String archiveName,
) {
  final bytes = Uint8List.fromList(archiveBytes);

  // Locate End of Central Directory record (EOCD) by scanning from the end.
  // EOCD signature: 0x06054b50 (little-endian).
  int eocdOffset = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset < 0) {
    throw StateError('Invalid ZIP archive: $archiveName — EOCD not found');
  }

  // Read central directory location from EOCD.
  final cdOffset = _readUint32LE(bytes, eocdOffset + 16);
  final cdSize = _readUint32LE(bytes, eocdOffset + 12);
  final entryCount = _readUint16LE(bytes, eocdOffset + 10);

  // Walk central directory entries to find the target file.
  // Collect all names so we can include them in the not-found error message.
  var pos = cdOffset;
  final allNames = <String>[];
  for (var i = 0; i < entryCount && pos < cdOffset + cdSize; i++) {
    // Central directory file header signature: 0x02014b50
    if (_readUint32LE(bytes, pos) != 0x02014b50) {
      throw StateError('Invalid central directory header at offset $pos');
    }

    final compressionMethod = _readUint16LE(bytes, pos + 10);
    final compressedSize = _readUint32LE(bytes, pos + 20);
    final fileNameLen = _readUint16LE(bytes, pos + 28);
    final extraLen = _readUint16LE(bytes, pos + 30);
    final commentLen = _readUint16LE(bytes, pos + 32);
    final localHeaderOffset = _readUint32LE(bytes, pos + 42);

    final nameEnd = pos + 46 + fileNameLen;
    final fileName = utf8.decode(bytes.sublist(pos + 46, nameEnd));
    pos += 46 + fileNameLen + extraLen + commentLen;

    allNames.add(fileName);
    if (fileName != innerPath) continue;

    // Found — read the local file header to get to the actual data.
    // LFH signature: 0x04034b50
    if (_readUint32LE(bytes, localHeaderOffset) != 0x04034b50) {
      throw StateError('Invalid local file header at $localHeaderOffset');
    }
    final lfhFileNameLen = _readUint16LE(bytes, localHeaderOffset + 26);
    final lfhExtraLen = _readUint16LE(bytes, localHeaderOffset + 28);
    final dataStart = localHeaderOffset + 30 + lfhFileNameLen + lfhExtraLen;
    final compressed = bytes.sublist(dataStart, dataStart + compressedSize);

    if (compressionMethod == 0) {
      return compressed; // stored — no compression
    }
    if (compressionMethod == 8) {
      // ZIP uses raw DEFLATE (no zlib header/trailer); ZLibDecoder(raw:true)
      // skips the zlib envelope that plain zlib.decoder expects.
      return ZLibDecoder(raw: true).convert(compressed);
    }
    throw UnsupportedError(
      'Unsupported ZIP compression method $compressionMethod in $archiveName',
    );
  }

  throw StateError(
    'Entry "$innerPath" not found in $archiveName.\n'
    'Available entries:\n${allNames.map((n) => '  $n').join('\n')}',
  );
}

/// Extracts [innerPath] from a `.tgz` (gzip-compressed TAR) [archiveBytes].
///
/// Supports POSIX/ustar headers and GNU long name records (typeflag 'L').
/// ORT tarballs use these standard formats.
List<int> _extractFromTar(
  List<int> archiveBytes,
  String innerPath,
  String archiveName,
) {
  // Decompress gzip envelope.
  final tarBytes = Uint8List.fromList(gzip.decode(archiveBytes));

  var pos = 0;
  String? pendingLongName;

  while (pos + 512 <= tarBytes.length) {
    final header = tarBytes.sublist(pos, pos + 512);

    // Two consecutive 512-byte zero blocks signal end of archive.
    if (header.every((b) => b == 0)) break;

    pos += 512;

    // Parse filename from the 100-byte name field (null-terminated, UTF-8).
    final nameBytes = header.sublist(0, 100);
    final nameNulIdx = nameBytes.indexOf(0);
    var entryName = utf8.decode(
      nameBytes.sublist(0, nameNulIdx < 0 ? 100 : nameNulIdx),
    );

    // GNU long-name record: typeflag == 0x4c ('L').
    // The data block(s) that follow contain the full path (null-terminated).
    final typeFlag = header[156];
    if (typeFlag == 0x4c) {
      final sizeStr = utf8.decode(header.sublist(124, 135)).trim();
      final dataSize = int.parse(sizeStr.isEmpty ? '0' : sizeStr, radix: 8);
      final nameData = tarBytes.sublist(pos, pos + dataSize);
      final nameNul = nameData.indexOf(0);
      pendingLongName = utf8.decode(
        nameData.sublist(0, nameNul < 0 ? nameData.length : nameNul),
      );
      pos += _tarBlockSize(dataSize);
      continue;
    }

    // Apply the pending long name (from a preceding GNU 'L' record).
    if (pendingLongName != null) {
      entryName = pendingLongName;
      pendingLongName = null;
    }

    // Parse the octal file size from the 12-byte size field.
    final sizeStr = utf8.decode(header.sublist(124, 135)).trim();
    final dataSize = int.parse(sizeStr.isEmpty ? '0' : sizeStr, radix: 8);

    // Normalise entry name (strip leading ./ if present).
    final normalised = entryName.startsWith('./')
        ? entryName.substring(2)
        : entryName;
    if (normalised == innerPath) {
      return tarBytes.sublist(pos, pos + dataSize);
    }

    pos += _tarBlockSize(dataSize);
  }

  throw StateError('Entry "$innerPath" not found in $archiveName');
}

/// Rounds [size] up to the next 512-byte TAR block boundary.
int _tarBlockSize(int size) => ((size + 511) ~/ 512) * 512;

// ── Integer helpers ───────────────────────────────────────────────────────────

/// Reads a little-endian unsigned 16-bit integer from [bytes] at [offset].
int _readUint16LE(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// Reads a little-endian unsigned 32-bit integer from [bytes] at [offset].
int _readUint32LE(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// Maps a `code_assets` [Architecture] to the CPU arch string used in ORT
/// GitHub Releases filenames.
String _dartArchString(Architecture arch) {
  if (arch == Architecture.arm64) return 'arm64';
  if (arch == Architecture.x64) return 'x64';
  if (arch == Architecture.arm) return 'arm';
  if (arch == Architecture.ia32) return 'x86';
  throw UnsupportedError('Unsupported architecture for betto_onnxrt: $arch');
}

// ── Pure-Dart SHA-256 ─────────────────────────────────────────────────────────

/// Computes the lowercase hex SHA-256 digest of [message].
///
/// This pure-Dart implementation (FIPS 180-4) is used instead of
/// `package:crypto` to keep the hook dependency footprint minimal. The hook
/// runs at build time; adding `crypto` would require it as a dependency of
/// `betto_onnxrt` itself, which is unnecessary for the production library.
String _sha256PureDart(Uint8List message) {
  // Initial hash values: first 32 bits of fractional parts of sqrt of first 8
  // primes (2, 3, 5, 7, 11, 13, 17, 19).
  final h = Uint32List.fromList([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);

  // Round constants: first 32 bits of fractional parts of cbrt of first 64
  // primes.
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  // Pre-processing: pad message to a multiple of 512 bits.
  // Append 0x80, then zero bytes, then 64-bit big-endian bit length.
  final msgLen = message.length;
  final bitLen = msgLen * 8;
  // Padded length: next multiple of 64 bytes such that (padded - 8) >= msgLen + 1.
  final paddedLen = ((msgLen + 1 + 8 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLen);
  padded.setRange(0, msgLen, message);
  padded[msgLen] = 0x80; // append bit '1' followed by zeros
  // Append 64-bit big-endian bit length in the last 8 bytes.
  for (var i = 0; i < 8; i++) {
    padded[paddedLen - 8 + i] = (bitLen >> (56 - i * 8)) & 0xff;
  }

  // Process each 512-bit (64-byte) chunk.
  final w = Uint32List(64);
  for (var chunk = 0; chunk < paddedLen; chunk += 64) {
    // Prepare the message schedule: first 16 words from the chunk.
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[chunk + i * 4] << 24) |
          (padded[chunk + i * 4 + 1] << 16) |
          (padded[chunk + i * 4 + 2] << 8) |
          padded[chunk + i * 4 + 3];
    }
    // Extend to 64 words.
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 =
          _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = _u32(w[i - 16] + s0 + w[i - 7] + s1);
    }

    // Initialise working variables.
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];

    // 64 rounds of compression.
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = _u32(hh + s1 + ch + k[i] + w[i]);
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = _u32(s0 + maj);

      hh = g;
      g = f;
      f = e;
      e = _u32(d + temp1);
      d = c;
      c = b;
      b = a;
      a = _u32(temp1 + temp2);
    }

    // Add the compressed chunk to the current hash value.
    h[0] = _u32(h[0] + a);
    h[1] = _u32(h[1] + b);
    h[2] = _u32(h[2] + c);
    h[3] = _u32(h[3] + d);
    h[4] = _u32(h[4] + e);
    h[5] = _u32(h[5] + f);
    h[6] = _u32(h[6] + g);
    h[7] = _u32(h[7] + hh);
  }

  // Produce the final 256-bit (32-byte) digest as a lowercase hex string.
  final sb = StringBuffer();
  for (final word in h) {
    sb.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}

/// Right-rotates the 32-bit integer [x] by [n] positions.
int _rotr32(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

/// Truncates [x] to 32 bits (unsigned).
int _u32(int x) => x & 0xffffffff;
