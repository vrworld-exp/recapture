// lib/utils/app_env.dart

enum AppEnvironment {
  dev,
  staging,
  prod;

  String get envFileName => switch (this) {
        AppEnvironment.dev => '.env.dev',
        AppEnvironment.staging => '.env.staging',
        AppEnvironment.prod => '.env.prod',
      };

  String get displayName => switch (this) {
        AppEnvironment.dev => 'Development',
        AppEnvironment.staging => 'Staging',
        AppEnvironment.prod => 'Production',
      };

  bool get isProduction => this == AppEnvironment.prod;
}

// Resolved at compile time from --dart-define=ENV=<dev|staging|prod>.
// Defaults to dev so `flutter run` with no dart-define works out of the box.
const String _rawEnv = String.fromEnvironment('ENV', defaultValue: 'dev');
const AppEnvironment kAppEnvironment = _rawEnv == 'prod'
    ? AppEnvironment.prod
    : _rawEnv == 'staging'
        ? AppEnvironment.staging
        : AppEnvironment.dev;
