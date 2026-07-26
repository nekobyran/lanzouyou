import 'package:flutter/material.dart';

import '../../config/library_config.dart';
import '../../controllers/library_controller.dart';
import '../downloads/downloads_page.dart';
import 'library_navigation.dart';

class LibraryPersonalPage extends StatelessWidget {
  const LibraryPersonalPage({
    required this.config,
    required this.controller,
    required this.searchFocusNode,
    required this.onOpenOfficial,
    super.key,
  });

  final LibraryConfig config;
  final LibraryController controller;
  final FocusNode searchFocusNode;
  final VoidCallback onOpenOfficial;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('library-personal-page'),
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                LibraryBrandLogo(config: config, size: 56),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.identity.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        'v${config.identity.versionName} (${config.identity.versionCode})',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (config.branding.publisher.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('发布者'),
            subtitle: Text(config.branding.publisher),
          ),
        if (config.branding.officialUrl.isNotEmpty)
          ListTile(
            key: const Key('personal-official-site'),
            leading: const Icon(Icons.public_outlined),
            title: const Text('官方网站'),
            trailing: const Icon(Icons.open_in_new),
            onTap: onOpenOfficial,
          ),
        const Divider(height: 1),
        Expanded(
          child: config.features.download
              ? DownloadsPage(
                  controller: controller,
                  searchFocusNode: searchFocusNode,
                )
              : const Center(child: Icon(Icons.person_outline, size: 48)),
        ),
      ],
    );
  }
}
