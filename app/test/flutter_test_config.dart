// Applies to every test in this folder: the PIN KDF runs with few rounds so
// widget tests stay fast and inline (no background isolate under fake time).
// test/pin_kdf_test.dart switches the real 210 000 rounds back on.

import 'dart:async';

import 'package:lumora/state/app_lock.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppLock.kdfIterations = 1000;
  await testMain();
}
