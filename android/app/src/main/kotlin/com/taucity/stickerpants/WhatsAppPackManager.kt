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

/// Builds the user's sticker packs (512x512 WebP + tray icon + contents.json)
/// into filesDir/sticker_packs/ and launches WhatsApp's
/// com.whatsapp.intent.action.ENABLE_STICKER_PACK intent — the same flow the
/// official sample apps (github.com/WhatsApp/stickers) use.
///
/// WhatsApp requirements enforced here:
///   - stickers: exactly 512x512, WebP, <= 100KB, transparent background
///   - tray icon: 96x96, PNG, <= 50KB
///   - pack: 3..30 stickers (we pad with copies if the user has fewer)
///
/// Because of that 30 cap a larger library used to fall off a cliff — only
/// the newest 30 reached the tray and the rest were unreachable. So the
/// library is chunked into several packs instead. [StickerContentProvider]
/// has always served every pack listed in contents.json; only this builder
/// assumed there was just one.
object WhatsAppPackManager {

    const val PACK_ROOT_DIR = "sticker_packs"

    /// Telegram imports out of its own directory. They cannot share one: the
    /// staging step clears its target before writing, so a shared directory
    /// would make importing to Telegram delete the contents.json and tray
    /// icons the WhatsApp pack depends on.
    const val TELEGRAM_ROOT_DIR = "telegram_import"

    private const val PACK_PUBLISHER = StickerContentProvider.PACK_PUBLISHER

    /// Request code for WhatsApp's per-pack confirmation, so MainActivity can
    /// chain the next pack when one lands.
    const val REQUEST_ADD_PACK = 200

    private const val STICKER_EDGE = 512
    private const val TRAY_EDGE = 96
    private const val MIN_PACK = 3
    private const val MAX_PACK = 30
    private const val IMAGE_DATA_VERSION = "1"

    /// Pack ids still waiting for the user's confirmation.
    ///
    /// WhatsApp's ENABLE_STICKER_PACK is per-pack, so several packs are added
    /// by chaining the intents through onActivityResult rather than firing
    /// them all at once — which would stack N confirmation screens on top of
    /// each other and land the user somewhere unpredictable.
    private val pendingPackIds = ArrayDeque<String>()

    /// Paths of the source sticker images, sent from Dart. Every path is
    /// packed; the library is chunked into as many packs as it needs.
    fun addToWhatsApp(activity: Activity, sourcePaths: List<String>) {
        if (sourcePaths.isEmpty()) {
            toast(activity, "No stickers to add yet")
            return
        }
        try {
            val ids = buildPacks(activity, sourcePaths)
            pendingPackIds.clear()
            pendingPackIds.addAll(ids)
            nextPack(activity)
        } catch (e: Exception) {
            toast(activity, "Could not add stickers to WhatsApp")
        }
    }

    /// Launches the next pending pack's confirmation, or returns when the run
    /// is finished.
    fun nextPack(activity: Activity) {
        val id = pendingPackIds.removeFirstOrNull() ?: return
        launchAddIntent(activity, id)
    }

    /// Drops any remaining packs, e.g. when the user dismissed a confirmation.
    fun clearPending() = pendingPackIds.clear()

    private fun packRoot(activity: Activity, dirName: String): File =
        File(activity.filesDir, dirName)

    /// Encodes [sourcePaths] to 512x512 transparent WebP inside
    /// filesDir/[dirName] and returns the files in submission order.
    ///
    /// Shared by the WhatsApp pack builder and the Telegram importer, which
    /// happen to want byte-compatible assets: both demand a transparent
    /// 512x512 WebP, and WhatsApp's 100KB ceiling is the stricter of the two
    /// (Telegram allows 512KB), so one encode satisfies both.
    ///
    /// Clears its target directory first, which is why each platform gets its
    /// own [dirName] — see [TELEGRAM_ROOT_DIR].
    fun stageStickerFiles(
        activity: Activity,
        sourcePaths: List<String>,
        dirName: String,
    ): List<File> {
        val root = packRoot(activity, dirName)
        root.mkdirs()
        root.listFiles()?.forEach { it.delete() }

        val files = mutableListOf<File>()
        sourcePaths.forEachIndexed { index, path ->
            val webp = encodeStickerWebp(path, STICKER_EDGE) ?: return@forEachIndexed
            val file = File(root, "s_%03d.webp".format(index))
            file.writeBytes(webp)
            files.add(file)
        }
        return files
    }

    /// Decodes each source image, letterboxes onto a transparent 512x512
    /// canvas, encodes WebP, and writes contents.json for EVERY pack. Runs on
    /// the caller's thread — Dart awaits the method-channel result, so
    /// blocking the platform thread here just shows the spinner until ready.
    ///
    /// Returns the pack ids in order, oldest stickers first, so the chain adds
    /// the first chunk before the overflow.
    private fun buildPacks(activity: Activity, sourcePaths: List<String>): List<String> {
        val files = stageStickerFiles(activity, sourcePaths, PACK_ROOT_DIR)
        if (files.isEmpty()) {
            throw IllegalStateException("No usable sticker files")
        }

        val root = packRoot(activity, PACK_ROOT_DIR)
        val packs = JSONArray()
        val packIds = mutableListOf<String>()
        val emojiPool = listOf("👗", "✨", "🔥", "💕", "😄", "👕", "🎉", "💅")

        files.chunked(MAX_PACK).forEachIndexed { packIndex, chunk ->
            // WhatsApp rejects a pack under MIN_PACK stickers, so a short
            // final chunk is padded by repeating its own last sticker.
            val padded = chunk.toMutableList()
            while (padded.size < MIN_PACK) padded.add(chunk.last())

            val stickers = JSONArray()
            padded.forEachIndexed { index, file ->
                stickers.put(
                    JSONObject()
                        .put("image_file", file.name)
                        .put("emojis", JSONArray().put(emojiPool[index % emojiPool.size]))
                        .put(
                            "accessibility_text",
                            "Outfit sticker ${index + 1} from FitCheck"
                        )
                )
            }

            // Each pack gets its own tray icon, and it shows THIS pack's first
            // sticker — a shared tray_icon.png would make every pack in the
            // tray look alike.
            val trayName = StickerContentProvider.trayImageFile(packIndex)
            writeTrayIcon(File(root, trayName), padded.first().absolutePath)

            val id = StickerContentProvider.packIdentifier(packIndex)
            packs.put(
                JSONObject()
                    .put("identifier", id)
                    .put("name", StickerContentProvider.packName(packIndex))
                    .put("publisher", PACK_PUBLISHER)
                    .put("tray_image_file", trayName)
                    .put("image_data_version", IMAGE_DATA_VERSION)
                    .put("avoid_cache", false)
                    .put("animated_sticker_pack", false)
                    .put("stickers", stickers)
            )
            packIds.add(id)
        }

        File(root, "contents.json")
            .writeText(JSONObject().put("sticker_packs", packs).toString())
        return packIds
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

    /// 96x96 tray icon on a rounded, colored square so it reads at tray size,
    /// with [sourcePath] (this pack's first sticker) drawn inside it.
    private fun writeTrayIcon(outFile: File, sourcePath: String) {
        val size = TRAY_EDGE
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFC1121F.toInt()
        }
        canvas.drawRoundRect(
            RectF(0f, 0f, size.toFloat(), size.toFloat()), 20f, 20f, bg
        )
        decodeScaled(sourcePath, size)?.let { src ->
            val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
            val dest = RectF(12f, 12f, (size - 12).toFloat(), (size - 12).toFloat())
            canvas.drawBitmap(src, null, dest, paint)
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
    private fun launchAddIntent(activity: Activity, packId: String) {
        val consumerInstalled = isInstalled(activity, "com.whatsapp")
        val smbInstalled = isInstalled(activity, "com.whatsapp.w4b")
        if (!consumerInstalled && !smbInstalled) {
            clearPending()
            toast(activity, "Install WhatsApp to add your stickers")
            return
        }
        val intent = Intent().apply {
            action = "com.whatsapp.intent.action.ENABLE_STICKER_PACK"
            putExtra("sticker_pack_id", packId)
            putExtra("sticker_pack_authority", StickerContentProvider.CONTENT_PROVIDER_AUTHORITY)
            putExtra("sticker_pack_name", StickerContentProvider.PACK_NAME)
        }
        try {
            // Try consumer first, fall back to business, else chooser.
            when {
                consumerInstalled -> intent.setPackage("com.whatsapp")
                smbInstalled -> intent.setPackage("com.whatsapp.w4b")
            }
            activity.startActivityForResult(intent, REQUEST_ADD_PACK)
        } catch (e: ActivityNotFoundException) {
            try {
                activity.startActivity(Intent.createChooser(intent, "Add to WhatsApp"))
            } catch (e2: ActivityNotFoundException) {
                clearPending()
                toast(activity, "Could not open WhatsApp")
            }
        }
    }

    fun isInstalled(activity: Activity, packageName: String): Boolean {
        return try {
            activity.packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun toast(activity: Activity, message: String) {
        android.widget.Toast.makeText(activity, message, android.widget.Toast.LENGTH_SHORT).show()
    }

    /// Build.VERSION alias so encodeWebp can stay terse.
    private object Build2 {
        val SDK_INT = android.os.Build.VERSION.SDK_INT
    }
}
