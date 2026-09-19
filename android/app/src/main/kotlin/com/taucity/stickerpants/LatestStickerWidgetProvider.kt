package com.taucity.stickerpants

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 2x2 homescreen widget: the single latest sticker, centered. Path from
 * home_widget key sticker_0 (newest). Whole widget opens the app.
 */
class LatestStickerWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
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
                val bmp = path?.takeIf { it.isNotEmpty() }
                    ?.let { runCatching { BitmapFactory.decodeFile(it) }.getOrNull() }
                if (bmp != null) {
                    setViewVisibility(R.id.widget_sticker_latest, android.view.View.VISIBLE)
                    setImageViewBitmap(R.id.widget_sticker_latest, bmp)
                    setViewVisibility(R.id.widget_empty, android.view.View.GONE)
                } else {
                    setViewVisibility(R.id.widget_sticker_latest, android.view.View.INVISIBLE)
                    setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
