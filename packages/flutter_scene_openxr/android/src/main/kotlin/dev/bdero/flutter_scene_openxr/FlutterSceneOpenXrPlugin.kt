package dev.bdero.flutter_scene_openxr

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// The flat activity only launches VR and receives the selected example on exit.
// The immersive activity owns a separate engine/process, so an activity result
// transfers a selection, not a live Dart scene or its tuned simulation state.
class FlutterSceneOpenXrPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var immersiveResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isOpenXrAvailable" -> result.success(isOpenXrAvailable())
            "enterImmersive" -> enterImmersive(call, result)
            "galleryInitialExample" -> result.success(activity?.intent?.getStringExtra("flutter_scene_openxr.example"))
            else -> result.notImplemented()
        }
    }

    private fun isOpenXrAvailable(): Boolean {
        val currentActivity = activity ?: return false
        val packageManager = currentActivity.packageManager
        val hasHeadTracking =
            packageManager.hasSystemFeature(OPENXR_HEAD_TRACKING_FEATURE) ||
                packageManager.hasSystemFeature(PackageManager.FEATURE_VR_MODE_HIGH_PERFORMANCE) ||
                packageManager.hasSystemFeature(META_STANDALONE_VR_FEATURE)
        val hasRuntime =
            packageManager
                .queryIntentServices(
                    Intent(OPENXR_RUNTIME_SERVICE),
                    PackageManager.MATCH_ALL,
                ).isNotEmpty()

        return hasHeadTracking || hasRuntime
    }

    private fun enterImmersive(call: MethodCall, result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("ACTIVITY_UNAVAILABLE", "No Android activity is attached.", null)
            return
        }
        if (!isOpenXrAvailable()) {
            result.error(
                "OPENXR_RUNTIME_UNAVAILABLE",
                "No OpenXR runtime or VR head-tracking feature is available.",
                null,
            )
            return
        }

        val dartEntrypoint = call.argument<String>("dartEntrypoint")
        val dartLibraryUri = call.argument<String>("dartLibraryUri")
        if (dartEntrypoint.isNullOrBlank() || dartLibraryUri.isNullOrBlank()) {
            result.error(
                "INVALID_DART_ENTRYPOINT",
                "A Dart entrypoint and library URI are required.",
                null,
            )
            return
        }

        val compositionQuad = call.argument<Map<String, Any?>>("compositionQuad")
        val quadTextureWidth = compositionQuad.number("textureWidthPixels")?.toInt() ?: 0
        val quadTextureHeight = compositionQuad.number("textureHeightPixels")?.toInt() ?: 0
        val quadWidthMeters = compositionQuad.number("widthMeters")?.toDouble() ?: 0.0
        val quadHeightMeters = compositionQuad.number("heightMeters")?.toDouble() ?: 0.0
        if (
            compositionQuad != null &&
                (quadTextureWidth <= 0 || quadTextureHeight <= 0 ||
                    quadWidthMeters <= 0.0 || quadHeightMeters <= 0.0)
        ) {
            result.error(
                "INVALID_COMPOSITION_QUAD",
                "Composition quad texture and physical dimensions must be positive.",
                null,
            )
            return
        }

        try {
            val intent = Intent(currentActivity, FlutterSceneOpenXrActivity::class.java)
                .putExtra(FlutterSceneOpenXrActivity.EXTRA_DART_ENTRYPOINT, dartEntrypoint)
                .putExtra(FlutterSceneOpenXrActivity.EXTRA_DART_LIBRARY_URI, dartLibraryUri)
            if (compositionQuad != null) {
                intent.putExtra(
                    FlutterSceneOpenXrActivity.EXTRA_PANEL_SPLIT_PIXELS,
                    compositionQuad.number("panelSplitPixels")?.toInt() ?: 0,
                )
                intent
                    .putExtra(FlutterSceneOpenXrActivity.EXTRA_QUAD_TEXTURE_WIDTH, quadTextureWidth)
                    .putExtra(FlutterSceneOpenXrActivity.EXTRA_QUAD_TEXTURE_HEIGHT, quadTextureHeight)
                    .putExtra(FlutterSceneOpenXrActivity.EXTRA_QUAD_WIDTH_METERS, quadWidthMeters)
                    .putExtra(FlutterSceneOpenXrActivity.EXTRA_QUAD_HEIGHT_METERS, quadHeightMeters)
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_POSITION_X,
                        compositionQuad.number("positionX")?.toDouble() ?: 0.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_POSITION_Y,
                        compositionQuad.number("positionY")?.toDouble() ?: 0.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_POSITION_Z,
                        compositionQuad.number("positionZ")?.toDouble() ?: -1.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_ORIENTATION_X,
                        compositionQuad.number("orientationX")?.toDouble() ?: 0.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_ORIENTATION_Y,
                        compositionQuad.number("orientationY")?.toDouble() ?: 0.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_ORIENTATION_Z,
                        compositionQuad.number("orientationZ")?.toDouble() ?: 0.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_ORIENTATION_W,
                        compositionQuad.number("orientationW")?.toDouble() ?: 1.0,
                    )
                    .putExtra(
                        FlutterSceneOpenXrActivity.EXTRA_QUAD_HEAD_LOCKED,
                        compositionQuad["headLocked"] as? Boolean ?: false,
                    )
            }
            intent.putExtra("flutter_scene_openxr.example", call.argument<String>("example"))
            if (call.argument<Boolean>("awaitExit") == true) {
                if (immersiveResult != null) {
                    result.error("ALREADY_IMMERSIVE", "An immersive launch is already pending.", null)
                    return
                }
                immersiveResult = result
                currentActivity.startActivityForResult(intent, GALLERY_REQUEST)
            } else {
                currentActivity.startActivity(intent)
                result.success(null)
            }
        } catch (error: Exception) {
            immersiveResult = null
            result.error(
                "OPENXR_LAUNCH_FAILED",
                error.message ?: "The native OpenXR activity could not be started.",
                null,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != GALLERY_REQUEST) return false
        immersiveResult?.success(data?.getStringExtra("flutter_scene_openxr.example"))
        immersiveResult = null
        return true
    }

    private fun Map<String, Any?>?.number(key: String): Number? = this?.get(key) as? Number

    private companion object {
        const val GALLERY_REQUEST = 4729
        const val CHANNEL_NAME = "dev.bdero.flutter_scene_openxr/session"
        const val OPENXR_HEAD_TRACKING_FEATURE = "android.hardware.vr.headtracking"
        const val OPENXR_RUNTIME_SERVICE = "org.khronos.openxr.OpenXRRuntimeService"
        const val META_STANDALONE_VR_FEATURE = "oculus.hardware.standalone_vr"
    }
}
