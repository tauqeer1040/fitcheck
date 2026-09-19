package com.taucity.stickerpants

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.UriMatcher
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.content.res.AssetFileDescriptor
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/// Serves the FitCheck sticker pack to WhatsApp via the official third-party
/// sticker API (github.com/WhatsApp/stickers), mirroring the sample
/// [StickerContentProvider] contract exactly:
///
///   <authority>/metadata                 → all packs
///   <authority>/metadata/<pack_id>       → one pack
///   <authority>/stickers/<pack_id>       → sticker list (name, emoji, a11y)
///   <authority>/stickers_asset/<pack_id>/<file> → sticker/tray bytes
///
/// Unlike the sample (which reads APK assets), the pack is generated at
/// runtime by [WhatsAppPackManager] into filesDir/sticker_packs/ —
/// contents.json + 512x512 WebP stickers + 96x96 tray PNG — right before
/// the add-to-WhatsApp intent fires, so the user's latest stickers ship.
class StickerContentProvider : ContentProvider() {

    companion object {
        // Do not change these — WhatsApp reads by these exact names.
        private const val STICKER_PACK_IDENTIFIER_IN_QUERY = "sticker_pack_identifier"
        private const val STICKER_PACK_NAME_IN_QUERY = "sticker_pack_name"
        private const val STICKER_PACK_PUBLISHER_IN_QUERY = "sticker_pack_publisher"
        private const val STICKER_PACK_ICON_IN_QUERY = "sticker_pack_icon"
        private const val ANDROID_APP_DOWNLOAD_LINK_IN_QUERY = "android_play_store_link"
        private const val IOS_APP_DOWNLOAD_LINK_IN_QUERY = "ios_app_download_link"
        private const val PUBLISHER_EMAIL = "sticker_pack_publisher_email"
        private const val PUBLISHER_WEBSITE = "sticker_pack_publisher_website"
        private const val PRIVACY_POLICY_WEBSITE = "sticker_pack_privacy_policy_website"
        private const val LICENSE_AGREEMENT_WEBSITE = "sticker_pack_license_agreement_website"
        private const val IMAGE_DATA_VERSION = "image_data_version"
        private const val AVOID_CACHE = "whatsapp_will_not_cache_stickers"
        private const val ANIMATED_STICKER_PACK = "animated_sticker_pack"
        private const val STICKER_FILE_NAME_IN_QUERY = "sticker_file_name"
        private const val STICKER_FILE_EMOJI_IN_QUERY = "sticker_emoji"
        private const val STICKER_FILE_ACCESSIBILITY_TEXT_IN_QUERY = "sticker_accessibility_text"

        const val CONTENT_PROVIDER_AUTHORITY =
            "com.taucity.stickerpants.stickercontentprovider"

        const val PACK_IDENTIFIER = "stickerpants_pack"
        const val PACK_NAME = "My StickerPants Stickers"
        const val PACK_PUBLISHER = "StickerPants"
        const val TRAY_IMAGE_FILE = "tray_icon.png"

        private const val METADATA = "metadata"
        private const val METADATA_CODE = 1
        private const val METADATA_CODE_FOR_SINGLE_PACK = 2
        private const val STICKERS = "stickers"
        private const val STICKERS_CODE = 3
        private const val STICKERS_ASSET = "stickers_asset"
        private const val STICKERS_ASSET_CODE = 4
        private const val STICKER_PACK_TRAY_ICON_CODE = 5
    }

    private val matcher = UriMatcher(UriMatcher.NO_MATCH)

    /// filesDir/sticker_packs — WhatsAppPackManager's output directory.
    private fun packRoot(context: Context): File =
        File(context.filesDir, WhatsAppPackManager.PACK_ROOT_DIR)

    private fun contentsFile(context: Context): File =
        File(packRoot(context), "contents.json")

    private fun readContents(context: Context): JSONObject =
        JSONObject(contentsFile(context).readText())

    override fun onCreate(): Boolean {
        val authority = CONTENT_PROVIDER_AUTHORITY
        if (!authority.startsWith(requireContext().packageName)) {
            throw IllegalStateException(
                "authority ($authority) must start with package name ${requireContext().packageName}"
            )
        }
        matcher.addURI(authority, METADATA, METADATA_CODE)
        matcher.addURI(authority, "$METADATA/*", METADATA_CODE_FOR_SINGLE_PACK)
        matcher.addURI(authority, "$STICKERS/*", STICKERS_CODE)
        // Note: unlike the sample we do NOT register per-file asset URIs at
        // startup — the pack is dynamic. openAssetFile validates the file
        // against contents.json on every fetch instead.
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        return when (matcher.match(uri)) {
            METADATA_CODE -> packCursor(uri, null)
            METADATA_CODE_FOR_SINGLE_PACK -> packCursor(uri, uri.lastPathSegment)
            STICKERS_CODE -> stickersCursor(uri, uri.lastPathSegment ?: return null)
            else -> throw IllegalArgumentException("Unknown URI: $uri")
        }
    }

    private fun packCursor(uri: Uri, wantedId: String?): Cursor {
        val cursor = MatrixCursor(
            arrayOf(
                STICKER_PACK_IDENTIFIER_IN_QUERY,
                STICKER_PACK_NAME_IN_QUERY,
                STICKER_PACK_PUBLISHER_IN_QUERY,
                STICKER_PACK_ICON_IN_QUERY,
                ANDROID_APP_DOWNLOAD_LINK_IN_QUERY,
                IOS_APP_DOWNLOAD_LINK_IN_QUERY,
                PUBLISHER_EMAIL,
                PUBLISHER_WEBSITE,
                PRIVACY_POLICY_WEBSITE,
                LICENSE_AGREEMENT_WEBSITE,
                IMAGE_DATA_VERSION,
                AVOID_CACHE,
                ANIMATED_STICKER_PACK,
            )
        )
        try {
            val packs = readContents(requireContext()).getJSONArray("sticker_packs")
            for (i in 0 until packs.length()) {
                val pack = packs.getJSONObject(i)
                val id = pack.getString("identifier")
                if (wantedId != null && id != wantedId) continue
                cursor.addRow(
                    arrayOf(
                        id,
                        pack.getString("name"),
                        pack.getString("publisher"),
                        pack.getString("tray_image_file"),
                        pack.optString("android_play_store_link", ""),
                        pack.optString("ios_app_store_link", ""),
                        pack.optString("publisher_email", ""),
                        pack.optString("publisher_website", ""),
                        pack.optString("privacy_policy_website", ""),
                        pack.optString("license_agreement_website", ""),
                        pack.getString("image_data_version"),
                        0, // avoid_cache: WhatsApp caches; version bump invalidates
                        pack.optBoolean("animated_sticker_pack", false),
                    )
                )
            }
        } catch (e: Exception) {
            // No pack built yet — return the empty cursor; WhatsApp shows
            // a validation error only if the user somehow got here.
        }
        cursor.setNotificationUri(requireContext().contentResolver, uri)
        return cursor
    }

    private fun stickersCursor(uri: Uri, packId: String): Cursor {
        val cursor = MatrixCursor(
            arrayOf(
                STICKER_FILE_NAME_IN_QUERY,
                STICKER_FILE_EMOJI_IN_QUERY,
                STICKER_FILE_ACCESSIBILITY_TEXT_IN_QUERY,
            )
        )
        try {
            val packs = readContents(requireContext()).getJSONArray("sticker_packs")
            for (i in 0 until packs.length()) {
                val pack = packs.getJSONObject(i)
                if (pack.getString("identifier") != packId) continue
                val stickers = pack.getJSONArray("stickers")
                for (j in 0 until stickers.length()) {
                    val sticker = stickers.getJSONObject(j)
                    cursor.addRow(
                        arrayOf(
                            sticker.getString("image_file"),
                            // Emojis are a comma-joined string, not JSON.
                            sticker.getJSONArray("emojis").join(","),
                            sticker.optString("accessibility_text", ""),
                        )
                    )
                }
            }
        } catch (e: Exception) {
            // Empty cursor on missing/corrupt pack file.
        }
        cursor.setNotificationUri(requireContext().contentResolver, uri)
        return cursor
    }

    override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor? {
        if (matcher.match(uri) != STICKERS_ASSET_CODE &&
            matcher.match(uri) != STICKER_PACK_TRAY_ICON_CODE
        ) return null
        val segments = uri.pathSegments
        if (segments.size != 3) {
            throw IllegalArgumentException("path segments should be 3, uri is: $uri")
        }
        val fileName = segments.last()
        val identifier = segments[segments.size - 2]
        if (fileName.contains("..") || fileName.contains('/') || fileName.contains('\\')) {
            return null
        }
        // Validate against contents.json: only serve files the pack lists.
        try {
            val packs = readContents(requireContext()).getJSONArray("sticker_packs")
            for (i in 0 until packs.length()) {
                val pack = packs.getJSONObject(i)
                if (pack.getString("identifier") != identifier) continue
                if (pack.getString("tray_image_file") == fileName) return openPackFile(fileName)
                val stickers = pack.getJSONArray("stickers")
                for (j in 0 until stickers.length()) {
                    if (stickers.getJSONObject(j).getString("image_file") == fileName) {
                        return openPackFile(fileName)
                    }
                }
                return null
            }
        } catch (e: Exception) {
            return null
        }
        return null
    }

    private fun openPackFile(fileName: String): AssetFileDescriptor? {
        val file = File(packRoot(requireContext()), fileName)
        if (!file.exists()) return null
        val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(pfd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun getType(uri: Uri): String? = when (matcher.match(uri)) {
        METADATA_CODE -> "vnd.android.cursor.dir/vnd.$CONTENT_PROVIDER_AUTHORITY.$METADATA"
        METADATA_CODE_FOR_SINGLE_PACK ->
            "vnd.android.cursor.item/vnd.$CONTENT_PROVIDER_AUTHORITY.$METADATA"
        STICKERS_CODE -> "vnd.android.cursor.dir/vnd.$CONTENT_PROVIDER_AUTHORITY.$STICKERS"
        STICKERS_ASSET_CODE -> "image/webp"
        STICKER_PACK_TRAY_ICON_CODE -> "image/png"
        else -> null
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("Not supported")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("Not supported")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("Not supported")
}
