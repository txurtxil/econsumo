package com.example.rebuild_app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
            } else if (call.method == "saveCsv") {
                try {
                    val filename = call.argument<String>("filename") ?: "consumos.csv"
                    val content = call.argument<String>("content") ?: ""
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, filename)
                            put(MediaStore.Downloads.MIME_TYPE, "text/csv")
                            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                        }
                        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        if (uri != null) {
                            contentResolver.openOutputStream(uri)?.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                            result.success(uri.toString())
                        } else {
                            result.error("SAVE_FAIL", "No se pudo crear el fichero en Descargas", null)
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        val f = File(dir, filename)
                        f.writeText(content, Charsets.UTF_8)
                        result.success(f.absolutePath)
                    }
                } catch (e: Exception) {
                    result.error("SAVE_FAIL", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
