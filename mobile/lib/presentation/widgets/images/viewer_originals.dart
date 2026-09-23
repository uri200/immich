import 'package:flutter/foundation.dart';

/// What the viewer's quality button says about the photo on screen.
enum ViewerOriginalState {
  /// The preview is showing and nothing will load the original.
  preview,

  /// The original has been asked for and has not arrived yet.
  loading,

  /// The original is on screen.
  original,

  /// The original was asked for and could not be fetched; the preview stays up.
  failed,
}

/// immich-sync fork: originals the user asked the viewer for by hand, one photo at a time.
///
/// With "Load original image" off the viewer stops at the preview, which is right for a
/// server that may be off and a data plan that is not free. This is the way past it for a
/// single photo: nothing is stored offline, and what comes back lands in the native
/// opportunistic cache like any other fetched file, so it is trimmed with the rest.
///
/// It lives outside Riverpod because the image provider that reports into it is not a
/// Riverpod object, and it lasts only as long as the process: an ask is about looking at
/// a photo now, not a standing preference.
class ViewerOriginals extends ChangeNotifier {
  ViewerOriginals._();

  static final instance = ViewerOriginals._();

  final _attempts = <String, int>{};
  final _loaded = <String>{};
  final _failed = <String>{};

  /// How many times the original of [assetId] was asked for by hand. It is part of the
  /// image provider's key, so each ask is a fresh load: the first moves past the cached
  /// preview-only image, and a retry is not served the failure it is retrying.
  int attemptOf(String? assetId) => assetId == null ? 0 : _attempts[assetId] ?? 0;

  void request(String assetId) {
    _attempts[assetId] = attemptOf(assetId) + 1;
    _failed.remove(assetId);
    _loaded.remove(assetId);
    notifyListeners();
  }

  /// Called by the image provider once an original load has ended, whoever started it.
  void settle(String assetId, {required bool loaded}) {
    final changed = loaded
        ? _loaded.add(assetId) | _failed.remove(assetId)
        : _failed.add(assetId) | _loaded.remove(assetId);
    if (changed) {
      notifyListeners();
    }
  }

  /// [wantedElsewhere] is whether the viewer loads the original on its own — the
  /// "Load original image" setting, or a copy already stored offline.
  ViewerOriginalState stateOf(String assetId, {required bool wantedElsewhere}) {
    if (!wantedElsewhere && attemptOf(assetId) == 0) {
      return ViewerOriginalState.preview;
    }
    if (_loaded.contains(assetId)) {
      return ViewerOriginalState.original;
    }
    if (_failed.contains(assetId)) {
      return ViewerOriginalState.failed;
    }
    return ViewerOriginalState.loading;
  }

  @visibleForTesting
  void reset() {
    _attempts.clear();
    _loaded.clear();
    _failed.clear();
  }
}
