import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/shared/app_motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('user and platform reduced-motion preferences zero durations', (
    tester,
  ) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
    });
    Duration? fast;
    Duration? medium;
    Duration? slow;

    Widget subject({required bool userReduced, required bool systemReduced}) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: systemReduced),
          child: AppMotionScope(
            reduceMotion: userReduced,
            child: Builder(
              builder: (context) {
                fast = AppMotion.fastFor(context);
                medium = AppMotion.mediumFor(context);
                slow = AppMotion.slowFor(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(subject(userReduced: false, systemReduced: false));
    expect(fast, AppMotion.fast);
    expect(medium, AppMotion.medium);
    expect(slow, AppMotion.slow);

    await tester.pumpWidget(subject(userReduced: true, systemReduced: false));
    expect(fast, Duration.zero);
    expect(medium, Duration.zero);
    expect(slow, Duration.zero);

    await tester.pumpWidget(subject(userReduced: false, systemReduced: true));
    expect(fast, Duration.zero);
    expect(medium, Duration.zero);
    expect(slow, Duration.zero);
  });

  testWidgets(
    'page transition preserves state and excludes inactive semantics',
    (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 20));
      });
      final firstKey = GlobalKey<_CounterPageState>();

      Widget subject(int index) => MaterialApp(
        home: AppMotionScope(
          reduceMotion: false,
          child: AppMotionPageStack(
            index: index,
            children: [
              _CounterPage(key: firstKey, label: '文件页'),
              const _CounterPage(label: '设置页'),
            ],
          ),
        ),
      );

      await tester.pumpWidget(subject(0));
      firstKey.currentState!.increment();
      await tester.pump();
      expect(find.text('文件页 1'), findsOneWidget);

      await tester.pumpWidget(subject(1));
      await tester.pumpAndSettle();
      expect(find.text('设置页 0'), findsOneWidget);
      expect(find.text('文件页 1'), findsNothing);

      await tester.pumpWidget(subject(0));
      await tester.pumpAndSettle();
      expect(find.text('文件页 1'), findsOneWidget);

      final semantics = tester.getSemantics(find.text('文件页 1'));
      expect(semantics.label, contains('文件页 1'));
    },
  );
}

class _CounterPage extends StatefulWidget {
  const _CounterPage({required this.label, super.key});

  final String label;

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int value = 0;

  void increment() => setState(() => value++);

  @override
  Widget build(BuildContext context) {
    final label = '${widget.label} $value';
    return Semantics(
      label: label,
      child: Center(child: Text(label)),
    );
  }
}
