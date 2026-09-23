import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/viewer_originals.dart';

class _StubCompleter extends ImageStreamCompleter {}

void main() {
  final originals = ViewerOriginals.instance;
  late int notifications;

  void count() => notifications++;

  setUp(() {
    originals.reset();
    notifications = 0;
    originals.addListener(count);
  });

  tearDown(() => originals.removeListener(count));

  group('ViewerOriginals.stateOf', () {
    test('stays at the preview until something asks for the original', () {
      expect(originals.stateOf('a', wantedElsewhere: false), ViewerOriginalState.preview);
      expect(originals.attemptOf('a'), 0);
      expect(originals.attemptOf(null), 0);
    });

    test('an original loaded by the setting or a stored copy is still reported', () {
      expect(originals.stateOf('a', wantedElsewhere: true), ViewerOriginalState.loading);
      originals.settle('a', loaded: true);
      expect(originals.stateOf('a', wantedElsewhere: true), ViewerOriginalState.original);
    });

    test('a request loads, then settles either way', () {
      originals.request('a');
      expect(originals.attemptOf('a'), 1);
      expect(originals.stateOf('a', wantedElsewhere: false), ViewerOriginalState.loading);

      originals.settle('a', loaded: false);
      expect(originals.stateOf('a', wantedElsewhere: false), ViewerOriginalState.failed);

      originals.request('a');
      expect(originals.attemptOf('a'), 2);
      expect(originals.stateOf('a', wantedElsewhere: false), ViewerOriginalState.loading);

      originals.settle('a', loaded: true);
      expect(originals.stateOf('a', wantedElsewhere: false), ViewerOriginalState.original);
    });

    test('one photo does not affect another', () {
      originals.request('a');
      originals.settle('a', loaded: true);
      expect(originals.stateOf('b', wantedElsewhere: false), ViewerOriginalState.preview);
    });

    test('settling the same outcome twice does not notify again', () {
      originals.settle('a', loaded: true);
      originals.settle('a', loaded: true);
      expect(notifications, 1);
    });
  });

  group('RemoteFullImageProvider.originalAttempt', () {
    RemoteFullImageProvider make({int originalAttempt = 0}) => RemoteFullImageProvider(
      assetId: 'a',
      thumbhash: 'h',
      assetType: AssetType.image,
      isAnimated: false,
      originalAttempt: originalAttempt,
    );

    test('is part of the cache key, so each request is a fresh load', () {
      final cache = ImageCache();
      var loads = 0;
      ImageStreamCompleter load() {
        loads++;
        return _StubCompleter();
      }

      expect(make(), make());
      expect(make().hashCode, make().hashCode);

      cache.putIfAbsent(make(), load);
      cache.putIfAbsent(make(), load);
      cache.putIfAbsent(make(originalAttempt: 1), load);
      cache.putIfAbsent(make(originalAttempt: 2), load);
      expect(loads, 3);
    });
  });
}
