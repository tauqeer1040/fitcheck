package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x3 homescreen widget: transparent — the pool's current sticker
 * floating over its tinted silhouette, with that sticker's roast as a
 * caption. Art, shape and text all come from [WidgetRotation], so this
 * widget advances on the same 4h clock as the 2x5 trio.
 *
 * The silhouette steps through pre-rendered rotation frames (60 × 1s
 * flips = one full turn per minute) on a ViewFlipper: no ticker, no
 * battery cost. Art stays static on top.
 */
class LatestStickerWidgetProvider : HomeWidgetProvider() {

    /// 60 frames × 1s flips = 6° steps, one full turn per minute:
    /// clock minute-hand sweep. 192px frames + 768px art for crisp
    /// edges at widget size (bitmaps ride shared memory).
    private val frameCount = 60
    private val framePx = 192
    private val artPx = 768

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            // A widget update must never kill the app: the receiver
            // crash takes the whole process down with it.
            runCatching {
                val frame = WidgetRotation.frame(widgetData, 1)
                val cell = frame.cells.first()
                val funny = frame.caption
                // Caption size from the debug slider (sp); Dart saves
                // a string, legacy doubles arrive as raw Long bits —
                // prefsFloat range-guards both to a sane default.
                val funnySp = WidgetShapes.prefsFloat(
                    widgetData, "funny_text_sp", 17f,
                )
                val opts = appWidgetManager.getAppWidgetOptions(widgetId)
                val sizeTag =
                    "${opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0)}" +
                        "x${opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)}"
                val sig = WidgetRotation.signature(frame, funnySp, sizeTag)
                val renderKey = "latest-$widgetId"
                // Same 30-minute tick as the 2x5: most land on the frame
                // already up, and 60 silhouette bitmaps is not a cheap
                // thing to re-ship.
                if (WidgetRotation.alreadyRendered(context, renderKey, sig)) {
                    return@runCatching
                }

                val art = if (cell.isEmpty) {
                    null
                } else {
                    WidgetBitmaps.decodeArt(cell.path, artPx)
                }
                val views = RemoteViews(
                    context.packageName,
                    R.layout.widget_latest_sticker_layout,
                ).apply {
                    val launch = HomeWidgetLaunchIntent.getActivity(
                        context,
                        MainActivity::class.java,
                    )
                    setOnClickPendingIntent(R.id.widget_container, launch)

                    if (art != null) {
                        // contentScale 1.0: the silhouette fills the
                        // widget box exactly as the grid cell does (the
                        // gallery passes shapeScale 1.0 to
                        // ShapedSticker), so the homescreen matches the
                        // in-app proportions instead of floating at 70%
                        // of the cutout.
                        val frames = WidgetShapes.renderSilhouetteFrames(
                            cell.shape, framePx, cell.color, frameCount,
                            contentScale = 1.0f,
                        )
                        removeAllViews(R.id.widget_spin)
                        for (bmp in frames) {
                            val flip = RemoteViews(
                                context.packageName,
                                R.layout.widget_spin_frame,
                            )
                            flip.setImageViewBitmap(R.id.widget_frame, bmp)
                            addView(R.id.widget_spin, flip)
                        }
                        setViewVisibility(R.id.widget_spin, View.VISIBLE)
                        setViewVisibility(
                            R.id.widget_sticker_latest, View.VISIBLE,
                        )
                        setImageViewBitmap(R.id.widget_sticker_latest, art)
                        setViewVisibility(R.id.widget_empty, View.GONE)
                    } else {
                        setViewVisibility(R.id.widget_spin, View.GONE)
                        setViewVisibility(
                            R.id.widget_sticker_latest, View.INVISIBLE,
                        )
                        setViewVisibility(R.id.widget_empty, View.VISIBLE)
                    }

                    if (art != null && funny.isNotEmpty()) {
                        setTextViewTextSize(
                            R.id.widget_funny,
                            android.util.TypedValue.COMPLEX_UNIT_SP,
                            funnySp,
                        )
                        setTextViewText(R.id.widget_funny, funny)
                        // Centred caption (see WidgetShapes
                        // .captionGravity): a remote view can't measure
                        // itself, so the rule is resolved here and
                        // shipped as an int.
                        setInt(
                            R.id.widget_funny,
                            "setGravity",
                            WidgetShapes.captionGravity(
                                context,
                                appWidgetManager,
                                widgetId,
                                funny,
                                funnySp,
                            ),
                        )
                        setViewVisibility(R.id.widget_funny, View.VISIBLE)
                    } else {
                        setViewVisibility(R.id.widget_funny, View.GONE)
                    }
                }
                appWidgetManager.updateAppWidget(widgetId, views)
                WidgetRotation.markRendered(context, renderKey, sig)
            }
        }
    }
}