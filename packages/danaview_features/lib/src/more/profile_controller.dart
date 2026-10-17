import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';

/// The on-device profile store. Opens SharedPreferences lazily so the app needs no startup
/// wiring for it; tests can override it with a repository over mock preferences.
final profileRepositoryProvider = FutureProvider<ProfileRepository>((ref) => ProfileRepository.create());

/// The saved profile ([UserProfile.empty] when none), shared by Settings and the profile page.
final profileProvider = AsyncNotifierProvider<ProfileController, UserProfile>(ProfileController.new);

class ProfileController extends AsyncNotifier<UserProfile> {
  @override
  Future<UserProfile> build() async {
    final repository = await ref.watch(profileRepositoryProvider.future);
    return repository.load();
  }

  /// Stores [profile] (trimmed; an empty one clears it) and returns what was stored.
  Future<UserProfile> save(UserProfile profile) async {
    final repository = await ref.read(profileRepositoryProvider.future);
    final saved = await repository.save(profile);
    state = AsyncData(saved);
    return saved;
  }

  Future<void> clear() async {
    final repository = await ref.read(profileRepositoryProvider.future);
    await repository.clear();
    state = const AsyncData(UserProfile.empty);
  }
}
