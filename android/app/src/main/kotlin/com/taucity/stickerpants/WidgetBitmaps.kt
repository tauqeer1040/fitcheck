package com.taucity.stickerpants

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/**
 * Widget bitmap pipeline: sticker PNGs are full-resolution files, far too
 * big for a RemoteViews binder transaction (~1MB limit — oversized bitmaps
 * fail silently and the widget shows stale/empty cells). Decode sampled
 * down to widget size, then clip to an M3 shape (RemoteViews has no
 * CardView/clip support).
 *
 * Shapes: 2x3 widget alternates arch/gem per save; 2x5 cells cycle
 * clamshell/semicircle. Shape names arrive from Dart (sticker_N_shape).
 */
object WidgetBitmaps {

    fun decodeCard(
        context: Context,
        path: String,
        shape: String = "rounded",
        maxSizePx: Int = 512,
    ): Bitmap? {
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val rawW = bounds.outWidth
            val rawH = bounds.outHeight
            if (rawW <= 0 || rawH <= 0) return null
            var sample = 1
            while ((rawW / sample) > maxSizePx || (rawH / sample) > maxSizePx) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bmp = BitmapFactory.decodeFile(path, opts) ?: return null
            val density = context.resources.displayMetrics.density
            val out = clipShape(bmp, shape, density)
            if (out != bmp) bmp.recycle()
            out
        }.getOrNull()
    }

    /**
     * Cutout art, sampled down but NOT clipped: the silhouette is a
     * separate view beneath it now, so the art keeps its own alpha
     * edges and overflows the shape.
     */
    fun decodeArt(path: String, maxSizePx: Int = 512): Bitmap? {
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val rawW = bounds.outWidth
            val rawH = bounds.outHeight
            if (rawW <= 0 || rawH <= 0) return null
            var sample = 1
            while ((rawW / sample) > maxSizePx || (rawH / sample) > maxSizePx) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeFile(path, opts)
        }.getOrNull()
    }

    private fun clipShape(src: Bitmap, shape: String, density: Float): Bitmap {
        val w = src.width.toFloat()
        val h = src.height.toFloat()
        val r = minOf(w, h) / 2f
        val path = Path().apply {
            when (shape) {
                // Arch: half-circle top, straight sides, flat bottom.
                "arch" -> {
                    val rad = minOf(w / 2f, h)
                    moveTo(0f, h)
                    lineTo(0f, rad)
                    arcTo(RectF(0f, 0f, w, rad * 2f), 180f, 180f)
                    lineTo(w, h)
                    close()
                }
                // Semicircle: flat top, half-circle bottom (smile).
                "semicircle" -> {
                    val rad = minOf(w / 2f, h)
                    moveTo(0f, 0f)
                    lineTo(w, 0f)
                    lineTo(w, h - rad)
                    arcTo(RectF(0f, h - rad * 2f, w, h), 0f, 180f)
                    close()
                }
                // Gem: diamond (vertices at edge midpoints).
                "gem" -> {
                    moveTo(w / 2f, 0f)
                    lineTo(w, h / 2f)
                    lineTo(w / 2f, h)
                    lineTo(0f, h / 2f)
                    close()
                }
                // Clamshell: big top radius, small bottom radius.
                "clamshell" -> {
                    val top = minOf(w, h) * 0.42f
                    val bottom = minOf(w, h) * 0.14f
                    addRoundRect(
                        RectF(0f, 0f, w, h),
                        floatArrayOf(top, top, top, top, bottom, bottom, bottom, bottom),
                        Path.Direction.CW,
                    )
                }
                // Fallback: M3 medium 20dp rounded rect.
                else -> {
                    val rad = 20f * density
                    addRoundRect(RectF(0f, 0f, w, h), rad, rad, Path.Direction.CW)
                }
            }
        }
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.save()
        canvas.clipPath(path)
        canvas.drawBitmap(src, 0f, 0f, Paint(Paint.ANTI_ALIAS_FLAG))
        canvas.restore()
        return out
    }
}
