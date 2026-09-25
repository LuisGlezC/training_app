import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfiguration {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  static Future<void> initialize() async {
    if (!isConfigured) return;

    await Supabase.initialize(
      url: url,
      publishableKey: publishableKey,
    );
  }
}
