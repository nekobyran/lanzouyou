import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef PublicLibraryStorageRootProvider = Future<String> Function();

/// Resolves and memoizes the one durable root shared by catalog and registry.
class PublicLibraryStorageRoot {
  PublicLibraryStorageRoot({PublicLibraryStorageRootProvider? provider})
    : _provider = provider ?? _defaultPublicLibraryStorageRoot;

  factory PublicLibraryStorageRoot.fixed(String value) {
    final validated = validatePublicLibraryStorageRoot(value);
    return PublicLibraryStorageRoot(provider: () async => validated);
  }

  final PublicLibraryStorageRootProvider _provider;
  Future<String>? _value;

  Future<String> resolve() =>
      _value ??= _provider().then(validatePublicLibraryStorageRoot);
}

Future<String> _defaultPublicLibraryStorageRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}${Platform.pathSeparator}data${Platform.pathSeparator}'
      'sources';
}

String validatePublicLibraryStorageRoot(String value) {
  final root = value.trim();
  final windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(root);
  if (root.isEmpty || (!root.startsWith('/') && !windowsAbsolute)) {
    throw ArgumentError.value(value, 'storageRoot', '必须是绝对路径');
  }
  return root;
}
