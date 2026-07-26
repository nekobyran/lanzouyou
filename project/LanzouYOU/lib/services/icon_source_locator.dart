import 'dart:io';

class IconSourceLocator {
  const IconSourceLocator();

  static const _candidateExtensions = <String>[
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
  ];

  Future<String?> findSidecar(String sourcePath) async {
    final base = _withoutExtension(sourcePath);
    final candidates = <String>[
      for (final extension in _candidateExtensions) '$base$extension',
      for (final extension in _candidateExtensions) '${base}_icon$extension',
    ];
    for (final candidate in candidates) {
      if (_samePath(candidate, sourcePath)) continue;
      final file = File(candidate);
      if (await file.exists()) return file.path;
    }
    return null;
  }
}

String _withoutExtension(String path) {
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  final dot = path.lastIndexOf('.');
  return dot > separator ? path.substring(0, dot) : path;
}

bool _samePath(String first, String second) {
  if (Platform.isWindows) return first.toLowerCase() == second.toLowerCase();
  return first == second;
}
