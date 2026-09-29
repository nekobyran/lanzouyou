package cc.nkbr.lanzouyou

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val OPEN_WITH_CHANNEL = "app.standard/open_with"

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        requestPreferredHighRefreshMode()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OPEN_WITH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "queryHandlers" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(queryOpenWithHandlers(path))
                        } catch (error: RuntimeException) {
                            result.error("OPEN_WITH_QUERY_FAILED", error.message, null)
                        }
                    }

                    "openWith" -> {
                        val path = call.argument<String>("path")
                        val handlerId = call.argument<String>("handlerId")
                        if (path.isNullOrBlank() || handlerId.isNullOrBlank()) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "path and handlerId are required",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            openWithHandler(path, handlerId)
                            result.success(null)
                        } catch (error: RuntimeException) {
                            result.error("OPEN_WITH_FAILED", error.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        requestPreferredHighRefreshMode()
    }

    private fun queryOpenWithHandlers(path: String): List<Map<String, String>> {
        val intent = createViewIntent(path)
        val handlers = linkedMapOf<String, Map<String, String>>()
        for (resolveInfo in queryIntentActivities(intent)) {
            val activityInfo = resolveInfo.activityInfo ?: continue
            val component = ComponentName(activityInfo.packageName, activityInfo.name)
            val id = component.flattenToString()
            val resolvedLabel = resolveInfo.loadLabel(packageManager).toString().trim()
            val label = resolvedLabel.ifEmpty { activityInfo.packageName }
            handlers.putIfAbsent(
                id,
                mapOf(
                    "id" to id,
                    "label" to label,
                    "detail" to activityInfo.packageName,
                ),
            )
        }
        return handlers.values.toList()
    }

    private fun openWithHandler(path: String, handlerId: String) {
        val component = ComponentName.unflattenFromString(handlerId)
            ?: throw IllegalArgumentException("Invalid Android handler id")
        startActivity(createViewIntent(path).setComponent(component))
    }

    private fun createViewIntent(path: String): Intent {
        val (uri, mimeType) = resolveUriAndMimeType(path)
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeType)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    private fun resolveUriAndMimeType(path: String): Pair<Uri, String> {
        val uri = when {
            path.startsWith("content://") -> Uri.parse(path)
            path.startsWith("file://") -> {
                val filePath = requireNotNull(Uri.parse(path).path) { "Invalid file URI" }
                fileProviderUri(File(filePath))
            }
            else -> fileProviderUri(File(path))
        }
        val resolverMimeType = contentResolver.getType(uri)
        val extension = (uri.lastPathSegment ?: path)
            .substringAfterLast('.', missingDelimiterValue = "")
            .lowercase()
        val extensionMimeType = extension
            .takeIf { it.isNotEmpty() }
            ?.let(MimeTypeMap.getSingleton()::getMimeTypeFromExtension)
        return uri to (resolverMimeType ?: extensionMimeType ?: "*/*")
    }

    private fun fileProviderUri(file: File): Uri {
        require(file.isFile) { "File does not exist: ${file.path}" }
        return FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.app_file_provider",
            file,
        )
    }

    @Suppress("DEPRECATION")
    private fun queryIntentActivities(intent: Intent): List<ResolveInfo> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }
    }

    @Suppress("DEPRECATION")
    private fun requestPreferredHighRefreshMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return

        val display = windowManager.defaultDisplay
        val currentMode = display.mode
        val preferred = display.supportedModes
            .asSequence()
            .filter {
                it.physicalWidth == currentMode.physicalWidth &&
                    it.physicalHeight == currentMode.physicalHeight
            }
            .maxByOrNull { it.refreshRate }
            ?: return

        if (preferred.refreshRate < 89f || preferred.modeId == currentMode.modeId) return

        val attributes = window.attributes
        attributes.preferredDisplayModeId = preferred.modeId
        window.attributes = attributes
    }
}

