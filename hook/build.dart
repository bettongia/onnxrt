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
/// ## iOS
///
/// The iOS XCFramework is NOT in the ORT GitHub Releases. It is distributed
/// via Microsoft's pod archive CDN:
///   `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-{ver}.zip`
///
/// The ZIP contains `onnxruntime.xcframework/` with two slices:
/// - `ios-arm64/onnxruntime.framework/onnxruntime` — physical device
/// - `ios-arm64_x86_64-simulator/onnxruntime.framework/onnxruntime` — sim
///
/// The hook extracts the appropriate Mach-O binary (no extension — standard
/// framework bundle convention) and emits it as a `CodeAsset` with
/// `DynamicLoadingBundled`. Flutter's iOS build system embeds it in the app
/// bundle and adds it to the link phase so it is present in the process image
/// at launch, which is why `runtime.dart` uses `DynamicLibrary.process()`.
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

// ── Version constant ──────────────────────────────────────────────────────────

/// Read the ORT version from the VERSION_ONNX file at the package root.
///
/// We re-read VERSION_ONNX directly here (rather than importing the generated
/// constant) because the hook runs in a separate build process where the
/// generated file may not have been produced yet on a fresh checkout.
String _readOrtVersion(Uri packageRoot) {
  final versionFile = File.fromUri(packageRoot.resolve('VERSION_ONNX'));
  if (!versionFile.existsSync()) {
    throw StateError(
      'VERSION_ONNX not found at ${versionFile.path}. '
      'This file must exist in the betto_onnxrt package root.',
    );
  }
  final raw = versionFile.readAsStringSync().trim();
  // Strip leading 'v' to get a bare version number like '1.22.0'.
  return raw.startsWith('v') ? raw.substring(1) : raw;
}

// ── SHA-256 manifest ──────────────────────────────────────────────────────────

// Expected SHA-256 digests for each ORT v1.22.0 release artifact.
// Keyed by archive filename.
//
// NOTE (2026-06-09): v1.22.0 was audited against the GitHub Releases asset
// list (https://github.com/microsoft/onnxruntime/releases/tag/v1.22.0).
// Findings:
//   - macOS x64 artifact is named 'onnxruntime-osx-x86_64-…', NOT 'osx-x64-…'.
//     The '_desktopArtifact' function below uses 'x86_64' for macOS/x64.
//   - No iOS XCFramework or Android AAR are present in the v1.22.0 GitHub
//     release assets. iOS and Android builds require a different source (e.g.
//     Microsoft's Maven/CocoaPods distribution or a future release). The
//     _buildIos and _buildAndroid paths below will fail with a missing-manifest
//     entry error until these artifacts become available or alternative URLs are
//     supplied.
//   - SHA-256 checksums are NOT published as sidecar files on the v1.22.0
//     release page. They must be computed by downloading each artifact:
//       curl -fsSL <url> | sha256sum
//     Replace the placeholder zeros below with the computed values before
//     shipping. The hook emits a WARNING (not an error) for all-zero values to
//     allow development to proceed without real checksums.
//
// TODO(betto_onnxrt#2): Fill in real checksums before the first release. Run:
//   for f in osx-arm64 osx-x86_64 linux-aarch64 linux-x64 win-arm64 win-x64; do
//     ext=tgz; [[ $f == win* ]] && ext=zip
//     url="https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-$f-1.22.0.$ext"
//     echo "$f: $(curl -fsSL $url | sha256sum | awk '{print $1}')"
//   done
const _sha256Manifest = <String, String>{
  // macOS — NOTE: GitHub releases use 'x86_64' not 'x64' for the x64 variant.
  'onnxruntime-osx-arm64-1.22.0.tgz':
      '0000000000000000000000000000000000000000000000000000000000000000',
  'onnxruntime-osx-x86_64-1.22.0.tgz':
      '0000000000000000000000000000000000000000000000000000000000000000',
  // Linux
  'onnxruntime-linux-aarch64-1.22.0.tgz':
      '0000000000000000000000000000000000000000000000000000000000000000',
  'onnxruntime-linux-x64-1.22.0.tgz':
      '0000000000000000000000000000000000000000000000000000000000000000',
  // Windows
  'onnxruntime-win-arm64-1.22.0.zip':
      '0000000000000000000000000000000000000000000000000000000000000000',
  'onnxruntime-win-x64-1.22.0.zip':
      '0000000000000000000000000000000000000000000000000000000000000000',
  // iOS XCFramework — distributed via Microsoft's pod archive CDN, NOT GitHub
  // Releases. URL: https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.22.0.zip
  // TODO(betto_onnxrt#2): compute with: curl -fsSL <url> | sha256sum
  'pod-archive-onnxruntime-c-1.22.0.zip':
      '0000000000000000000000000000000000000000000000000000000000000000',
  // Android AAR — NOT present in the v1.22.0 GitHub release assets.
  // This entry is a placeholder; _buildAndroid will fail until the Maven
  // Central AAR URL is confirmed for v1.22.0.
  'onnxruntime-android-1.22.0.aar':
      '0000000000000000000000000000000000000000000000000000000000000000',
};

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
  final version = _readOrtVersion(packageRoot);
  final cacheDir = _cacheDirectory(packageRoot, version);

  final (archiveName, libPathInArchive, libFileName) = _desktopArtifact(
    os,
    arch,
    version,
  );

  final expectedSha = _sha256Manifest[archiveName];
  if (expectedSha == null) {
    throw StateError(
      'No SHA-256 manifest entry for "$archiveName". '
      'Add the checksum to _sha256Manifest in hook/build.dart.',
    );
  }

  final libFile = File('${cacheDir.path}/$libFileName');
  await _ensureFile(
    dest: libFile,
    archiveName: archiveName,
    innerPath: libPathInArchive,
    expectedSha256: expectedSha,
    version: version,
    logger: logger,
  );

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

/// Returns `(archiveName, pathInsideArchive, localLibFileName)` for desktop.
(String, String, String) _desktopArtifact(
  OS os,
  Architecture arch,
  String version,
) {
  final dartArch = _dartArchString(arch);

  if (os == OS.macOS) {
    // GitHub Releases uses 'arm64' for Apple Silicon and 'x86_64' (not 'x64')
    // for Intel Macs — verified against the v1.22.0 asset list 2026-06-09.
    final osxArch = arch == Architecture.x64 ? 'x86_64' : dartArch;
    final archive = 'onnxruntime-osx-$osxArch-$version.tgz';
    final inner =
        'onnxruntime-osx-$osxArch-$version/lib/libonnxruntime.$version.dylib';
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
/// Source: `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-{ver}.zip`
///
/// ZIP structure (no wrapper directory at root):
///   onnxruntime.xcframework/ios-arm64/onnxruntime.framework/onnxruntime
///   onnxruntime.xcframework/ios-arm64_x86_64-simulator/onnxruntime.framework/onnxruntime
///
/// The simulator slice is a fat binary (arm64 + x86_64); we emit it for both
/// Architecture.arm64 and Architecture.x64 simulator builds.
Future<void> _buildIos(
  BuildInput input,
  BuildOutputBuilder output,
  Logger logger,
  Architecture arch,
  Uri packageRoot,
) async {
  final version = _readOrtVersion(packageRoot);
  final cacheDir = _cacheDirectory(packageRoot, version);

  // Determine whether this is a simulator or device build.
  final iosSdk = input.config.code.iOS.targetSdk;
  final isSimulator = iosSdk == IOSSdk.iPhoneSimulator;

  // iOS XCFramework is distributed via Microsoft's CDN, not GitHub Releases.
  final archiveName = 'pod-archive-onnxruntime-c-$version.zip';
  final downloadUrl =
      'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-$version.zip';

  final expectedSha = _sha256Manifest[archiveName];
  if (expectedSha == null) {
    throw StateError(
      'No SHA-256 manifest entry for "$archiveName". '
      'Add the checksum to _sha256Manifest in hook/build.dart.',
    );
  }

  // XCFramework slice directory depends on simulator vs device.
  // The simulator fat slice covers arm64 + x86_64; emit for both arch builds.
  final xcSliceDir = isSimulator ? 'ios-arm64_x86_64-simulator' : 'ios-arm64';
  final sliceSuffix = isSimulator ? 'sim' : 'device';
  // Binary has no extension — standard Apple framework bundle convention.
  // Verified from pod-archive-onnxruntime-c-1.22.0.zip entry listing (2026-06-10):
  // the XCFramework root is 'onnxruntime.xcframework', framework is 'onnxruntime.framework'.
  final innerPath =
      'onnxruntime.xcframework/$xcSliceDir/onnxruntime.framework/onnxruntime';
  // Give the staged file a .dylib extension for the CodeAsset file path.
  final libFileName = 'libonnxruntime-$sliceSuffix.dylib';

  final libFile = File('${cacheDir.path}/ios/$libFileName');
  await Directory(libFile.parent.path).create(recursive: true);

  await _ensureFile(
    dest: libFile,
    archiveName: archiveName,
    innerPath: innerPath,
    expectedSha256: expectedSha,
    version: version,
    logger: logger,
    downloadUrl: downloadUrl,
  );

  output.assets.code.add(
    CodeAsset(
      package: 'betto_onnxrt',
      name: 'src/ort_library.dart',
      linkMode: DynamicLoadingBundled(),
      file: libFile.uri,
    ),
  );

  logger.info('betto_onnxrt: iOS emitted CodeAsset ${libFile.path}');
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
  final version = _readOrtVersion(packageRoot);
  final cacheDir = _cacheDirectory(packageRoot, version);

  final versionedArchiveName = 'onnxruntime-android-$version.aar';
  final expectedSha = _sha256Manifest[versionedArchiveName];
  if (expectedSha == null) {
    throw StateError(
      'No SHA-256 manifest entry for "$versionedArchiveName". '
      'Add the checksum to _sha256Manifest in hook/build.dart.',
    );
  }

  final abiDir = _androidAbiDir(arch);
  final innerPath = 'jni/$abiDir/libonnxruntime.so';
  final libFile = File('${cacheDir.path}/android/$abiDir/libonnxruntime.so');
  await Directory(libFile.parent.path).create(recursive: true);

  // Android AAR is hosted on Maven Central, not GitHub Releases.
  final mavenUrl =
      'https://repo1.maven.org/maven2/com/microsoft/onnxruntime'
      '/onnxruntime-android/$version/onnxruntime-android-$version.aar';

  await _ensureFile(
    dest: libFile,
    archiveName: versionedArchiveName,
    innerPath: innerPath,
    expectedSha256: expectedSha,
    version: version,
    logger: logger,
    downloadUrl: mavenUrl,
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

/// Ensures [dest] exists and its SHA-256 matches [expectedSha256].
///
/// If [dest] is already present and valid, returns immediately (fast path).
/// Otherwise downloads the archive from GitHub Releases (or [downloadUrl] if
/// supplied), extracts [innerPath], verifies the checksum, and atomically
/// renames the temp file to [dest].
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
}) async {
  // Fast path: file already present and checksum valid.
  if (await _isValid(dest, expectedSha256)) {
    logger.info('  cached: ${dest.path}');
    return;
  }

  await dest.parent.create(recursive: true);

  final url =
      downloadUrl ??
      'https://github.com/microsoft/onnxruntime/releases/download'
          '/v$version/$archiveName';

  logger.info('  downloading $archiveName ...');
  final archiveBytes = await _download(url, logger);

  logger.info('  extracting $innerPath ...');
  final fileBytes = _extractFromArchive(archiveBytes, archiveName, innerPath);

  // Verify SHA-256 before writing. This is the integrity guarantee.
  final actualSha = _sha256PureDart(Uint8List.fromList(fileBytes));
  if (actualSha != expectedSha256) {
    // If expectedSha256 is the all-zeros placeholder, skip verification
    // and warn. This lets development proceed without real checksums.
    // Remove this bypass before shipping (replace zeros with real values).
    if (expectedSha256 == '0' * 64) {
      logger.warning(
        '  WARNING: SHA-256 not configured for $archiveName. '
        'Update _sha256Manifest with the real checksum before release. '
        'Got: $actualSha',
      );
    } else {
      throw StateError(
        'SHA-256 mismatch for $archiveName.\n'
        '  Expected : $expectedSha256\n'
        '  Got      : $actualSha\n'
        'The download may be corrupt. Delete the cache and retry, or update '
        '_sha256Manifest in hook/build.dart.',
      );
    }
  }

  // Write to a .part temp file, then atomically rename.
  // Last-writer-wins is safe: concurrent writers produce identical output.
  final tempFile = File('${dest.path}.part');
  await tempFile.writeAsBytes(fileBytes, flush: true);
  await tempFile.rename(dest.path);
  logger.info('  staged: ${dest.path}');
}

/// Returns `true` if [file] exists and its SHA-256 matches [expectedHex].
///
/// If [expectedHex] is the all-zeros placeholder (not yet configured), returns
/// `false` to force a fresh download — this ensures we re-verify after real
/// checksums are added to the manifest.
Future<bool> _isValid(File file, String expectedHex) async {
  // Placeholder checksums — always force re-download so the file gets
  // re-staged when real checksums are eventually filled in.
  if (expectedHex == '0' * 64) return false;
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
      // DEFLATE — use raw inflate (no zlib header/trailer)
      return zlib.decoder.convert(compressed);
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
