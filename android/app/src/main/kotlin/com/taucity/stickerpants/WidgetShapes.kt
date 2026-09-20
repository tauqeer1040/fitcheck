package com.taucity.stickerpants

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
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
}
