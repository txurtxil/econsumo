package com.example.rebuild_app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val WIDGET_CHANNEL = "widget_channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "updateWidget") {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any?>
                val prefs = getSharedPreferences("econsumo_widget_prefs", Context.MODE_PRIVATE)
                prefs.edit()
                    .putString("fechas", args?.get("fechas") as? String ?: "")
                    .putString("euros", args?.get("euros") as? String ?: "")
                    .putString("kwh", args?.get("kwh") as? String ?: "")
                    .putString("prediccion", args?.get("prediccion") as? String ?: "")
                    .putString("consejo", args?.get("consejo") as? String ?: "")
                    .putString("grafica", args?.get("grafica") as? String ?: "")
                    .apply()

                val manager = AppWidgetManager.getInstance(applicationContext)
                val ids = manager.getAppWidgetIds(
                    ComponentName(applicationContext, EconsumoWidgetProvider::class.java)
                )
                if (ids.isNotEmpty()) {
                    EconsumoWidgetProvider.actualizarTodos(applicationContext, manager, ids)
                }
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
