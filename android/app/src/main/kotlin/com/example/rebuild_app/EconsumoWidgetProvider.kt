package com.example.rebuild_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
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
            val consejo = prefs.getString("consejo", "🔌 eConsumo") ?: "🔌 eConsumo"

            for (id in appWidgetIds) {
                val views = RemoteViews(context.packageName, R.layout.widget_econsumo)
                views.setTextViewText(R.id.widget_fechas, fechas)
                views.setTextViewText(R.id.widget_euros, euros)
                views.setTextViewText(R.id.widget_kwh, kwh)
                views.setTextViewText(R.id.widget_prediccion, prediccion)
                views.setTextViewText(R.id.widget_consejo, consejo)
                appWidgetManager.updateAppWidget(id, views)
            }
        }
    }
}
