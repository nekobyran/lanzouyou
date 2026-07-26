import 'package:flutter/material.dart';

import '../../models/source_registry.dart';

Future<String?> showSourceCategoryDialog(
  BuildContext context, {
  required List<SourceRegistryCategory> categories,
  required String selectedId,
}) => showDialog<String>(
  context: context,
  builder: (context) => Dialog(
    key: const Key('source-category-dialog'),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择分类',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              key: const Key('source-category-options'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: categories.length + 1,
              itemBuilder: (context, index) {
                final id = index == 0 ? 'all' : categories[index - 1].id;
                final title = index == 0 ? '全部来源' : categories[index - 1].title;
                final selected = id == selectedId;
                return Semantics(
                  selected: selected,
                  button: true,
                  child: ListTile(
                    key: Key('source-category-$id'),
                    selected: selected,
                    leading: Icon(
                      index == 0 ? Icons.apps_rounded : Icons.folder_outlined,
                    ),
                    title: Text(title),
                    trailing: selected ? const Icon(Icons.check_rounded) : null,
                    onTap: () => Navigator.pop(context, id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  ),
);

Future<SourceRegistrySourceDraft?> showSourceDraftDialog(
  BuildContext context, {
  required List<SourceRegistryCategory> categories,
}) async {
  final title = TextEditingController();
  final url = TextEditingController();
  final code = TextEditingController();
  var searchable = true;
  var categoryId = '';
  String? validation;
  try {
    return await showDialog<SourceRegistrySourceDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('source-add-dialog'),
          icon: const Icon(Icons.add_link_rounded),
          title: const Text('添加来源'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('source-title-field'),
                    controller: title,
                    autofocus: true,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      prefixIcon: Icon(Icons.label_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('source-url-field'),
                    controller: url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '蓝奏链接',
                      prefixIcon: Icon(Icons.link_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('source-code-field'),
                    controller: code,
                    maxLength: 64,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '访问码（可选）',
                      prefixIcon: Icon(Icons.password_rounded),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('参与搜索'),
                    value: searchable,
                    onChanged: (value) => setState(() => searchable = value),
                  ),
                  if (categories.isNotEmpty)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text('加入分类'),
                      subtitle: Text(
                        categoryId.isEmpty
                            ? '暂不分类'
                            : categories
                                  .firstWhere((item) => item.id == categoryId)
                                  .title,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        final value = await showSourceCategoryDialog(
                          context,
                          categories: categories,
                          selectedId: categoryId.isEmpty ? 'all' : categoryId,
                        );
                        if (value != null && context.mounted) {
                          setState(
                            () => categoryId = value == 'all' ? '' : value,
                          );
                        }
                      },
                    ),
                  if (validation != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          validation!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('source-add-confirm'),
              onPressed: () {
                final name = title.text.trim();
                final share = url.text.trim();
                if (name.isEmpty || share.isEmpty) {
                  setState(() => validation = '名称和蓝奏链接不能为空');
                  return;
                }
                Navigator.pop(
                  context,
                  SourceRegistrySourceDraft(
                    title: name,
                    url: share,
                    accessCode: code.text,
                    searchable: searchable,
                    categoryId: categoryId,
                  ),
                );
              },
              child: const Text('交给 Rust 校验并添加'),
            ),
          ],
        ),
      ),
    );
  } finally {
    title.dispose();
    url.dispose();
    code.dispose();
  }
}

Future<SourceRegistryRawImportDraft?> showSourceBatchImportDialog(
  BuildContext context, {
  required List<SourceRegistryCategory> categories,
}) async {
  final input = TextEditingController();
  var categoryId = '';
  try {
    return await showDialog<SourceRegistryRawImportDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('source-batch-import-dialog'),
          icon: const Icon(Icons.playlist_add_rounded),
          title: const Text('批量添加来源'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('source-batch-input'),
                    controller: input,
                    autofocus: true,
                    minLines: 7,
                    maxLines: 12,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '链接与访问码',
                      hintText: '每行一个链接；访问码放在链接后并以空格分隔',
                      helperText: '标题识别、规范化、查重和校验全部由 Rust 完成',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (categories.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      key: const Key('source-batch-category'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text('加入分类'),
                      subtitle: Text(
                        categoryId.isEmpty
                            ? '暂不分类'
                            : categories
                                  .firstWhere((item) => item.id == categoryId)
                                  .title,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        final value = await showSourceCategoryDialog(
                          context,
                          categories: categories,
                          selectedId: categoryId.isEmpty ? 'all' : categoryId,
                        );
                        if (value != null && context.mounted) {
                          setState(
                            () => categoryId = value == 'all' ? '' : value,
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              key: const Key('source-batch-preview'),
              onPressed: () {
                final value = input.text.trim();
                if (value.isNotEmpty) {
                  Navigator.pop(
                    context,
                    SourceRegistryRawImportDraft(
                      rawText: value,
                      categoryId: categoryId,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.preview_outlined),
              label: const Text('预览'),
            ),
          ],
        ),
      ),
    );
  } finally {
    input.dispose();
  }
}

Future<SourceRegistrySourceUpdateDraft?> showSourceUpdateDialog(
  BuildContext context,
  SourceRegistrySource source,
) async {
  final title = TextEditingController(text: source.title);
  final code = TextEditingController();
  var searchable = source.searchable;
  var changeCode = false;
  String? validation;
  try {
    return await showDialog<SourceRegistrySourceUpdateDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('source-update-dialog'),
          icon: const Icon(Icons.edit_outlined),
          title: const Text('编辑来源'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('source-update-title'),
                    controller: title,
                    autofocus: true,
                    maxLength: 160,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('参与搜索'),
                    value: searchable,
                    onChanged: (value) => setState(() => searchable = value),
                  ),
                  if (source.kind == SourceRegistrySourceKind.official) ...[
                    CheckboxListTile(
                      key: const Key('source-update-change-code'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('修改访问码'),
                      subtitle: const Text('关闭时保留现有访问码'),
                      value: changeCode,
                      onChanged: (value) =>
                          setState(() => changeCode = value ?? false),
                    ),
                    if (changeCode)
                      TextField(
                        key: const Key('source-update-code'),
                        controller: code,
                        maxLength: 64,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '新访问码',
                          helperText: '留空并保存会清除访问码',
                        ),
                      ),
                  ],
                  if (validation != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        validation!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('source-update-confirm'),
              onPressed: () {
                final value = title.text.trim();
                if (value.isEmpty) {
                  setState(() => validation = '名称不能为空');
                  return;
                }
                Navigator.pop(
                  context,
                  SourceRegistrySourceUpdateDraft(
                    sourceId: source.id,
                    title: value,
                    searchable: searchable,
                    accessCode: changeCode ? code.text : null,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  } finally {
    title.dispose();
    code.dispose();
  }
}

Future<String?> showSourceRulesUrlDialog(BuildContext context) async {
  final url = TextEditingController();
  String? validation;
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('source-rules-url-dialog'),
          icon: const Icon(Icons.language_rounded),
          title: const Text('从网址导入规则'),
          content: TextField(
            key: const Key('source-rules-url'),
            controller: url,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'HTTPS 规则网址',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = url.text.trim();
                final uri = Uri.tryParse(value);
                if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
                  setState(() => validation = '请输入有效的 HTTPS 网址');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
  } finally {
    url.dispose();
  }
}

Future<bool> showSourceImportPreviewDialog(
  BuildContext context,
  SourceRegistryImportPreview preview,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('source-import-preview-dialog'),
        icon: const Icon(Icons.fact_check_outlined),
        title: const Text('导入预览'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('可添加 ${preview.valid.length}')),
                  Chip(label: Text('重复 ${preview.duplicates.length}')),
                  Chip(label: Text('无效 ${preview.invalid.length}')),
                ],
              ),
              if (preview.invalid.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('无效项目'),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: preview.invalid.length,
                    itemBuilder: (context, index) {
                      final item = preview.invalid[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.error_outline_rounded),
                        title: Text('第 ${item.line} 行'),
                        subtitle: Text(item.message),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            key: const Key('source-import-commit'),
            onPressed: preview.valid.isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('确认添加'),
          ),
        ],
      ),
    ) ??
    false;

Future<SourceRegistryCategoryDraft?> showCategoryDraftDialog(
  BuildContext context, {
  SourceRegistryCategory? existing,
  List<String> sourceIds = const [],
}) async {
  final title = TextEditingController(text: existing?.title ?? '');
  try {
    return await showDialog<SourceRegistryCategoryDraft>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('source-category-edit-dialog'),
        icon: const Icon(Icons.create_new_folder_outlined),
        title: Text(existing == null ? '新建分类' : '重命名分类'),
        content: TextField(
          key: const Key('source-category-title-field'),
          controller: title,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '分类名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = title.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(
                context,
                SourceRegistryCategoryDraft(
                  id: existing?.id ?? _categoryId(value),
                  title: value,
                  sourceIds: existing?.sourceIds ?? sourceIds,
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    title.dispose();
  }
}

Future<SourceRegistryCompositeDraft?> showCompositeDraftDialog(
  BuildContext context,
) async {
  final title = TextEditingController();
  final publisher = TextEditingController();
  final description = TextEditingController();
  final links = TextEditingController();
  String? validation;
  try {
    return await showDialog<SourceRegistryCompositeDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('source-composite-dialog'),
          icon: const Icon(Icons.folder_copy_outlined),
          title: const Text('新建软件合集'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '合集名称'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: publisher,
                    decoration: const InputDecoration(labelText: '发布者（可选）'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: '简介（可选）'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('source-composite-links'),
                    controller: links,
                    minLines: 4,
                    maxLines: 8,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '软件或目录链接',
                      helperText: '每行一个；规范化、查重与有效性由 Rust 完成',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (validation != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        validation!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = title.text.trim();
                final values = links.text
                    .split(RegExp(r'[\r\n]+'))
                    .map((value) => value.trim())
                    .where((value) => value.isNotEmpty)
                    .take(4096)
                    .toList(growable: false);
                if (name.isEmpty || values.isEmpty) {
                  setState(() => validation = '合集名称和至少一个链接不能为空');
                  return;
                }
                Navigator.pop(
                  context,
                  SourceRegistryCompositeDraft(
                    title: name,
                    publisher: publisher.text.trim(),
                    description: description.text.trim(),
                    members: values
                        .map(
                          (value) => SourceRegistryMemberDraft(
                            kind: SourceRegistryMemberKind.file,
                            url: value,
                          ),
                        )
                        .toList(growable: false),
                  ),
                );
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  } finally {
    title.dispose();
    publisher.dispose();
    description.dispose();
    links.dispose();
  }
}

String _categoryId(String title) {
  final folded = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (folded.length >= 2) {
    return folded.substring(0, folded.length.clamp(2, 48));
  }
  return 'category-${DateTime.now().microsecondsSinceEpoch}';
}
