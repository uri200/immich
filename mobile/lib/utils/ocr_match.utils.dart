// immich-sync fork: finds the words an OCR search matched, so the viewer can mark them.
//
// The server matches with `f_unaccent(ocr_search.text) %>> f_unaccent(query)`, which is
// pg_trgm's strict word similarity at its default threshold of 0.5. ocr_search.text is every
// box's text run through tokenizeForSearch and joined with spaces, in box order. This file
// reproduces that rule on the phone with the OCR rows sync already stored, so it marks the
// same words the server matched on, near-misses like "dent" for "dental" included.

/// pg_trgm's default `strict_word_similarity_threshold`; the server leaves it unchanged.
const double kOcrMatchThreshold = 0.5;

/// A run of characters in one OCR box's text, as `[start, end)` offsets into that text.
class OcrMatchSpan {
  final int boxIndex;
  final int start;
  final int end;

  const OcrMatchSpan(this.boxIndex, this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is OcrMatchSpan && other.boxIndex == boxIndex && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(boxIndex, start, end);

  @override
  String toString() => 'OcrMatchSpan($boxIndex, $start, $end)';
}

/// One place the query matched: consecutive words, which may run across several boxes.
class OcrMatch {
  /// One span per box the matched words fall in, in reading order.
  final List<OcrMatchSpan> spans;
  final double similarity;

  const OcrMatch(this.spans, this.similarity);

  @override
  String toString() => 'OcrMatch($spans, ${similarity.toStringAsFixed(3)})';
}

class _Word {
  final int boxIndex;
  final int start;
  final int end;
  final Set<String> trigrams;

  const _Word(this.boxIndex, this.start, this.end, this.trigrams);
}

/// Every place in [boxTexts] that [query] matches, in reading order, without overlaps.
///
/// Returns an empty list when the query has no words or nothing reaches [threshold].
List<OcrMatch> findOcrMatches(String query, List<String> boxTexts, {double threshold = kOcrMatchThreshold}) {
  final joinedQuery = tokenizeForSearch(query).map((t) => t.text).join(' ');
  final queryTrigrams = <String>{};
  var queryWordCount = 0;
  for (final (start, end) in _wordRanges(joinedQuery)) {
    queryWordCount++;
    queryTrigrams.addAll(_trigrams(_fold(joinedQuery.substring(start, end))));
  }
  if (queryTrigrams.isEmpty) {
    return const [];
  }

  final words = <_Word>[];
  for (var box = 0; box < boxTexts.length; box++) {
    final text = boxTexts[box];
    for (final token in tokenizeForSearch(text)) {
      for (final (start, end) in _wordRanges(token.text)) {
        final trigrams = _trigrams(_fold(token.text.substring(start, end)));
        if (trigrams.isEmpty) {
          continue;
        }
        // A CJK bigram's characters sit next to each other in the box text, so offsets carry over.
        words.add(_Word(box, token.start + start, token.start + end, trigrams));
      }
    }
  }

  // A run longer than the query only adds trigrams the query lacks, so a couple of extra words
  // covers every run that can still clear the threshold.
  final maxRun = queryWordCount + 2;
  final candidates = <(int, int, double)>[];
  for (var first = 0; first < words.length; first++) {
    final union = <String>{};
    for (var last = first; last < words.length && last - first < maxRun; last++) {
      union.addAll(words[last].trigrams);
      final shared = union.where(queryTrigrams.contains).length;
      final similarity = shared / (queryTrigrams.length + union.length - shared);
      // pg_trgm works in float4, so allow for rounding at an exact 0.5.
      if (similarity >= threshold - 1e-6) {
        candidates.add((first, last, similarity));
      }
    }
  }

  // Best first, then shortest, so "dental" wins over "dental clinic" and over a nearby "dent".
  candidates.sort((a, b) {
    final bySimilarity = b.$3.compareTo(a.$3);
    return bySimilarity != 0 ? bySimilarity : (a.$2 - a.$1).compareTo(b.$2 - b.$1);
  });
  final taken = List<bool>.filled(words.length, false);
  final chosen = <(int, int, double)>[];
  for (final candidate in candidates) {
    var free = true;
    for (var i = candidate.$1; i <= candidate.$2 && free; i++) {
      free = !taken[i];
    }
    if (!free) {
      continue;
    }
    for (var i = candidate.$1; i <= candidate.$2; i++) {
      taken[i] = true;
    }
    chosen.add(candidate);
  }
  chosen.sort((a, b) => a.$1.compareTo(b.$1));

  return [
    for (final (first, last, similarity) in chosen) OcrMatch(_spansFor(words.sublist(first, last + 1)), similarity),
  ];
}

/// The match to jump to: the closest one, and the earliest of equally close ones.
OcrMatch? bestOcrMatch(List<OcrMatch> matches) {
  OcrMatch? best;
  for (final match in matches) {
    if (best == null || match.similarity > best.similarity) {
      best = match;
    }
  }
  return best;
}

List<OcrMatchSpan> _spansFor(List<_Word> words) {
  final spans = <OcrMatchSpan>[];
  for (final word in words) {
    final last = spans.isEmpty ? null : spans.last;
    if (last != null && last.boxIndex == word.boxIndex) {
      spans[spans.length - 1] = OcrMatchSpan(word.boxIndex, last.start, word.end);
    } else {
      spans.add(OcrMatchSpan(word.boxIndex, word.start, word.end));
    }
  }
  return spans;
}

final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// pg_trgm's words: runs of letters and digits, everything else separates them.
Iterable<(int, int)> _wordRanges(String text) => _wordPattern.allMatches(text).map((m) => (m.start, m.end));

/// pg_trgm's trigrams of one word: lowercased, two spaces before and one after.
Set<String> _trigrams(String word) {
  if (word.isEmpty) {
    return const {};
  }
  final padded = '  ${word.toLowerCase()} '.runes.toList();
  return {for (var i = 0; i + 3 <= padded.length; i++) String.fromCharCodes(padded.sublist(i, i + 3))};
}

/// A token from [tokenizeForSearch], with where it starts in the original text.
class SearchToken {
  final String text;
  final int start;

  const SearchToken(this.text, this.start);
}

bool _isCjk(int c) =>
    (c >= 0x4e00 && c <= 0x9fff) ||
    (c >= 0xac00 && c <= 0xd7af) ||
    (c >= 0x3040 && c <= 0x309f) ||
    (c >= 0x30a0 && c <= 0x30ff) ||
    (c >= 0x3400 && c <= 0x4dbf);

/// Port of the server's `tokenizeForSearch` (server/src/utils/database.ts): split on
/// whitespace and control characters, and turn each CJK run into overlapping bigrams.
List<SearchToken> tokenizeForSearch(String text) {
  final tokens = <SearchToken>[];
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c <= 32) {
      i++;
      continue;
    }
    final start = i;
    if (_isCjk(c)) {
      while (i < text.length && _isCjk(text.codeUnitAt(i))) {
        i++;
      }
      if (i - start == 1) {
        tokens.add(SearchToken(text[start], start));
      } else {
        for (var k = start; k < i - 1; k++) {
          tokens.add(SearchToken(text.substring(k, k + 2), k));
        }
      }
    } else {
      while (i < text.length && text.codeUnitAt(i) > 32 && !_isCjk(text.codeUnitAt(i))) {
        i++;
      }
      tokens.add(SearchToken(text.substring(start, i), start));
    }
  }
  return tokens;
}

/// A stand-in for Postgres `unaccent` on Latin text, plus lowercasing.
String _fold(String word) {
  final buffer = StringBuffer();
  for (final rune in word.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_unaccent[char] ?? char);
  }
  return buffer.toString();
}

const _unaccent = <String, String>{
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', //
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ĉ': 'c', 'ċ': 'c', //
  'ď': 'd', 'đ': 'd', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', //
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g', //
  'ĥ': 'h', 'ħ': 'h', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i', 'ı': 'i', //
  'ĵ': 'j', 'ķ': 'k', //
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ŀ': 'l', 'ł': 'l', //
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ŏ': 'o', 'ő': 'o', //
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r', //
  'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ß': 'ss', //
  'ţ': 't', 'ť': 't', 'ŧ': 't', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u', //
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', //
  'ź': 'z', 'ż': 'z', 'ž': 'z', //
  'æ': 'ae', 'œ': 'oe', 'þ': 'th', 'ð': 'd', //
};
