import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_domain/danaview_domain.dart';

/// The optional user profile, stored as one JSON value on this device only. Nothing here is
/// sent anywhere.
class ProfileRepository {
  final SharedPreferences _prefs;

  ProfileRepository(this._prefs);

  static Future<ProfileRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return ProfileRepository(prefs);
  }

  static const _kProfile = 'danaview_profile';

  /// The saved profile, or [UserProfile.empty] when none is saved or the stored value is unreadable.
  UserProfile load() {
    final raw = _prefs.getString(_kProfile);
    if (raw == null) return UserProfile.empty;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? UserProfile.fromJson(json) : UserProfile.empty;
    } catch (_) {
      return UserProfile.empty;
    }
  }

  /// Stores [profile] normalized (trimmed, date only); an empty profile removes the stored value.
  Future<UserProfile> save(UserProfile profile) async {
    final normalized = profile.normalized();
    if (normalized.isEmpty) {
      await clear();
      return UserProfile.empty;
    }
    await _prefs.setString(_kProfile, jsonEncode(normalized.toJson()));
    return normalized;
  }

  Future<void> clear() => _prefs.remove(_kProfile);
}
