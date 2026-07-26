import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/services/json_core_transport.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

void main() {
  test(
    'concurrent requests keep their response ids and reuse bounded workers',
    () async {
      final spawns = <String>[];
      final transport = PersistentIsolateJsonCoreTransport.testHarness(
        workerEntrypoint: _testWorkerMain,
        generalWorkerCount: 2,
        onWorkerSpawn: spawns.add,
      );
      addTearDown(transport.close);

      final responses = await Future.wait([
        transport.dispatch(_request('library_browse', 'slow', delayMs: 60)),
        transport.dispatch(_request('library_browse', 'fast', delayMs: 1)),
        transport.dispatch(
          _request('library_fetch_asset', 'asset', delayMs: 5),
        ),
        transport.dispatch(_request('operation_status', 'status')),
      ]);
      expect(
        responses.map(_responseToken),
        containsAll(<String>['slow', 'fast', 'asset', 'status']),
      );
      expect(spawns.toSet(), {'general-0', 'general-1', 'control'});
      expect(spawns, hasLength(3));

      for (var index = 0; index < 20; index++) {
        final response = await transport.dispatch(
          _request('library_browse', 'reuse-$index'),
        );
        expect(_responseToken(response), 'reuse-$index');
      }
      expect(spawns, hasLength(3), reason: '重复请求必须复用已有 isolate');
    },
  );

  test(
    'a blocked search cannot delay status or cancellation control',
    () async {
      final spawns = <String>[];
      final transport = PersistentIsolateJsonCoreTransport.testHarness(
        workerEntrypoint: _testWorkerMain,
        generalWorkerCount: 1,
        onWorkerSpawn: spawns.add,
      );

      final search = transport.dispatch(_request('library_search', 'search'));
      final searchFailure = expectLater(
        search,
        throwsA(
          isA<LibraryCoreFailure>().having(
            (error) => error.code,
            'code',
            'coreClosed',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final status = await transport
          .dispatch(_request('operation_status', 'status'))
          .timeout(const Duration(milliseconds: 300));
      final cancel = await transport
          .dispatch(_request('operation_cancel', 'cancel'))
          .timeout(const Duration(milliseconds: 300));

      expect(_responseToken(status), 'status');
      expect(_responseToken(cancel), 'cancel');
      expect(spawns, ['general-0', 'control']);
      await transport.close();
      await searchFailure;
      await expectLater(
        transport.dispatch(_request('library_browse', 'after-close')),
        throwsA(
          isA<LibraryCoreFailure>().having(
            (error) => error.code,
            'code',
            'coreClosed',
          ),
        ),
      );
    },
  );

  test('worker crashes fail pending work and restart only once', () async {
    final spawns = <String>[];
    final transport = PersistentIsolateJsonCoreTransport.testHarness(
      workerEntrypoint: _testWorkerMain,
      generalWorkerCount: 1,
      maxRestartsPerWorker: 1,
      onWorkerSpawn: spawns.add,
    );
    addTearDown(transport.close);

    await expectLater(
      transport.dispatch(_request('crash', 'first-crash')),
      throwsA(isA<LibraryCoreFailure>()),
    );
    final recovered = await transport.dispatch(
      _request('library_browse', 'recovered'),
    );
    expect(_responseToken(recovered), 'recovered');
    expect(spawns, ['general-0', 'general-0']);

    await expectLater(
      transport.dispatch(_request('crash', 'second-crash')),
      throwsA(isA<LibraryCoreFailure>()),
    );
    await expectLater(
      transport.dispatch(_request('library_browse', 'no-loop')),
      throwsA(isA<LibraryCoreFailure>()),
    );
    expect(spawns, hasLength(2), reason: '崩溃后不得无限创建 isolate');
  });
}

String _request(String op, String token, {int delayMs = 0}) =>
    jsonEncode({'op': op, 'token': token, 'delayMs': delayMs});

String _responseToken(String response) =>
    (jsonDecode(response) as Map<String, Object?>)['token']! as String;

@pragma('vm:entry-point')
void _testWorkerMain(List<Object?> bootstrap) {
  final parent = bootstrap[0]! as SendPort;
  final label = bootstrap[1]! as String;
  final commands = ReceivePort('test-$label-commands');
  parent.send({'type': 'ready', 'commandPort': commands.sendPort});
  commands.listen((message) {
    final envelope = (message! as Map).cast<String, Object?>();
    if (envelope['type'] == 'close') {
      commands.close();
      Isolate.exit();
    }
    if (envelope['type'] != 'request') return;
    final requestId = envelope['requestId']! as int;
    final request = jsonDecode(envelope['request']! as String);
    final body = (request! as Map).cast<String, Object?>();
    final op = body['op'];
    if (op == 'crash') Isolate.exit();
    if (op == 'library_search' || op == 'hang') return;
    final delayMs = body['delayMs']! as int;
    Future<void>.delayed(Duration(milliseconds: delayMs), () {
      parent.send({
        'type': 'response',
        'requestId': requestId,
        'ok': true,
        'response': jsonEncode({
          'token': body['token'],
          'op': op,
          'worker': label,
        }),
      });
    });
  });
}
