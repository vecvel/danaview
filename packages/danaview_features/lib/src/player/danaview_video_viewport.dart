import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/providers.dart';
import 'danaview_player_actions.dart';

class DanaviewVideoViewport extends ConsumerWidget {
  const DanaviewVideoViewport({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final videoCtrl = ref.watch(playbackEngineProvider).videoController;

    if (!playerHasMedia(state)) {
      return ColoredBox(
        color: DanaviewColors.background,
        child: SafeArea(
          child: DanaviewEmptyState(
            icon: Icons.movie_creation_outlined,
            title: 'No Media Loaded',
            message: context.isTouchPlatform
                ? 'Open a video from your device to start watching.'
                : 'Drop videos or folders here, or press O to open files.',
            actions: [
              DanaviewButton.primary(
                label: 'Open file',
                icon: Icons.video_file_rounded,
                onPressed: () => openVideoFiles(context, ref),
              ),
            ],
          ),
        ),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: videoCtrl is mkv.VideoController
            ? mkv.Video(
                controller: videoCtrl,
                controls: mkv.NoVideoControls,
                fit: _boxFit(state.transform.aspectOverride),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  BoxFit _boxFit(String? aspect) {
    if (aspect == 'fill') return BoxFit.fill;
    if (aspect == 'cover') return BoxFit.cover;
    return BoxFit.contain;
  }
}
