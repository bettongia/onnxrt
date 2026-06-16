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

import 'dart:async';
import 'dart:io';

import 'package:betto_onnxrt/betto_onnxrt.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

// ── Mock HTTP infrastructure ──────────────────────────────────────────────────

/// Returns the lowercase hex SHA-256 digest of [bytes].
String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// A minimal fake HTTP server for testing [ModelDownloader].
///
/// [responses] maps URL strings to the byte content returned for that URL.
/// Set [statusCode] to a non-2xx value to simulate server errors.
class _FakeHttpServer {
  _FakeHttpServer({this.statusCode = 200, Map<String, List<int>>? responses})
    : _responses = responses ?? {};

  final int statusCode;
  final Map<String, List<int>> _responses;

  /// Ordered list of URLs that have been requested, for assertion.
  final List<String> requestedUrls = [];

  HttpClient get client => _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._server);
  final _FakeHttpServer _server;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _server.requestedUrls.add(url.toString());
    return _FakeHttpClientRequest(_server, url);
  }

  @override
  void close({bool force = false}) {}

  // Unimplemented stubs — only getUrl is exercised by ModelDownloader.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._server, this._url);
  final _FakeHttpServer _server;
  final Uri _url;

  @override
  Future<HttpClientResponse> close() async {
    final body = _server._responses[_url.toString()] ?? <int>[];
    return _FakeHttpClientResponse(statusCode: _server.statusCode, body: body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse({required this.statusCode, required this._body});

  @override
  final int statusCode;
  final List<int> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final ctrl = StreamController<List<int>>();
    ctrl.add(_body);
    ctrl.close();
    return ctrl.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  HttpHeaders get headers => _FakeHeaders(contentLength: _body.length);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders({required this.contentLength});

  @override
  final int contentLength;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── An allowlist that accepts only a known model id ───────────────────────────

class _StrictAllowlist implements AllowlistProvider {
  _StrictAllowlist(this._allowedId);
  final String _allowedId;

  @override
  bool isAllowed(ModelSpec spec) => spec.id == _allowedId;
}

// ── Helper: build a ModelSpec with generated checksums ────────────────────────

/// Constructs a [ModelSpec] whose [ModelFile.sha256] fields are computed from
/// [onnxBytes] and [configBytes] respectively so that the [ModelDownloader]
/// checksum verification passes when those exact bytes are served.
ModelSpec _makeSpec({
  required String id,
  required List<int> onnxBytes,
  required List<int> configBytes,
}) {
  final onnxUrl = Uri.parse('https://example.com/$id/model.onnx');
  final configUrl = Uri.parse('https://example.com/$id/config.json');
  return ModelSpec(
    id: id,
    files: {
      'onnx': ModelFile(url: onnxUrl, sha256: _sha256Hex(onnxBytes)),
      'config': ModelFile(url: configUrl, sha256: _sha256Hex(configBytes)),
    },
    meta: {'dimensions': 384},
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'betto_onnxrt_downloader_test_',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ── Successful download ─────────────────────────────────────────────────────

  group('ModelDownloader — successful download', () {
    test('downloads both files and returns correct paths', () async {
      final onnxBytes = [1, 2, 3, 4, 5];
      final configBytes = [10, 20, 30];
      final spec = _makeSpec(
        id: 'test-model',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      final resolved = await downloader.ensure(spec, cacheDir: tempDir.path);

      expect(File(resolved.filePaths['onnx']!).existsSync(), isTrue);
      expect(File(resolved.filePaths['config']!).existsSync(), isTrue);
      expect(
        File(resolved.filePaths['onnx']!).readAsBytesSync(),
        equals(onnxBytes),
      );
      expect(
        File(resolved.filePaths['config']!).readAsBytesSync(),
        equals(configBytes),
      );
    });

    test('creates model subdirectory inside cacheDir', () async {
      final onnxBytes = [1, 2];
      final configBytes = [3, 4];
      final spec = _makeSpec(
        id: 'subdir-test',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await downloader.ensure(spec, cacheDir: tempDir.path);

      // Model files are placed in a subdirectory named after the model ID.
      final modelDir = Directory('${tempDir.path}/subdir-test');
      expect(modelDir.existsSync(), isTrue);
    });

    test('ResolvedModel carries the original spec', () async {
      final onnxBytes = [0xAB, 0xCD];
      final configBytes = [0xEF];
      final spec = _makeSpec(
        id: 'resolve-spec',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );
      final resolved = await downloader.ensure(spec, cacheDir: tempDir.path);

      expect(resolved.spec.id, equals('resolve-spec'));
      expect(resolved.spec.meta['dimensions'], equals(384));
    });

    test('invokes progress callback during download', () async {
      final onnxBytes = List<int>.generate(1000, (i) => i % 256);
      final configBytes = List<int>.generate(200, (i) => i % 256);
      final spec = _makeSpec(
        id: 'progress-test',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final progressCalls = <({int received, int total})>[];

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await downloader.ensure(
        spec,
        cacheDir: tempDir.path,
        onProgress: (received, total) {
          progressCalls.add((received: received, total: total));
        },
      );

      // At least one progress event should have been fired per file.
      expect(progressCalls, isNotEmpty);
      // The last progress call for the first file should report its full length.
      expect(progressCalls.any((c) => c.received == onnxBytes.length), isTrue);
    });
  });

  // ── Present-file short-circuit ──────────────────────────────────────────────

  group('ModelDownloader — present-file short-circuit', () {
    test(
      'skips download when both files are cached with correct checksums',
      () async {
        final onnxBytes = [1, 2, 3];
        final configBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'cached-model',
          onnxBytes: onnxBytes,
          configBytes: configBytes,
        );

        // Pre-populate the cache with correctly named files and correct content.
        final modelDir = Directory('${tempDir.path}/cached-model');
        await modelDir.create(recursive: true);
        // The downloader derives local filenames from the URL path segment.
        await File('${modelDir.path}/model.onnx').writeAsBytes(onnxBytes);
        await File('${modelDir.path}/config.json').writeAsBytes(configBytes);

        // Server returns wrong bytes — proves it is never contacted.
        final server = _FakeHttpServer(
          responses: {
            spec.files['onnx']!.url.toString(): [99],
            spec.files['config']!.url.toString(): [99],
          },
        );

        final downloader = ModelDownloader(
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec, cacheDir: tempDir.path);

        expect(server.requestedUrls, isEmpty);
      },
    );

    test('re-downloads only the file with a bad checksum', () async {
      final onnxBytes = [1, 2, 3];
      final configBytes = [4, 5, 6];
      final spec = _makeSpec(
        id: 'partial-cache',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      // Pre-populate only the onnx file with correct content.
      final modelDir = Directory('${tempDir.path}/partial-cache');
      await modelDir.create(recursive: true);
      await File('${modelDir.path}/model.onnx').writeAsBytes(onnxBytes);
      // config.json is absent.

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): [99], // should not be fetched
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await downloader.ensure(spec, cacheDir: tempDir.path);

      // Only the config URL should have been fetched.
      expect(
        server.requestedUrls,
        equals([spec.files['config']!.url.toString()]),
      );
    });

    test(
      're-downloads file whose cached content does not match checksum',
      () async {
        final onnxBytes = [1, 2, 3];
        final configBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'bad-cache',
          onnxBytes: onnxBytes,
          configBytes: configBytes,
        );

        // Pre-populate model.onnx with the wrong bytes.
        final modelDir = Directory('${tempDir.path}/bad-cache');
        await modelDir.create(recursive: true);
        await File('${modelDir.path}/model.onnx').writeAsBytes([9, 9, 9]);
        await File('${modelDir.path}/config.json').writeAsBytes(configBytes);

        final server = _FakeHttpServer(
          responses: {
            spec.files['onnx']!.url.toString(): onnxBytes,
            spec.files['config']!.url.toString(): [99], // should not be fetched
          },
        );

        final downloader = ModelDownloader(
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec, cacheDir: tempDir.path);

        // Only the onnx URL should have been re-fetched.
        expect(
          server.requestedUrls,
          equals([spec.files['onnx']!.url.toString()]),
        );
        // The file should now contain the correct bytes.
        expect(
          File('${modelDir.path}/model.onnx').readAsBytesSync(),
          equals(onnxBytes),
        );
      },
    );
  });

  // ── Checksum mismatch error ─────────────────────────────────────────────────

  group('ModelDownloader — checksum mismatch error', () {
    test(
      'throws StateError when server returns bytes with wrong checksum',
      () async {
        final onnxBytes = [1, 2, 3];
        final configBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'corrupt-onnx',
          onnxBytes: onnxBytes,
          configBytes: configBytes,
        );

        // Server returns different bytes — checksum will not match.
        final server = _FakeHttpServer(
          responses: {
            spec.files['onnx']!.url.toString(): [0, 0, 0],
            spec.files['config']!.url.toString(): configBytes,
          },
        );

        final downloader = ModelDownloader(
          httpClientFactory: () => server.client,
        );

        await expectLater(
          downloader.ensure(spec, cacheDir: tempDir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('checksum mismatch'),
            ),
          ),
        );
      },
    );

    test(
      'error message includes expected and actual SHA-256 digests',
      () async {
        final onnxBytes = [1, 2, 3];
        final configBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'checksum-msg',
          onnxBytes: onnxBytes,
          configBytes: configBytes,
        );

        final server = _FakeHttpServer(
          responses: {
            spec.files['onnx']!.url.toString(): [0xFF, 0xFF],
            spec.files['config']!.url.toString(): configBytes,
          },
        );

        final downloader = ModelDownloader(
          httpClientFactory: () => server.client,
        );

        await expectLater(
          downloader.ensure(spec, cacheDir: tempDir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('SHA-256'),
                contains(spec.files['onnx']!.sha256),
              ]),
            ),
          ),
        );
      },
    );

    test('deletes temp .part file after checksum mismatch', () async {
      final onnxBytes = [1, 2, 3];
      final configBytes = [4, 5, 6];
      final spec = _makeSpec(
        id: 'temp-cleanup',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): [7, 8, 9], // wrong bytes
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await expectLater(
        downloader.ensure(spec, cacheDir: tempDir.path),
        throwsA(isA<StateError>()),
      );

      // No .part file should have been left behind.
      final modelDir = Directory('${tempDir.path}/temp-cleanup');
      if (modelDir.existsSync()) {
        final partFiles = modelDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.part'))
            .toList();
        expect(partFiles, isEmpty);
      }
    });
  });

  // ── HTTP error handling ─────────────────────────────────────────────────────

  group('ModelDownloader — HTTP error handling', () {
    test('throws HttpException on non-2xx response', () async {
      final onnxBytes = [1, 2, 3];
      final configBytes = [4, 5, 6];
      final spec = _makeSpec(
        id: 'http-error',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        statusCode: 404,
        responses: {
          spec.files['onnx']!.url.toString(): [],
          spec.files['config']!.url.toString(): [],
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await expectLater(
        downloader.ensure(spec, cacheDir: tempDir.path),
        throwsA(isA<HttpException>()),
      );
    });

    test('HTTP error message includes status code and URL', () async {
      final onnxBytes = [1, 2, 3];
      final configBytes = [4, 5, 6];
      final spec = _makeSpec(
        id: 'http-error-msg',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        statusCode: 503,
        responses: {
          spec.files['onnx']!.url.toString(): [],
          spec.files['config']!.url.toString(): [],
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await expectLater(
        downloader.ensure(spec, cacheDir: tempDir.path),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('503'),
              contains(spec.files['onnx']!.url.toString()),
            ]),
          ),
        ),
      );
    });
  });

  // ── Temp-file-then-rename crash safety ──────────────────────────────────────

  group('ModelDownloader — temp-file-then-rename crash safety', () {
    test('no .part files remain after a successful download', () async {
      final onnxBytes = [1, 2, 3, 4];
      final configBytes = [5, 6, 7, 8];
      final spec = _makeSpec(
        id: 'atomic-rename',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      await downloader.ensure(spec, cacheDir: tempDir.path);

      final modelDir = Directory('${tempDir.path}/atomic-rename');
      final partFiles = modelDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();
      expect(partFiles, isEmpty);

      // Final files are present.
      expect(File('${modelDir.path}/model.onnx').existsSync(), isTrue);
      expect(File('${modelDir.path}/config.json').existsSync(), isTrue);
    });

    test(
      'pre-existing .part file from a previous crash is overwritten',
      () async {
        final onnxBytes = [10, 20, 30];
        final configBytes = [40, 50];
        final spec = _makeSpec(
          id: 'leftover-part',
          onnxBytes: onnxBytes,
          configBytes: configBytes,
        );

        // Simulate a leftover .part file from a previous interrupted download.
        final modelDir = Directory('${tempDir.path}/leftover-part');
        await modelDir.create(recursive: true);
        final stalePartFile = File('${modelDir.path}/model.onnx.part');
        await stalePartFile.writeAsBytes([0xDE, 0xAD]);

        final server = _FakeHttpServer(
          responses: {
            spec.files['onnx']!.url.toString(): onnxBytes,
            spec.files['config']!.url.toString(): configBytes,
          },
        );

        final downloader = ModelDownloader(
          httpClientFactory: () => server.client,
        );

        // The download should succeed, overwriting the stale .part file.
        final resolved = await downloader.ensure(spec, cacheDir: tempDir.path);

        expect(
          File(resolved.filePaths['onnx']!).readAsBytesSync(),
          equals(onnxBytes),
        );
        // No .part file should remain.
        expect(stalePartFile.existsSync(), isFalse);
      },
    );
  });

  // ── Allowlist rejection ─────────────────────────────────────────────────────

  group('ModelDownloader — allowlist rejection', () {
    test('throws ArgumentError when model is not on the allowlist', () async {
      final onnxBytes = [1, 2, 3];
      final configBytes = [4, 5, 6];
      final spec = _makeSpec(
        id: 'forbidden-model',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      // The allowlist only permits 'allowed-model', not 'forbidden-model'.
      final downloader = ModelDownloader(
        allowlist: _StrictAllowlist('allowed-model'),
        httpClientFactory: () => _FakeHttpServer().client,
      );

      await expectLater(
        downloader.ensure(spec, cacheDir: tempDir.path),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('ArgumentError message mentions the rejected model id', () async {
      final spec = _makeSpec(
        id: 'rejected-model',
        onnxBytes: [1],
        configBytes: [2],
      );

      final downloader = ModelDownloader(
        allowlist: _StrictAllowlist('other-model'),
        httpClientFactory: () => _FakeHttpServer().client,
      );

      await expectLater(
        downloader.ensure(spec, cacheDir: tempDir.path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('rejected-model'),
          ),
        ),
      );
    });

    test('permit-all mode (null allowlist) accepts any spec', () async {
      final onnxBytes = [1, 2];
      final configBytes = [3, 4];
      final spec = _makeSpec(
        id: 'any-model',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      // No allowlist — permit-all mode.
      final downloader = ModelDownloader(
        httpClientFactory: () => server.client,
      );

      // Should not throw.
      final resolved = await downloader.ensure(spec, cacheDir: tempDir.path);
      expect(resolved.spec.id, equals('any-model'));
    });

    test('downloads when model is on the allowlist', () async {
      final onnxBytes = [0xAA, 0xBB];
      final configBytes = [0xCC];
      final spec = _makeSpec(
        id: 'whitelisted',
        onnxBytes: onnxBytes,
        configBytes: configBytes,
      );

      final server = _FakeHttpServer(
        responses: {
          spec.files['onnx']!.url.toString(): onnxBytes,
          spec.files['config']!.url.toString(): configBytes,
        },
      );

      final downloader = ModelDownloader(
        allowlist: _StrictAllowlist('whitelisted'),
        httpClientFactory: () => server.client,
      );

      final resolved = await downloader.ensure(spec, cacheDir: tempDir.path);
      expect(resolved.spec.id, equals('whitelisted'));
    });
  });

  // ── ModelSpec and related types ─────────────────────────────────────────────

  group('ModelSpec', () {
    test('stores id, files, and meta correctly', () {
      final spec = ModelSpec(
        id: 'my-model',
        files: {
          'onnx': ModelFile(
            url: Uri.parse('https://example.com/model.onnx'),
            sha256: 'abc123',
          ),
        },
        meta: {'dimensions': 512},
      );

      expect(spec.id, equals('my-model'));
      expect(spec.files.length, equals(1));
      expect(spec.files['onnx']!.sha256, equals('abc123'));
      expect(spec.meta['dimensions'], equals(512));
    });

    test('meta defaults to empty map', () {
      const spec = ModelSpec(id: 'no-meta', files: {});

      expect(spec.meta, isEmpty);
    });

    test('toString includes id and file keys', () {
      final spec = ModelSpec(
        id: 'str-test',
        files: {
          'onnx': ModelFile(
            url: Uri.parse('https://example.com/x.onnx'),
            sha256: 'deadbeef',
          ),
        },
      );

      expect(spec.toString(), contains('str-test'));
    });
  });

  group('ModelFile', () {
    test('stores url and sha256', () {
      final file = ModelFile(
        url: Uri.parse('https://example.com/weights.onnx'),
        sha256: 'feedcafe',
      );

      expect(file.url, equals(Uri.parse('https://example.com/weights.onnx')));
      expect(file.sha256, equals('feedcafe'));
    });

    test('toString includes url', () {
      final file = ModelFile(
        url: Uri.parse('https://example.com/weights.onnx'),
        sha256: 'feedcafe',
      );
      expect(file.toString(), contains('https://example.com/weights.onnx'));
    });
  });

  group('ResolvedModel', () {
    test('stores spec and filePaths', () {
      const spec = ModelSpec(id: 'resolved', files: {});
      const resolved = ResolvedModel(
        spec: spec,
        filePaths: {'onnx': '/cache/resolved/model.onnx'},
      );

      expect(resolved.spec.id, equals('resolved'));
      expect(resolved.filePaths['onnx'], equals('/cache/resolved/model.onnx'));
    });

    test('toString includes id and file keys', () {
      const spec = ModelSpec(id: 'to-str', files: {});
      const resolved = ResolvedModel(
        spec: spec,
        filePaths: {'onnx': '/p/model.onnx'},
      );
      expect(resolved.toString(), contains('to-str'));
    });
  });
}
