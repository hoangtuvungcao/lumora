// Android Back on the layers drawn above the app's Navigator (call screen,
// remote screen, app lock — LayerHost in lib/ui/widgets/common.dart).
// Regression: Back never reached a layer's own Navigator, so the call
// screen's "More" sheet stayed open and Lumora went to the background.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/ui/widgets/common.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> system;

  setUp(() {
    system = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      system.add(c.method);
      return null;
    });
  });

  tearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  Future<void> pumpApp(WidgetTester t, {required Widget layer, Widget? home}) async {
    await t.pumpWidget(MaterialApp(
      home: home ?? const Scaffold(body: Text('home')),
      builder: (context, child) => Stack(children: [child!, Positioned.fill(child: layer)]),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('Back closes a sheet open in the layer, then asks onBack', (t) async {
    var minimised = 0;
    await pumpApp(
      t,
      layer: LayerHost(
        onBack: (_) {
          minimised++;
          return true;
        },
        child: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(context: ctx, builder: (_) => const Text('sheet')),
              child: const Text('more'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('more'));
    await t.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);

    await binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(minimised, 0);
    expect(system, isNot(contains('SystemNavigator.pop')));

    await binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(minimised, 1);
    expect(system, isNot(contains('SystemNavigator.pop')));
  });

  testWidgets('a layer with nothing to do lets the app handle Back', (t) async {
    await pumpApp(t, layer: const LayerHost(child: SizedBox.shrink()));
    await binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(system, contains('SystemNavigator.pop'));
  });

  testWidgets('the app lock (barrier) hides the layers below it from Back', (t) async {
    var below = 0;
    await t.pumpWidget(MaterialApp(
      home: const Scaffold(body: Text('home')),
      builder: (context, child) => Stack(children: [
        child!,
        Positioned.fill(
          child: LayerHost(
            onBack: (_) {
              below++;
              return true;
            },
            child: const SizedBox.shrink(),
          ),
        ),
        const Positioned.fill(child: LayerHost(barrier: true, child: Text('lock'))),
      ]),
    ));
    await t.pumpAndSettle();
    await binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(below, 0);
    expect(system, contains('SystemNavigator.pop'));
  });
}
