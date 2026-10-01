package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x5 homescreen widget: transparent — three stickers, each floating
 * over its own tinted silhouette glow (blurred, so it reads as a soft
 * drop shadow rather than a plate). Both the art and the silhouettes
 * come from [WidgetRotation]: the pool head plus the two behind it, and
 * the head's roast as the caption. Whole widget opens the app.
 *
 * The silhouettes step through pre-rendered rotation frames (15 × 1s
 * flips) on a ViewFlipper, so the shadows are never static.
 */
class RecentStickersWidgetProvider : HomeWidgetProvider() {

    /// 15 frames × 1s flips = 24° steps, 15s turn per sticker. Coarser
    /// than the 2x3 minute-hand (three flippers share the budget);
    /// 128px frames for edge clarity.
    private val frameCount = 15
    private val framePx = 128

    /// Glow radius as a fraction of the cell. Small on purpose: the
    /// kernel is fitted inside the bitmap (WidgetShapes.BLR_FIT_ROOM),
    /// so a bigger radius would shrink the silhouette, not thicken it.
    private val glow = 0.055f

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
                val frame = WidgetRotation.frame(widgetData, 3)
                val funny = frame.caption
                val funnySp = WidgetShapes.prefsFloat(
                    widgetData, "funny_text_sp", 17f,
                )
                val opts = appWidgetManager.getAppWidgetOptions(widgetId)
                val sizeTag = "${opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0)}" +
                    "x${opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)}"
                val sig = WidgetRotation.signature(frame, funnySp, sizeTag)
                val renderKey = "recent-$widgetId"
                // Seven of the eight 30-minute ticks in an image slot
                // land on the frame already on screen. Redrawing those
                // would re-ship 45 silhouette bitmaps for nothing.
                if (WidgetRotation.alreadyRendered(context, renderKey, sig)) {
                    return@runCatching
                }

                val views = RemoteViews(
                    context.packageName,
                    R.layout.widget_recent_stickers_layout,
                ).apply {
                    val launch = HomeWidgetLaunchIntent.getActivity(
                        context,
                        MainActivity::class.java,
                    )
                    setOnClickPendingIntent(R.id.widget_container, launch)

                    val shapeIds = intArrayOf(
                        R.id.widget_spin_0,
                        R.id.widget_spin_1,
                        R.id.widget_spin_2,
                    )
                    val artIds = intArrayOf(
                        R.id.widget_sticker_0,
                        R.id.widget_sticker_1,
                        R.id.widget_sticker_2,
                    )
                    frame.cells.forEachIndexed { index, cell ->
                        if (cell.isEmpty) {
                            setViewVisibility(shapeIds[index], View.INVISIBLE)
                            setViewVisibility(artIds[index], View.INVISIBLE)
                            return@forEachIndexed
                        }
                        val art = WidgetBitmaps.decodeArt(cell.path)
                        if (art == null) {
                            setViewVisibility(shapeIds[index], View.INVISIBLE)
                            setViewVisibility(artIds[index], View.INVISIBLE)
                            return@forEachIndexed
                        }
                        // Blurred halo behind each sticker. contentScale
                        // 1.0 asks for a full-cell silhouette; the
                        // shrink that keeps the glow inside the bitmap
                        // is applied inside renderSilhouette.
                        val frames = WidgetShapes.renderSilhouetteFrames(
                            cell.shape, framePx, cell.color, frameCount,
                            glow, 1.0f,
                        )
                        removeAllViews(shapeIds[index])
                        for (bmp in frames) {
                            val flip = RemoteViews(
                                context.packageName,
                                R.layout.widget_spin_frame,
                            )
                            flip.setImageViewBitmap(R.id.widget_frame, bmp)
                            addView(shapeIds[index], flip)
                        }
                        setViewVisibility(shapeIds[index], View.VISIBLE)
                        setViewVisibility(artIds[index], View.VISIBLE)
                        setImageViewBitmap(artIds[index], art)
                    }

                    if (funny.isNotEmpty()) {
                        setTextViewTextSize(
                            R.id.widget_funny,
                            android.util.TypedValue.COMPLEX_UNIT_SP,
                            funnySp,
                        )
                        setTextViewText(R.id.widget_funny, funny)
                        // Centred caption: a remote view can't measure
                        // itself, so the rule is resolved here and shipped
                        // as an int. This caption sits inside the layout's
                        // 8dp padding, not 10dp margins.
                        setInt(
                            R.id.widget_funny,
                            "setGravity",
                            WidgetShapes.captionGravity(
                                context,
                                appWidgetManager,
                                widgetId,
                                funny,
                                funnySp,
                                sideMarginDp = 8f,
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