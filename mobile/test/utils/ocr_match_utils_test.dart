import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/ocr_match_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_overlay.widget.dart';
import 'package:immich_mobile/utils/ocr_match.utils.dart';

void main() {
  group('findOcrMatches', () {
    test('marks just the matched word inside a line', () {
      final matches = findOcrMatches('dental', ['Soothing Dental Associates']);

      expect(matches, hasLength(1));
      expect(matches.single.spans, [const OcrMatchSpan(0, 9, 15)]);
      expect(matches.single.similarity, 1.0);
    });

    test('matches "dent" for "dental", like the server does at exactly 0.5', () {
      // "dental" has 7 trigrams, "dent" 5, and they share 4: 4 / (7 + 5 - 4) = 0.5.
      final matches = findOcrMatches('dental', ['Check for dent and scratches']);

      expect(matches, hasLength(1));
      expect(matches.single.spans, [const OcrMatchSpan(0, 10, 14)]);
      expect(matches.single.similarity, closeTo(0.5, 1e-9));
    });

    test('leaves out words below the threshold', () {
      // "dentist" shares 4 of 11 trigrams with "dental" (0.36); "dance" shares 1.
      expect(findOcrMatches('dental', ['Ask your dentist', 'dance class']), isEmpty);
    });

    test('ignores case, accents and punctuation', () {
      final matches = findOcrMatches('medico', ['Centre MÉDICO, Barcelona']);

      expect(matches.single.spans, [const OcrMatchSpan(0, 7, 13)]);
    });

    test('follows a multi-word query across boxes', () {
      final matches = findOcrMatches('soothing dental', ['Soothing', 'Dental Associates']);

      expect(matches, hasLength(1));
      expect(matches.single.spans, [const OcrMatchSpan(0, 0, 8), const OcrMatchSpan(1, 0, 6)]);
    });

    test('finds every occurrence in reading order, and the best one to jump to', () {
      final matches = findOcrMatches('dental', ['small dent', 'Dental care']);

      expect(matches.map((m) => m.spans.single), [const OcrMatchSpan(0, 6, 10), const OcrMatchSpan(1, 0, 6)]);
      expect(bestOcrMatch(matches), same(matches[1]));
    });

    test('returns nothing for a query without words', () {
      expect(findOcrMatches('  ', ['Dental']), isEmpty);
      expect(findOcrMatches('?!', ['Dental']), isEmpty);
      expect(bestOcrMatch(const []), isNull);
    });

    test('matches CJK text through the same bigrams the server indexes', () {
      final matches = findOcrMatches('東京', ['東京駅']);

      expect(matches.single.spans, [const OcrMatchSpan(0, 0, 2)]);
    });
  });

  group('tokenizeForSearch', () {
    test('keeps where each token starts in the original text', () {
      final tokens = tokenizeForSearch(' ab  東京駅 c');

      expect(tokens.map((t) => (t.text, t.start)), [('ab', 1), ('東京', 5), ('京駅', 6), ('c', 9)]);
    });
  });

  group('ocrSpanQuad', () {
    const line = [Offset.zero, Offset(100, 0), Offset(100, 10), Offset(0, 10)];

    test('takes the matched characters\' share of a horizontal box, with a little padding', () {
      final quad = ocrSpanQuad(line, 10, 2, 5);

      expect(quad[0].dx, closeTo(16.5, 1e-9));
      expect(quad[1].dx, closeTo(53.5, 1e-9));
      expect(quad[2], Offset(quad[1].dx, 10));
      expect(quad[3], Offset(quad[0].dx, 10));
    });

    test('stays inside the box at its edges', () {
      final quad = ocrSpanQuad(line, 4, 0, 4);

      expect(quad, line);
    });

    test('returns vertical boxes whole', () {
      const column = [Offset.zero, Offset(10, 0), Offset(10, 100), Offset(0, 100)];

      expect(ocrSpanQuad(column, 5, 1, 2), column);
    });
  });

  group('ocrMatchSnippet', () {
    test('splits each touched box into matched and unmatched parts', () {
      final parts = ocrMatchSnippet(const OcrMatch([OcrMatchSpan(0, 9, 15), OcrMatchSpan(1, 0, 4)], 1), [
        'Soothing Dental',
        'Care team',
        'unrelated',
      ]);

      expect(parts, [
        (text: 'Soothing ', isMatch: false),
        (text: 'Dental', isMatch: true),
        (text: ' ', isMatch: false),
        (text: 'Care', isMatch: true),
        (text: ' team', isMatch: false),
      ]);
    });
  });
}
