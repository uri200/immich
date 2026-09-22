/// immich-sync fork — which band a held file falls into (FORK.md §3.2, §3.6).
///
/// This is the predicate that decides what a removal is allowed to take, and it is SQL with no Dart twin on purpose:
/// one expression is what keeps the figure a screen quotes and the files a deletion takes the same set. So it is tested
/// against a real database rather than re-implemented here.
///
/// The case worth guarding is the one the rung alone gets wrong: an item whose original the camera roll holds is never
/// fetched in full by the mirror, so any full-size copy it does hold arrived by hand and is a spare — at every rung,
/// "keep full photos" included.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late OfflineFlagsRepository sut;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = await ctx.offlineFlags();
  });

  tearDown(() async {
    await ctx.dispose();
  });

  late String ownerId;
  late String photo;
  late String video;

  /// The assets the rows below are about.
  ///
  /// Real ones, because the band predicate reads what an item *is* from upstream's table now rather than from a copy
  /// on the `wanted` row — which is the point: a remembered answer is one that can be wrong, and the one about the
  /// camera roll was wrong routinely.
  setUp(() async {
    ownerId = (await ctx.newUser()).id;
    final image = await ctx.newRemoteAsset(ownerId: ownerId, type: AssetType.image);
    photo = image.id;
    video = (await ctx.newRemoteAsset(ownerId: ownerId, type: AssetType.video)).id;
  });

  /// Puts a copy of an asset in the camera roll, matched by checksum as upstream's merged view matches it.
  Future<void> inCameraRoll([String? assetId]) async {
    final row = await (ctx.db.select(ctx.db.remoteAssetEntity)
          ..where((asset) => asset.id.equals(assetId ?? photo)))
        .getSingle();
    await ctx.newLocalAsset(checksum: row.checksum);
  }

  /// And takes it away again, which is what upstream's Free Up Space does.
  Future<void> leftCameraRoll() async {
    await ctx.db.delete(ctx.db.localAssetEntity).go();
  }

  /// Makes [photo] a Live Photo, whose motion part is stored as a file of the photo itself (§3.2).
  Future<void> withMotion() async {
    final motion = await ctx.newRemoteAsset(ownerId: ownerId, type: AssetType.video, visibility: AssetVisibility.hidden);
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(photo))).write(
      RemoteAssetEntityCompanion(livePhotoVideoId: Value(motion.id)),
    );
  }

  Future<void> want(String id, {required OfflineQuality quality, bool onDemand = false}) => sut.set([
    OfflineFlagRow(
      id: id,
      quality: quality,
      createdAt: DateTime.utc(2026, 8, 20),
      touchedAt: DateTime.utc(2026, 8, 21),
      onDemand: onDemand,
    ),
  ]);

  Future<void> hold(String id, OfflineVariant variant, int size) => sut.markHeld([
    OfflineHeldRow(name: '$id-${variant.name}', assetId: id, variant: variant, token: 1, size: size),
  ]);

  Future<void> holdWholePhoto(String id) async {
    await hold(id, OfflineVariant.thumbnail, 10);
    await hold(id, OfflineVariant.preview, 90);
    await hold(id, OfflineVariant.original, 900);
  }

  group('a full-size copy of a photo the camera roll holds', () {
    setUp(() async {
      await want(photo, quality: OfflineQuality.fullWithVideos);
      await holdWholePhoto(photo);
    });

    test('is library while nothing says the phone has the original', () async {
      final storage = await sut.storage();

      expect(storage.keptOriginalBytes, 900);
      expect(storage.spareOriginalBytes, 0);
    });

    test('becomes a spare once it does, at the top rung', () async {
      await inCameraRoll();
      final storage = await sut.storage();

      // The mirror never fetches this file (§3.2), so no selection can be said to maintain it, whatever the rung says.
      expect(storage.spareOriginalBytes, 900);
      expect(storage.keptOriginalBytes, 0);
    });

    test('and its previews stay library, or a removal would strand the item off the grid', () async {
      await inCameraRoll();
      final storage = await sut.storage();

      expect(storage.libraryPreviewBytes, 100);
      expect(storage.sparePreviewBytes, 0);
    });

    test('so a removal of every spare takes the original and leaves the previews', () async {
      await inCameraRoll();

      final plan = await sut.reclaimPlan();
      expect(plan.bytes, 900);
      expect(plan.files, 1);
      expect(plan.losingOriginals, 1);
      expect(plan.losingPreviews, 0);
    });

    test('goes back to library when the camera-roll copy does not survive Free Up Space', () async {
      await inCameraRoll();
      await leftCameraRoll();
      final storage = await sut.storage();

      expect(storage.keptOriginalBytes, 900);
      expect(storage.spareOriginalBytes, 0);
    });

    test('survives a re-derivation, which knows nothing about the camera roll', () async {
      await inCameraRoll();
      // What applying a selection does: the row is rewritten. This used to be a live fault — the answer lived in a
      // column, so replacing the row reset it and filed the copy as library again — and is now unreachable, because
      // nothing about the camera roll is written down to be reset.
      await want(photo, quality: OfflineQuality.fullWithVideos);

      expect((await sut.storage()).spareOriginalBytes, 900);
    });
  });

  test("a video's playable file follows the same rule", () async {
    await want(video, quality: OfflineQuality.fullWithVideos);
    await hold(video, OfflineVariant.thumbnail, 10);
    await hold(video, OfflineVariant.preview, 90);
    await hold(video, OfflineVariant.video, 5000);

    expect((await sut.storage()).keptVideoBytes, 5000);

    await inCameraRoll(video);
    expect((await sut.storage()).spareVideoBytes, 5000);
  });

  test("a Live Photo's motion part follows it too, being a file of the photo", () async {
    await withMotion();
    await want(photo, quality: OfflineQuality.fullWithVideos);
    await hold(photo, OfflineVariant.video, 4000);

    expect((await sut.storage()).keptVideoBytes, 4000);

    await inCameraRoll();
    expect((await sut.storage()).spareVideoBytes, 4000);
  });

  test('the paged row asks the camera roll rather than remembering it', () async {
    await want(photo, quality: OfflineQuality.full);
    expect((await sut.page(limit: 10)).single.localCopy, isFalse);

    await inCameraRoll();
    expect((await sut.page(limit: 10)).single.localCopy, isTrue);
  });

  test('a hand-fetched row is a spare throughout, local copy or not', () async {
    await want(photo, quality: OfflineQuality.fullWithVideos, onDemand: true);
    await holdWholePhoto(photo);

    final storage = await sut.storage();
    expect(storage.spareOriginalBytes, 900);
    expect(storage.sparePreviewBytes, 100);
  });

  /// The distinction the sign-out dialog rests on. Emptying the store leaves the selection standing, so the next pass
  /// fetches it all back; abandoning the mirror has to take the decisions with the files or "delete downloads" simply
  /// downloads them again after the next sign-in.
  group('clearing', () {
    setUp(() async {
      await want(photo, quality: OfflineQuality.full);
      await holdWholePhoto(photo);
      await sut.addErrands([photo]);
      // Past the attempt limit, so it counts as abandoned and the assertions below are about something.
      for (var attempt = 0; attempt < 3; attempt++) {
        await sut.recordFailure('some-file');
      }
    });

    test('the files alone leaves what was asked for', () async {
      await sut.clearHeld();

      expect((await sut.storage()).bytes, 0);
      expect((await sut.page(limit: 10)).single.id, photo);
      expect(await sut.errands(), {photo});
      expect(await sut.abandonedCount(), 1);
    });

    test('everything leaves nothing to re-derive from', () async {
      await sut.clearAll();

      expect((await sut.storage()).bytes, 0);
      expect(await sut.page(limit: 10), isEmpty);
      expect(await sut.errands(), isEmpty);
      expect(await sut.abandonedCount(), 0);
    });
  });

  // --------------------------------------------------------------------------- Deriving

  /// `derive` is `OfflinePolicy.resolve` expressed as SQL, and the two must not be allowed to drift apart: one decides
  /// what the mirror fetches, the other is what every screen reads. So rather than trust that they look alike, this
  /// builds a library whose assets sit in every combination of a library rung, an included album and an excluded one,
  /// and checks the rows the statement wrote against what the Dart says for each of them.
  group('the derive agrees with the policy it implements', () {
    late MediumRepositoryContext ctx;
    late OfflineFlagsRepository flags;
    late String ownerId;

    setUp(() async {
      ctx = MediumRepositoryContext();
      flags = await ctx.offlineFlags();
      ownerId = (await ctx.newUser()).id;
    });

    tearDown(() async {
      await ctx.dispose();
    });

    test('over every combination of library rung, included album and exclusion', () async {
      final included = await ctx.newRemoteAlbum(ownerId: ownerId);
      final alsoIncluded = await ctx.newRemoteAlbum(ownerId: ownerId);
      final excluded = await ctx.newRemoteAlbum(ownerId: ownerId);

      // Every subset of the three albums, so an asset exists for "in none", "in the excluded one only", "in an
      // included one and the excluded one", and so on.
      final memberships = <String, List<String>>{};
      for (var mask = 0; mask < 8; mask++) {
        final asset = await ctx.newRemoteAsset(ownerId: ownerId);
        final albums = [
          if (mask & 1 != 0) included.id,
          if (mask & 2 != 0) alsoIncluded.id,
          if (mask & 4 != 0) excluded.id,
        ];
        for (final album in albums) {
          await ctx.newRemoteAlbumAsset(albumId: album, assetId: asset.id);
        }
        memberships[asset.id] = albums;
      }

      for (final library in [null, OfflineQuality.preview, OfflineQuality.full, OfflineQuality.fullWithVideos]) {
        for (final rung in [OfflineQuality.preview, OfflineQuality.full, OfflineQuality.fullWithVideos]) {
          final policy = OfflinePolicy(
            library: library,
            albums: {included.id: rung, alsoIncluded.id: OfflineQuality.preview},
            excluded: {excluded.id},
          );

          await flags.derive(policy, DateTime.now());
          final rows = {
            for (final want in await flags.page(limit: 100)) want.id: want.quality,
          };

          for (final entry in memberships.entries) {
            expect(
              rows[entry.key],
              policy.resolve(entry.value),
              reason: 'library=$library rung=$rung albums=${entry.value}',
            );
          }
        }
      }
    });

    test('a hand-fetched row survives a selection that covers nothing', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.set([
        OfflineFlagRow(
          id: asset.id,
          quality: OfflineQuality.fullWithVideos,
          createdAt: DateTime.now(),
          touchedAt: DateTime.now(),
          onDemand: true,
        ),
      ]);

      await flags.derive(OfflinePolicy.empty, DateTime.now());

      // Nothing on the settings screen ever asked for it, so no change to the settings may take it away.
      expect((await flags.page(limit: 10)).map((want) => want.id), contains(asset.id));
    });

    test('an unchanged decision keeps the stamp its own change gave it', () async {
      // `touched_at` orders the download queue, so a walk that re-stamps rows nobody changed re-orders the whole
      // backlog behind work that did not move.
      await ctx.newRemoteAsset(ownerId: ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.full);

      await flags.derive(policy, DateTime.fromMillisecondsSinceEpoch(1000000000000));
      final first = (await flags.page(limit: 10)).single.touchedAt;

      await flags.derive(policy, DateTime.fromMillisecondsSinceEpoch(2000000000000));

      expect((await flags.page(limit: 10)).single.touchedAt, first);
    });

    test('a rung that moves takes a fresh stamp', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.derive(const OfflinePolicy(library: OfflineQuality.preview), DateTime.fromMillisecondsSinceEpoch(1000000000000));
      final first = (await flags.page(limit: 10)).single.touchedAt;

      await flags.derive(const OfflinePolicy(library: OfflineQuality.full), DateTime.fromMillisecondsSinceEpoch(2000000000000));
      final row = (await flags.page(limit: 10)).single;

      expect(row.quality, OfflineQuality.full);
      expect(row.touchedAt, greaterThan(first));
      expect(asset.id, row.id);
    });
  });
}
