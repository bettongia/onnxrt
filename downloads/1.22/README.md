# ORT binary SHA-256 digests

macOS and Linux use v1.22.0. Windows uses v1.22.1 (patch: replaces static
dxcore.lib link with optional runtime loading, lowering minimum Windows version
from 10.0.22621 to 10.0.19041; no ORT C API changes).
macOS x86_64 (Intel) is not supported.

## Results

| File | SHA-256 |
|------|---------|
| `onnxruntime-osx-arm64-1.22.0.tgz` | `cab6dcbd77e7ec775390e7b73a8939d45fec3379b017c7cb74f5b204c1a1cc07` |
| `onnxruntime-linux-aarch64-1.22.0.tgz` | `bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702` |
| `onnxruntime-linux-x64-1.22.0.tgz` | `8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3` |
| `onnxruntime-win-arm64-1.22.1.zip` | `3c984f25de07fdbbd2be36792dabfa18810c7483262238ea241ca5a1e52a4f82` |
| `onnxruntime-win-x64-1.22.1.zip` | `855276cd4be3cda14fe636c69eb038d75bf5bcd552bda1193a5d79c51f436dfe` |
| ORT iOS XCFramework 1.24.2 (SPM, `onnxruntime-c`) | `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54` |
