package app.alextran.immich.images

import android.content.Context
import app.alextran.immich.NativeBuffer
import app.alextran.immich.NativeByteBuffer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.net.URI
import java.net.URLDecoder
import java.nio.channels.FileChannel
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * immich-sync fork: the blob store, Android side. The counterpart of
 * `ios/Runner/Images/OfflineStore.swift`, and the same store — the names, the two regions and the
 * bucketing are defined once in `lib/utils/offline_paths.dart` and reproduced here.
 *
 * Everything above this file is shared: the reconciler, the queue, the selection, the integrity
 * pass and the whole UI are Dart with no platform branch in them, and downloads already run on both
 * platforms through `background_downloader`. What a platform has to supply is only this — a place
 * to put bytes, and a read that beats the network — because the image path is native on each.
 */
object OfflineStore {
  /**
   * `filesDir`, not `cacheDir`: the library is not a cache and the system may empty the latter at
   * will. It is the same distinction Application Support and Caches draw on iOS.
   */
  private var root: File? = null
  private var pinnedRoot: File? = null
  private var cacheRoot: File? = null

  /**
   * How much the opportunistic region may hold. Dart owns the value and pushes it at launch and on
   * every change; this default holds until it does. Zero means keep nothing — browsing then writes
   * no blobs at all.
   */
  private var cacheBudget: Long = 256L * 1024 * 1024

  /** Reads happen here, off the thread that asked. Writes are serialised on their own. */
  private val io = Executors.newFixedThreadPool(4)
  private val writes = Executors.newSingleThreadExecutor()
  private val maintenance = Executors.newSingleThreadExecutor()

  private val lock = ReentrantLock()

  /**
   * 64-bit name hashes of every file held, in either region. Answers "is it worth touching the
   * filesystem for this URL?" in a lock and a hash lookup. A collision costs one wasted open, never
   * a wrong image.
   */
  private val present = HashSet<Long>()
  private var indexed = false
  private var cacheBytes: Long = 0
  private var trimming = false

  // ---------------------------------------------------------------------------
  // Naming — mirrors offline_paths.dart
  // ---------------------------------------------------------------------------

  private fun isSafe(byte: Int): Boolean {
    val value = byte and 0xFF
    return (value in 0x30..0x39) ||
      (value in 0x41..0x5A) ||
      (value in 0x61..0x7A) ||
      value == '.'.code ||
      value == '_'.code ||
      value == '-'.code
  }

  private fun sanitize(value: String): String {
    val bytes = value.toByteArray(Charsets.UTF_8)
    for (i in bytes.indices) {
      if (!isSafe(bytes[i].toInt())) bytes[i] = '-'.code.toByte()
    }
    return String(bytes, Charsets.UTF_8)
  }

  fun fnv1a32(value: String): Int {
    var hash = -0x7EE3623B // 2166136261 as a signed Int
    for (byte in value.toByteArray(Charsets.UTF_8)) {
      hash = (hash xor (byte.toInt() and 0xFF)) * 16777619
    }
    return hash
  }

  fun fnv1a64(value: String): Long {
    var hash = -0x340D631B7BDDDCDBL // 14695981039346656037 as a signed Long
    for (byte in value.toByteArray(Charsets.UTF_8)) {
      hash = (hash xor (byte.toLong() and 0xFF)) * 1099511628211L
    }
    return hash
  }

  /**
   * Filename for a remote URL. Mirrors `offlineBlobName` in Dart and `fileName(for:)` in Swift, and
   * the three must agree byte for byte: Dart names a blob when it downloads it, and this names it
   * when the image path looks for it. A divergence is silent — every image simply falls through to
   * the network and the mirror appears to do nothing.
   *
   * Derived from the URL rather than hashed whole: the path already carries the asset id and the
   * variant, so an asset's files sort together and there is no cryptographic hash on the render
   * path. Scheme and host are excluded, so a file fetched over the LAN endpoint still resolves once
   * endpoint switching moves to the external one; the query folds into a short token, which is how
   * an edited asset lands on a new name rather than serving stale bytes.
   *
   * Three places where the obvious spelling differs from Dart's, each of which would produce a
   * different name for the same URL:
   *
   * - path segments are percent-decoded but `+` is **left alone**, while query values decode `+` to
   *   a space — which is what Dart's `Uri.pathSegments` and `Uri.queryParameters` do, and what
   *   `URLDecoder.decode` would get wrong if used for both;
   * - a repeated query key takes the **last** value, because Dart's `queryParameters` is a map;
   * - and the query is ordered by **UTF-8 bytes**, not by `String.compareTo`, which orders by UTF-16
   *   code unit and agrees only up to the BMP.
   */
  fun fileName(url: String): String? {
    val uri = try {
      URI(url)
    } catch (_: Exception) {
      return null
    }

    val rawPath = uri.rawPath ?: return null
    val segments = rawPath.split('/').filter { it.isNotEmpty() }.map(::decodePath).toMutableList()
    if (segments.firstOrNull() == "api") segments.removeAt(0)
    if (segments.isEmpty()) return null

    var size: String? = null
    val values = LinkedHashMap<String, String>()
    for (pair in (uri.rawQuery ?: "").split('&')) {
      if (pair.isEmpty()) continue
      val split = pair.indexOf('=')
      val key = decodeQuery(if (split < 0) pair else pair.substring(0, split))
      // A valueless `?size` is "" in Dart, which would otherwise name the file differently here.
      val value = if (split < 0) "" else decodeQuery(pair.substring(split + 1))
      if (key == "size") {
        size = value
        continue
      }
      values[key] = value
    }

    val params = values.entries
      .map { "${it.key}=${it.value}" }
      .sortedWith { a, b -> compareUtf8(a, b) }

    val name = StringBuilder(segments.joinToString("_") { sanitize(it) })
    if (size != null) name.append('_').append(sanitize(size))
    name.append(String.format("_%08x", fnv1a32(params.joinToString("&"))))

    val playable = segments.contains("video") || segments.last() == "original"
    return if (playable) "$name.mp4" else name.toString()
  }

  /** Percent-decoding only, as `Uri.pathSegments` does — a `+` in a path is a `+`. */
  private fun decodePath(value: String): String =
    if (value.contains('%')) URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") else value

  /** Percent-decoding and `+` as a space, as `Uri.queryParameters` does. */
  private fun decodeQuery(value: String): String =
    if (value.contains('%') || value.contains('+')) URLDecoder.decode(value, "UTF-8") else value

  private fun compareUtf8(a: String, b: String): Int {
    val left = a.toByteArray(Charsets.UTF_8)
    val right = b.toByteArray(Charsets.UTF_8)
    for (i in 0 until minOf(left.size, right.size)) {
      val diff = (left[i].toInt() and 0xFF) - (right[i].toInt() and 0xFF)
      if (diff != 0) return diff
    }
    return left.size - right.size
  }

  /**
   * Bucket a name falls into. Hashed rather than taken from its first characters, which all read
   * `assets_` and would land in one directory.
   */
  fun bucket(name: String): String = String.format("%02x", fnv1a32(name) and 0xFF)

  private fun pinnedPath(name: String): File? = pinnedRoot?.let { File(File(it, bucket(name)), name) }

  private fun cachePath(name: String): File? = cacheRoot?.let { File(File(it, bucket(name)), name) }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /**
   * Creates the store and indexes it, once at launch.
   *
   * The index build walks the whole store, so it runs off the launch path. Until it finishes every
   * lookup is treated as a possible hit and falls through to the filesystem: correct, just not as
   * cheap.
   */
  fun prepare(context: Context) {
    val base = File(context.filesDir, "mirrich_blobs")
    val pinned = File(base, "pinned")
    val cache = File(base, "cache")
    lock.withLock {
      root = base
      pinnedRoot = pinned
      cacheRoot = cache
    }
    pinned.mkdirs()
    cache.mkdirs()

    maintenance.execute {
      val hashes = HashSet<Long>()
      var bytes = 0L
      for ((region, isCache) in listOf(pinned to false, cache to true)) {
        for (file in walk(region)) {
          hashes.add(fnv1a64(file.name))
          if (isCache) bytes += file.length()
        }
      }
      lock.withLock {
        present.addAll(hashes)
        cacheBytes = bytes
        indexed = true
      }
      trimCacheIfNeeded()
    }
  }

  /**
   * Every regular file under a region.
   *
   * Hidden files are not skipped: `sanitize` permits a leading `.`, and such a name would then be
   * uncounted, unevictable and reported absent by [mightHold]. The Dart integrity pass lists the
   * same directories without skipping anything.
   */
  private fun walk(directory: File): List<File> =
    directory.walkTopDown().filter { it.isFile }.toList()

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /** Whether a lookup is worth a filesystem call. Safe to call on any thread. */
  fun mightHold(name: String): Boolean = lock.withLock {
    if (indexed) present.contains(fnv1a64(name)) else true
  }

  /** Runs [body] on the store's own pool, off the thread the image API called from. */
  fun read(body: () -> Unit) {
    io.execute(body)
  }

  /**
   * Stored bytes for a name, or null.
   *
   * Read straight into the off-heap buffer the image path already speaks, through a mapped channel,
   * so the bytes are not copied through the JVM heap on the way to the decoder.
   */
  fun load(name: String): NativeByteBuffer? {
    val file = pinnedPath(name)?.takeIf { it.isFile } ?: cachePath(name)?.takeIf { it.isFile } ?: return null
    val length = file.length()
    if (length <= 0 || length > Int.MAX_VALUE) return null

    val buffer = NativeByteBuffer(length.toInt())
    try {
      RandomAccessFile(file, "r").use { handle ->
        handle.channel.use { channel ->
          val target = NativeBuffer.wrap(buffer.pointer, length.toInt())
          var read = 0
          while (read < length) {
            val count = channel.read(target)
            if (count <= 0) break
            read += count
          }
          if (read.toLong() != length) {
            buffer.free()
            return null
          }
          buffer.advance(read)
        }
      }
    } catch (_: Throwable) {
      buffer.free()
      return null
    }
    return buffer
  }

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  /**
   * Keeps bytes that were just fetched for the screen, in the opportunistic region only: deciding
   * that a photo belongs in the mirror is the Dart side's job, and it claims these by renaming
   * rather than downloading again.
   */
  fun store(bytes: ByteArray, name: String) {
    val keeping = lock.withLock { cacheBudget > 0 }
    if (!keeping) return
    val target = cachePath(name) ?: return
    val pinned = pinnedPath(name) ?: return

    writes.execute {
      if (pinned.exists()) return@execute
      target.parentFile?.mkdirs()

      // What this write replaces, if anything. Two fetches for one tile can both land, the second
      // overwriting rather than adding, and counting both would trim a region never over budget.
      val replaced = if (target.isFile) target.length() else 0L

      // Written aside and renamed into place: a half-written blob that a later read maps decodes as
      // a corrupt image.
      val temporary = File(target.parentFile, "$name.part")
      try {
        temporary.writeBytes(bytes)
        if (!temporary.renameTo(target)) {
          temporary.delete()
          return@execute
        }
      } catch (_: Throwable) {
        temporary.delete()
        return@execute
      }

      lock.withLock {
        present.add(fnv1a64(name))
        cacheBytes = cacheBytes - minOf(cacheBytes, replaced) + bytes.size
      }
      trimCacheIfNeeded()
    }
  }

  /**
   * Records names Dart has just written into `pinned/`, so the next lookup for one does not have to
   * discover it by missing first.
   */
  fun noteStored(names: List<String>) {
    lock.withLock { for (name in names) present.add(fnv1a64(name)) }
  }

  /**
   * Accounts for bytes Dart moved out of `cache/` into `pinned/`.
   *
   * A rename it performs itself is invisible here, so without this the region keeps counting bytes
   * it no longer holds. The next trim recomputes from a walk, but a number that is only right after
   * a trim is not worth showing.
   */
  fun notePromoted(bytes: Long) {
    if (bytes <= 0) return
    lock.withLock { cacheBytes = if (cacheBytes > bytes) cacheBytes - bytes else 0 }
  }

  /**
   * Forgets names Dart has just deleted.
   *
   * The index only gates whether the filesystem is consulted, so a stale name costs one failed
   * open. Dropping all of it is the honest answer to a bulk delete, since rebuilding is one walk.
   */
  fun forgetAll(context: Context) {
    lock.withLock {
      present.clear()
      indexed = false
      cacheBytes = 0
    }
    prepare(context)
  }

  // ---------------------------------------------------------------------------
  // Trimming
  // ---------------------------------------------------------------------------

  /** Whether browsing is allowed to keep anything at all. */
  fun isKeeping(): Boolean = lock.withLock { cacheBudget > 0 }

  /** Total bytes held in the opportunistic region. */
  fun cacheSize(): Long = lock.withLock { cacheBytes }

  /**
   * Sets the budget and trims down to it straight away, so lowering it takes effect while the user
   * is still looking at the screen that changed it.
   */
  fun setCacheBudget(bytes: Long, context: Context) {
    lock.withLock { cacheBudget = bytes }
    if (bytes == 0L) {
      clearCache(context)
      return
    }
    trimCacheIfNeeded()
  }

  /**
   * Empties the opportunistic region. `pinned/` is untouched: it is the library, not a cache, and
   * has its own control.
   */
  fun clearCache(context: Context, done: (() -> Unit)? = null) {
    val cache = cacheRoot
    if (cache == null) {
      done?.invoke()
      return
    }
    writes.execute {
      cache.deleteRecursively()
      cache.mkdirs()
      forgetAll(context)
      done?.invoke()
    }
  }

  private fun trimCacheIfNeeded() {
    val budget = lock.withLock {
      if (cacheBytes <= cacheBudget || trimming) return
      trimming = true
      cacheBudget
    }
    val cache = cacheRoot
    if (cache == null) {
      lock.withLock { trimming = false }
      return
    }

    maintenance.execute {
      // Oldest written first, not least recently read: access order would mean a write on every
      // cache hit, and this only has to be bounded.
      val files = walk(cache).sortedBy { it.lastModified() }.toMutableList()
      var remaining = files.sumOf { it.length() }
      val target = budget * 4 / 5

      val dropped = ArrayList<Long>()
      while (remaining > target && files.isNotEmpty()) {
        val file = files.removeAt(0)
        val size = file.length()
        // Only bytes actually given back are counted: deducting on a failed delete would let the
        // loop conclude it is under budget with the files still there.
        if (!file.delete()) continue
        // The index covers both regions, so a pinned copy may still earn this name — the reconciler
        // writes there directly, without passing through `store()` and its existence check.
        // Dropping it would tell `mightHold` that a mirrored photo is absent and send the image path
        // to the network for a file on disk, invisible until the user is offline.
        if (pinnedPath(file.name)?.exists() != true) dropped.add(fnv1a64(file.name))
        remaining -= minOf(remaining, size)
      }

      lock.withLock {
        present.removeAll(dropped.toSet())
        cacheBytes = remaining
        trimming = false
      }
    }
  }
}

/**
 * immich-sync fork: lets Dart keep the lookup index in step.
 *
 * The reconciler writes into `pinned/` through background_downloader and deletes from it directly,
 * neither passing through this file, so without these a freshly mirrored blob stays invisible until
 * the next launch.
 */
object OfflineStoreChannel {
  fun register(context: Context, messenger: BinaryMessenger) {
    val channel = MethodChannel(messenger, "mirrich/offline_store")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "noteStored" -> {
          @Suppress("UNCHECKED_CAST")
          OfflineStore.noteStored(call.arguments as? List<String> ?: emptyList())
          result.success(null)
        }

        "notePromoted" -> {
          OfflineStore.notePromoted((call.arguments as? Number)?.toLong() ?: 0L)
          result.success(null)
        }

        "forgetAll" -> {
          OfflineStore.forgetAll(context)
          result.success(null)
        }

        "cacheSize" -> result.success(OfflineStore.cacheSize())

        "setCacheBudget" -> {
          OfflineStore.setCacheBudget((call.arguments as? Number)?.toLong() ?: 0L, context)
          result.success(null)
        }

        else -> result.notImplemented()
      }
    }
  }
}
