import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'player_controller.dart';

class QueueController extends StateNotifier<QueueState> {
  final PlayerController _playerCtrl;
  final LibraryRepository libraryRepo;
  int _consecutiveFailures = 0;

  QueueController(this._playerCtrl, this.libraryRepo) : super(const QueueState());

  Future<void> playFrom(List<MediaRef> items, {int startIndex = 0}) async {
    if (items.isEmpty) return;
    _consecutiveFailures = 0;

    final targetIndex = startIndex.clamp(0, items.length - 1);
    state = state.copyWith(
      items: items,
      currentIndex: targetIndex,
      unShuffledItems: items,
      isShuffled: false,
    );

    await _playerCtrl.openMedia(items[targetIndex]);
  }

  /// Inserts [item] after the current one. Callers should start playback instead when
  /// nothing is playing ([QueueState.hasCurrent] is false).
  Future<void> playNext(MediaRef item) async {
    final list = List<MediaRef>.from(state.items);
    if (state.hasCurrent) {
      list.insert(state.currentIndex + 1, item);
    } else {
      list.add(item);
    }
    state = state.copyWith(items: list, unShuffledItems: _withOriginal((orig) {
      final at = state.currentItem == null ? -1 : orig.indexOf(state.currentItem!);
      if (at >= 0) {
        orig.insert(at + 1, item);
      } else {
        orig.add(item);
      }
    }));
  }

  Future<void> addToQueue(List<MediaRef> items) async {
    final list = List<MediaRef>.from(state.items)..addAll(items);
    state = state.copyWith(items: list, unShuffledItems: _withOriginal((orig) => orig.addAll(items)));
    if (state.currentIndex == -1 && list.isNotEmpty) {
      await jumpTo(0);
    }
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= state.items.length) return;
    final list = List<MediaRef>.from(state.items);
    final removed = list.removeAt(index);
    final original = _withOriginal((orig) => orig.remove(removed));
    final wasCurrent = index == state.currentIndex;

    if (!wasCurrent) {
      final cur = index < state.currentIndex ? state.currentIndex - 1 : state.currentIndex;
      state = state.copyWith(items: list, currentIndex: cur, unShuffledItems: original);
      return;
    }
    if (list.isEmpty) {
      state = state.copyWith(items: list, currentIndex: -1, unShuffledItems: original);
      await _playerCtrl.stop();
      return;
    }
    // The item that slid into the removed slot (or the new last one) plays in its place.
    state = state.copyWith(items: list, unShuffledItems: original);
    await jumpTo(min(index, list.length - 1));
  }

  /// The pre-shuffle order with [edit] applied; unchanged while not shuffled.
  List<MediaRef>? _withOriginal(void Function(List<MediaRef> orig) edit) {
    if (!state.isShuffled) return null;
    final orig = List<MediaRef>.from(state.unShuffledItems);
    edit(orig);
    return orig;
  }

  Future<void> move(int from, int to) async {
    if (from < 0 || from >= state.items.length || to < 0 || to >= state.items.length) {
      return;
    }
    final list = List<MediaRef>.from(state.items);
    final item = list.removeAt(from);
    list.insert(to, item);

    int nextCur = state.currentIndex;
    if (state.currentIndex == from) {
      nextCur = to;
    } else if (from < state.currentIndex && to >= state.currentIndex) {
      nextCur--;
    } else if (from > state.currentIndex && to <= state.currentIndex) {
      nextCur++;
    }

    state = state.copyWith(items: list, currentIndex: nextCur);
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.items.length) return;
    _consecutiveFailures = 0;
    state = state.copyWith(currentIndex: index);
    await _playerCtrl.openMedia(state.items[index]);
  }

  Future<void> next({bool userInitiated = true}) async {
    if (state.items.isEmpty) return;

    if (state.repeatMode == RepeatMode.one && !userInitiated) {
      await _playerCtrl.seek(Duration.zero);
      await _playerCtrl.play();
      return;
    }

    if (state.currentIndex < state.items.length - 1) {
      await jumpTo(state.currentIndex + 1);
    } else if (state.repeatMode == RepeatMode.all) {
      await jumpTo(0);
    }
  }

  Future<void> previous() async {
    if (state.items.isEmpty) return;

    // TRD §7.6: if >5s elapsed, restart current
    if (_playerCtrl.state.position.inSeconds > 5) {
      await _playerCtrl.seek(Duration.zero);
      return;
    }

    if (state.currentIndex > 0) {
      await jumpTo(state.currentIndex - 1);
    } else if (state.repeatMode == RepeatMode.all) {
      await jumpTo(state.items.length - 1);
    }
  }

  void setRepeat(RepeatMode mode) {
    state = state.copyWith(repeatMode: mode);
  }

  void cycleRepeatMode() {
    final next = switch (state.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    setRepeat(next);
  }

  void setShuffle(bool shuffle) {
    if (shuffle == state.isShuffled) return;

    if (shuffle) {
      final current = state.currentItem;
      final remaining = List<MediaRef>.from(state.items);
      if (current != null) {
        remaining.remove(current);
      }

      // Seeded Fisher-Yates
      final rng = Random();
      for (var i = remaining.length - 1; i > 0; i--) {
        final j = rng.nextInt(i + 1);
        final temp = remaining[i];
        remaining[i] = remaining[j];
        remaining[j] = temp;
      }

      final shuffled = current != null ? [current, ...remaining] : remaining;
      state = state.copyWith(
        items: shuffled,
        currentIndex: current != null ? 0 : -1,
        unShuffledItems: state.items,
        isShuffled: true,
      );
    } else {
      // Restore original order
      final current = state.currentItem;
      final orig = state.unShuffledItems;
      final curIdx = current != null ? orig.indexOf(current) : -1;
      state = state.copyWith(
        items: orig,
        currentIndex: curIdx >= 0 ? curIdx : 0,
        isShuffled: false,
      );
    }
  }

  void setStopAfterCurrent(bool stop) {
    state = state.copyWith(stopAfterCurrent: stop);
  }

  Future<void> onPlaybackEnded() async {
    if (state.stopAfterCurrent) {
      setStopAfterCurrent(false);
      return;
    }

    if (_consecutiveFailures >= 3) {
      debugPrint('[QueueController] Circuit breaker halted auto-advance after 3 failures.');
      return;
    }

    if (state.repeatMode == RepeatMode.one || state.hasNext) {
      await next(userInitiated: false);
    }
  }

  /// Clears the active queue and stops/resets the player.
  Future<void> clear() async {
    _consecutiveFailures = 0;
    state = const QueueState();
    await _playerCtrl.stopAndClear();
  }
}
