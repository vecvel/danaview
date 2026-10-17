import 'package:meta/meta.dart';
import 'media_source.dart';

enum RepeatMode {
  off,
  one,
  all,
}

@immutable
class QueueState {
  final List<MediaRef> items;
  final int currentIndex;
  final RepeatMode repeatMode;
  final bool isShuffled;
  final List<MediaRef> unShuffledItems;
  final bool stopAfterCurrent;

  const QueueState({
    this.items = const [],
    this.currentIndex = -1,
    this.repeatMode = RepeatMode.off,
    this.isShuffled = false,
    this.unShuffledItems = const [],
    this.stopAfterCurrent = false,
  });

  static const QueueState empty = QueueState();

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  bool get hasCurrent => currentIndex >= 0 && currentIndex < items.length;

  MediaRef? get currentItem => hasCurrent ? items[currentIndex] : null;

  bool get hasNext {
    if (items.isEmpty) return false;
    if (repeatMode == RepeatMode.all) return true;
    return currentIndex < items.length - 1;
  }

  bool get hasPrevious {
    if (items.isEmpty) return false;
    if (repeatMode == RepeatMode.all) return true;
    return currentIndex > 0;
  }

  MediaRef? get nextItem {
    if (!hasNext) return null;
    if (currentIndex + 1 < items.length) {
      return items[currentIndex + 1];
    } else if (repeatMode == RepeatMode.all && items.isNotEmpty) {
      return items.first;
    }
    return null;
  }

  QueueState copyWith({
    List<MediaRef>? items,
    int? currentIndex,
    RepeatMode? repeatMode,
    bool? isShuffled,
    List<MediaRef>? unShuffledItems,
    bool? stopAfterCurrent,
  }) {
    return QueueState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      repeatMode: repeatMode ?? this.repeatMode,
      isShuffled: isShuffled ?? this.isShuffled,
      unShuffledItems: unShuffledItems ?? this.unShuffledItems,
      stopAfterCurrent: stopAfterCurrent ?? this.stopAfterCurrent,
    );
  }
}
