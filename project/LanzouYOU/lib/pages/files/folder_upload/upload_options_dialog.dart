import 'dart:io';

import 'package:flutter/material.dart';

enum UploadPickerKind { files, apk, directory }

class UploadOptionsChoice {
  const UploadOptionsChoice({
    required this.kind,
    required this.compatibilityWrap,
    required this.autoIcon,
  });

  final UploadPickerKind kind;
  final bool compatibilityWrap;
  final bool autoIcon;
}

class UploadOptionsDialog extends StatefulWidget {
  const UploadOptionsDialog({super.key});

  @override
  State<UploadOptionsDialog> createState() => _UploadOptionsDialogState();
}

class _UploadOptionsDialogState extends State<UploadOptionsDialog> {
  bool _compatibilityWrap = false;
  bool _autoIcon = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.upload_file_outlined),
      title: const Text('上传到当前目录'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              key: const Key('force-compat-wrap-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('强制兼容封装'),
              subtitle: const Text('默认仅为蓝奏云不支持的扩展名自动封装，文件夹内层级保持不变'),
              value: _compatibilityWrap,
              onChanged: (value) => setState(() => _compatibilityWrap = value),
            ),
            const Divider(height: 1),
            SwitchListTile(
              key: const Key('auto-icon-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动设置软件图标（严格小于 100KB）'),
              subtitle: Text(
                Platform.isWindows
                    ? '单文件可从 APK/EXE 或同名图片获取；上传文件夹时只处理 APK'
                    : '单文件可从 APK 或同名图片获取；上传文件夹时只处理 APK',
              ),
              value: _autoIcon,
              onChanged: (value) => setState(() => _autoIcon = value),
            ),
            const SizedBox(height: 12),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 20),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '上传文件夹会先完成安全扫描，再在云端创建同名顶层目录并保留所有空目录和层级。取消后不再开始新项目；已上传内容不会自动删除。',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        OutlinedButton.icon(
          key: const Key('folder-upload-action'),
          onPressed: () => _finish(UploadPickerKind.directory),
          icon: const Icon(Icons.drive_folder_upload_outlined),
          label: const Text('选择文件夹'),
        ),
        OutlinedButton.icon(
          onPressed: () => _finish(UploadPickerKind.files),
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('选择多个文件'),
        ),
        FilledButton.icon(
          key: const Key('one-click-apk-upload-action'),
          onPressed: () => _finish(UploadPickerKind.apk),
          icon: const Icon(Icons.android_outlined),
          label: Text(_autoIcon ? '选择 APK，一键上传并设置图标' : '选择 APK 并上传'),
        ),
      ],
    );
  }

  void _finish(UploadPickerKind kind) {
    Navigator.pop(
      context,
      UploadOptionsChoice(
        kind: kind,
        compatibilityWrap: _compatibilityWrap,
        autoIcon: _autoIcon,
      ),
    );
  }
}
