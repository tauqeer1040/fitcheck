package com.taucity.stickerpants

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.photopicker.EmbeddedPhotoPickerFeatureInfo
import android.widget.photopicker.EmbeddedPhotoPickerProviderFactory
import android.widget.photopicker.EmbeddedPhotoPickerSession
import androidx.photopicker.EmbeddedPhotoPickerView
import androidx.photopicker.ExperimentalPhotoPickerApi
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

const val EMBEDDED_PICKER_VIEW_TYPE = "fitcheck/embedded_picker_view"
const val EMBEDDED_PICKER_CHANNEL = "fitcheck/embedded_picker"

/**
 * Sink for picker events, wired by MainActivity to the shared
 * MethodChannel. Always invoked on the main thread.
 */
object EmbeddedPickerEvents {
    private val main = Handler(Looper.getMainLooper())
    var emit: ((method: String, args: Any?) -> Unit)? = null

    fun post(method: String, args: Any? = null) {
        main.post { emit?.invoke(method, args) }
    }
}

@OptIn(ExperimentalPhotoPickerApi::class)
class EmbeddedPickerViewFactory(
    private val activity: Activity,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    val views = mutableMapOf<Int, EmbeddedPickerPlatformView>()

    override fun create(
        context: Context,
        viewId: Int,
        args: Any?,
    ): PlatformView = EmbeddedPickerPlatformView(
        context,
        activity,
        args as? Map<String, *>,
    ).also { views[viewId] = it }
}

/** Deletes stale embedded picks (>24h) so the cache never grows. */
fun pruneCache(context: Context) {
    try {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        context.cacheDir.listFiles { f ->
            f.isFile && f.name.startsWith("embedded_") && f.lastModified() < cutoff
        }?.forEach {
            try {
                it.delete()
            } catch (_: Exception) {
            }
        }
    } catch (_: Exception) {
    }
}

/**
 * Hosts the Jetpack embedded photo picker. Single-select behavior is
 * enforced Dart-side: the first granted URI is copied to cache and
 * reported, so one tap picks with no Done confirmation.
 */
@OptIn(ExperimentalPhotoPickerApi::class)
class EmbeddedPickerPlatformView(
    context: Context,
    private val activity: Activity,
    args: Map<String, *>?,
) : PlatformView {
    private val container: View
    private val listener = PickerListener(context.applicationContext)

    /// Live session for expand/resize hints. Set on open, cleared on
    /// dispose; every call site guards with try/catch since framework
    /// methods vary across SDK extensions.
    var session: EmbeddedPhotoPickerSession? = null
        private set

    init {
        var view: View = View(context)
        try {
            // Brand-yellow accent (opaque, mid luminance per picker docs).
            val accent =
                (args?.get("accentColor") as? Number)?.toLong()
                    ?: 0xFFFFD60A
            val picker = EmbeddedPhotoPickerView(context)
            picker.layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            // Binds the system-side picker service; without this the
            // session refuses to open ("without a provider").
            picker.setProvider(EmbeddedPhotoPickerProviderFactory.create(context))
            picker.setEmbeddedPhotoPickerFeatureInfo(
                EmbeddedPhotoPickerFeatureInfo.Builder()
                    .setAccentColor(accent)
                    .setMaxSelectionLimit(1)
                    .setMimeTypes(listOf("image/*"))
                    .build(),
            )
            picker.addEmbeddedPhotoPickerStateChangeListener(listener)
            view = picker
        } catch (t: Throwable) {
            EmbeddedPickerEvents.post("onSessionError", t.message)
        }
        container = view
    }

    override fun getView(): View = container

    override fun dispose() {
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        session = null
        (container as? EmbeddedPhotoPickerView)
            ?.removeEmbeddedPhotoPickerStateChangeListener(listener)
    }

    fun notifyExpanded(expanded: Boolean) {
        try {
            session?.notifyPhotoPickerExpanded(expanded)
        } catch (_: Throwable) {
        }
    }

    private inner class PickerListener(
        private val appContext: Context,
    ) : EmbeddedPhotoPickerView.EmbeddedPhotoPickerStateChangeListener {
        override fun onSessionOpened(session: EmbeddedPhotoPickerSession) {
            this@EmbeddedPickerPlatformView.session = session
            pruneCache(appContext)
        }

        override fun onSessionError(throwable: Throwable) {
            EmbeddedPickerEvents.post("onSessionError", throwable.message)
        }

        override fun onUriPermissionGranted(uris: List<Uri>) {
            val first = uris.firstOrNull() ?: return
            Thread {
                try {
                    val out = File(
                        appContext.cacheDir,
                        "embedded_${System.currentTimeMillis()}.jpg",
                    )
                    appContext.contentResolver.openInputStream(first)?.use { ins ->
                        out.outputStream().use { outs -> ins.copyTo(outs) }
                    }
                    EmbeddedPickerEvents.post("onGranted", out.absolutePath)
                } catch (e: Exception) {
                    EmbeddedPickerEvents.post("onSessionError", e.message)
                }
            }.start()
        }

        override fun onUriPermissionRevoked(uris: List<Uri>) {}

        override fun onSelectionComplete() {
            EmbeddedPickerEvents.post("onSelectionComplete")
        }
    }
}

/** Registers the view factory + availability channel. Call once per engine. */
fun registerEmbeddedPicker(
    activity: Activity,
    flutterEngine: io.flutter.embedding.engine.FlutterEngine,
) {
    val messenger = flutterEngine.dartExecutor.binaryMessenger
    val factory = EmbeddedPickerViewFactory(activity)
    flutterEngine.platformViewsController.registry.registerViewFactory(
        EMBEDDED_PICKER_VIEW_TYPE,
        factory,
    )
    EmbeddedPickerEvents.emit = { method, args ->
        MethodChannel(messenger, EMBEDDED_PICKER_CHANNEL)
            .invokeMethod(method, args)
    }
    MethodChannel(messenger, EMBEDDED_PICKER_CHANNEL)
        .setMethodCallHandler { call, result ->
            when (call.method) {
                // Embedded picker needs Android 14+. The Jetpack session
                // reports finer failures (e.g. missing SDK extension)
                // via onSessionError at runtime.
                "isAvailable" ->
                    result.success(Build.VERSION.SDK_INT >= 34)
                // Tells the live session the host expanded/collapsed so
                // it can switch its peak/expanded layout instead of just
                // stretching pixels.
                "notifyExpanded" -> {
                    val expanded = call.argument<Boolean>("expanded") == true
                    try {
                        factory.views.values.forEach {
                            it.notifyExpanded(expanded)
                        }
                        result.success(true)
                    } catch (e: Throwable) {
                        result.error("EXPAND_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
}
