import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Kept in sync with `version:` in the root pubspec.yaml (a test checks it).
const String danaviewAppVersion = '1.2.0';
const int danaviewBuildNumber = 4;

/// Contact address shown in the legal pages and About; they hide the contact line while it is null.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? danaviewSupportEmail = 'support@vecvel.com';

/// [danaviewSupportEmail], read through a provider so tests can show the contact rows.
final supportEmailProvider = Provider<String?>((ref) => danaviewSupportEmail);
