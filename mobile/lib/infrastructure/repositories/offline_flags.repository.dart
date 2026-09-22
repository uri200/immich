/// immich-sync fork — which photos are wanted on this device (`wanted`), and which of their files are here (`held`).
///
/// The rows live in the fork's own file, attached to upstream's connection as the `offline` schema
/// (`offline_paths.dart` says why it is attached rather than merged). One connection, so a statement here can join what
/// the user selected against the assets, the albums and the camera roll; a separate file, so upstream's migration
/// ladder, its all-pairs migration test and `Drift.reset()` are none of the fork's business.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';

/// Originals and playable files — the expensive, optional part of an asset, and what a preview may not be taken from
/// under.
final String _fullSizeVariants = '${OfflineVariant.original.index},${OfflineVariant.video.index}';

/// Whether the camera roll holds a usable original of the asset at alias [a] — `OfflineAsset.localCopyUsable` in SQL.
///
/// A live join, and that matters more than it looks. This used to be a `local_copy` column on `wanted`, refreshed by
/// whichever pass happened to walk the row, because the two facts lived in two databases and SQL could not cross
/// between them. Every way of missing that refresh was a way for the mirror to fetch a full-size copy of a photo the
/// phone already held and then draw it as though a setting maintained it — and hashing an existing camera-roll row is
/// the most ordinary write there is, so it was missed routinely. Asked rather than remembered, it cannot be stale.
///
/// `EXISTS`, not a join: a checksum can match several camera-roll rows, and one extra row here would multiply every
/// `SUM` the storage figures are built from.
///
/// An **edited** asset is excluded: the server's rendition is the picture now, and the local file is the pre-edit one.
String _localCopyUsable(String a) =>
    '($a.is_edited = 0 '
    ' AND EXISTS (SELECT 1 FROM main.local_asset_entity dev WHERE dev.checksum = $a.checksum))';

/// When a held file is maintained by nothing, over the aliases [h] (held), [w] (wanted) and [a] (the upstream asset).
///
/// The playable file belongs to a video asset *or* to the still of a Live Photo, whose motion part is stored under the
/// photo's own id (§3.2). Without that second case the integrity pass reclaims a Live Photo's video the moment it
/// arrives, and "free up space" quotes it as unwanted.
///
/// **A full-size file is a spare whenever the camera roll holds the original**, whatever rung the row records. The
/// mirror never fetches one for those items (§3.2), so no selection can be said to maintain it: the only way it gets
/// here is *Save offline*, which asks for a spare and says so. Reading the rung alone would file that copy as library —
/// promising a maintenance it does not get, and putting it out of reach of the removal that should take it, because
/// "kept by your settings" is locked until every spare above it is going.
///
/// An asset upstream no longer has is spare in its entirety, for the same reason: nothing can be maintaining files of
/// something the server cannot serve. The pass that forgets those decisions gets there a moment later anyway; this is
/// what the answer is in between. A *trashed* asset is not that case — the row is still there, the trash is undoable,
/// and its copies stay maintained.
String _unselectedOver(String h, String w, String a) =>
    '$w.asset_id IS NULL '
    'OR $a.id IS NULL '
    'OR $w.on_demand = 1 '
    'OR ($h.variant IN ($_fullSizeVariants) AND ${_localCopyUsable(a)}) '
    'OR ($h.variant = ${OfflineVariant.original.index} '
    '    AND NOT ($a.type = ${AssetType.image.index} AND $w.quality >= ${OfflineQuality.full.code})) '
    'OR ($h.variant = ${OfflineVariant.video.index} '
    '    AND NOT (($a.type <> ${AssetType.image.index} OR $a.live_photo_video_id IS NOT NULL) '
    '             AND $w.quality >= ${OfflineQuality.fullWithVideos.code}))';

/// The SQL each reclaim kind stands for.
extension _ReclaimSql on OfflineReclaimKind {
  /// The variants each covers, as SQL.
  String get variants => switch (this) {
    OfflineReclaimKind.videos => '${OfflineVariant.video.index}',
    OfflineReclaimKind.originals => '${OfflineVariant.original.index}',
    OfflineReclaimKind.previews => '${OfflineVariant.thumbnail.index},${OfflineVariant.preview.index}',
  };
}

/// One reclaim as a `WHERE` clause, so the figure a screen quotes and the files a deletion takes are the same set by
/// construction.
extension _ReclaimWhere on OfflineReclaim {
  /// The rows in one band, over the aliases [h] and [w].
  static String band(OfflineReclaimBand band, String h, String w, String a) => switch (band) {
    OfflineReclaimBand.spares => '(${_unselectedOver(h, w, a)})',
    OfflineReclaimBand.maintained => 'NOT (${_unselectedOver(h, w, a)})',
  };

  /// Every cell of the choice, over the aliases [h] and [w]: one band-and-kind pair per `OR`.
  String cellsOver(String h, String w, String a) {
    if (cells.isEmpty) {
      return '0';
    }
    return cells.map((cell) => '(${band(cell.$1, h, w, a)} AND $h.variant IN (${cell.$2.variants}))').join(' OR ');
  }

  /// The whole predicate: the cells that were ticked, minus the previews that would be left holding nothing up.
  String get sql {
    if (cells.isEmpty) {
      return '0';
    }
    final survivor =
        'SELECT 1 FROM held g '
        'LEFT JOIN wanted wg ON wg.asset_id = g.asset_id AND wg.quality > 0 '
        'LEFT JOIN main.remote_asset_entity ag ON ag.id = g.asset_id '
        'WHERE g.asset_id = h.asset_id AND g.variant IN ($_fullSizeVariants) '
        'AND NOT (${cellsOver('g', 'wg', 'ag')})';
    return '(${cellsOver('h', 'w', 'a')}) '
        'AND (h.variant IN ($_fullSizeVariants) OR NOT EXISTS ($survivor))';
  }
}

class OfflineFlagsRepository {
  OfflineFlagsRepository._(this._db);

  final Drift _db;

  static OfflineFlagsRepository? _opened;

  /// Available once [ensureInitialized] has run, which bootstrap does before any provider is read. A getter rather than
  /// a nullable field so a mistake in that ordering fails loudly instead of silently deciding nothing is wanted.
  static OfflineFlagsRepository get instance {
    final opened = _opened;
    if (opened == null) {
      throw StateError('OfflineFlagsRepository.ensureInitialized() must run during bootstrap');
    }
    return opened;
  }

  /// Ensures the schema and becomes [instance], following `SettingsRepository.ensureInitialized`.
  static Future<OfflineFlagsRepository> ensureInitialized(Drift db) async {
    final existing = _opened;
    if (existing != null) {
      return existing;
    }
    final instance = OfflineFlagsRepository._(db);
    await instance.ensureSchema();
    return _opened = instance;
  }

  /// The same repository over a connection a test built for itself, without becoming [instance].
  ///
  /// The predicate deciding which held files a removal may take is SQL with no Dart twin, which is the point: one
  /// expression keeps the figure a screen quotes and the files a deletion takes the same set. So the tests run it
  /// against a real database, and now against one that also holds the assets it joins.
  @visibleForTesting
  static Future<OfflineFlagsRepository> forConnection(Drift db) async {
    final instance = OfflineFlagsRepository._(db);
    await instance.ensureSchema();
    return instance;
  }

  /// The tables this file reads, which are also the names it must not share with upstream.
  static const _tables = ['wanted', 'held', 'failures', 'meta'];

  /// Creates whatever is missing, on every launch.
  ///
  /// Deliberately **not** a drift migration and not versioned. These tables are derived — `wanted` from the selection
  /// and the albums, `held` from what is on disk — so there is no data to carry across a shape change, only a shape to
  /// ensure, and idempotent DDL says that in one step. It also keeps the fork out of upstream's `schemaVersion`, whose
  /// single number line cannot be safely shared with an upstream we do not control: whichever side renumbers after
  /// shipping leaves installed databases stamped with a version that now means something else.
  @visibleForTesting
  Future<void> ensureSchema() async {
    await _guardNames();
    await _db.transaction(() async {
      // Only the DDL names the schema, and it must: a CREATE with no schema lands in `main`, which is the one place
      // these tables may not be. Everything after this point says `wanted` and `held` plainly, because SQLite resolves
      // an unqualified name against `main` before the attached databases and [_guardNames] has just established that
      // upstream has neither.
      await _exec('''
        CREATE TABLE IF NOT EXISTS $kOfflineSchema.wanted (
          asset_id   TEXT PRIMARY KEY,
          quality    INTEGER NOT NULL,
          -- Capture date, and the only thing here that is also on the asset row. It stays, because it is the second
          -- key of `idx_wanted_queue` and the queue pages by it: read from upstream instead, every page would sort
          -- the whole selection instead of walking an index.
          created_at INTEGER NOT NULL,
          on_demand  INTEGER NOT NULL DEFAULT 0,
          touched_at INTEGER NOT NULL DEFAULT 0,
          -- *Save offline*, outstanding. A column and not a table of its own, because every mark belongs to a row that
          -- is already here and two places to keep in step is one too many. It answers a different question from
          -- `on_demand`, which is why both exist: `on_demand` says no selection maintains these copies, and is false
          -- whenever one does — which is exactly when the mark still has to jump the queue.
          pinned     INTEGER NOT NULL DEFAULT 0
        )
      ''');
      // Columns an older build wrote that nothing reads any longer: what kind of asset it is, whether it is a Live
      // Photo, and whether the camera roll holds it. All three are questions for upstream's tables, which are now on
      // this connection, and the last of them is why this fork kept fetching full-size copies of photos already on the
      // phone — a remembered answer that any missed refresh left wrong. Dropped rather than left in place, so nothing
      // can start reading them again by accident.
      final columns = {
        for (final column in await _all('PRAGMA $kOfflineSchema.table_info(wanted)')) column.data['name'] as String,
      };
      for (final stale in const ['is_image', 'has_motion', 'local_copy']) {
        if (columns.contains(stale)) {
          await _exec('ALTER TABLE $kOfflineSchema.wanted DROP COLUMN $stale');
        }
      }
      if (!columns.contains('pinned') && columns.isNotEmpty) {
        await _exec('ALTER TABLE $kOfflineSchema.wanted ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
      }
      // The table this column replaced, and whatever it was still holding. Carried over rather than dropped on the
      // floor: a row there is a fetch the user asked for and is waiting on.
      final tables = {
        for (final row in await _all("SELECT name FROM $kOfflineSchema.sqlite_master WHERE type = 'table'"))
          row.data['name'] as String,
      };
      if (tables.contains('errands')) {
        await _exec('UPDATE $kOfflineSchema.wanted SET pinned = 1 WHERE asset_id IN (SELECT asset_id FROM errands)');
        await _exec('DROP TABLE $kOfflineSchema.errands');
      }
      // The order the reconciler *pages* in: most recently asked for first, then newest photo. The rank that decides
      // what is fetched first is applied in Dart (FORK.md §3.3), since it depends on the variants a row implies. The
      // tie-break column lets paging be a cursor rather than an OFFSET.
      await _exec(
        'CREATE INDEX IF NOT EXISTS $kOfflineSchema.idx_wanted_queue '
        'ON wanted (touched_at DESC, created_at DESC, asset_id DESC)',
      );
      await _exec('''
        CREATE TABLE IF NOT EXISTS $kOfflineSchema.held (
          name     TEXT PRIMARY KEY,
          asset_id TEXT NOT NULL,
          variant  INTEGER NOT NULL,
          token    INTEGER NOT NULL,
          size     INTEGER NOT NULL
        )
      ''');
      await _exec('CREATE INDEX IF NOT EXISTS $kOfflineSchema.idx_held_asset ON held (asset_id)');
      await _exec('CREATE TABLE IF NOT EXISTS $kOfflineSchema.meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      // Files the server will not give us — a photo deleted mid-pass, or one it cannot generate a preview for.
      // Attempted a few times, then left alone rather than retried on every pass forever.
      await _exec('''
        CREATE TABLE IF NOT EXISTS $kOfflineSchema.failures (
          name     TEXT PRIMARY KEY,
          attempts INTEGER NOT NULL DEFAULT 1
        )
      ''');
    });
  }

  /// Refuses to run if upstream has grown a table of the same name as one of ours.
  ///
  /// Unqualified names in this file resolve to the attached schema only because `main` has nothing by those names. That
  /// is true today and cheap to keep true, but if it ever stopped being true every statement below would silently start
  /// reading upstream's table instead. One query a launch turns that into a crash on the first run after the rebase
  /// that caused it, which is the only time anybody could act on it.
  Future<void> _guardNames() async {
    final clash = await _all(
      "SELECT name FROM main.sqlite_master WHERE type = 'table' AND name IN "
      "(${List.filled(_tables.length, '?').join(',')})",
      _tables,
    );
    if (clash.isNotEmpty) {
      throw StateError(
        'Upstream now has a table named ${clash.map((row) => row.data['name']).join(', ')}, which would shadow the '
        "fork's own. Qualify every statement in offline_flags.repository.dart, or rename the fork's table.",
      );
    }
  }

  // --------------------------------------------------------------------------- Running hand-written SQL
  //
  // The fork's statements are written out rather than built by drift, because the ones that matter — the reclaim
  // bands, the storage breakdown — are single expressions shared between a figure on screen and the files a deletion
  // takes, and splitting either into a query builder is how the two stop agreeing. These wrappers are the whole of
  // what drift needs that `sqlite_async` did not.

  /// Drift wants typed variables; hand-written SQL arrives with plain values.
  static List<Variable> _vars(Iterable<Object?> args) => [
    for (final arg in args)
      switch (arg) {
        null => const Variable<String>(null),
        final int value => Variable<int>(value),
        final double value => Variable<double>(value),
        final bool value => Variable<bool>(value),
        final String value => Variable<String>(value),
        _ => throw ArgumentError('Unsupported SQL argument: $arg'),
      },
  ];

  Future<List<QueryRow>> _all(String sql, [List<Object?> args = const []]) =>
      _db.customSelect(sql, variables: _vars(args)).get();

  Future<QueryRow> _one(String sql, [List<Object?> args = const []]) =>
      _db.customSelect(sql, variables: _vars(args)).getSingle();

  Future<QueryRow?> _oneOrNull(String sql, [List<Object?> args = const []]) =>
      _db.customSelect(sql, variables: _vars(args)).getSingleOrNull();

  Future<void> _exec(String sql, [List<Object?> args = const []]) => _db.customStatement(sql, args);

  /// One statement per row, in one transaction — what `executeBatch` did, in the terms drift has.
  Future<void> _execEach(String sql, List<List<Object?>> rows) async {
    if (rows.isEmpty) {
      return;
    }
    await _db.transaction(() async {
      for (final row in rows) {
        await _db.customStatement(sql, row);
      }
    });
  }

  /// Bumped on every write, so a caller can notice that something it derived from these rows is out of date.
  int revision = 0;

  // --------------------------------------------------------------------------- Reading

  /// Assets wanted offline: most recently asked for first, newest photo first within one change.
  Future<List<OfflineWant>> page({OfflineWantCursor? after, required int limit}) async {
    final columns =
        'SELECT w.asset_id AS asset_id, w.quality AS quality, w.created_at AS created_at, '
        'w.touched_at AS touched_at, ${_localCopyUsable('a')} AS local_copy '
        'FROM wanted w JOIN main.remote_asset_entity a ON a.id = w.asset_id '
        'WHERE w.quality > 0';
    const order = 'ORDER BY w.touched_at DESC, w.created_at DESC, w.asset_id DESC LIMIT ?';

    final rows = after == null
        ? await _all('$columns $order', [limit])
        : await _all(
            '$columns AND (w.touched_at < ? OR (w.touched_at = ? '
            'AND (w.created_at < ? OR (w.created_at = ? AND w.asset_id < ?)))) $order',
            [after.touchedAt, after.touchedAt, after.createdAt, after.createdAt, after.id, limit],
          );

    return [
      for (final row in rows)
        OfflineWant(
          id: row.data['asset_id'] as String,
          quality: OfflineQuality.fromCode(row.data['quality'] as int),
          createdAt: row.data['created_at'] as int,
          touchedAt: row.data['touched_at'] as int,
          localCopy: (row.data['local_copy'] as int) == 1,
        ),
    ];
  }

  /// Whether any selected item is missing the thumbnail or preview every rung asks for.
  ///
  /// One `EXISTS` inside SQLite, so a pass can tell in a millisecond whether it has to look past its own budget for
  /// cheap files (`offline_sync.service.dart`). It cannot see a *superseded* copy — the token lives in `held` but the
  /// comparison needs upstream's thumbhash — so a stale preview reads as present here and is picked up by a later pass
  /// instead.
  Future<bool> hasMissingBase() async {
    final base = '${OfflineVariant.thumbnail.index},${OfflineVariant.preview.index}';
    final row = await _one(
      'SELECT EXISTS ('
      'SELECT 1 FROM wanted w WHERE w.quality > 0 AND '
      '(SELECT COUNT(*) FROM held h WHERE h.asset_id = w.asset_id AND h.variant IN ($base)) < 2'
      ') AS missing',
    );
    return (row.data['missing'] as int) == 1;
  }

  /// Every asset that is selected *or* has a file on disk: deselecting never deletes, so an asset can have every file
  /// it needs and no selection.
  Future<List<OfflineIndexRow>> loadIndex() async {
    final thumbnails = '${OfflineVariant.preview.index}';
    final original = '${OfflineVariant.original.index}';
    final video = '${OfflineVariant.video.index}';
    final rows = await _all('''
      SELECT k.asset_id AS asset_id,
             COALESCE(w.quality, 0) AS quality,
             -- The asset says what it is; the fallback is for files held for an asset upstream has since lost, where
             -- a stored playable file is the only evidence left of which kind it was.
             COALESCE(a.type = ${AssetType.image.index},
                      CASE WHEN SUM(h.variant = $video) > 0 THEN 0 ELSE 1 END) AS is_image,
             COALESCE(a.live_photo_video_id IS NOT NULL, 0) AS has_motion,
             COALESCE(SUM(DISTINCT 1 << h.variant), 0) AS held,
             COALESCE(MAX(CASE WHEN h.variant <= $thumbnails THEN h.token END), 0) AS token,
             COALESCE(MAX(CASE WHEN h.variant = $original THEN h.token END), 0) AS original_token,
             COALESCE(MAX(CASE WHEN h.variant = $video THEN h.token END), 0) AS video_token,
             COALESCE(${_localCopyUsable('a')}, 0) AS local_copy,
             COALESCE(w.on_demand, 0) AS on_demand,
             COALESCE(w.pinned, 0) AS errand
      FROM (SELECT asset_id FROM wanted WHERE quality > 0 UNION SELECT asset_id FROM held) k
      LEFT JOIN wanted w ON w.asset_id = k.asset_id AND w.quality > 0
      LEFT JOIN held h ON h.asset_id = k.asset_id
      LEFT JOIN main.remote_asset_entity a ON a.id = k.asset_id
      GROUP BY k.asset_id
    ''');

    return [
      for (final row in rows)
        OfflineIndexRow(
          assetId: row.data['asset_id'] as String,
          quality: OfflineQuality.fromCode(row.data['quality'] as int),
          isImage: (row.data['is_image'] as int) == 1,
          hasMotion: (row.data['has_motion'] as int) == 1,
          held: (row.data['held'] as int?) ?? 0,
          token: (row.data['token'] as int?) ?? 0,
          originalToken: (row.data['original_token'] as int?) ?? 0,
          videoToken: (row.data['video_token'] as int?) ?? 0,
          localCopy: ((row.data['local_copy'] as int?) ?? 0) == 1,
          errand: ((row.data['errand'] as int?) ?? 0) == 1,
          onDemand: ((row.data['on_demand'] as int?) ?? 0) == 1,
        ),
    ];
  }

  /// What the store occupies on disk — every file, including ones no selection counts towards progress.
  ///
  /// The *count* is not asked for any more: how many files count towards progress is a question about the entries, and
  /// [OfflineIndex] answers it from them rather than from a second figure that had to be kept in step.
  Future<int> heldBytes() async => (await _one('SELECT COALESCE(SUM(size), 0) AS b FROM held')).data['b'] as int;

  /// When a held file is no longer selected, over the aliases [_reclaimFrom] introduces.
  static final String _unselected = _unselectedOver('h', 'w', 'a');

  /// Everything the storage overview shows, in one query — figures that have to add up must not come from six different
  /// moments — and aggregated in SQL, so a six-figure store never becomes a six-figure Dart collection to be counted.
  Future<OfflineStorage> storage() async {
    final base = OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit;
    final original = OfflineVariant.original.index;
    final video = OfflineVariant.video.index;

    final row = await _one('''
      WITH file AS (
        SELECT h.asset_id AS asset_id,
               h.variant   AS variant,
               h.size      AS size,
               CASE WHEN ($_unselected) THEN 0 ELSE 1 END AS kept
        $_reclaimFrom
      ),
      asset AS (
        SELECT h.asset_id AS asset_id,
               COALESCE(SUM(DISTINCT 1 << h.variant), 0) AS mask
        FROM held h
        GROUP BY h.asset_id
      )
      SELECT
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $original THEN f.size END), 0) AS kept_original,
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $video THEN f.size END), 0) AS kept_video,
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant NOT IN ($_fullSizeVariants) THEN f.size END), 0)
          AS kept_preview,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $original THEN f.size END), 0) AS cached_original,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $video THEN f.size END), 0) AS cached_video,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant NOT IN ($_fullSizeVariants) THEN f.size END), 0)
          AS cached_preview,
        -- The thumbnail and the preview are what makes anything open off-grid,
        -- videos included: below the top rung a video's still is all that was
        -- ever asked for, so it counts as available rather than as nothing.
        COUNT(DISTINCT CASE WHEN (a.mask & $base) = $base THEN a.asset_id END) AS available_assets
      FROM file f JOIN asset a ON a.asset_id = f.asset_id
    ''');

    return OfflineStorage(
      keptOriginalBytes: row.data['kept_original'] as int,
      keptVideoBytes: row.data['kept_video'] as int,
      keptPreviewBytes: row.data['kept_preview'] as int,
      cachedOriginalBytes: row.data['cached_original'] as int,
      cachedVideoBytes: row.data['cached_video'] as int,
      cachedPreviewBytes: row.data['cached_preview'] as int,
      availableAssets: row.data['available_assets'] as int,
    );
  }

  /// What "free up space" would do, split by what the user loses: an item that loses its original still opens off-grid,
  /// one that is removed does not.
  Future<OfflineReclaimPlan> reclaimPlan({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final columns =
        '''
        COUNT(*) AS files,
        COALESCE(SUM(h.size), 0) AS bytes,
        COUNT(DISTINCT h.asset_id) AS assets,
        COUNT(DISTINCT CASE WHEN h.variant NOT IN ($_fullSizeVariants) THEN h.asset_id END) AS losing_previews,
        COUNT(DISTINCT CASE WHEN h.variant = ${OfflineVariant.original.index} THEN h.asset_id END)
          AS losing_originals,
        COUNT(DISTINCT CASE WHEN h.variant = ${OfflineVariant.video.index} THEN h.asset_id END) AS losing_videos,
        -- The hand-saved share, by media type: what a removal takes that nothing
        -- on the settings screen ever listed.
        COUNT(DISTINCT CASE WHEN w.on_demand = 1 AND a.type <> ${AssetType.image.index} THEN h.asset_id END) AS hand_videos,
        COALESCE(SUM(CASE WHEN w.on_demand = 1 AND a.type <> ${AssetType.image.index} THEN h.size END), 0) AS hand_video_bytes,
        COUNT(DISTINCT CASE WHEN w.on_demand = 1 AND a.type = ${AssetType.image.index} THEN h.asset_id END) AS hand_photos,
        COALESCE(SUM(CASE WHEN w.on_demand = 1 AND a.type = ${AssetType.image.index} THEN h.size END), 0) AS hand_photo_bytes''';
    final where = what.sql;

    if (assetIds == null) {
      return _planOf(await _one('SELECT $columns $_reclaimFrom WHERE $where'));
    }

    // Chunks partition the ids, so the per-asset `DISTINCT` counts add up.
    var plan = OfflineReclaimPlan.empty;
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      plan += _planOf(
        await _one('SELECT $columns $_reclaimFrom WHERE $where AND h.asset_id IN ($placeholders)', chunk),
      );
    }
    return plan;
  }

  /// Held files, what selects them, and the asset they belong to.
  ///
  /// The asset join is **not** filtered to what can be stored: a trashed asset still has a row, the trash is undoable,
  /// and its copies must stay maintained until the user says otherwise.
  static const _reclaimFrom =
      'FROM held h '
      'LEFT JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0 '
      'LEFT JOIN main.remote_asset_entity a ON a.id = h.asset_id';

  // Every column is `COALESCE`d or a `COUNT`, so none can come back null.
  OfflineReclaimPlan _planOf(QueryRow row) => OfflineReclaimPlan(
    files: row.data['files']! as int,
    bytes: row.data['bytes']! as int,
    assets: row.data['assets']! as int,
    losingPreviews: row.data['losing_previews']! as int,
    losingOriginals: row.data['losing_originals']! as int,
    losingVideos: row.data['losing_videos']! as int,
    handVideos: row.data['hand_videos']! as int,
    handVideoBytes: row.data['hand_video_bytes']! as int,
    handPhotos: row.data['hand_photos']! as int,
    handPhotoBytes: row.data['hand_photo_bytes']! as int,
  );

  /// What each cell of the choice actually contributes, which is not the same as what it holds: a previews cell gives
  /// up only the previews of items whose full-size copies are going too, and that depends on the rest of the choice.
  Future<Map<OfflineReclaimCell, int>> reclaimBytesByCell(OfflineReclaim what) async {
    if (what.isEmpty) {
      return const {};
    }

    // Positions, not names: the enums are what the screen reads back, and a
    // string here would be a second spelling of them to keep in step.
    final bandCase =
        'CASE WHEN ${_ReclaimWhere.band(OfflineReclaimBand.spares, 'h', 'w', 'a')} '
        'THEN ${OfflineReclaimBand.spares.index} ELSE ${OfflineReclaimBand.maintained.index} END';
    final kindCase =
        'CASE '
        'WHEN h.variant = ${OfflineVariant.video.index} THEN ${OfflineReclaimKind.videos.index} '
        'WHEN h.variant = ${OfflineVariant.original.index} THEN ${OfflineReclaimKind.originals.index} '
        'ELSE ${OfflineReclaimKind.previews.index} END';

    final rows = await _all(
      'SELECT $bandCase AS band, $kindCase AS kind, COALESCE(SUM(h.size), 0) AS bytes '
      '$_reclaimFrom WHERE ${what.sql} GROUP BY band, kind',
    );
    return {
      for (final row in rows)
        (OfflineReclaimBand.values[row.data['band'] as int], OfflineReclaimKind.values[row.data['kind'] as int]):
            row.data['bytes'] as int,
    };
  }

  /// Reclaimable bytes per asset, for the rows that report what their own change left behind.
  Future<Map<String, int>> reclaimableBytesByAsset() async {
    final rows = await _all(
      'SELECT h.asset_id AS asset_id, SUM(h.size) AS bytes '
      '$_reclaimFrom '
      'WHERE $_unselected GROUP BY h.asset_id',
    );
    return {for (final row in rows) row.data['asset_id'] as String: row.data['bytes'] as int};
  }

  /// The reclaimable files among [assetIds]. Unpaged: bounded by the album.
  Future<List<OfflineHeldRow>> reclaimableFilesFor(
    Iterable<String> assetIds, {
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final result = <OfflineHeldRow>[];
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _all(
        'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
        '$_reclaimFrom '
        'WHERE ${what.sql} AND h.asset_id IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        result.add(
          OfflineHeldRow(
            name: row.data['name'] as String,
            assetId: row.data['asset_id'] as String,
            variant: OfflineVariant.values[row.data['variant'] as int],
            token: row.data['token'] as int,
            size: row.data['size'] as int,
          ),
        );
      }
    }
    return result;
  }

  /// Every held file, in pages — what the integrity pass is allowed to keep.
  Future<List<OfflineHeldRow>> heldPage({required int limit, String? afterName}) async {
    final rows = await _all(
      'SELECT name, asset_id, variant, token, size FROM held WHERE name > ? ORDER BY name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [
      for (final row in rows)
        OfflineHeldRow(
          name: row.data['name'] as String,
          assetId: row.data['asset_id'] as String,
          variant: OfflineVariant.values[row.data['variant'] as int],
          token: row.data['token'] as int,
          size: row.data['size'] as int,
        ),
    ];
  }

  /// Those files, in pages, for the reclaim itself.
  Future<List<OfflineHeldRow>> reclaimableFiles({
    required int limit,
    String? afterName,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final rows = await _all(
      'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
      '$_reclaimFrom '
      'WHERE ${what.sql} AND h.name > ? ORDER BY h.name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [
      for (final row in rows)
        OfflineHeldRow(
          name: row.data['name'] as String,
          assetId: row.data['asset_id'] as String,
          variant: OfflineVariant.values[row.data['variant'] as int],
          token: row.data['token'] as int,
          size: row.data['size'] as int,
        ),
    ];
  }

  /// Drops on-demand rows whose files have all gone, so a fetched item stops counting as wanted once "free up space"
  /// has taken it back.
  Future<void> dropFetchedWithoutFiles() async {
    await _exec(
      'DELETE FROM wanted WHERE on_demand = 1 '
      'AND asset_id NOT IN (SELECT DISTINCT asset_id FROM held)',
    );
    revision++;
  }

  /// Forgets selection-derived rows the current selection no longer covers.
  Future<void> dropUnselected(Iterable<String> assetIds) async {
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('DELETE FROM wanted WHERE on_demand = 0 AND asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Forgets decisions outright, for assets upstream no longer has at all.
  Future<void> forget(Iterable<String> assetIds) async {
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('DELETE FROM wanted WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Assets asked for by hand and not yet complete, which the queue puts before all standing work (FORK.md §3.3).
  ///
  /// Read whole rather than paged or joined: it holds what the user tapped and nothing else, and a pass needs the set
  /// before it can rank anything.
  Future<Set<String>> errands() async {
    final rows = await _all('SELECT asset_id FROM wanted WHERE pinned = 1');
    return {for (final row in rows) row.data['asset_id'] as String};
  }

  Future<void> addErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    await _execEach('UPDATE wanted SET pinned = 1 WHERE asset_id = ?', [
      for (final id in ids) [id],
    ]);
    revision++;
  }

  /// Drops the mark, for an errand that has arrived or been taken back. Not a decision about the files: what a selection
  /// maintains is untouched, and the copies stay on disk either way.
  Future<void> dropErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    for (final chunk in _chunked(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('UPDATE wanted SET pinned = 0 WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  // --------------------------------------------------------------------------- Writing

  // --------------------------------------------------------------------------- Deriving

  /// Which upstream rows the mirror is allowed to store at all, as SQL.
  ///
  /// The same three exclusions `OfflineRepository._storable` applies, and for the same reasons: a locked-folder asset
  /// would leave bytes readable outside the PIN gate, and a hidden one is the video half of a Live Photo, which the
  /// server never renders a thumbnail for and so can never be fetched.
  static final String _storable =
      'a.deleted_at IS NULL '
      'AND a.visibility <> ${AssetVisibility.locked.index} '
      'AND a.visibility <> ${AssetVisibility.hidden.index}';

  /// Re-derives every decision from the selection, in one statement.
  ///
  /// This replaced a paged walk that read the whole library through Dart — a page of assets, a query for their albums,
  /// a query for what was already recorded, three round trips per five hundred assets — and with it went every
  /// mechanism that existed to *avoid* running it: the scope tracking that re-derived one album at a time, the
  /// remembered album sizes that decided which of them had changed, the watermark over `updated_at` and the window
  /// that re-scanned recent rows because the watermark could not be trusted. Total is cheaper than incremental once
  /// the selection and the assets are in the same database, and nothing that is always run needs to be tracked.
  ///
  /// [OfflinePolicy.resolve] in SQL, and it must stay exactly that: an exclusion anywhere wins, otherwise the most
  /// generous of the library rung and every album naming the item. `offline_flags_repository_test.dart` checks the two
  /// against each other rather than trusting the resemblance.
  Future<int> derive(OfflinePolicy policy, DateTime touchedAt) async {
    var moved = 0;
    await _db.transaction(() async {
      await _exec('DROP TABLE IF EXISTS temp.album_rung');
      await _exec('CREATE TEMP TABLE album_rung (album_id TEXT PRIMARY KEY, quality INTEGER NOT NULL)');
      // Zero is the exclusion, which is why the rung and the state fit in one column: no row at all is "the album says
      // nothing", and `OfflineQuality.none` is never recorded as an inclusion.
      await _execEach('INSERT OR REPLACE INTO temp.album_rung (album_id, quality) VALUES (?, ?)', [
        for (final entry in policy.albums.entries)
          if (entry.value.isWanted) [entry.key, entry.value.code],
        for (final id in policy.excluded) [id, 0],
      ]);

      // One scan, grouped, rather than a correlated sub-query per asset. The join to the link table is what makes the
      // exclusion and the best rung answerable in the same pass over the library.
      await _exec('''
        DROP TABLE IF EXISTS temp.selected
      ''');
      await _exec(
        '''
        CREATE TEMP TABLE selected AS
        SELECT asset_id,
               CASE WHEN excluded = 1 THEN 0 ELSE MAX(best, ?) END AS quality,
               created_at
        FROM (
          SELECT a.id AS asset_id,
                 MAX(CASE WHEN r.quality = 0 THEN 1 ELSE 0 END) AS excluded,
                 COALESCE(MAX(CASE WHEN r.quality > 0 THEN r.quality END), 0) AS best,
                 unixepoch(a.created_at) * 1000 AS created_at
          FROM main.remote_asset_entity a
          LEFT JOIN main.remote_album_asset_entity l ON l.asset_id = a.id
          LEFT JOIN temp.album_rung r ON r.album_id = l.album_id
          WHERE $_storable
          GROUP BY a.id
        )
        WHERE quality > 0
      ''',
        [policy.library?.code ?? 0],
      );

      // `touched_at` means "when the change that selected this was made", never "when a walk last passed over it", so
      // the upsert only stamps rows whose decision actually moved. Without that guard a library-wide re-derivation
      // would re-order the entire download queue for work nobody changed.
      await _exec(
        'INSERT INTO wanted (asset_id, quality, created_at, on_demand, touched_at) '
        'SELECT asset_id, quality, created_at, 0, ? FROM temp.selected '
        // `WHERE true` is not idle: after a SELECT, SQLite cannot tell the upsert's ON from a join's
        // without a clause between them, and says only "syntax error near DO".
        'WHERE true '
        'ON CONFLICT(asset_id) DO UPDATE SET '
        'quality = excluded.quality, created_at = excluded.created_at, '
        'on_demand = excluded.on_demand, touched_at = excluded.touched_at '
        'WHERE wanted.quality <> excluded.quality',
        [touchedAt.millisecondsSinceEpoch ~/ 1000],
      );
      // How much actually moved, so a caller can skip reading it all back when nothing did — which is the usual
      // answer, since a pass re-derives whether or not the selection changed.
      moved += (await _one('SELECT changes() AS n')).data['n'] as int;

      // What the selection no longer covers. A row fetched by hand survives: nothing on the settings screen ever asked
      // for it, so no change to the settings can take it away — only "free up space" can.
      await _exec('DELETE FROM wanted WHERE on_demand = 0 AND asset_id NOT IN (SELECT asset_id FROM temp.selected)');
      moved += (await _one('SELECT changes() AS n')).data['n'] as int;

      await _exec('DROP TABLE temp.selected');
      await _exec('DROP TABLE temp.album_rung');
    });
    if (moved > 0) {
      revision++;
    }
    return moved;
  }

  /// Records decisions, one write for a whole library.
  Future<void> set(Iterable<OfflineFlagRow> assets) async {
    final rows = [
      for (final row in assets)
        [
          row.id,
          row.quality.code,
          row.createdAt.millisecondsSinceEpoch,
          row.onDemand ? 1 : 0,
          // Whole seconds, and truncated in exactly one place.
          row.touchedAt.millisecondsSinceEpoch ~/ 1000,
        ],
    ];
    if (rows.isEmpty) {
      return;
    }
    // An upsert naming its columns, not `INSERT OR REPLACE`: replacing the row resets every column the statement does
    // not mention, and `on_demand` is one a caller correcting a rung has no business clearing.
    await _execEach(
      'INSERT INTO wanted (asset_id, quality, created_at, on_demand, touched_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(asset_id) DO UPDATE SET '
      'quality = excluded.quality, created_at = excluded.created_at, '
      'on_demand = excluded.on_demand, touched_at = excluded.touched_at',
      rows,
    );
    revision++;
  }

  /// Records files that have arrived, at most one per asset and variant.
  Future<void> markHeld(Iterable<OfflineHeldRow> files) async {
    final held = files.toList();
    if (held.isEmpty) {
      return;
    }
    await _execEach('DELETE FROM held WHERE asset_id = ? AND variant = ? AND name <> ?', [
      for (final file in held) [file.assetId, file.variant.index, file.name],
    ]);
    await _execEach('INSERT OR REPLACE INTO held (name, asset_id, variant, token, size) VALUES (?, ?, ?, ?, ?)', [
      for (final file in held) [file.name, file.assetId, file.variant.index, file.token, file.size],
    ]);
  }

  Future<void> dropHeld(Iterable<String> names) async {
    for (final chunk in _chunked(names.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('DELETE FROM held WHERE name IN ($placeholders)', chunk);
    }
  }

  Future<void> clearHeld() => _exec('DELETE FROM held');

  /// Forgets the mirror entirely: every decision, every file recorded, every errand, every failure and every
  /// watermark.
  ///
  /// The counterpart of a selection *abandoned* rather than changed, which is what signing out and erasing the
  /// downloads is. [clearHeld] alone leaves the decisions behind, and since they outlive the sign-out along with the
  /// selection in settings, the next sign-in re-derives the lot and fetches the library all over again.
  Future<void> clearAll() async {
    await _db.transaction(() async {
      for (final table in const ['wanted', 'held', 'failures', 'meta']) {
        await _exec('DELETE FROM $table');
      }
    });
    revision++;
  }

  // --------------------------------------------------------------------------- Failures

  /// Attempts before a file is left alone: enough to ride out a restart or a server hiccup without hammering something
  /// broken.
  static const _maxAttempts = 3;

  Future<void> recordFailure(String name) => _exec(
    'INSERT INTO failures (name, attempts) VALUES (?, 1) ON CONFLICT(name) DO UPDATE SET attempts = attempts + 1',
    [name],
  );

  Future<void> clearFailure(String name) => _exec('DELETE FROM failures WHERE name = ?', [name]);

  /// Names that have failed too often to keep trying.
  Future<Set<String>> abandoned() async => {
    for (final row in await _all('SELECT name FROM failures WHERE attempts >= ?', [_maxAttempts]))
      row.data['name'] as String,
  };

  Future<int> abandonedCount() async =>
      (await _one('SELECT COUNT(*) AS c FROM failures WHERE attempts >= ?', [_maxAttempts])).data['c'] as int;

  Future<void> forgetFailures() async {
    await _exec('DELETE FROM failures');
    revision++;
  }

  // --------------------------------------------------------------------------- Meta

  Future<String?> _meta(String key) async {
    final row = await _oneOrNull('SELECT value FROM meta WHERE key = ?', [key]);
    return row == null ? null : row.data['value'] as String;
  }

  Future<void> _setMeta(String key, String? value) async {
    if (value == null) {
      await _exec('DELETE FROM meta WHERE key = ?', [key]);
      return;
    }
    await _exec('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);
  }

  /// When the store was last walked end to end.
  Future<DateTime?> lastReclaim() async {
    final millis = int.tryParse(await _meta('last_reclaim') ?? '');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Records a completed walk, which is also what clears [reclaimPending].
  Future<void> setReclaimed(DateTime at) async {
    await _setMeta('last_reclaim', at.millisecondsSinceEpoch.toString());
    await _setMeta('reclaim_pending', null);
  }

  /// Whether a walk stopped without finishing its job, so the next launch should try again rather than wait out the
  /// interval — the conditions it stops for clear in minutes.
  Future<bool> reclaimPending() async => await _meta('reclaim_pending') != null;

  Future<void> setReclaimPending() => _setMeta('reclaim_pending', '1');

  /// Which video the store was filled with, `original` or `video/playback`.
  Future<String?> videoForm() => _meta('video_form');

  Future<void> setVideoForm(String value) => _setMeta('video_form', value);

  /// When each task the downloader is holding was first seen, by task id.
  ///
  /// In the database rather than in memory, which is what the reaper that reads it needs and never had. A task the
  /// plugin holds but does not move — dropped when the app was replaced, deferred by the system, or waiting on a
  /// constraint that will not come — outlives the process, while an in-memory first-seen time does not: every launch
  /// declared it new, so the fifteen minutes it takes to be called stuck could only ever elapse in one uninterrupted
  /// session. A wedged download therefore survived restart after restart, holding a slot and a place in the count, and
  /// the only thing that cleared it was turning downloading off and on.
  Future<Map<String, DateTime>> outstandingSince() async {
    final raw = await _meta('outstanding_since');
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      return {
        for (final entry in (jsonDecode(raw) as Map<String, dynamic>).entries)
          if (entry.value case final int millis) entry.key: DateTime.fromMillisecondsSinceEpoch(millis),
      };
    } catch (error) {
      // One forgotten generation of first-seen times costs one more interval before a stuck task is noticed.
      Logger('OfflineFlags').warning('Could not read when downloads were handed over', error);
      return const {};
    }
  }

  Future<void> setOutstandingSince(Map<String, DateTime> since) => _setMeta(
    'outstanding_since',
    since.isEmpty
        ? null
        : jsonEncode({for (final entry in since.entries) entry.key: entry.value.millisecondsSinceEpoch}),
  );

  /// SQLite's variable limit is 999 by default; this stays well inside it.
  Iterable<List<String>> _chunked(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += 500) {
      yield ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    }
  }
}
