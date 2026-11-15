// immich-sync fork: what the viewer needs to mark the words an OCR search matched.
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/ocr.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/utils/ocr_match.utils.dart';

/// The OCR text of the search the search page last ran, or null if that search wasn't by OCR.
final ocrSearchQueryProvider = NotifierProvider<OcrSearchQueryNotifier, String?>(OcrSearchQueryNotifier.new);

class OcrSearchQueryNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? query) {
    final trimmed = query?.trim();
    state = trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// An asset's recognised text boxes and where the OCR query matched in them.
class OcrHighlight {
  final List<Ocr> boxes;
  final List<OcrMatch> matches;

  const OcrHighlight(this.boxes, this.matches);

  OcrMatch? get best => bestOcrMatch(matches);
}

/// Matches for `(assetId, query)`, worked out from the OCR rows sync stored on the phone.
final ocrHighlightProvider = FutureProvider.autoDispose.family<OcrHighlight, (String, String)>((ref, key) async {
  final (assetId, query) = key;
  final boxes = await ref.watch(Store.ocr.forAsset(assetId).future);
  return OcrHighlight(boxes, findOcrMatches(query, [for (final box in boxes) box.text]));
});

/// The OCR query to mark in the viewer: only when it was opened from the search results.
String? watchOcrHighlightQuery(WidgetRef ref) {
  if (ref.watch(timelineServiceProvider).origin != TimelineOrigin.search) {
    return null;
  }
  return ref.watch(ocrSearchQueryProvider);
}

/// The id OCR rows are stored under, or null for assets that have none on the phone.
String? ocrAssetId(BaseAsset asset) => asset is RemoteAsset ? asset.id : null;

/// The highlight for [asset] when the viewer was opened from an OCR search, else null.
OcrHighlight? watchOcrHighlight(WidgetRef ref, BaseAsset asset) {
  final query = watchOcrHighlightQuery(ref);
  final assetId = ocrAssetId(asset);
  if (query == null || assetId == null) {
    return null;
  }
  return ref.watch(ocrHighlightProvider((assetId, query))).valueOrNull;
}
