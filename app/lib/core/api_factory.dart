import 'package:flutter/foundation.dart';

import 'api.dart';
import 'ffi_api.dart';
import 'mock_api.dart';

const String _mockEnv = String.fromEnvironment('LUMORA_MOCK');

/// `--dart-define=LUMORA_MOCK=1`: run the UI against the demo API.
const bool kForceMock = _mockEnv == '1' || _mockEnv == 'true';

/// The demo API may stand in for a missing native core only when explicitly
/// requested or in debug builds. Release builds show an error instead.
const bool kAllowMockFallback = kForceMock || kDebugMode;

/// Result of [createApi]: either an API or a reason it could not be created.
class ApiLoad {
  const ApiLoad(this.api, [this.error]);
  final LumoraApi? api;
  final String? error;
}

/// Picks the FFI implementation. The mock is used when forced, or (debug
/// builds only) when the native library can't be loaded.
ApiLoad createApi() {
  if (kForceMock) return ApiLoad(MockLumoraApi(autoDemo: true));
  try {
    return ApiLoad(FfiLumoraApi.load());
  } catch (e) {
    if (kAllowMockFallback) {
      debugPrint('Lumora: native core unavailable ($e) – using mock API (debug only)');
      return ApiLoad(MockLumoraApi(autoDemo: true));
    }
    return ApiLoad(null, '$e');
  }
}
