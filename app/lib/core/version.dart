// App version shown in Settings › About. Keep in sync with `version:` in
// pubspec.yaml (test/version_test.dart fails if they drift). A build can
// override it with --dart-define=LUMORA_VERSION=x.y.z.
const String kPubspecVersion = '1.0.7';
const String kAppVersion = String.fromEnvironment('LUMORA_VERSION', defaultValue: kPubspecVersion);
