package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x3 homescreen widget: transparent — the single latest cutout
 * floating over its tinted silhouette. The silhouette steps through 8
 * pre-rendered rotation frames (45° each, 1s apart) via the
 * launcher-driven ViewFlipper: the fullscreen rotation as a frozen
 * flip-book, with no ticker and no battery cost. Art stays static on
 * top. Path from home_widget key sticker_0 (newest); shape from
 * latest_shape; tint from sticker_0_color.
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
            val views = RemoteViews(
                context.packageName,
                R.layout.widget_latest_sticker_layout,
            ).apply {
                val launch = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                )
                setOnClickPendingIntent(R.id.widget_container, launch)

                val path = widgetData.getString("sticker_0", null)
                // The sticker's OWN homescreen shape (not the cycling
                // alternation): silhouette matches the grid cell.
                val shape = WidgetShapes.resolveStickerShape(
                    widgetData,
                    "sticker_0_shapeIdx",
                    "latest_shape",
                    "arch",
                )
                val color = WidgetShapes.colorInt(
                    widgetData,
                    "sticker_0_color",
                    Color.parseColor("#FF606060"),
                )

                val art = path?.takeIf { it.isNotEmpty() }
                    ?.let { WidgetBitmaps.decodeArt(it, artPx) }
                if (art != null) {
                    val frames = WidgetShapes.renderSilhouetteFrames(
                        shape, framePx, color, frameCount,
                    )
                    removeAllViews(R.id.widget_spin)
                    for (bmp in frames) {
                        val frame = RemoteViews(
                            context.packageName,
                            R.layout.widget_spin_frame,
                        )
                        frame.setImageViewBitmap(R.id.widget_frame, bmp)
                        addView(R.id.widget_spin, frame)
                    }
                    setViewVisibility(
                        R.id.widget_spin, android.view.View.VISIBLE,
                    )
                    setViewVisibility(
                        R.id.widget_sticker_latest, android.view.View.VISIBLE,
                    )
                    setImageViewBitmap(R.id.widget_sticker_latest, art)
                    setViewVisibility(R.id.widget_empty, android.view.View.GONE)
                    val funny = widgetData.getString("funny_line", null)
                    // Caption size from the debug slider (sp); Dart saves
                    // a string, legacy doubles arrive as raw Long bits —
                    // prefsFloat range-guards both to a sane default.
                    val funnySp = WidgetShapes.prefsFloat(
                        widgetData, "funny_text_sp", 17f,
                    )
                    if (!funny.isNullOrEmpty()) {
                        setTextViewTextSize(
                            R.id.widget_funny,
                            android.util.TypedValue.COMPLEX_UNIT_SP,
                            funnySp,
                        )
                        setTextViewText(
                            R.id.widget_funny, funny,
                        )
                        // Caption starts at the left edge and only centres
                        // once it has to wrap. A remote view can't measure
                        // itself, so the rule is resolved here and shipped
                        // as an int (see WidgetShapes.captionGravity).
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
                        setViewVisibility(
                            R.id.widget_funny, android.view.View.VISIBLE,
                        )
                    } else {
                        setViewVisibility(
                            R.id.widget_funny, android.view.View.GONE,
                        )
                    }
                } else {
                    setViewVisibility(R.id.widget_spin, android.view.View.GONE)
                    setViewVisibility(
                        R.id.widget_sticker_latest,
                        android.view.View.INVISIBLE,
                    )
                    setViewVisibility(
                        R.id.widget_empty, android.view.View.VISIBLE,
                    )
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
            }
        }
    }
}
