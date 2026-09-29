import 'directory_upload.dart';

enum TransferKind { upload, directoryUpload, download }

extension TransferKindCoreName on TransferKind {
  String get coreName => switch (this) {
    TransferKind.upload => 'upload',
    TransferKind.directoryUpload => 'directory_upload',
    TransferKind.download => 'download',
  };
}

enum TransferStage {
  waiting,
  preparingIcon,
  transferring,
  bindingIcon,
  finished,
}

enum TransferState {
  queued,
  running,
  paused,
  cancelling,
  cancelled,
  succeeded,
  succeededWithWarning,
  failed,
}

class TransferEntry {
  const TransferEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.createdAt,
    required this.operationId,
    this.stage = TransferStage.waiting,
    this.bytesTransferred = 0,
    this.totalBytes,
    this.completedUnits = 0,
    this.totalUnits = 0,
    this.cancelRequested = false,
    this.errorMessage,
    this.iconRetryAvailable = false,
    this.directoryUploadResult,
  });

  final int id;
  final String name;
  final TransferKind kind;
  final TransferState state;
  final DateTime createdAt;
  final String operationId;
  final TransferStage stage;
  final int bytesTransferred;
  final int? totalBytes;
  final int completedUnits;
  final int totalUnits;
  final bool cancelRequested;
  final String? errorMessage;
  final bool iconRetryAvailable;
  final DirectoryUploadResult? directoryUploadResult;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (bytesTransferred / total).clamp(0, 1).toDouble();
  }

  TransferEntry copyWith({
    TransferState? state,
    TransferStage? stage,
    int? bytesTransferred,
    Object? totalBytes = _unchanged,
    int? completedUnits,
    int? totalUnits,
    bool? cancelRequested,
    Object? errorMessage = _unchanged,
    bool? iconRetryAvailable,
    Object? directoryUploadResult = _unchanged,
  }) {
    return TransferEntry(
      id: id,
      name: name,
      kind: kind,
      state: state ?? this.state,
      createdAt: createdAt,
      operationId: operationId,
      stage: stage ?? this.stage,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: identical(totalBytes, _unchanged)
          ? this.totalBytes
          : totalBytes as int?,
      completedUnits: completedUnits ?? this.completedUnits,
      totalUnits: totalUnits ?? this.totalUnits,
      cancelRequested: cancelRequested ?? this.cancelRequested,
      errorMessage: identical(errorMessage, _unchanged)
          ? this.errorMessage
          : errorMessage as String?,
      iconRetryAvailable: iconRetryAvailable ?? this.iconRetryAvailable,
      directoryUploadResult: identical(directoryUploadResult, _unchanged)
          ? this.directoryUploadResult
          : directoryUploadResult as DirectoryUploadResult?,
    );
  }
}

const Object _unchanged = Object();

class UploadRequest {
  const UploadRequest({
    required this.path,
    this.displayName,
    this.compatibilityWrap = false,
    this.kind = 'auto',
    this.autoFileIcon = false,
    this.iconSourcePath,
  });

  final String path;
  final String? displayName;
  final bool compatibilityWrap;
  final String kind;
  final bool autoFileIcon;
  final String? iconSourcePath;
}
