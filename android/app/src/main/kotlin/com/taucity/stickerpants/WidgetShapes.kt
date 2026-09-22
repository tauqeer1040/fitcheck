package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * M3E container shapes for the homescreen widgets, Pixel-clock style:
 * the widget background itself is a 12-pointed cookie, and the
 * stickers float on top — unclipped, free to leak over its edges.
 *
 * Rendered to a bitmap at the widget's real pixel size (RemoteViews
 * can't run custom draw code, so the shape ships as an ImageView).
 */
object WidgetShapes {

    /**
     * Color round-trip from Dart: ints cross the method channel as Long
     * whenever they exceed Int range (every 0xFF alpha color does), so
     * a plain getInt() throws ClassCastException and kills the host
     * process from inside the widget receiver. Read as Number instead —
     * handles Integer, Long, and absent keys.
     */
    fun colorInt(data: SharedPreferences, key: String, default: Int): Int {
        return (data.all[key] as? Number)?.toInt() ?: default
    }

    /**
     * Float round-trip from Dart: doubles cross as raw Long bits, which
     * toFloat() turns into garbage magnitudes (~1e18) that crash widget
     * inflation (TextViewSizeAction rejects them). Accept Number or
     * String, and range-guard everything: garbage can only ever fall
     * back to [default], never into a view.
     */
    fun prefsFloat(
        data: SharedPreferences,
        key: String,
        default: Float,
        min: Float = 0.5f,
        max: Float = 100f,
    ): Float {
        val raw: Float? = when (val v = data.all[key]) {
            is Number -> v.toFloat()
            is String -> v.toFloatOrNull()
            else -> null
        }
        if (raw == null || !raw.isFinite() || raw < min || raw > max) {
            return default
        }
        return raw
    }

    /**
     * 12-pointed cookie path centered in [w]x[h]: 12 outer lobes with
     * rounded valleys between them. [lobeDepth] 0..1 controls how
     * pronounced the scallops are (0.16 reads like the Pixel clock).
     */
    fun cookie12Path(w: Float, h: Float, lobeDepth: Float = 0.16f): Path {
        val cx = w / 2f
        val cy = h / 2f
        val rOut = min(w, h) / 2f
        val rIn = rOut * (1f - lobeDepth)
        // 12 lobes -> 24 alternating vertices; quadratic smoothing
        // through edge midpoints gives the rounded M3 cookie feel.
        val n = 24
        val pts = Array(n) { i ->
            val a = (i.toFloat() / n) * (Math.PI * 2) - Math.PI / 2
            val r = if (i % 2 == 0) rOut else rIn
            // Stretch to fill wide widgets: x spans full width, y keeps
            // the cookie round within the height.
            val xScale = w / min(w, h)
            floatArrayOf(
                (cx + cos(a).toFloat() * r * xScale).toFloat(),
                (cy + sin(a).toFloat() * r).toFloat(),
            )
        }
        return Path().apply {
            moveTo(
                (pts[0][0] + pts[n - 1][0]) / 2f,
                (pts[0][1] + pts[n - 1][1]) / 2f,
            )
            for (i in 0 until n) {
                val p = pts[i]
                val q = pts[(i + 1) % n]
                quadTo(p[0], p[1], (p[0] + q[0]) / 2f, (p[1] + q[1]) / 2f)
            }
            close()
        }
    }

    /** Regular n-gon centered in w×h (first vertex at top). */
    private fun regularPolygonPath(w: Float, h: Float, sides: Int): Path {
        val cx = w / 2f
        val cy = h / 2f
        val r = min(w, h) / 2f
        return Path().apply {
            for (i in 0 until sides) {
                val a = (i * 2 * Math.PI / sides - Math.PI / 2).toFloat()
                val x = cx + cos(a).toFloat() * r
                val y = cy + sin(a).toFloat() * r
                if (i == 0) moveTo(x, y) else lineTo(x, y)
            }
            close()
        }
    }

    /** n-point star centered in w×h ([innerRatio] = valley depth). */
    private fun starPath(w: Float, h: Float, points: Int, innerRatio: Float): Path {
        val cx = w / 2f
        val cy = h / 2f
        val rOut = min(w, h) / 2f
        return Path().apply {
            for (i in 0 until points * 2) {
                val a = (i * Math.PI / points - Math.PI / 2).toFloat()
                val r = if (i % 2 == 0) rOut else rOut * innerRatio
                val x = cx + cos(a).toFloat() * r
                val y = cy + sin(a).toFloat() * r
                if (i == 0) moveTo(x, y) else lineTo(x, y)
            }
            close()
        }
    }

    /** Container bitmap: cookie on transparent, exact pixel size. */
    fun renderCookie(widthPx: Int, heightPx: Int, color: Int): Bitmap? {
        if (widthPx <= 0 || heightPx <= 0) return null
        return runCatching {
            val bmp = Bitmap.createBitmap(
                widthPx, heightPx, Bitmap.Config.ARGB_8888,
            )
            val canvas = Canvas(bmp)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = color
                style = Paint.Style.FILL
            }
            canvas.drawPath(
                cookie12Path(widthPx.toFloat(), heightPx.toFloat()),
                paint,
            )
            bmp
        }.getOrNull()
    }

    /**
     * Widget container shapes (filled paths), mirroring the sticker
     * clip math in WidgetBitmaps: 2x2 alternates gem/arch, 2x4 cycles
     * semicircle/clamshell. Unknown names fall back to the 12-cookie
     * (the previous look).
     *
     * kStyleShapes indices (same order as Dart) resolve via
     * [shapeNameForIndex]: 0 gem, 1 cookie, 2 sunny, 3 flower,
     * 4 pentagon, 5 oval, 6 pill, 7 arch, 8 diamond, 9 slanted —
     * so the widget silhouette is the sticker's own homescreen shape.
     */
    fun shapeNameForIndex(idx: Int): String = when (idx) {
        0 -> "gem"
        1 -> "cookie"
        2 -> "sunny"
        3 -> "flower"
        4 -> "pentagon"
        5 -> "oval"
        6 -> "pill"
        7 -> "arch"
        8 -> "diamond"
        9 -> "slanted"
        10 -> "circle"
        11 -> "square"
        12 -> "semicircle"
        13 -> "triangle"
        14 -> "arrow"
        15 -> "fan"
        16 -> "very_sunny"
        17 -> "c4"
        18 -> "c6"
        19 -> "c7"
        20 -> "c9"
        21 -> "l4"
        22 -> "l8"
        23 -> "burst"
        24 -> "soft_burst"
        25 -> "boom"
        26 -> "soft_boom"
        27 -> "puffy"
        28 -> "puffy_diamond"
        29 -> "ghostish"
        30 -> "pixel_circle"
        31 -> "pixel_triangle"
        32 -> "bun"
        33 -> "hearth"
        else -> "cookie"
    }

    /**
     * The sticker's own homescreen shape: prefers the stored kStyleShapes
     * index, falls back to the legacy cycling string keys so widgets
     * pinned before the index was saved keep rendering.
     */
    fun resolveStickerShape(
        data: SharedPreferences,
        idxKey: String,
        legacyKey: String,
        legacyDefault: String,
    ): String {
        val idx = (data.all[idxKey] as? Number)?.toInt() ?: -1
        if (idx in 0..33) return shapeNameForIndex(idx)
        return data.getString(legacyKey, legacyDefault) ?: legacyDefault
    }
    fun containerPath(shape: String, w: Float, h: Float): Path {
        return Path().apply {
            when (shape) {
                "arch" -> {
                    val rad = minOf(w / 2f, h)
                    moveTo(0f, h)
                    lineTo(0f, rad)
                    arcTo(RectF(0f, 0f, w, rad * 2f), 180f, 180f)
                    lineTo(w, h)
                    close()
                }
                "semicircle" -> {
                    val rad = minOf(w / 2f, h)
                    moveTo(0f, 0f)
                    lineTo(w, 0f)
                    lineTo(w, h - rad)
                    arcTo(RectF(0f, h - rad * 2f, w, h), 0f, 180f)
                    close()
                }
                "gem", "diamond" -> {
                    moveTo(w / 2f, 0f)
                    lineTo(w, h / 2f)
                    lineTo(w / 2f, h)
                    lineTo(0f, h / 2f)
                    close()
                }
                "clamshell" -> {
                    val top = minOf(w, h) * 0.42f
                    val bottom = minOf(w, h) * 0.14f
                    addRoundRect(
                        RectF(0f, 0f, w, h),
                        floatArrayOf(top, top, top, top, bottom, bottom, bottom, bottom),
                        Path.Direction.CW,
                    )
                }
                "sunny" -> {
                    addPath(starPath(w, h, points = 12, innerRatio = 0.82f))
                }
                "flower" -> {
                    // Union of petals in one fill: overlapping same-color
                    // circles read as a single blossom.
                    val cx = w / 2f
                    val cy = h / 2f
                    val rOut = min(w, h) / 2f
                    for (k in 0 until 8) {
                        val a = (k * Math.PI * 2 / 8).toFloat()
                        addCircle(
                            cx + cos(a).toFloat() * rOut * 0.52f,
                            cy + sin(a).toFloat() * rOut * 0.52f,
                            rOut * 0.42f,
                            Path.Direction.CW,
                        )
                    }
                    addCircle(cx, cy, rOut * 0.4f, Path.Direction.CW)
                }
                "pentagon" -> {
                    addPath(regularPolygonPath(w, h, sides = 5))
                }
                "oval" -> {
                    addOval(RectF(0f, 0f, w, h), Path.Direction.CW)
                }
                "pill" -> {
                    val r = minOf(w, h) / 2f
                    addRoundRect(
                        RectF(0f, 0f, w, h),
                        floatArrayOf(r, r, r, r, r, r, r, r),
                        Path.Direction.CW,
                    )
                }
                "slanted" -> {
                    val lean = w * 0.18f
                    moveTo(lean, 0f)
                    lineTo(w, 0f)
                    lineTo(w - lean, h)
                    lineTo(0f, h)
                    close()
                }
                "circle", "bun" -> {
                    // Bun reads as a soft round roll: same disc.
                    addOval(RectF(0f, 0f, w, h), Path.Direction.CW)
                }
                "square" -> {
                    addRect(RectF(0f, 0f, w, h), Path.Direction.CW)
                }
                "triangle", "pixel_triangle" -> {
                    // Pixel triangle reads as a triangle at widget size.
                    addPath(regularPolygonPath(w, h, sides = 3))
                }
                "pixel_circle" -> {
                    // Octagon reads pixelly at widget size.
                    addPath(regularPolygonPath(w, h, sides = 8))
                }
                "arrow" -> {
                    moveTo(0f, h * 0.2f)
                    lineTo(w * 0.55f, h * 0.2f)
                    lineTo(w * 0.55f, 0f)
                    lineTo(w, h * 0.5f)
                    lineTo(w * 0.55f, h)
                    lineTo(w * 0.55f, h * 0.8f)
                    lineTo(0f, h * 0.8f)
                    close()
                }
                "fan" -> {
                    // Quarter disc anchored bottom-left.
                    val r = min(w, h)
                    moveTo(0f, h)
                    lineTo(0f, h - r)
                    arcTo(RectF(-r, h - r, r, h + r), 270f, 90f)
                    lineTo(w, h)
                    close()
                }
                "very_sunny" -> {
                    addPath(starPath(w, h, points = 20, innerRatio = 0.7f))
                }
                "burst" -> {
                    addPath(starPath(w, h, points = 10, innerRatio = 0.62f))
                }
                "boom" -> {
                    addPath(starPath(w, h, points = 14, innerRatio = 0.5f))
                }
                "soft_burst" -> {
                    addPath(starPath(w, h, points = 10, innerRatio = 0.82f))
                }
                "soft_boom" -> {
                    addPath(starPath(w, h, points = 14, innerRatio = 0.78f))
                }
                "c4" -> {
                    addPath(starPath(w, h, points = 4, innerRatio = 0.88f))
                }
                "c6" -> {
                    addPath(starPath(w, h, points = 6, innerRatio = 0.9f))
                }
                "c7" -> {
                    addPath(starPath(w, h, points = 7, innerRatio = 0.9f))
                }
                "c9" -> {
                    addPath(starPath(w, h, points = 9, innerRatio = 0.92f))
                }
                "l4" -> {
                    val cx = w / 2f
                    val cy = h / 2f
                    val rOut = min(w, h) / 2f
                    for (k in 0 until 4) {
                        val a = (k * Math.PI * 2 / 4).toFloat()
                        addCircle(
                            cx + cos(a).toFloat() * rOut * 0.5f,
                            cy + sin(a).toFloat() * rOut * 0.5f,
                            rOut * 0.42f,
                            Path.Direction.CW,
                        )
                    }
                    addCircle(cx, cy, rOut * 0.4f, Path.Direction.CW)
                }
                "l8" -> {
                    val cx = w / 2f
                    val cy = h / 2f
                    val rOut = min(w, h) / 2f
                    for (k in 0 until 8) {
                        val a = (k * Math.PI * 2 / 8).toFloat()
                        addCircle(
                            cx + cos(a).toFloat() * rOut * 0.58f,
                            cy + sin(a).toFloat() * rOut * 0.58f,
                            rOut * 0.3f,
                            Path.Direction.CW,
                        )
                    }
                    addCircle(cx, cy, rOut * 0.34f, Path.Direction.CW)
                }
                "puffy" -> {
                    val cx = w / 2f
                    val cy = h / 2f
                    val rOut = min(w, h) / 2f
                    for (k in 0 until 6) {
                        val a = (k * Math.PI * 2 / 6).toFloat()
                        addCircle(
                            cx + cos(a).toFloat() * rOut * 0.42f,
                            cy + sin(a).toFloat() * rOut * 0.42f,
                            rOut * 0.44f,
                            Path.Direction.CW,
                        )
                    }
                    addCircle(cx, cy, rOut * 0.46f, Path.Direction.CW)
                }
                "puffy_diamond" -> {
                    val cx = w / 2f
                    val cy = h / 2f
                    val rOut = min(w, h) / 2f
                    for (k in 0 until 4) {
                        val a = (k * Math.PI * 2 / 4).toFloat()
                        addCircle(
                            cx + cos(a).toFloat() * rOut * 0.5f,
                            cy + sin(a).toFloat() * rOut * 0.5f,
                            rOut * 0.36f,
                            Path.Direction.CW,
                        )
                    }
                    addCircle(cx, cy, rOut * 0.38f, Path.Direction.CW)
                }
                "ghostish" -> {
                    // Round head, zigzag hem.
                    val rad = minOf(w / 2f, h)
                    moveTo(0f, h)
                    lineTo(0f, rad)
                    arcTo(RectF(0f, 0f, w, rad * 2f), 180f, 180f)
                    lineTo(w, h)
                    lineTo(w * 0.75f, h * 0.86f)
                    lineTo(w * 0.5f, h)
                    lineTo(w * 0.25f, h * 0.86f)
                    close()
                }
                "hearth" -> {
                    // Heart: twin lobes + tapered base.
                    val r = min(w, h) / 2f
                    val cx = w / 2f
                    addCircle(
                        cx - r * 0.36f, h * 0.34f, r * 0.42f,
                        Path.Direction.CW,
                    )
                    addCircle(
                        cx + r * 0.36f, h * 0.34f, r * 0.42f,
                        Path.Direction.CW,
                    )
                    moveTo(cx - r * 0.72f, h * 0.38f)
                    lineTo(cx + r * 0.72f, h * 0.38f)
                    lineTo(cx, h)
                    close()
                }
                else -> set(cookie12Path(w, h))
            }
        }
    }

    /** Container bitmap: [shape] filled with [color] on transparent. */
    fun renderContainer(
        shape: String,
        widthPx: Int,
        heightPx: Int,
        color: Int,
    ): Bitmap? {
        if (widthPx <= 0 || heightPx <= 0) return null
        return runCatching {
            val bmp = Bitmap.createBitmap(
                widthPx, heightPx, Bitmap.Config.ARGB_8888,
            )
            val canvas = Canvas(bmp)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = color
                style = Paint.Style.FILL
            }
            canvas.drawPath(
                containerPath(shape, widthPx.toFloat(), heightPx.toFloat()),
                paint,
            )
            bmp
        }.getOrNull()
    }

    /**
     * Sticker silhouette: [shape] filled with [color], drawn at
     * [contentScale] and centered so the cutout art (drawn full-bleed
     * on top) leaks past its edges. Optional fully-blurred halo
     * ([blurFraction] of size, NORMAL) for a soft overlay glow — the
     * content scale must leave room: extremes (1-scale)/2..(1+scale)/2
     * plus blur must stay inside [0,1] (2x4: 0.78 + 0.10 fits).
     * [angleDeg] rotates the shape around its center — the frames of
     * the launcher-driven flip rotation.
     */
    fun renderSilhouette(
        shape: String,
        sizePx: Int,
        color: Int,
        angleDeg: Float = 0f,
        blurFraction: Float = 0f,
        contentScale: Float = 0.7f,
    ): Bitmap? {
        if (sizePx <= 0) return null
        return runCatching {
            val bmp = Bitmap.createBitmap(
                sizePx, sizePx, Bitmap.Config.ARGB_8888,
            )
            val canvas = Canvas(bmp)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = color
                style = Paint.Style.FILL
                if (blurFraction > 0f) {
                    maskFilter = android.graphics.BlurMaskFilter(
                        sizePx * blurFraction,
                        android.graphics.BlurMaskFilter.Blur.NORMAL,
                    )
                }
            }
            val path = containerPath(shape, sizePx.toFloat(), sizePx.toFloat())
            val c = sizePx / 2f
            val m = Matrix().apply {
                setScale(contentScale, contentScale, c, c)
                postRotate(angleDeg, c, c)
            }
            path.transform(m)
            canvas.drawPath(path, paint)
            bmp
        }.getOrNull()
    }

    /**
     * Rotation frames for the flipper: [frames] silhouettes evenly
     * spaced over a full turn (8 = 45° steps). Small bitmaps — flat
     * color upscales cleanly, keeping the binder transaction light.
     */
    fun renderSilhouetteFrames(
        shape: String,
        sizePx: Int,
        color: Int,
        frames: Int,
        blurFraction: Float = 0f,
        contentScale: Float = 0.7f,
    ): List<Bitmap> {
        if (frames <= 0) return emptyList()
        val out = ArrayList<Bitmap>(frames)
        for (i in 0 until frames) {
            renderSilhouette(
                shape, sizePx, color, i * 360f / frames,
                blurFraction, contentScale,
            )?.let { out.add(it) }
        }
        return out
    }

    /**
     * Widget backdrop: [shape] container in [color] (0xAARRGGBB, same
     * int Dart passes), sized from the widget's real options. Rendered
     * at half scale — flat color upscales cleanly and the binder
     * transaction stays small next to the sticker bitmaps. Null when
     * [color] is 0 (no color pushed yet), so the backdrop stays gone.
     */
    fun renderWidgetBg(
        context: Context,
        mgr: AppWidgetManager,
        widgetId: Int,
        color: Int,
        shape: String,
    ): Bitmap? {
        if (color == 0) return null
        val density = context.resources.displayMetrics.density
        val opts = mgr.getAppWidgetOptions(widgetId)
        val wDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0)
        val hDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
        val wPx = ((if (wDp > 0) wDp * density else 256f).toInt()) / 2
        val hPx = ((if (hDp > 0) hDp * density else 128f).toInt()) / 2
        return renderContainer(shape, wPx, hPx, color)
    }
}
