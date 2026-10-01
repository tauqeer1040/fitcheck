package com.taucity.stickerpants

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import kotlin.math.floor

/**
 * Native rotation clock for the homescreen widgets.
 *
 * Dart publishes a *pool* — every sticker the user has made, newest
 * first, each with its path, tint, shape index and two caption
 * variants — as one JSON blob (`WidgetService`). This object resolves
 * that pool against the wall clock so the widgets keep turning over
 * with the app closed:
 *
 *  - **image**: one pool step every 4h, so a fresh save shows the new
 *    sticker for four hours,
 *  - **caption**: one step every 2h (two variants per sticker), so a
 *    line always belongs to the sticker on screen,
 *  - **epoch**: re-stamped by Dart only when the pool content changes,
 *    which is why a wordmark colour toggle can't reshuffle the phase.
 *
 * The pool holds *all* stickers, so a user with thirty waits thirty
 * slots (five days) before the first sticker comes round again, while a
 * user with two still sees both.
 *
 * Ticks arrive from `updatePeriodMillis` (30 min — Android's floor).
 * That is 7 no-op ticks per image slot, so [signature]/[alreadyRendered]
 * gate the actual `updateAppWidget`: a day costs six real renders
 * instead of 48 heavy ones (the 2x5 ships 45 silhouette frames + 3
 * sticker bitmaps per render).
 *
 * Installs predating the pool have no blob; every reader falls back to
 * the old `sticker_N` window so pinned widgets keep rendering until
 * Dart republishes.
 */
object WidgetRotation {

    /// Key of the pool blob Dart writes (a JSON string, see
    /// WidgetService._pushPool).
    private const val KEY_POOL = "widget_pool"

    /// Image cadence. Six of these per day.
    const val IMAGE_PERIOD_MS = 4L * 60 * 60 * 1000

    /// Caption cadence: two caption variants per image slot.
    const val CAPTION_PERIOD_MS = 2L * 60 * 60 * 1000

    /// Default caption variants when the blob doesn't say.
    const val DEFAULT_CAPTION_VARIANTS = 2

    /// Sanity bound on how many pool entries one update will read. Not
    /// a product limit — Pro accounts are uncapped — just a stop for a
    /// corrupt blob turning one tick into unbounded work.
    const val MAX_POOL = 200

    /// Render-skip bookkeeping. Separate file from home_widget's own
    /// prefs: this is native state, and a Dart `saveWidgetData` sweep
    /// must never be able to clear it (that would make every tick
    /// re-render).
    private const val PREFS = "stickerpants_widget_render"

    /// Tinted silhouette fallback when Dart never pushed a tint.
    const val DEFAULT_TINT = 0xFF606060.toInt()

    /** One cell of the widget: art path plus the shape/tint behind it. */
    data class Cell(
        val path: String,
        val color: Int,
        val shape: String,
    ) {
        val isEmpty: Boolean get() = path.isEmpty()
    }

    /** Everything one widget instance draws this tick. */
    data class Frame(
        val cells: List<Cell>,
        val caption: String,
    )

    /** One published sticker: art plus its caption variants. */
    private data class Entry(
        val path: String,
        val color: Int,
        val shapeIdx: Int,
        val captions: List<String>,
    )

    /** The parsed blob. */
    private data class Pool(
        val epochMs: Long,
        val variants: Int,
        val entries: List<Entry>,
    )

    /** Shared blank cell: nothing to draw, so the providers hide the
     * view instead of shipping an empty silhouette. */
    private val EMPTY = Cell("", DEFAULT_TINT, "cookie")

    /**
     * Resolves the cells + caption for one widget instance. [cellCount]
     * is 3 for the 2x5 trio (pool head and the two behind it) and 1 for
     * the 2x3 single sticker.
     */
    fun frame(
        data: SharedPreferences,
        cellCount: Int,
        nowMs: Long = System.currentTimeMillis(),
    ): Frame {
        val pool = pool(data) ?: return legacyFrame(data, cellCount)
        if (pool.entries.isEmpty()) {
            return Frame(List(cellCount) { EMPTY }, "")
        }
        val epoch = epochMs(pool, nowMs)
        val head = floorMod(
            floorDiv(nowMs - epoch, IMAGE_PERIOD_MS),
            pool.entries.size.toLong(),
        ).toInt()
        val variant = floorMod(
            floorDiv(nowMs - epoch, CAPTION_PERIOD_MS),
            pool.variants.toLong(),
        ).toInt()
        val cells = (0 until cellCount).map { k -> cellAt(pool, head + k) }
        val captions = pool.entries[head].captions
        val caption = captions.getOrNull(variant)
            ?: captions.firstOrNull()
            ?: ""
        return Frame(cells, caption)
    }

    /**
     * Everything the drawn views depend on, as one string: the resolved
     * cells, the caption, the caption size, and the instance's current
     * size. [sizeTag] comes from the widget options so a resize forces a
     * re-render even though nothing else changed.
     */
    fun signature(frame: Frame, funnySp: Float, sizeTag: String): String =
        buildString {
            append(sizeTag).append('|').append(funnySp).append('|')
            append(frame.caption).append('|')
            for (c in frame.cells) {
                append(c.path).append(',').append(c.color).append(',')
                append(c.shape).append(';')
            }
        }

    /**
     * True when this exact frame is already on screen for this instance.
     * Keyed per widget id: a freshly pinned widget has no entry, so it
     * always renders its first frame instead of inheriting a skip.
     */
    fun alreadyRendered(context: Context, key: String, signature: String): Boolean =
        renderPrefs(context).getString(key, null) == signature

    /** Records the frame just drawn for [key]. */
    fun markRendered(context: Context, key: String, signature: String) {
        renderPrefs(context).edit().putString(key, signature).apply()
    }

    /**
     * When the running rotation started. Absent in a blob written by a
     * build that didn't stamp one, so fall back to the current
     * wall-clock 4h block: the window then still turns over on a sane
     * schedule instead of never.
     */
    private fun epochMs(pool: Pool, nowMs: Long): Long =
        if (pool.epochMs > 0L) pool.epochMs else nowMs - floorMod(nowMs, IMAGE_PERIOD_MS)

    /** Pool entry [rawIndex] (may be head+k, wraps). */
    private fun cellAt(pool: Pool, rawIndex: Int): Cell {
        val e = pool.entries[floorMod(rawIndex.toLong(), pool.entries.size.toLong()).toInt()]
        return Cell(
            e.path,
            e.color,
            WidgetShapes.shapeName(e.shapeIdx, null, "cookie"),
        )
    }

    /**
     * Parses the blob Dart wrote. Never throws: a truncated or corrupt
     * blob reads as "no pool", which lands on the legacy window rather
     * than on a blank widget.
     */
    private fun pool(data: SharedPreferences): Pool? {
        val raw = data.getString(KEY_POOL, null) ?: return null
        return runCatching {
            val root = JSONObject(raw)
            val arr = root.optJSONArray("cells")
            val entries = ArrayList<Entry>(minOf(arr?.length() ?: 0, MAX_POOL))
            for (i in 0 until minOf(arr?.length() ?: 0, MAX_POOL)) {
                val o = arr!!.getJSONObject(i)
                val path = o.optString("p")
                if (path.isEmpty()) continue
                val lines = ArrayList<String>(DEFAULT_CAPTION_VARIANTS)
                val t = o.optJSONArray("t")
                if (t != null) {
                    for (v in 0 until t.length()) lines.add(t.getString(v))
                }
                entries.add(
                    Entry(
                        path,
                        o.optInt("c", DEFAULT_TINT),
                        o.optInt("s", -1),
                        lines,
                    )
                )
            }
            Pool(
                root.optLong("epochMs", 0L),
                root.optInt("variants", DEFAULT_CAPTION_VARIANTS).coerceIn(1, 8),
                entries,
            )
        }.getOrNull()
    }

    /**
     * Pre-pool layout: one sticker per slot with a cycling shape
     * string, and a single line of text.
     */
    private fun legacyFrame(data: SharedPreferences, cellCount: Int): Frame {
        val quad = arrayOf("clamshell", "semicircle")
        val cells = (0 until cellCount).map { i ->
            val path = data.getString("sticker_$i", null) ?: ""
            if (path.isEmpty()) {
                EMPTY
            } else {
                Cell(
                    path,
                    WidgetShapes.colorInt(data, "sticker_${i}_color", DEFAULT_TINT),
                    WidgetShapes.resolveStickerShape(
                        data,
                        "sticker_${i}_shapeIdx",
                        "sticker_${i}_shape",
                        quad[i % quad.size],
                    ),
                )
            }
        }
        return Frame(cells, data.getString("funny_line", null) ?: "")
    }

    private fun renderPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun floorDiv(a: Long, b: Long): Long = floor(a.toDouble() / b).toLong()

    private fun floorMod(a: Long, b: Long): Long {
        val m = a % b
        return if (m < 0) m + b else m
    }
}