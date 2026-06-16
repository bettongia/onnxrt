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

/// [AllowlistProvider] — interface for model allowlists.
library;

import 'model_spec.dart';

/// Guards model downloads by checking whether a [ModelSpec] is on an
/// explicit allowlist.
///
/// Implement this interface to restrict which models [ModelDownloader] will
/// fetch. The KMDB `ModelCatalog` is the canonical implementation:
///
/// ```dart
/// class ModelCatalog implements AllowlistProvider {
///   @override
///   bool isAllowed(ModelSpec spec) => _knownIds.contains(spec.id);
/// }
/// ```
///
/// Pass an [AllowlistProvider] to [ModelDownloader] to gate downloads:
///
/// ```dart
/// final downloader = ModelDownloader(allowlist: ModelCatalog());
/// ```
///
/// If no allowlist is provided (`null`), [ModelDownloader] operates in
/// **permit-all** mode and accepts any [ModelSpec].
abstract interface class AllowlistProvider {
  /// Returns `true` if [spec] is permitted to be downloaded.
  ///
  /// Return `false` to reject [spec]; [ModelDownloader] will throw
  /// [ArgumentError] if this method returns `false`.
  bool isAllowed(ModelSpec spec);
}
