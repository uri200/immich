// immich-sync fork: shows the text an OCR search matched, so it's clear why a photo came up.
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/providers/search/ocr_search_highlight.provider.dart';
import 'package:immich_mobile/utils/ocr_match.utils.dart';

const _maxSnippets = 5;

class OcrMatchDetails extends ConsumerWidget {
  final BaseAsset asset;

  const OcrMatchDetails({super.key, required this.asset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final highlight = watchOcrHighlight(ref, asset);
    if (highlight == null || highlight.matches.isEmpty) {
      return const SizedBox.shrink();
    }

    final textStyle = context.textTheme.bodyMedium;
    final matchStyle = textStyle?.copyWith(
      fontWeight: FontWeight.bold,
      backgroundColor: Colors.amber.withValues(alpha: 0.35),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            'Matched text',
            style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceSecondary),
          ),
          for (final match in highlight.matches.take(_maxSnippets))
            Text.rich(
              TextSpan(
                style: textStyle,
                children: ocrMatchSnippet(match, [
                  for (final box in highlight.boxes) box.text,
                ]).map((part) => TextSpan(text: part.text, style: part.isMatch ? matchStyle : null)).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

/// A piece of a snippet, and whether it's part of the matched words.
typedef OcrSnippetPart = ({String text, bool isMatch});

/// The full text of every box [match] touches, split into matched and unmatched parts.
List<OcrSnippetPart> ocrMatchSnippet(OcrMatch match, List<String> boxTexts) {
  final parts = <OcrSnippetPart>[];
  for (final span in match.spans) {
    if (span.boxIndex >= boxTexts.length) {
      continue;
    }
    final text = boxTexts[span.boxIndex];
    final start = span.start.clamp(0, text.length);
    final end = span.end.clamp(start, text.length);
    if (parts.isNotEmpty) {
      parts.add((text: ' ', isMatch: false));
    }
    if (start > 0) {
      parts.add((text: text.substring(0, start), isMatch: false));
    }
    parts.add((text: text.substring(start, end), isMatch: true));
    if (end < text.length) {
      parts.add((text: text.substring(end), isMatch: false));
    }
  }
  return parts;
}
