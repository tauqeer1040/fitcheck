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

    /**
     * Render-format tag, mixed into the [WidgetRotation] cache key.
     * Bump it whenever contentScale, framePx, frameCount or the glow
     * changes: the signature deliberately tracks only *content* (paths,
     * colors, caption, size), so without a version in the key a change
     * to how the silhouette is drawn ships new code that never repaints
     * an already-placed widget -- it just keeps serving cached frames.
     */
    private val RENDER_FORMAT = "v2"

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
                val renderKey = "latest-$RENDER_FORMAT-$widgetId"
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
                        // contentScale 0.7071 = 1/sqrt(2): the exact
                        // no-clipping ceiling for renderSilhouette.
                        //
                        // The shape is drawn into a SQUARE bitmap and
                        // spun, and rotating by theta grows its bounding
                        // box by |cos| + |sin| -- peaking at sqrt(2) on
                        // the diagonals. At scale 1.0 the bitmap edge
                        // therefore slices the corners off every angled
                        // frame (the original bug).
                        //
                        // widget_spin_frame is fitCenter, so the square
                        // bitmap maps onto the cell's SHORT side: apparent
                        // size == contentScale * cellHeight, and no higher
                        // value can render unclipped. 1/sqrt(2) is that
                        // limit, rounded down so float error cannot push
                        // it over.
                        //
                        // Going larger needs either per-frame sizing
                        // (scale each of the 60 frames by
                        // 1/(|cos|+|sin|) -- full size at the cardinals,
                        // 0.707 on the diagonals, but visibly breathing)
                        // or a taller cell. The 2x5 sits at 0.802 because
                        // its blur shrink happens to land there, which is
                        // why it still clips ~13% on the diagonals.
                        val frames = WidgetShapes.renderSilhouetteFrames(
                            cell.shape, framePx, cell.color, frameCount,
                            contentScale = 0.7071f,
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