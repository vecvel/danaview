import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'player_controller.dart';
import 'queue_controller.dart';

final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  throw UnimplementedError('playbackEngineProvider must be overridden with a concrete engine');
});

final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  throw UnimplementedError('sessionRepositoryProvider must be initialized');
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  throw UnimplementedError('libraryRepositoryProvider must be initialized');
});

final playerControllerProvider =
    StateNotifierProvider<PlayerController, PlayerState>((ref) {
  final engine = ref.watch(playbackEngineProvider);
  final sessionRepo = ref.watch(sessionRepositoryProvider);
  final libraryRepo = ref.watch(libraryRepositoryProvider);
  return PlayerController(engine, sessionRepo, libraryRepo, ref);
});

final queueControllerProvider =
    StateNotifierProvider<QueueController, QueueState>((ref) {
  final playerCtrl = ref.watch(playerControllerProvider.notifier);
  final libraryRepo = ref.watch(libraryRepositoryProvider);
  return QueueController(playerCtrl, libraryRepo);
});

/// How far, in seconds, a double tap on the left or right of the video seeks.
final doubleTapSeekProvider = StateNotifierProvider<DoubleTapSeekController, int>((ref) {
  return DoubleTapSeekController(ref.watch(sessionRepositoryProvider));
});

class DoubleTapSeekController extends StateNotifier<int> {
  DoubleTapSeekController(this._sessionRepo) : super(_sessionRepo.getDoubleTapSeekSeconds());

  final SessionRepository _sessionRepo;

  Future<void> set(int seconds) async {
    if (seconds <= 0 || seconds == state) return;
    state = seconds;
    await _sessionRepo.saveDoubleTapSeekSeconds(seconds);
  }
}
