import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/animated_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/one_frame_multi_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/viewer_originals.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:openapi/api.dart';

class RemoteImageProvider extends ImageProvider<RemoteImageProvider> {
  final String url;
  final bool edited;

  /// Physical size to decode, or null for the source size.
  final Size? decodeSize;

  const RemoteImageProvider({required this.url, this.edited = true, this.decodeSize});

  RemoteImageProvider.thumbnail({
    required String assetId,
    required String thumbhash,
    this.edited = true,
    this.decodeSize,
  }) : url = getThumbnailUrlForRemoteId(assetId, thumbhash: thumbhash, edited: edited);

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteImageProvider key, ImageDecoderCallback decode) {
    final loader = ImageLoader(key);
    return OneFramePlaceholderImageStreamCompleter(
      _codec(loader, key, decode),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('URL', key.url),
      ],
      onLastListenerRemoved: loader.cancel,
    );
  }

  Stream<ImageInfo> _codec(ImageLoader loader, RemoteImageProvider key, ImageDecoderCallback decode) {
    final request = loader.request = RemoteImageRequest(uri: key.url, decodeSize: key.decodeSize);
    return loader.loadRequest(request, decode, isFinal: true);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteImageProvider) {
      return url == other.url && edited == other.edited && decodeSize == other.decodeSize;
    }
    return false;
  }

  @override
  int get hashCode => url.hashCode ^ edited.hashCode ^ decodeSize.hashCode;
}

class RemoteFullImageProvider extends ImageProvider<RemoteFullImageProvider> {
  final String assetId;
  final String thumbhash;
  final AssetType assetType;
  final bool isAnimated;
  final bool edited;

  /// immich-sync fork: whether an edited version exists, which decides the offline store's URL for the original.
  /// Unlike [edited], which asks for that version.
  final bool isEdited;

  /// Physical size of the thumbnail shown before the preview.
  final Size? thumbnailSize;

  /// immich-sync fork: how many times the viewer's quality button asked for this photo's original
  /// ([ViewerOriginals.attemptOf]). Zero is upstream's behaviour.
  final int originalAttempt;

  const RemoteFullImageProvider({
    required this.assetId,
    required this.thumbhash,
    required this.assetType,
    required this.isAnimated,
    this.edited = true,
    this.isEdited = false,
    this.thumbnailSize,
    this.originalAttempt = 0,
  });

  /// immich-sync fork: the same URL the offline store uses.
  String _originalUrl(String thumbhash) =>
      offlineOriginalUrl(assetId, isEdited: isEdited, thumbHash: thumbhash, edited: edited);

  /// immich-sync fork: a merged asset carries no thumbhash, so it is read from the synced row. Without it the preview
  /// and original URLs name no version, and the offline store would serve what it kept under them before an edit.
  static Future<String> _version(RemoteFullImageProvider key) async {
    if (key.thumbhash.isNotEmpty) {
      return key.thumbhash;
    }
    try {
      return await OfflineFlagsRepository.instance.thumbHashOf(key.assetId) ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<RemoteFullImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteFullImageProvider key, ImageDecoderCallback decode) {
    final loader = ImageLoader(key);
    if (key.isAnimated) {
      return AnimatedImageStreamCompleter(
        stream: _animatedCodec(loader, key, decode),
        scale: 1.0,
        initialImage: loader.getInitialImage(
          RemoteImageProvider.thumbnail(assetId: key.assetId, thumbhash: key.thumbhash, decodeSize: key.thumbnailSize),
        ),
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('Asset Id', key.assetId),
          DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
        ],
        onLastListenerRemoved: loader.cancel,
      );
    }

    return OneFramePlaceholderImageStreamCompleter(
      _codec(loader, key, decode),
      // immich-sync fork: an original asked for by hand reloads a photo whose preview is already on screen, which stays
      // up until this stream's first frame. Starting from the thumbnail would blur it before sharpening it.
      initialImage: key.originalAttempt > 0
          ? null
          : loader.getInitialImage(
              RemoteImageProvider.thumbnail(
                assetId: key.assetId,
                thumbhash: key.thumbhash,
                edited: key.edited,
                decodeSize: key.thumbnailSize,
              ),
            ),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Asset Id', key.assetId),
        DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
      ],
      onLastListenerRemoved: loader.cancel,
    );
  }

  Stream<ImageInfo> _codec(ImageLoader loader, RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* loader.initialImageStream();

    if (loader.isCancelled) {
      return;
    }

    final thumbhash = await _version(key);
    if (loader.isCancelled) {
      return;
    }

    final previewRequest = loader.request = _previewRequest(key, thumbhash);
    // immich-sync fork: a stored original costs no network, so an item kept at full quality shows the real photo even
    // with the setting off, and so does one the viewer's quality button asked for.
    final requested = key.originalAttempt > 0;
    final loadOriginal =
        assetType == AssetType.image &&
        (SettingsRepository.instance.appConfig.image.loadOriginal ||
            OfflineIndex.availability(key.assetId) == OfflineAvailability.full ||
            requested);
    yield* loader.loadRequest(previewRequest, decode, isFinal: !loadOriginal);

    if (!loadOriginal) {
      return;
    }

    if (loader.isCancelled) {
      return;
    }

    final originalRequest = loader.request = _originalRequest(key, thumbhash);
    yield* _loadOriginal(loader, key.assetId, originalRequest, decode, failSoft: requested);
  }

  /// immich-sync fork: tells [ViewerOriginals] whether the original reached the screen, for the viewer's quality
  /// button. One asked for by hand fails soft — the preview stays up and the button offers a retry — where upstream's
  /// error path would swap in the thumbnail.
  Stream<ImageInfo> _loadOriginal(
    ImageLoader loader,
    String assetId,
    RemoteImageRequest originalRequest,
    ImageDecoderCallback decode, {
    required bool failSoft,
  }) async* {
    var shown = false;
    try {
      await for (final image in loader.loadRequest(originalRequest, decode, isFinal: !failSoft)) {
        shown = true;
        yield image;
      }
    } finally {
      if (!loader.isCancelled) {
        ViewerOriginals.instance.settle(assetId, loaded: shown);
      }
    }
    loader.isFinished = true;
  }

  Stream<Object> _animatedCodec(ImageLoader loader, RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* loader.initialImageStream();

    if (loader.isCancelled) {
      return;
    }

    final thumbhash = await _version(key);
    if (loader.isCancelled) {
      return;
    }

    final previewRequest = loader.request = _previewRequest(key, thumbhash);
    yield* loader.loadRequest(previewRequest, decode, isFinal: false);

    if (loader.isCancelled) {
      return;
    }

    // always try original for animated, since previews don't support animation
    final originalRequest = loader.request = _originalRequest(key, thumbhash);
    final codec = await loader.loadCodecRequest(originalRequest, isFinal: true);
    if (codec == null) {
      if (loader.isCancelled) {
        return;
      }
      throw StateError('Failed to load animated codec for asset ${key.assetId}');
    }
    yield codec;
  }

  RemoteImageRequest _previewRequest(RemoteFullImageProvider key, String thumbhash) => RemoteImageRequest(
    uri: getThumbnailUrlForRemoteId(
      key.assetId,
      type: AssetMediaSize.preview,
      thumbhash: thumbhash,
      edited: key.edited,
    ),
  );

  RemoteImageRequest _originalRequest(RemoteFullImageProvider key, String thumbhash) =>
      RemoteImageRequest(uri: key._originalUrl(thumbhash));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteFullImageProvider) {
      return assetId == other.assetId &&
          thumbhash == other.thumbhash &&
          isAnimated == other.isAnimated &&
          edited == other.edited &&
          isEdited == other.isEdited &&
          originalAttempt == other.originalAttempt;
    }

    return false;
  }

  @override
  int get hashCode =>
      assetId.hashCode ^
      thumbhash.hashCode ^
      isAnimated.hashCode ^
      edited.hashCode ^
      isEdited.hashCode ^
      originalAttempt.hashCode;
}
