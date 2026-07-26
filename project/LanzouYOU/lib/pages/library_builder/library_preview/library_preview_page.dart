import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanzou_library_shell/library_preview.dart' as shell;

import '../library_recipe.dart';

const _runtimeLogoAsset = 'assets/runtime/logo.png';
const _shellLogoAsset = 'packages/lanzou_library_shell/assets/runtime/logo.png';

/// Converts the in-edit recipe to the exact production shell configuration.
///
/// Downloads are deliberately overridden only for this ephemeral preview. The
/// user's recipe is not mutated, persisted or stripped of its other features.
shell.LibraryConfig libraryPreviewConfigFromRecipe(LibraryBuildRecipe recipe) {
  if (recipe.sources.isEmpty) {
    throw const shell.LibraryConfigException('预览至少需要一个有效软件源');
  }
  final runtime = Map<String, Object?>.of(recipe.runtimeJson());
  runtime['features'] = {...recipe.features.toJson(), 'download': false};
  return shell.LibraryConfig.fromJson(runtime);
}

bool isLibraryRecipePreviewable(LibraryBuildRecipe recipe) {
  try {
    libraryPreviewConfigFromRecipe(recipe);
    return true;
  } on shell.LibraryConfigException {
    return false;
  }
}

/// A host-owned route body that reuses the shell's production list experience
/// without nesting another MaterialApp or persisting the preview configuration.
class LibraryPreviewPage extends StatelessWidget {
  factory LibraryPreviewPage.production({
    Key? key,
    required LibraryBuildRecipe recipe,
  }) {
    final config = libraryPreviewConfigFromRecipe(recipe);
    return LibraryPreviewPage._(
      key: key,
      iconSourcePath: recipe.build.iconSourcePath,
      preview: shell.EmbeddedLibraryPreview.production(config: config),
    );
  }

  factory LibraryPreviewPage.testHarness({
    Key? key,
    required LibraryBuildRecipe recipe,
    required shell.LibraryCore core,
    required shell.LinkOpener linkOpener,
  }) {
    final config = libraryPreviewConfigFromRecipe(recipe);
    return LibraryPreviewPage._(
      key: key,
      iconSourcePath: recipe.build.iconSourcePath,
      preview: shell.EmbeddedLibraryPreview.testHarness(
        config: config,
        core: core,
        linkOpener: linkOpener,
      ),
    );
  }

  const LibraryPreviewPage._({
    super.key,
    required this.iconSourcePath,
    required this.preview,
  });

  final String iconSourcePath;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    return DefaultAssetBundle(
      bundle: _RecipePreviewAssetBundle(
        parent: DefaultAssetBundle.of(context),
        iconSourcePath: iconSourcePath,
      ),
      child: Semantics(
        key: const Key('library-preview-root'),
        container: true,
        label: '软件库列表预览',
        child: preview,
      ),
    );
  }
}

class _RecipePreviewAssetBundle extends CachingAssetBundle {
  _RecipePreviewAssetBundle({
    required this.parent,
    required this.iconSourcePath,
  });

  final AssetBundle parent;
  final String iconSourcePath;

  @override
  Future<ByteData> load(String key) async {
    if (key != _runtimeLogoAsset) return parent.load(key);
    final localPath = iconSourcePath.trim();
    if (localPath.isNotEmpty) {
      try {
        final bytes = await File(localPath).readAsBytes();
        if (bytes.isNotEmpty) return ByteData.sublistView(bytes);
      } on FileSystemException {
        // The shell's bundled neutral logo remains the safe visual fallback.
      }
    }
    return parent.load(_shellLogoAsset);
  }
}
