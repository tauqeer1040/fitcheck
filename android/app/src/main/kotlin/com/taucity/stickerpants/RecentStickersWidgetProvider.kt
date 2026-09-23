package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x5 homescreen widget: transparent — the user's three most recent
 * cutouts, each floating over its own static tinted silhouette (70%,
 * centered, so the art leaks past its edges). Rotation lives on the
 * 2x3 widget only: three flippers would triple the binder payload for
 * little gain. Paths from Dart via home_widget (keys sticker_0..2,
 * newest first); shapes from sticker_N_shape; tints from
 * sticker_N_color. Whole widget opens the app.
 */
class RecentStickersWidgetProvider : HomeWidgetProvider() {

    /// 15 frames × 1s flips = 24° steps, 15s turn per sticker. Coarser
    /// than the 2x3 minute-hand (three flippers share the budget);
    /// 128px frames for edge clarity.
    private val frameCount = 15
    private val framePx = 128

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
                val quad = arrayOf("clamshell", "semicircle")
                artIds.forEachIndexed { index, viewId ->
                    val path = widgetData.getString("sticker_$index", null)
                    // The sticker's OWN homescreen shape (not the cycling
                    // alternation): silhouette matches the grid cell.
                    val shape = WidgetShapes.resolveStickerShape(
                        widgetData,
                        "sticker_${index}_shapeIdx",
                        "sticker_${index}_shape",
                        quad[index % quad.size],
                    )
                    val color = WidgetShapes.colorInt(
                        widgetData,
                        "sticker_${index}_color",
                        Color.parseColor("#FF606060"),
                    )
                    val art = path?.takeIf { it.isNotEmpty() }
                        ?.let { WidgetBitmaps.decodeArt(it) }
                    if (art != null) {
                        // Blurred, upsized halo (2x5 only): soft overlay
                        // glow behind each sticker.
                        val frames = WidgetShapes.renderSilhouetteFrames(
                            shape, framePx, color, frameCount,
                            0.10f, 0.78f,
                        )
                        removeAllViews(shapeIds[index])
                        for (bmp in frames) {
                            val frame = RemoteViews(
                                context.packageName,
                                R.layout.widget_spin_frame,
                            )
                            frame.setImageViewBitmap(R.id.widget_frame, bmp)
                            addView(shapeIds[index], frame)
                        }
                        setViewVisibility(
                            shapeIds[index], android.view.View.VISIBLE,
                        )
                        setViewVisibility(viewId, android.view.View.VISIBLE)
                        setImageViewBitmap(viewId, art)
                    } else {
                        setViewVisibility(
                            shapeIds[index], android.view.View.INVISIBLE,
                        )
                        setViewVisibility(viewId, android.view.View.INVISIBLE)
                    }
                }
                val funny = widgetData.getString("funny_line", null)
                val funnySp = WidgetShapes.prefsFloat(
                    widgetData, "funny_text_sp", 17f,
                )
                if (!funny.isNullOrEmpty()) {
                    setTextViewTextSize(
                        R.id.widget_funny,
                        android.util.TypedValue.COMPLEX_UNIT_SP,
                        funnySp,
                    )
                    setTextViewText(R.id.widget_funny, funny)
                    // Same rule as the 2x3 widget: caption starts at the left
                    // edge and only centres once it has to wrap. A remote
                    // view can't measure itself, so the rule is resolved here
                    // and shipped as an int. This caption sits inside the
                    // layout's 8dp padding, not 10dp margins.
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
                    setViewVisibility(
                        R.id.widget_funny, android.view.View.VISIBLE,
                    )
                } else {
                    setViewVisibility(
                        R.id.widget_funny, android.view.View.GONE,
                    )
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
            }
        }
    }
}
