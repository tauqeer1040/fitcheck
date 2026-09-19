package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x4 homescreen widget: the user's three most recent stickers side by
 * side. Paths are written from Dart via home_widget (keys sticker_0..2,
 * newest first). Whole widget opens the app.
 */
class RecentStickersWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(
                context.packageName,
                R.layout.widget_recent_stickers_layout,
            ).apply {
                val launch = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                )
                setOnClickPendingIntent(R.id.widget_container, launch)

                val ids = intArrayOf(
                    R.id.widget_sticker_0,
                    R.id.widget_sticker_1,
                    R.id.widget_sticker_2,
                )
                ids.forEachIndexed { index, viewId ->
                    val path = widgetData.getString("sticker_$index", null)
                    val bmp = path?.takeIf { it.isNotEmpty() }
                        ?.let { runCatching { BitmapFactory.decodeFile(it) }.getOrNull() }
                    if (bmp != null) {
                        setViewVisibility(viewId, android.view.View.VISIBLE)
                        setImageViewBitmap(viewId, bmp)
                    } else {
                        setViewVisibility(viewId, android.view.View.INVISIBLE)
                    }
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
