// Real-core smoke test (skipped unless LUMORA_REAL_CORE=<lib>:<lumorad>:<tmpdir>).
// Runs tool/ffi_smoke.dart under the Flutter test runner (ffi_api pulls Flutter
// in via the Android bridge, so plain `dart run` no longer compiles).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/ffi_smoke.dart' as smoke;

void main() {
  final spec = Platform.environment['LUMORA_REAL_CORE'];
  test('real core smoke', () async {
    await smoke.main(spec!.split(':'));
  }, skip: spec == null ? 'set LUMORA_REAL_CORE' : false, timeout: const Timeout(Duration(minutes: 8)));
}
