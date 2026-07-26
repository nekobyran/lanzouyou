import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'library_core.dart';

typedef _NativeDispatch = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartDispatch = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

abstract interface class JsonCoreTransport {
  Future<String> dispatch(String request);
}

abstract interface class ClosableJsonCoreTransport
    implements JsonCoreTransport {
  Future<void> close();
}

/// Entrypoint contract for a persistent JSON worker isolate.
///
/// The bootstrap list contains the parent [SendPort] followed by a diagnostic
/// worker label. It is public only so isolate lifecycle tests can replace the
/// native worker without loading a platform library.
typedef JsonCoreWorkerEntrypoint = void Function(List<Object?> bootstrap);

/// A bounded, reusable isolate group for synchronous native dispatch.
///
/// General requests are spread over a small persistent pool. Operation control
/// requests use a dedicated worker, so a long synchronous `library_search`
/// never blocks progress, cancellation, or cleanup. Every worker opens and
/// resolves the native library exactly once at startup.
class PersistentIsolateJsonCoreTransport implements ClosableJsonCoreTransport {
  PersistentIsolateJsonCoreTransport.production()
    : this._(
        workerEntrypoint: _ffiJsonCoreWorkerMain,
        generalWorkerCount: _defaultGeneralWorkerCount,
        maxRestartsPerWorker: _defaultMaxRestartsPerWorker,
      );

  @visibleForTesting
  PersistentIsolateJsonCoreTransport.testHarness({
    required JsonCoreWorkerEntrypoint workerEntrypoint,
    int generalWorkerCount = 2,
    int maxRestartsPerWorker = 1,
    void Function(String label)? onWorkerSpawn,
  }) : this._(
         workerEntrypoint: workerEntrypoint,
         generalWorkerCount: generalWorkerCount,
         maxRestartsPerWorker: maxRestartsPerWorker,
         onWorkerSpawn: onWorkerSpawn,
       );

  PersistentIsolateJsonCoreTransport._({
    required JsonCoreWorkerEntrypoint workerEntrypoint,
    required int generalWorkerCount,
    required int maxRestartsPerWorker,
    void Function(String label)? onWorkerSpawn,
  }) : assert(generalWorkerCount > 0),
       assert(maxRestartsPerWorker >= 0),
       _controlWorker = _PersistentJsonWorker(
         label: 'control',
         entrypoint: workerEntrypoint,
         maxRestarts: maxRestartsPerWorker,
         onSpawn: onWorkerSpawn,
       ),
       _generalWorkers = List.generate(
         generalWorkerCount,
         (index) => _PersistentJsonWorker(
           label: 'general-$index',
           entrypoint: workerEntrypoint,
           maxRestarts: maxRestartsPerWorker,
           onSpawn: onWorkerSpawn,
         ),
         growable: false,
       );

  final _PersistentJsonWorker _controlWorker;
  final List<_PersistentJsonWorker> _generalWorkers;
  int _nextGeneralWorker = 0;
  bool _closed = false;

  @override
  Future<String> dispatch(String request) {
    if (_closed) return Future.error(_closedFailure);
    if (_isOperationControl(request)) {
      return _controlWorker.dispatch(request);
    }
    final worker = _selectGeneralWorker();
    if (worker == null) {
      return Future.error(
        const LibraryCoreFailure(
          'coreUnavailable',
          'LanzouYOU 核心工作线程不可用，请稍后重试',
          retriable: true,
        ),
      );
    }
    return worker.dispatch(request);
  }

  _PersistentJsonWorker? _selectGeneralWorker() {
    _PersistentJsonWorker? selected;
    var selectedLoad = 1 << 30;
    for (var offset = 0; offset < _generalWorkers.length; offset++) {
      final index = (_nextGeneralWorker + offset) % _generalWorkers.length;
      final candidate = _generalWorkers[index];
      if (!candidate.canAccept || candidate.load > selectedLoad) continue;
      if (candidate.load < selectedLoad || selected == null) {
        selected = candidate;
        selectedLoad = candidate.load;
      }
    }
    if (selected != null) {
      final index = _generalWorkers.indexOf(selected);
      _nextGeneralWorker = (index + 1) % _generalWorkers.length;
    }
    return selected;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait<void>([
      _controlWorker.close(),
      for (final worker in _generalWorkers) worker.close(),
    ]);
  }
}

class _PersistentJsonWorker {
  _PersistentJsonWorker({
    required this.label,
    required this.entrypoint,
    required this.maxRestarts,
    required this.onSpawn,
  });

  final String label;
  final JsonCoreWorkerEntrypoint entrypoint;
  final int maxRestarts;
  final void Function(String label)? onSpawn;

  final Map<int, Completer<String>> _pending = {};
  int _nextRequestId = 0;
  int _generation = 0;
  int _restartCount = 0;
  bool _hasStarted = false;
  bool _closed = false;
  SendPort? _commandPort;
  Isolate? _isolate;
  ReceivePort? _responsePort;
  ReceivePort? _errorPort;
  ReceivePort? _exitPort;
  Completer<void>? _starting;
  Timer? _startupTimer;
  LibraryCoreFailure? _lastFailure;

  int get load =>
      _pending.length + (_starting != null && _commandPort == null ? 1 : 0);

  bool get canAccept =>
      !_closed &&
      (_commandPort != null || !_hasStarted || _restartCount < maxRestarts);

  Future<String> dispatch(String request) async {
    if (_closed) throw _closedFailure;
    await _ensureStarted();
    if (_closed) throw _closedFailure;
    final commandPort = _commandPort;
    if (commandPort == null) {
      throw _lastFailure ?? _workerUnavailableFailure;
    }
    final requestId = ++_nextRequestId;
    final completer = Completer<String>();
    _pending[requestId] = completer;
    try {
      commandPort.send({
        _messageTypeKey: _requestMessageType,
        _requestIdKey: requestId,
        _requestBodyKey: request,
      });
    } on Object {
      _pending.remove(requestId);
      _failCurrentGeneration(_workerUnavailableFailure);
      throw _workerUnavailableFailure;
    }
    return completer.future;
  }

  Future<void> _ensureStarted() {
    if (_closed) return Future.error(_closedFailure);
    if (_commandPort != null) return Future.value();
    final activeStart = _starting;
    if (activeStart != null) return activeStart.future;
    if (_hasStarted && _restartCount >= maxRestarts) {
      return Future.error(_lastFailure ?? _workerUnavailableFailure);
    }
    if (_hasStarted) _restartCount++;
    _hasStarted = true;
    final generation = ++_generation;
    final completer = Completer<void>();
    _starting = completer;
    _spawn(generation);
    return completer.future;
  }

  Future<void> _spawn(int generation) async {
    final responsePort = ReceivePort('$label-responses');
    final errorPort = ReceivePort('$label-errors');
    final exitPort = ReceivePort('$label-exit');
    _responsePort = responsePort;
    _errorPort = errorPort;
    _exitPort = exitPort;
    responsePort.listen((message) => _handleWorkerMessage(generation, message));
    errorPort.listen(
      (message) => _failGeneration(
        generation,
        const LibraryCoreFailure(
          'coreUnavailable',
          'LanzouYOU 核心工作线程异常退出',
          retriable: true,
        ),
      ),
    );
    exitPort.listen(
      (_) => _failGeneration(
        generation,
        const LibraryCoreFailure(
          'coreUnavailable',
          'LanzouYOU 核心工作线程已退出',
          retriable: true,
        ),
      ),
    );
    _startupTimer = Timer(
      _workerStartupTimeout,
      () => _failGeneration(generation, _workerUnavailableFailure),
    );
    onSpawn?.call(label);
    try {
      final isolate = await Isolate.spawn<List<Object?>>(
        entrypoint,
        <Object?>[responsePort.sendPort, label],
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
        debugName: 'lanzou-library-$label',
      );
      if (_closed || generation != _generation) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } on Object {
      _failGeneration(generation, _workerUnavailableFailure);
    }
  }

  void _handleWorkerMessage(int generation, Object? message) {
    if (_closed || generation != _generation || message is! Map) return;
    final envelope = message.cast<Object?, Object?>();
    switch (envelope[_messageTypeKey]) {
      case _readyMessageType:
        final port = envelope[_commandPortKey];
        if (port is! SendPort) {
          _failGeneration(generation, _workerProtocolFailure);
          return;
        }
        _commandPort = port;
        _startupTimer?.cancel();
        _startupTimer = null;
        final starting = _starting;
        _starting = null;
        if (starting != null && !starting.isCompleted) starting.complete();
      case _responseMessageType:
        final requestId = envelope[_requestIdKey];
        if (requestId is! int) {
          _failGeneration(generation, _workerProtocolFailure);
          return;
        }
        final completer = _pending.remove(requestId);
        if (completer == null || completer.isCompleted) return;
        if (envelope[_responseOkKey] == true &&
            envelope[_responseBodyKey] is String) {
          completer.complete(envelope[_responseBodyKey]! as String);
          return;
        }
        completer.completeError(_decodeWorkerFailure(envelope[_errorKey]));
      case _startupErrorMessageType:
        _failGeneration(generation, _decodeWorkerFailure(envelope[_errorKey]));
      default:
        _failGeneration(generation, _workerProtocolFailure);
    }
  }

  void _failCurrentGeneration(LibraryCoreFailure failure) =>
      _failGeneration(_generation, failure);

  void _failGeneration(int generation, LibraryCoreFailure failure) {
    if (_closed || generation != _generation) return;
    _generation++;
    _lastFailure = failure;
    _startupTimer?.cancel();
    _startupTimer = null;
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    final starting = _starting;
    _starting = null;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(failure);
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(failure);
    }
    _pending.clear();
    _closePorts();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    try {
      _commandPort?.send(const {_messageTypeKey: _closeMessageType});
    } on Object {
      // Immediate isolate termination below is the authoritative close path.
    }
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    final starting = _starting;
    _starting = null;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(_closedFailure);
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(_closedFailure);
    }
    _pending.clear();
    _closePorts();
  }

  void _closePorts() {
    _responsePort?.close();
    _errorPort?.close();
    _exitPort?.close();
    _responsePort = null;
    _errorPort = null;
    _exitPort = null;
  }
}

bool _isOperationControl(String request) {
  try {
    final decoded = jsonDecode(request);
    if (decoded is! Map) return false;
    return _operationControlNames.contains(decoded['op']);
  } on Object {
    return false;
  }
}

LibraryCoreFailure _decodeWorkerFailure(Object? raw) {
  if (raw is! Map) return _workerUnavailableFailure;
  final error = raw.cast<Object?, Object?>();
  final code = error[_errorCodeKey];
  final message = error[_errorMessageKey];
  return LibraryCoreFailure(
    code is String && code.isNotEmpty ? code : 'coreUnavailable',
    message is String && message.isNotEmpty ? message : 'LanzouYOU 核心工作线程不可用',
    retriable: error[_errorRetriableKey] == true,
  );
}

Map<String, Object?> _workerFailureEnvelope(Object error) {
  if (error case LibraryCoreFailure failure) {
    return {
      _errorCodeKey: failure.code,
      _errorMessageKey: failure.message,
      _errorRetriableKey: failure.retriable,
    };
  }
  return const {
    _errorCodeKey: 'coreUnavailable',
    _errorMessageKey: 'LanzouYOU 核心调用失败，请稍后重试',
    _errorRetriableKey: true,
  };
}

@pragma('vm:entry-point')
void _ffiJsonCoreWorkerMain(List<Object?> bootstrap) {
  final parent = bootstrap.isNotEmpty ? bootstrap.first : null;
  if (parent is! SendPort) return;
  final ReceivePort commands;
  final _NativeJsonDispatcher dispatcher;
  try {
    dispatcher = _NativeJsonDispatcher.open();
    commands = ReceivePort('lanzou-library-native-commands');
  } on Object catch (error) {
    parent.send({
      _messageTypeKey: _startupErrorMessageType,
      _errorKey: _workerFailureEnvelope(error),
    });
    Isolate.exit();
  }
  parent.send({
    _messageTypeKey: _readyMessageType,
    _commandPortKey: commands.sendPort,
  });
  commands.listen((message) {
    if (message is! Map) return;
    final request = message.cast<Object?, Object?>();
    if (request[_messageTypeKey] == _closeMessageType) {
      commands.close();
      Isolate.exit();
    }
    if (request[_messageTypeKey] != _requestMessageType) return;
    final requestId = request[_requestIdKey];
    final requestBody = request[_requestBodyKey];
    if (requestId is! int || requestBody is! String) return;
    try {
      final response = dispatcher.dispatch(requestBody);
      parent.send({
        _messageTypeKey: _responseMessageType,
        _requestIdKey: requestId,
        _responseOkKey: true,
        _responseBodyKey: response,
      });
    } on Object catch (error) {
      parent.send({
        _messageTypeKey: _responseMessageType,
        _requestIdKey: requestId,
        _responseOkKey: false,
        _errorKey: _workerFailureEnvelope(error),
      });
    }
  });
}

class _NativeJsonDispatcher {
  const _NativeJsonDispatcher(this.dispatchNative, this.freeNative);

  factory _NativeJsonDispatcher.open() {
    final DynamicLibrary library;
    try {
      if (Platform.isWindows) {
        library = DynamicLibrary.open('lanzouyou_core.dll');
      } else if (Platform.isAndroid) {
        library = DynamicLibrary.open('liblanzouyou_core.so');
      } else {
        throw UnsupportedError('unsupported platform');
      }
    } on Object {
      throw const LibraryCoreFailure(
        'coreUnavailable',
        '当前平台没有可用的 LanzouYOU 核心',
        retriable: true,
      );
    }
    try {
      return _NativeJsonDispatcher(
        library.lookupFunction<_NativeDispatch, _DartDispatch>(
          'lanzouyou_dispatch',
        ),
        library.lookupFunction<_NativeFree, _DartFree>('lanzouyou_free'),
      );
    } on Object {
      throw const LibraryCoreFailure(
        'coreUnavailable',
        'LanzouYOU 核心接口不完整，请重新安装完整版本',
      );
    }
  }

  final _DartDispatch dispatchNative;
  final _DartFree freeNative;

  String dispatch(String request) {
    final requestPointer = request.toNativeUtf8();
    Pointer<Utf8> responsePointer = nullptr;
    try {
      responsePointer = dispatchNative(requestPointer);
      if (responsePointer == nullptr) {
        throw const LibraryCoreFailure('invalidResponse', '核心没有返回数据');
      }
      return responsePointer.toDartString();
    } finally {
      calloc.free(requestPointer);
      if (responsePointer != nullptr) freeNative(responsePointer);
    }
  }
}

const _operationControlNames = {
  'operation_status',
  'operation_cancel',
  'operation_forget',
};
const _defaultGeneralWorkerCount = 3;
const _defaultMaxRestartsPerWorker = 1;
const _workerStartupTimeout = Duration(seconds: 5);
const _messageTypeKey = 'type';
const _requestIdKey = 'requestId';
const _requestBodyKey = 'request';
const _commandPortKey = 'commandPort';
const _responseOkKey = 'ok';
const _responseBodyKey = 'response';
const _errorKey = 'error';
const _errorCodeKey = 'code';
const _errorMessageKey = 'message';
const _errorRetriableKey = 'retriable';
const _readyMessageType = 'ready';
const _requestMessageType = 'request';
const _responseMessageType = 'response';
const _startupErrorMessageType = 'startupError';
const _closeMessageType = 'close';

const _closedFailure = LibraryCoreFailure('coreClosed', 'LanzouYOU 核心已关闭');
const _workerUnavailableFailure = LibraryCoreFailure(
  'coreUnavailable',
  'LanzouYOU 核心工作线程不可用，请稍后重试',
  retriable: true,
);
const _workerProtocolFailure = LibraryCoreFailure(
  'invalidResponse',
  'LanzouYOU 核心工作线程响应无效',
);
