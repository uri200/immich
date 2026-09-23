import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/viewer_originals.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// immich-sync fork: says which version of the photo is on screen, and fetches the original
/// for this one photo when tapped (see [ViewerOriginals]).
///
/// Only drawn for a photo rendered from the server: one shown from the phone's own file is
/// already the original, and a video or animation has no preview to step up from.
class ViewOriginalButton extends ConsumerWidget {
  const ViewOriginalButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assetId = remoteFullImageId(asset);
    final isPlayingMotionVideo = ref.watch(isPlayingMotionVideoProvider);
    if (assetId == null || !asset.isImage || asset.isAnimatedImage || isPlayingMotionVideo) {
      return const SizedBox.shrink();
    }

    final loadOriginalSetting = ref.watch(appConfigProvider.select((config) => config.image.loadOriginal));
    final originals = ViewerOriginals.instance;

    return ListenableBuilder(
      listenable: originals,
      builder: (context, _) {
        final state = originals.stateOf(
          assetId,
          wantedElsewhere: loadOriginalSetting || OfflineIndex.availability(assetId) == OfflineAvailability.full,
        );
        return switch (state) {
          ViewerOriginalState.preview => IconButton(
            icon: const Icon(Icons.hd_outlined),
            tooltip: 'Showing the preview. Tap to load full quality',
            onPressed: () => originals.request(assetId),
          ),
          ViewerOriginalState.loading => const Tooltip(
            message: 'Loading full quality',
            child: Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
          ),
          ViewerOriginalState.original => const Tooltip(
            message: 'Showing full quality',
            child: Padding(padding: EdgeInsets.all(10), child: Icon(Icons.hd)),
          ),
          ViewerOriginalState.failed => IconButton(
            icon: const Icon(Icons.cloud_off_outlined),
            tooltip: "Couldn't reach the server for full quality. Tap to retry",
            onPressed: () => originals.request(assetId),
          ),
        };
      },
    );
  }
}
