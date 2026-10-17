/// The app's version, passed in by build-apk.sh (`--dart-define=APP_VERSION=...`); empty in a
/// plain `flutter run`.
const String appVersion = String.fromEnvironment('APP_VERSION');

/// "버전 0.8.12", or empty when the build carries no version.
String get appVersionLabel => appVersion.isEmpty ? '' : '버전 $appVersion';
