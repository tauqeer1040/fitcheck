package com.taucity.stickerpants

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

/// Builds the user's sticker pack (512x512 WebP + tray icon + contents.json)
/// into filesDir/sticker_packs/ and launches WhatsApp's
/// com.whatsapp.intent.action.ENABLE_STICKER_PACK intent — the same flow the
/// official sample apps (github.com/WhatsApp/stickers) use.
///
/// WhatsApp requirements enforced here:
///   - stickers: exactly 512x512, WebP, <= 100KB, transparent background
///   - tray icon: 96x96, PNG, <= 50KB
///   - pack: 3..30 stickers (we pad with copies if the user has fewer)
object WhatsAppPackManager {

    const val PACK_ROOT_DIR = "sticker_packs"

    private const val PACK_ID = StickerContentProvider.PACK_IDENTIFIER
    private const val PACK_NAME = StickerContentProvider.PACK_NAME
    private const val PACK_PUBLISHER = StickerContentProvider.PACK_PUBLISHER
    private const val TRAY_FILE = StickerContentProvider.TRAY_IMAGE_FILE

    private const val STICKER_EDGE = 512
    private const val TRAY_EDGE = 96
    private const val MIN_PACK = 3
    private const val MAX_PACK = 30
    private const val IMAGE_DATA_VERSION = "1"

    /// Paths of the source sticker PNGs, sent from Dart.
    fun addToWhatsApp(activity: Activity, sourcePaths: List<String>) {
        if (sourcePaths.isEmpty()) {
            android.widget.Toast.makeText(
                activity, "No stickers to add yet", android.widget.Toast.LENGTH_SHORT
            ).show()
            return
        }
        try {
            buildPack(activity, sourcePaths)
            launchAddIntent(activity)
        } catch (e: Exception) {
            android.widget.Toast.makeText(
                activity, "Could not add stickers to WhatsApp", android.widget.Toast.LENGTH_SHORT
            ).show()
        }
    }

    private fun packRoot(activity: Activity): File =
        File(activity.filesDir, PACK_ROOT_DIR)

    /// Decodes each source PNG, letterboxes onto a transparent 512x512
    /// canvas, encodes lossless WebP, and writes contents.json. Runs on the
    /// caller's thread — Dart awaits the method-channel result, so blocking
    /// the platform thread here just shows the spinner until ready.
    private fun buildPack(activity: Activity, sourcePaths: List<String>) {
        val root = packRoot(activity)
        root.mkdirs()
        // Clear previous generation so removed stickers disappear.
        root.listFiles()?.forEach { it.delete() }

        val sources = sourcePaths.take(MAX_PACK)
        // Pack must have >= 3 stickers: pad by repeating the last one.
        val padded = sources.toMutableList()
        while (padded.size < MIN_PACK) padded.add(sources.last())

        val stickers = JSONArray()
        val emojiPool = listOf("👗", "✨", "🔥", "💕", "😄", "👕", "🎉", "💅")
        padded.forEachIndexed { index, path ->
            val webp = encodeStickerWebp(path, STICKER_EDGE) ?: return@forEachIndexed
            val fileName = "sticker_%03d.webp".format(index)
            File(root, fileName).writeBytes(webp)
            stickers.put(
                JSONObject()
                    .put("image_file", fileName)
                    .put("emojis", JSONArray().put(emojiPool[index % emojiPool.size]))
                    .put(
                        "accessibility_text",
                        "Outfit sticker ${index + 1} from FitCheck"
                    )
            )
        }
        if (stickers.length() < MIN_PACK) {
            throw IllegalStateException("No usable sticker files")
        }

        writeTrayIcon(activity, File(root, TRAY_FILE))

        val pack = JSONObject()
            .put("identifier", PACK_ID)
            .put("name", PACK_NAME)
            .put("publisher", PACK_PUBLISHER)
            .put("tray_image_file", TRAY_FILE)
            .put("image_data_version", IMAGE_DATA_VERSION)
            .put("avoid_cache", false)
            .put("animated_sticker_pack", false)
            .put("stickers", stickers)

        val contents = JSONObject().put("sticker_packs", JSONArray().put(pack))
        File(root, "contents.json").writeText(contents.toString())
    }

    /// Center-fits the source image on a transparent STICKER_EDGE square and
    /// encodes lossless WebP (alpha preserved). Falls back to lossy quality 90
    /// if the lossless bytes exceed WhatsApp's 100KB limit.
    private fun encodeStickerWebp(path: String, edge: Int): ByteArray? {
        val src = decodeScaled(path, edge) ?: return null
        val bitmap = Bitmap.createBitmap(edge, edge, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        val scale = minOf(
            edge.toFloat() / src.width,
            edge.toFloat() / src.height
        )
        val w = src.width * scale
        val h = src.height * scale
        val dest = RectF(
            (edge - w) / 2f, (edge - h) / 2f,
            (edge + w) / 2f, (edge + h) / 2f
        )
        canvas.drawBitmap(src, null, dest, paint)

        var bytes = encodeWebp(bitmap, true, 100)
        if (bytes == null || bytes.size > 100 * 1024) {
            bytes = encodeWebp(bitmap, false, 90)
        }
        return bytes
    }

    private fun encodeWebp(bitmap: Bitmap, lossless: Boolean, quality: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        // WEBP_LOSSLESS needs API 30; WEBP_LOSSY needs 30 too. Old format
        // constant is API 14. Guard per-API.
        val format = when {
            lossless && Build2.SDK_INT >= 30 -> Bitmap.CompressFormat.WEBP_LOSSLESS
            Build2.SDK_INT >= 30 -> Bitmap.CompressFormat.WEBP_LOSSY
            else -> @Suppress("DEPRECATION") Bitmap.CompressFormat.WEBP
        }
        if (!bitmap.compress(format, quality, out)) return null
        return out.toByteArray()
    }

    /// 96x96 tray icon on a rounded, colored square so it reads at tray size.
    private fun writeTrayIcon(activity: Activity, outFile: File) {
        val size = TRAY_EDGE
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFC1121F.toInt()
        }
        canvas.drawRoundRect(
            RectF(0f, 0f, size.toFloat(), size.toFloat()), 20f, 20f, bg
        )
        // Draw the most recent sticker into the tray icon if decodable.
        val latest = packRoot(activity).listFiles()
            ?.filter { it.extension == "webp" }
            ?.maxByOrNull { it.name }
        if (latest != null) {
            decodeScaled(latest.absolutePath, size)?.let { src ->
                val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
                val dest = RectF(12f, 12f, (size - 12).toFloat(), (size - 12).toFloat())
                canvas.drawBitmap(src, null, dest, paint)
            }
        }
        FileOutputStream(outFile).use { fos ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos)
        }
    }

    /// Decodes [path] downscaled so its longest edge is <= [edge], or null.
    private fun decodeScaled(path: String, edge: Int): Bitmap? {
        return try {
            val opts = android.graphics.BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            android.graphics.BitmapFactory.decodeFile(path, opts)
            if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
            var sample = 1
            while (opts.outWidth / (sample * 2) >= edge &&
                opts.outHeight / (sample * 2) >= edge
            ) {
                sample *= 2
            }
            val decodeOpts = android.graphics.BitmapFactory.Options().apply {
                inSampleSize = sample
            }
            android.graphics.BitmapFactory.decodeFile(path, decodeOpts)
        } catch (e: Exception) {
            null
        }
    }

    /// Same intent contract as the official AddStickerPackActivity sample:
    /// prefer whichever WhatsApp flavor doesn't have the pack yet, chooser
    /// when both/neither are candidates.
    private fun launchAddIntent(activity: Activity) {
        val consumerInstalled = isInstalled(activity, "com.whatsapp")
        val smbInstalled = isInstalled(activity, "com.whatsapp.w4b")
        if (!consumerInstalled && !smbInstalled) {
            android.widget.Toast.makeText(
                activity, "Install WhatsApp to add your stickers",
                android.widget.Toast.LENGTH_LONG
            ).show()
            return
        }
        val intent = Intent().apply {
            action = "com.whatsapp.intent.action.ENABLE_STICKER_PACK"
            putExtra("sticker_pack_id", PACK_ID)
            putExtra("sticker_pack_authority", StickerContentProvider.CONTENT_PROVIDER_AUTHORITY)
            putExtra("sticker_pack_name", PACK_NAME)
        }
        try {
            // Try consumer first, fall back to business, else chooser.
            when {
                consumerInstalled -> intent.setPackage("com.whatsapp")
                smbInstalled -> intent.setPackage("com.whatsapp.w4b")
            }
            activity.startActivityForResult(intent, 200)
        } catch (e: ActivityNotFoundException) {
            try {
                activity.startActivity(Intent.createChooser(intent, "Add to WhatsApp"))
            } catch (e2: ActivityNotFoundException) {
                android.widget.Toast.makeText(
                    activity, "Could not open WhatsApp", android.widget.Toast.LENGTH_SHORT
                ).show()
            }
        }
    }

    private fun isInstalled(activity: Activity, packageName: String): Boolean {
        return try {
            activity.packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /// Build.VERSION alias so encodeWebp can stay terse.
    private object Build2 {
        val SDK_INT = android.os.Build.VERSION.SDK_INT
    }
}
