package com.txurtxil.econsumo

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.widget.RemoteViews
import java.util.Calendar

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

        // Periodo tarifario 2.0TD (peninsula, L-V): valle 0-8, punta 10-14 y 18-22, resto llano.
        // Fines de semana: todo valle.
        private fun periodoActual(): Pair<String, Int> {
            val cal = Calendar.getInstance()
            val dow = cal.get(Calendar.DAY_OF_WEEK)
            val h = cal.get(Calendar.HOUR_OF_DAY)
            if (dow == Calendar.SATURDAY || dow == Calendar.SUNDAY) return Pair("VALLE", Color.parseColor("#4CAF50"))
            return when {
                h < 8 -> Pair("VALLE", Color.parseColor("#4CAF50"))
                (h in 10..13) || (h in 18..21) -> Pair("PUNTA", Color.parseColor("#F44336"))
                else -> Pair("LLANO", Color.parseColor("#FF9800"))
            }
        }

        private fun dibujarGrafica(datos: String, width: Int, height: Int): Bitmap {
            val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val barras = datos.split(";").mapNotNull {
                val p = it.split("|")
                if (p.size == 2) Pair(p[0], p[1].toDoubleOrNull() ?: 0.0) else null
            }
            if (barras.isEmpty()) return bmp

            val maxKwh = (barras.maxOf { it.second }).coerceAtLeast(0.1)
            val paintBar = Paint().apply { isAntiAlias = true; color = Color.parseColor("#00E5FF") }
            val paintTxt = Paint().apply { isAntiAlias = true; color = Color.parseColor("#B0BEC5"); textSize = height * 0.13f; textAlign = Paint.Align.CENTER }
            val paintVal = Paint().apply { isAntiAlias = true; color = Color.WHITE; textSize = height * 0.13f; textAlign = Paint.Align.CENTER }

            val labelSpace = height * 0.18f
            val valueSpace = height * 0.16f
            val chartH = height - labelSpace - valueSpace
            val slotW = width.toFloat() / barras.size
            val barW = slotW * 0.55f

            barras.forEachIndexed { i, par ->
                val fecha = par.first
                val kwh = par.second
                val cx = slotW * i + slotW / 2
                val barH = (kwh / maxKwh * chartH).toFloat().coerceAtLeast(3f)
                val top = valueSpace + (chartH - barH)
                canvas.drawRoundRect(cx - barW / 2, top, cx + barW / 2, valueSpace + chartH, 6f, 6f, paintBar)
                canvas.drawText(String.format("%.1f", kwh), cx, top - 4f, paintVal)
                val dia = fecha.split("/").firstOrNull() ?: fecha
                canvas.drawText(dia, cx, height - 4f, paintTxt)
            }
            return bmp
        }

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
            val grafica = prefs.getString("grafica", "") ?: ""

            val periodo = periodoActual()
            val periodoNombre = periodo.first
            val periodoColor = periodo.second

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent().setClassName(context.packageName, "com.txurtxil.econsumo.MainActivity")
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
                views.setTextViewText(R.id.widget_periodo, "Ahora: " + periodoNombre)
                views.setTextColor(R.id.widget_periodo, periodoColor)

                if (grafica.isNotEmpty()) {
                    val bmp = dibujarGrafica(grafica, 600, 220)
                    views.setImageViewBitmap(R.id.widget_grafica, bmp)
                }

                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
                appWidgetManager.updateAppWidget(id, views)
            }
        }
    }
}
