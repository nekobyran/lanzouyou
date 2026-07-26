import 'package:lanzou_library_shell/services/library_core.dart';

typedef RustJsonDispatch =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// Rejects credential-shaped response keys before any public-library DTO is
/// constructed. Requests may contain write-only access data; responses may
/// never echo it back across the Rust/Dart boundary.
void validatePasswordFreePublicLibraryPayload(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('catalog response key must be a string');
      }
      final normalized = key.toLowerCase();
      final passwordPresenceOnly =
          normalized == 'haspassword' && entry.value is bool;
      if ((!passwordPresenceOnly && normalized.contains('password')) ||
          normalized.contains('cookie') ||
          normalized.contains('accesscode') ||
          normalized.contains('secret')) {
        throw const LibraryCoreFailure('unsafeResponse', '公共软件库响应包含不允许返回的凭据字段');
      }
      validatePasswordFreePublicLibraryPayload(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      validatePasswordFreePublicLibraryPayload(item);
    }
  }
}
