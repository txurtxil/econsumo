package com.example.rebuild_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class EconsumoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        actualizarTodos(context, appWidgetManager, appWidgetIds)
    }

    companion object {
        private const val PREFS_NAME = "econsumo_widget_prefs"

        fun actualizarTodos(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetIds: IntArray
        ) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val fechas = prefs.getString("fechas", "Sin sincronizar") ?: "Sin sincronizar"
            val euros = prefs.getString("euros", "-- €") ?: "-- €"
            val kwh = prefs.getString("kwh", "-- kWh") ?: "-- kWh"
            val prediccion = prefs.getString("prediccion", "") ?: ""

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent().setClassName(context.packageName, "com.example.rebuild_app.MainActivity")
            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP

            for (id in appWidgetIds) {
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    id,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val views = RemoteViews(context.packageName, R.layout.widget_econsumo)
                views.setTextViewText(R.id.widget_fechas, fechas)
                views.setTextViewText(R.id.widget_euros, euros)
                views.setTextViewText(R.id.widget_kwh, kwh)
                views.setTextViewText(R.id.widget_prediccion, prediccion)
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
                appWidgetManager.updateAppWidget(id, views)
            }
        }
    }
}
