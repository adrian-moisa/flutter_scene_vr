package dev.bdero.flutter_scene_openxr

import android.app.NativeActivity
import android.content.Intent
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister
import android.graphics.SurfaceTexture
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.ViewConfiguration
import androidx.annotation.Keep
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.embedding.engine.renderer.ExternalGpuSurfaceFrameCallback
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// NativeActivity's worker owns OpenXR pacing and swapchain access.
// Android's main thread owns Flutter embedding/channel calls; the surface thread
// only signals UI-buffer availability and never decides when eye leases are safe.
class FlutterSceneOpenXrActivity : NativeActivity() {
    private data class RenderingTag(val sequence: Long, val markedAtNanos: Long)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val surfaceFrameThread = HandlerThread("FlutterSceneOpenXRSurfaceFrame").apply {
        start()
    }
    private val surfaceFrameHandler = Handler(surfaceFrameThread.looper)
    private val surfaceOwnershipLock = Any()
    private val pendingViews = AtomicReference<DoubleArray?>(null)
    private val viewPublishQueued = AtomicBoolean(false)
    private val pendingPerformance = AtomicReference<DoubleArray?>(null)
    private val performancePublishQueued = AtomicBoolean(false)
    private val stereoFrameAvailable = AtomicBoolean(false)
    private val renderingTagLock = Any()
    private val renderingTags = ArrayDeque<RenderingTag>()

    private var engineGroup: FlutterEngineGroup? = null
    private var flutterEngine: FlutterEngine? = null
    private var flutterSurface: Surface? = null
    private var flutterSurfaceTexture: SurfaceTexture? = null
    private var sessionChannel: MethodChannel? = null
    private val flutterEngineReady = CountDownLatch(1)
    @Volatile private var producerStopCompletion = CountDownLatch(0)
    @Volatile private var producerStopped = true
    @Volatile private var gpuResourcesQuarantined = false
    private var leftEyeSurfaceRegistered = false
    private var rightEyeSurfaceRegistered = false
    @Volatile private var activityResumed = false
    @Volatile private var destroyed = false
    private lateinit var dartEntrypoint: String
    private lateinit var dartLibraryUri: String
    private var quadTextureWidth = 0
    private var quadTextureHeight = 0
    private var quadWidthMeters = 0.0
    private var quadHeightMeters = 0.0
    private var quadPositionX = 0.0
    private var quadPositionY = 0.0
    private var quadPositionZ = -1.0
    private var quadOrientationX = 0.0
    private var quadOrientationY = 0.0
    private var quadOrientationZ = 0.0
    private var quadOrientationW = 1.0
    private var quadHeadLocked = false
    @Volatile private var performanceLoggingEnabled = false
    @Volatile private var directEyeRendererReady = false
    @Volatile private var directEyeSurfacesAttached = false
    // Main-thread ownership of leases offered to Dart. A pause reply waits for
    // terminal GPU callbacks before Flutter disposes/rebuilds the old example.
    private val pendingStereoTokens = mutableSetOf<Long>()
    private var pendingResolution: Pair<Long, MethodChannel.Result>? = null
    private external fun nativeRequestResolution(scale: Double): Long

    @Keep
    fun completeOpenXrResolutionChange(request: Long, scale: Double, width: Int, height: Int, error: String?) {
        mainHandler.post {
            val pending = pendingResolution
            if (pending?.first == request) {
                pendingResolution = null
                if (error != null) pending.second.error("resolution_failed", error, null)
                else pending.second.success(mapOf("scale" to scale, "width" to width, "height" to height))
            }
        }
    }

    private val pendingRendererPauseReplies = mutableListOf<MethodChannel.Result>()
    private var directStereoDiagnosticFrames = 0
    private var surfaceCallbackWindowStartedNanos = 0L
    private var surfaceCallbackLastNanos = 0L
    private var surfaceCallbackCount = 0L
    private var surfaceCallbackOverwriteCount = 0L
    private var surfaceCallbackIntervalNanos = 0L
    private var surfaceCallbackMaximumIntervalNanos = 0L
    private val resolvedRenderingTagCount = AtomicLong(0)
    private val missingRenderingTagCount = AtomicLong(0)
    private val renderingTagDeltaNanos = AtomicLong(0)
    private val renderingTagMaximumDeltaNanos = AtomicLong(0)
    private val latestRenderingTagPendingCount = AtomicLong(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        dartEntrypoint = intent.getStringExtra(EXTRA_DART_ENTRYPOINT) ?: DEFAULT_DART_ENTRYPOINT
        dartLibraryUri = intent.getStringExtra(EXTRA_DART_LIBRARY_URI) ?: DEFAULT_DART_LIBRARY_URI
        quadTextureWidth = numberExtra(EXTRA_QUAD_TEXTURE_WIDTH, 0.0).toInt()
        quadTextureHeight = numberExtra(EXTRA_QUAD_TEXTURE_HEIGHT, 0.0).toInt()
        quadWidthMeters = numberExtra(EXTRA_QUAD_WIDTH_METERS, 0.0)
        quadHeightMeters = numberExtra(EXTRA_QUAD_HEIGHT_METERS, 0.0)
        quadPositionX = numberExtra(EXTRA_QUAD_POSITION_X, 0.0)
        quadPositionY = numberExtra(EXTRA_QUAD_POSITION_Y, 0.0)
        quadPositionZ = numberExtra(EXTRA_QUAD_POSITION_Z, -1.0)
        quadOrientationX = numberExtra(EXTRA_QUAD_ORIENTATION_X, 0.0)
        quadOrientationY = numberExtra(EXTRA_QUAD_ORIENTATION_Y, 0.0)
        quadOrientationZ = numberExtra(EXTRA_QUAD_ORIENTATION_Z, 0.0)
        quadOrientationW = numberExtra(EXTRA_QUAD_ORIENTATION_W, 1.0)
        quadHeadLocked = intent.getBooleanExtra(EXTRA_QUAD_HEAD_LOCKED, false)
        performanceLoggingEnabled = intent.getBooleanExtra(EXTRA_PERFORMANCE_LOGGING, false)
        super.onCreate(savedInstanceState)
        try {
            createFlutterEngineOnMain()
        } finally {
            flutterEngineReady.countDown()
        }
    }

    private fun numberExtra(name: String, fallback: Double): Double =
        (intent.extras?.get(name) as? Number)?.toDouble() ?: fallback

    override fun onResume() {
        super.onResume()
        activityResumed = true
        flutterEngine?.lifecycleChannel?.appIsResumed()
    }

    override fun onPause() {
        flutterEngine?.lifecycleChannel?.appIsInactive()
        activityResumed = false
        super.onPause()
    }

    override fun onStop() {
        flutterEngine?.lifecycleChannel?.appIsPaused()
        super.onStop()
    }

    override fun onDestroy() {
        pendingResolution?.second?.error("session_closed", "The VR session closed before resizing.", null)
        pendingResolution = null
        val completion = synchronized(surfaceOwnershipLock) {
            destroyed = true
            producerStopCompletion
        }
        try {
            if (!releaseFlutterSurfaceOnMain()) quarantineOpenXrGpuResources()
        } catch (error: Throwable) {
            Log.e(TAG, "Flutter stereo surface cleanup failed", error)
            quarantineOpenXrGpuResources()
        } finally {
            completion.countDown()
        }
        surfaceFrameThread.quitSafely()
        try {
            // Let native OpenXR release its shared GLES context before destroying Flutter's.
            super.onDestroy()
        } finally {
            if (!gpuResourcesQuarantined) destroyFlutterEngineOnMain()
        }
    }

    // Called from either native or main during failed teardown. A strong
    // process-lifetime reference keeps the engine/share group alive after this
    // Activity exits; recovery requires restarting the process.
    @Keep
    fun quarantineOpenXrGpuResources() {
        gpuResourcesQuarantined = true
        directEyeSurfacesAttached = false
        synchronized(quarantinedActivities) {
            if (!quarantinedActivities.contains(this)) quarantinedActivities.add(this)
        }
        Log.e(TAG, "Retaining unresolved OpenXR GPU resources until process cleanup; restart the process")
    }

    /// Starts the Dart renderer after native OpenXR has chosen the eye size.
    @Keep
    fun startFlutterStereoSurface(
        surface: Surface,
        surfaceTexture: SurfaceTexture,
        stereoWidth: Int,
        stereoHeight: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
        compositionQuadWidth: Int,
        compositionQuadHeight: Int,
    ) {
        val completion = synchronized(surfaceOwnershipLock) {
            if (destroyed) {
                null
            } else {
                CountDownLatch(1).also { producerStopCompletion = it }
            }
        }
        if (completion == null) {
            surface.release()
            return
        }
        producerStopped = false

        if (!mainHandler.post {
            if (destroyed) {
                surface.release()
                completion.countDown()
                return@post
            }

            try {
                check(releaseFlutterSurfaceOnMain()) {
                    "Previous stereo surface still has unresolved GPU ownership"
                }
                flutterSurfaceTexture = surfaceTexture
                stereoFrameAvailable.set(false)
                synchronized(renderingTagLock) { renderingTags.clear() }
                resetSurfaceCallbackStats()
                surfaceTexture.setOnFrameAvailableListener(
                    {
                        val replacedPendingSignal = stereoFrameAvailable.getAndSet(true)
                        recordSurfaceCallback(replacedPendingSignal)
                    },
                    surfaceFrameHandler,
                )
                startFlutterSurfaceOnMain(surface, surfaceWidth, surfaceHeight)
                Log.i(
                    TAG,
                    "Flutter surface ${surfaceWidth}x$surfaceHeight contains " +
                        "stereo ${stereoWidth}x$stereoHeight and composition quad " +
                        "${compositionQuadWidth}x$compositionQuadHeight",
                )
            } catch (error: Throwable) {
                Log.e(TAG, "Unable to start the Flutter stereo renderer", error)
                if (releaseFlutterSurfaceOnMain()) {
                    if (surface.isValid) surface.release()
                } else {
                    quarantineOpenXrGpuResources()
                }
                completion.countDown()
            }
        }) {
            surface.release()
            completion.countDown()
        }
    }

    /// Coalesces native frame poses before forwarding them to the Dart isolate.
    @Keep
    fun publishOpenXrViews(values: DoubleArray) {
        pendingViews.set(values)
        if (viewPublishQueued.compareAndSet(false, true)) {
            mainHandler.post(::publishLatestViewsOnMain)
        }
    }

    // Coalesces the one-second native sample before forwarding it to Dart.
    @Keep
    fun publishOpenXrPerformance(values: DoubleArray) {
        pendingPerformance.set(values)
        if (performancePublishQueued.compareAndSet(false, true)) {
            mainHandler.post(::publishLatestPerformanceOnMain)
        }
    }

    /// Returns whether Flutter queued a new stereo buffer since native latched.
    @Keep
    fun consumeFlutterStereoFrameAvailable(): Boolean =
        stereoFrameAvailable.getAndSet(false)

    /// Resolves the exact tracked view used by a latched SurfaceTexture buffer.
    ///
    /// SurfaceTexture timestamps and [System.nanoTime] share Android's
    /// monotonic timebase for Flutter's EGL producer. Keeping every render tag
    /// until the buffer timestamp is known avoids labeling an older buffer
    /// with the newest camera pose when Flutter and OpenXR run asynchronously.
    @Keep
    fun resolveFlutterStereoFrameSequence(textureTimestampNanos: Long): Long {
        if (textureTimestampNanos <= 0L) return UNTAGGED_FRAME

        var resolved: RenderingTag? = null
        val pendingCount = synchronized(renderingTagLock) {
            while (
                renderingTags.isNotEmpty() &&
                renderingTags.first().markedAtNanos <= textureTimestampNanos
            ) {
                resolved = renderingTags.removeFirst()
            }
            renderingTags.size
        }
        val tag = resolved
        if (tag == null) {
            missingRenderingTagCount.incrementAndGet()
            return UNTAGGED_FRAME
        }

        val deltaNanos = textureTimestampNanos - tag.markedAtNanos
        resolvedRenderingTagCount.incrementAndGet()
        renderingTagDeltaNanos.addAndGet(deltaNanos)
        renderingTagMaximumDeltaNanos.updateAndGet { current ->
            maxOf(current, deltaNanos)
        }
        latestRenderingTagPendingCount.set(pendingCount.toLong())
        return tag.sequence
    }

    /// Keeps profile logging opt-in for applications embedding the package.
    @Keep
    fun isOpenXrPerformanceLoggingEnabled(): Boolean = performanceLoggingEnabled

    // Both the Dart consumer and the native eye surfaces must be ready before acquiring eye images.
    @Keep
    fun isDirectEyeRendererReady(): Boolean =
        !destroyed && directEyeRendererReady && directEyeSurfacesAttached

    /// Returns the optional compositor-quad contract to the native OpenXR host.
    @Keep
    fun openXrCompositionQuadConfiguration(): DoubleArray = doubleArrayOf(
        quadTextureWidth.toDouble(),
        quadTextureHeight.toDouble(),
        quadWidthMeters,
        quadHeightMeters,
        quadPositionX,
        quadPositionY,
        quadPositionZ,
        quadOrientationX,
        quadOrientationY,
        quadOrientationZ,
        quadOrientationW,
        if (quadHeadLocked) 1.0 else 0.0,
        numberExtra(EXTRA_PANEL_SPLIT_PIXELS, 0.0),
    )

    /// Returns the GLES handles required to create the OpenXR context in
    /// Flutter Impeller's resource share group.
    @Keep
    fun openGLESExternalContextDescriptor(): LongArray? {
        awaitFlutterEngine()
        return flutterEngine?.renderer?.openGLESExternalContextDescriptor
    }

    /// Offers one acquired texture per eye to one Flutter Scene stereo render.
    @Keep
    fun renderOpenXrStereo(
        leftTexture: Int,
        leftWidth: Int,
        leftHeight: Int,
        leftFormat: Int,
        leftFrameToken: Long,
        rightTexture: Int,
        rightWidth: Int,
        rightHeight: Int,
        rightFormat: Int,
        rightFrameToken: Long,
        viewSequence: Long,
    ): Boolean {
        if (
            leftTexture == 0 || leftWidth <= 0 || leftHeight <= 0 ||
            leftFrameToken <= 0L || rightTexture == 0 || rightWidth <= 0 ||
            rightHeight <= 0 || rightFrameToken <= 0L
        ) {
            return false
        }

        return mainHandler.post {
            // Trace startup only; successful steady-state frames must not flood logcat.
            val trace = performanceLoggingEnabled &&
                directStereoDiagnosticFrames++ < DIRECT_DIAGNOSTIC_FRAME_LIMIT
            if (trace) {
                Log.i(TAG, "Direct stereo main-thread handoff seq=$viewSequence tokens=$leftFrameToken/$rightFrameToken")
            }
            val engine = flutterEngine
            val channel = sessionChannel
            if (destroyed || !directEyeSurfacesAttached || engine == null || channel == null) {
                Log.e(TAG, "Direct stereo renderer unavailable seq=$viewSequence destroyed=$destroyed attached=$directEyeSurfacesAttached")
                completeStereoToken(
                    leftFrameToken,
                    EXTERNAL_FRAME_ERROR,
                )
                completeStereoToken(
                    rightFrameToken,
                    EXTERNAL_FRAME_ERROR,
                )
                return@post
            }
            // Readiness can change after the XR thread checked it but before
            // this queued main-thread handoff runs. Nothing has been imported,
            // so both native leases can be returned as intentionally discarded.
            if (!directEyeRendererReady) {
                completeStereoToken(leftFrameToken, EXTERNAL_FRAME_DISCARDED)
                completeStereoToken(rightFrameToken, EXTERNAL_FRAME_DISCARDED)
                return@post
            }
            pendingStereoTokens.add(leftFrameToken)
            pendingStereoTokens.add(rightFrameToken)
            if (trace) Log.i(TAG, "Direct stereo push left token=$leftFrameToken texture=$leftTexture")
            val leftPushed = engine.renderer.pushExternalGpuSurfaceTextureFrame(
                DIRECT_LEFT_EYE_SURFACE,
                leftTexture,
                leftWidth,
                leftHeight,
                leftFormat,
                leftFrameToken,
                ExternalGpuSurfaceFrameCallback { token, status ->
                    if (trace || status != 0) {
                        Log.i(TAG, "Direct stereo engine callback left token=$token status=$status")
                    }
                    completeStereoToken(token, status)
                },
            )
            if (trace) Log.i(TAG, "Direct stereo push left accepted=$leftPushed; push right token=$rightFrameToken texture=$rightTexture")
            val rightPushed = engine.renderer.pushExternalGpuSurfaceTextureFrame(
                DIRECT_RIGHT_EYE_SURFACE,
                rightTexture,
                rightWidth,
                rightHeight,
                rightFormat,
                rightFrameToken,
                ExternalGpuSurfaceFrameCallback { token, status ->
                    if (trace || status != 0) {
                        Log.i(TAG, "Direct stereo engine callback right token=$token status=$status")
                    }
                    completeStereoToken(token, status)
                },
            )
            if (trace) Log.i(TAG, "Direct stereo push right accepted=$rightPushed")
            if (!leftPushed || !rightPushed) {
                Log.e(TAG, "Direct stereo texture import rejected seq=$viewSequence left=$leftPushed right=$rightPushed")
                if (!leftPushed) {
                    completeStereoToken(
                        leftFrameToken,
                        EXTERNAL_FRAME_ERROR,
                    )
                }
                if (!rightPushed) {
                    completeStereoToken(
                        rightFrameToken,
                        EXTERNAL_FRAME_ERROR,
                    )
                }
                recycleDirectStereoSurfaces(engine)
                return@post
            }

            // Deliver the matching pose before asking Dart to consume these targets.
            // The XR worker waits for both eyes, so it cannot publish a newer
            // render request while this pair is still borrowed by Flutter.
            publishLatestViewsOnMain()
            if (trace) Log.i(TAG, "Direct stereo dispatch Dart seq=$viewSequence")
            channel.invokeMethod(
                "renderExternalStereo",
                longArrayOf(
                    DIRECT_LEFT_EYE_SURFACE,
                    DIRECT_RIGHT_EYE_SURFACE,
                    viewSequence,
                ),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        // The method reply confirms Dart submission, not GPU completion.
                        if (trace) Log.i(TAG, "Direct stereo Dart returned seq=$viewSequence; awaiting engine callbacks")
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.e(TAG, "Direct stereo Dart error seq=$viewSequence code=$code message=${message?.take(500)} details=${details?.toString()?.take(2000)}")
                        recycleDirectStereoSurfaces(engine)
                    }

                    override fun notImplemented() {
                        Log.e(TAG, "Direct stereo Dart method missing seq=$viewSequence")
                        recycleDirectStereoSurfaces(engine)
                    }
                },
            )
        }
    }

    private fun completeStereoToken(token: Long, status: Int) {
        // Native can release an image only after this authoritative completion.
        nativeOnExternalGpuSurfaceFrameReleased(token, status)
        val finishOnMain: () -> Unit = {
            pendingStereoTokens.remove(token)
            if (pendingStereoTokens.isEmpty()) {
                val replies = pendingRendererPauseReplies.toList()
                pendingRendererPauseReplies.clear()
                replies.forEach { it.success(null) }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) finishOnMain()
        else mainHandler.post(finishOnMain)
    }

    @Keep
    private external fun nativeResetPerformance(): Long

    private external fun nativeOnExternalGpuSurfaceFrameReleased(frameToken: Long, status: Int)

    /// Cancels a direct frame whose Dart renderer did not reach a terminal callback.
    @Keep
    fun cancelOpenXrStereoFrame(): Boolean {
        Log.w(TAG, "Direct stereo cancellation requested; waiting for surface release callbacks")
        val completion = CountDownLatch(1)
        var cancelled = false
        val cancelOnMain: () -> Unit = {
            try {
                val engine = flutterEngine
                if (engine != null) {
                    cancelled = recycleDirectStereoSurfaces(engine)
                }
            } finally {
                completion.countDown()
            }
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            cancelOnMain()
        } else if (!mainHandler.post(cancelOnMain)) {
            return false
        }
        return try {
            val finished = completion.await(DIRECT_CANCEL_WAIT_SECONDS, TimeUnit.SECONDS)
            Log.w(TAG, "Direct stereo cancellation main-thread finished=$finished surfacesRecycled=$cancelled")
            finished && cancelled
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    /// Stops Flutter before native releases the SurfaceTexture consumer.
    @Keep
    fun stopFlutterStereoSurface(): Boolean {
        val completion = synchronized(surfaceOwnershipLock) { producerStopCompletion }
        if (completion.count == 0L) return producerStopped

        val stopOnMain: () -> Unit = {
            try {
                releaseFlutterSurfaceOnMain()
            } catch (error: Throwable) {
                Log.e(TAG, "Flutter stereo surface cleanup failed", error)
            } finally {
                completion.countDown()
            }
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            stopOnMain()
            return producerStopped
        }
        if (!mainHandler.post(stopOnMain)) {
            Log.e(TAG, "Unable to post Flutter stereo surface cleanup")
            return false
        }
        return awaitProducerStop(completion) && producerStopped
    }

    private fun startFlutterSurfaceOnMain(surface: Surface, width: Int, height: Int) {
        awaitFlutterEngine()
        val engine = checkNotNull(flutterEngine) { "Flutter engine was not initialized" }
        flutterSurface = surface

        val renderer = engine.renderer
        if (!renderer.registerExternalGpuSurface(DIRECT_LEFT_EYE_SURFACE)) {
            throw IllegalStateException("Unable to register the direct left-eye GPU surface")
        }
        leftEyeSurfaceRegistered = true
        producerStopped = false
        if (!renderer.registerExternalGpuSurface(DIRECT_RIGHT_EYE_SURFACE)) {
            if (renderer.unregisterExternalGpuSurface(DIRECT_LEFT_EYE_SURFACE)) {
                leftEyeSurfaceRegistered = false
            }
            throw IllegalStateException("Unable to register the direct right-eye GPU surface")
        }
        rightEyeSurfaceRegistered = true
        attachFlutterRendererToSurface(engine, renderer, surface, width, height)
        directStereoDiagnosticFrames = 0
        directEyeSurfacesAttached = true
    }

    private fun createFlutterEngineOnMain() {
        // The direct eye bridge shares GLES texture names with the native host.
        // Allowing Flutter to select Vulkan would break that resource contract.
        val group = FlutterEngineGroup(
            applicationContext,
            arrayOf("--impeller-backend=opengles"),
        )
        engineGroup = group

        val loader = FlutterInjector.instance().flutterLoader()
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            dartLibraryUri,
            dartEntrypoint,
        )
        val options = FlutterEngineGroup.Options(this)
            .setDartEntrypoint(entrypoint)
            .setAutomaticallyRegisterPlugins(false)
            .setWaitForRestorationData(false)
        val engine = group.createAndRunEngine(options)
        flutterEngine = engine
        // Gallery audio, video and path-provider dependencies use the same UI
        // engine. The OpenXR session channel below remains owned by this host.
        GeneratedPluginRegister.registerGeneratedPlugins(engine)

        val renderer = engine.renderer
        renderer.addIsDisplayingFlutterUiListener(
            object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    Log.i(TAG, "Flutter UI surface displayed its first frame (not a direct eye completion)")
                }

                override fun onFlutterUiNoLongerDisplayed() {
                    Log.i(TAG, "Flutter UI surface stopped displaying frames")
                }
            },
        )
        sessionChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "galleryInitialExample" -> {
                        result.success(intent.getStringExtra("flutter_scene_openxr.example"))
                        return@setMethodCallHandler
                    }
                    "gallerySelection" -> {
                        val selected = call.arguments as? String
                        intent.putExtra("flutter_scene_openxr.example", selected)
                        setResult(RESULT_OK, Intent().putExtra("flutter_scene_openxr.example", selected))
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    "setRenderScale" -> {
                        val scale = (call.arguments as? Number)?.toDouble()
                        if (scale == null || !scale.isFinite() || scale < 0.5 || scale > 1.5) {
                            result.error("invalid_resolution", "Scale must be between 0.5 and 1.5.", null)
                        } else if (pendingResolution != null) {
                            result.error("resolution_busy", "An eye resize is already pending.", null)
                        } else {
                            pendingResolution = nativeRequestResolution(scale) to result
                        }
                        return@setMethodCallHandler
                    }
                    "resetPanels" -> {
                        nativeResetPanels()
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    "resetPerformance" -> {
                        pendingPerformance.set(null)
                        result.success(nativeResetPerformance())
                        return@setMethodCallHandler
                    }
                    "exitImmersive" -> {
                        result.success(null)
                        if (callingActivity == null) {
                            packageManager.getLaunchIntentForPackage(packageName)?.let { launcher ->
                                launcher.putExtra("flutter_scene_openxr.example", intent.getStringExtra("flutter_scene_openxr.example"))
                                startActivity(launcher)
                            }
                        }
                        finish()
                        return@setMethodCallHandler
                    }
                }

                if (call.method == "directEyeRendererReady") {
                    directEyeRendererReady = call.arguments == true
                    if (!directEyeRendererReady && pendingStereoTokens.isNotEmpty()) {
                        // Keep the message loop free: Dart can discard a queued
                        // frame and GPU completion can resolve this barrier.
                        pendingRendererPauseReplies.add(result)
                    } else {
                        result.success(null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "markFrameRendering") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val sequence = (call.arguments as? Number)?.toLong()
                if (sequence == null || sequence <= 0L) {
                    result.error("invalid_sequence", "A positive OpenXR frame sequence is required", null)
                    return@setMethodCallHandler
                }
                synchronized(renderingTagLock) {
                    val previous = renderingTags.lastOrNull()
                    if (previous?.sequence != sequence) {
                        renderingTags.addLast(RenderingTag(sequence, System.nanoTime()))
                    }
                    while (renderingTags.size > MAX_RENDERING_TAGS) {
                        renderingTags.removeFirst()
                    }
                }
                result.success(null)
            }
        }
        if (activityResumed) engine.lifecycleChannel.appIsResumed()
    }

    private fun attachFlutterRendererToSurface(
        engine: FlutterEngine,
        renderer: FlutterRenderer,
        surface: Surface,
        width: Int,
        height: Int,
    ) {
        renderer.startRenderingToSurface(surface, false)
        renderer.surfaceChanged(width, height)
        renderer.setViewportMetrics(
            FlutterRenderer.ViewportMetrics().apply {
                devicePixelRatio = 1.0f
                this.width = width
                this.height = height
                minWidth = width
                maxWidth = width
                minHeight = height
                maxHeight = height
                physicalTouchSlop =
                    ViewConfiguration.get(this@FlutterSceneOpenXrActivity).scaledTouchSlop
            },
        )

        publishLatestViewsOnMain()
    }

    private fun recycleDirectStereoSurfaces(engine: FlutterEngine): Boolean {
        // Late callbacks from a detached surface must not register new eye targets.
        if (destroyed || !directEyeSurfacesAttached || flutterEngine !== engine) {
            return false
        }

        if (!unregisterDirectStereoSurfaces(engine)) {
            directEyeSurfacesAttached = false
            Log.e(TAG, "Cannot recycle stereo surfaces while GPU ownership is unresolved")
            return false
        }
        val leftRegistered =
            engine.renderer.registerExternalGpuSurface(DIRECT_LEFT_EYE_SURFACE)
        leftEyeSurfaceRegistered = leftRegistered
        val rightRegistered =
            engine.renderer.registerExternalGpuSurface(DIRECT_RIGHT_EYE_SURFACE)
        rightEyeSurfaceRegistered = rightRegistered
        directEyeSurfacesAttached = leftRegistered && rightRegistered
        Log.w(TAG, "Direct stereo surface recycle registered=$leftRegistered/$rightRegistered")
        return directEyeSurfacesAttached
    }

    private fun unregisterDirectStereoSurfaces(engine: FlutterEngine): Boolean {
        if (leftEyeSurfaceRegistered &&
            engine.renderer.unregisterExternalGpuSurface(DIRECT_LEFT_EYE_SURFACE)) {
            leftEyeSurfaceRegistered = false
        }
        if (rightEyeSurfaceRegistered &&
            engine.renderer.unregisterExternalGpuSurface(DIRECT_RIGHT_EYE_SURFACE)) {
            rightEyeSurfaceRegistered = false
        }
        return !leftEyeSurfaceRegistered && !rightEyeSurfaceRegistered
    }

    private fun publishLatestViewsOnMain() {
        val values = pendingViews.getAndSet(null)
        if (values != null) {
            sessionChannel?.invokeMethod("viewsChanged", values)
        }

        viewPublishQueued.set(false)
        if (pendingViews.get() != null && viewPublishQueued.compareAndSet(false, true)) {
            mainHandler.post(::publishLatestViewsOnMain)
        }
    }

    private fun publishLatestPerformanceOnMain() {
        val values = pendingPerformance.getAndSet(null)
        if (values != null) {
            sessionChannel?.invokeMethod("performanceChanged", values)
        }

        performancePublishQueued.set(false)
        if (
            pendingPerformance.get() != null &&
            performancePublishQueued.compareAndSet(false, true)
        ) {
            mainHandler.post(::publishLatestPerformanceOnMain)
        }
    }

    private fun resetSurfaceCallbackStats() {
        surfaceCallbackWindowStartedNanos = System.nanoTime()
        surfaceCallbackLastNanos = 0L
        surfaceCallbackCount = 0L
        surfaceCallbackOverwriteCount = 0L
        surfaceCallbackIntervalNanos = 0L
        surfaceCallbackMaximumIntervalNanos = 0L
        resolvedRenderingTagCount.set(0)
        missingRenderingTagCount.set(0)
        renderingTagDeltaNanos.set(0)
        renderingTagMaximumDeltaNanos.set(0)
        latestRenderingTagPendingCount.set(0)
    }

    private fun recordSurfaceCallback(overwrotePendingCallback: Boolean) {
        val now = System.nanoTime()
        if (surfaceCallbackWindowStartedNanos == 0L) {
            surfaceCallbackWindowStartedNanos = now
        }
        if (surfaceCallbackLastNanos != 0L) {
            val intervalNanos = now - surfaceCallbackLastNanos
            surfaceCallbackIntervalNanos += intervalNanos
            surfaceCallbackMaximumIntervalNanos =
                maxOf(surfaceCallbackMaximumIntervalNanos, intervalNanos)
        }
        surfaceCallbackLastNanos = now
        surfaceCallbackCount++
        if (overwrotePendingCallback) surfaceCallbackOverwriteCount++

        val elapsedNanos = now - surfaceCallbackWindowStartedNanos
        if (!performanceLoggingEnabled || elapsedNanos < SURFACE_LOG_INTERVAL_NANOS) return

        val elapsedSeconds = elapsedNanos / NANOS_PER_SECOND
        val intervalCount = maxOf(0L, surfaceCallbackCount - 1)
        val intervalMeanMs = if (intervalCount == 0L) {
            0.0
        } else {
            surfaceCallbackIntervalNanos / intervalCount.toDouble() / NANOS_PER_MILLISECOND
        }
        val resolvedTags = resolvedRenderingTagCount.get()
        val tagDeltaMeanMs = if (resolvedTags == 0L) {
            0.0
        } else {
            renderingTagDeltaNanos.get() / resolvedTags.toDouble() / NANOS_PER_MILLISECOND
        }
        Log.i(
            TAG,
            "+++ OpenXR surface callbacks | " +
                "callback_hz=${"%.1f".format(surfaceCallbackCount / elapsedSeconds)} " +
                "overwritten=$surfaceCallbackOverwriteCount " +
                "interval_mean_ms=${"%.2f".format(intervalMeanMs)} " +
                "interval_max_ms=${"%.2f".format(
                    surfaceCallbackMaximumIntervalNanos / NANOS_PER_MILLISECOND,
                )} " +
                "tagged=$resolvedTags missing_tags=${missingRenderingTagCount.get()} " +
                "tag_delta_mean_ms=${"%.2f".format(tagDeltaMeanMs)} " +
                "tag_delta_max_ms=${"%.2f".format(
                    renderingTagMaximumDeltaNanos.get() / NANOS_PER_MILLISECOND,
                )} pending_tags=${latestRenderingTagPendingCount.get()}",
        )
        resetSurfaceCallbackStats()
    }

    // Detach only the surface and eye targets. The activity keeps the engine, Dart channel,
    // and consumer readiness because native OpenXR already shares this engine's GLES context.
    // This also runs before the first attachment, when there is no old surface to stop.
    private fun releaseFlutterSurfaceOnMain(): Boolean {
        val engine = flutterEngine
        val surface = flutterSurface
        directEyeSurfacesAttached = false
        if (engine != null && !unregisterDirectStereoSurfaces(engine)) {
            Log.e(TAG, "Stereo producer stop failed: retaining surface and engine while a GPU lease is unresolved")
            producerStopped = false
            return false
        }
        if (surface != null && engine != null) {
            engine.renderer.stopRenderingToSurface()
        }
        flutterSurface = null
        flutterSurfaceTexture?.setOnFrameAvailableListener(null)
        flutterSurfaceTexture = null
        stereoFrameAvailable.set(false)
        synchronized(renderingTagLock) { renderingTags.clear() }
        pendingViews.set(null)
        pendingPerformance.set(null)

        surface?.release()
        producerStopped = true
        return true
    }

    // Destroy the activity-owned engine only after its surfaces and native OpenXR host have stopped.
    private fun destroyFlutterEngineOnMain() {
        val engine = flutterEngine
        sessionChannel?.setMethodCallHandler(null)
        sessionChannel = null
        directEyeRendererReady = false
        flutterEngine = null
        engineGroup = null
        engine?.lifecycleChannel?.appIsDetached()
        engine?.destroy()
    }

    private fun awaitProducerStop(completion: CountDownLatch): Boolean {
        return try {
            completion.await(STOP_WAIT_LOG_SECONDS, TimeUnit.SECONDS).also { stopped ->
                if (!stopped) Log.e(TAG, "Timed out verifying stereo producer stop; GPU resources must be retained")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    private fun awaitFlutterEngine() {
        var interrupted = false
        while (flutterEngineReady.count != 0L) {
            try {
                flutterEngineReady.await()
            } catch (_: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }

    @Keep
    private external fun nativeResetPanels()

    companion object {
        private val quarantinedActivities = mutableListOf<FlutterSceneOpenXrActivity>()
        init {
            // NativeActivity loads this library for its C entrypoint, but Java
            // also needs it registered with this class loader to resolve our JNI callbacks.
            System.loadLibrary("flutter_scene_openxr")
        }

        const val EXTRA_DART_ENTRYPOINT = "flutter_scene_openxr.dartEntrypoint"
        const val EXTRA_DART_LIBRARY_URI = "flutter_scene_openxr.dartLibraryUri"
        const val EXTRA_PERFORMANCE_LOGGING = "flutter_scene_openxr.performanceLogging"
        const val EXTRA_QUAD_TEXTURE_WIDTH = "flutter_scene_openxr.quadTextureWidth"
        const val EXTRA_QUAD_TEXTURE_HEIGHT = "flutter_scene_openxr.quadTextureHeight"
        const val EXTRA_QUAD_WIDTH_METERS = "flutter_scene_openxr.quadWidthMeters"
        const val EXTRA_QUAD_HEIGHT_METERS = "flutter_scene_openxr.quadHeightMeters"
        const val EXTRA_QUAD_POSITION_X = "flutter_scene_openxr.quadPositionX"
        const val EXTRA_QUAD_POSITION_Y = "flutter_scene_openxr.quadPositionY"
        const val EXTRA_QUAD_POSITION_Z = "flutter_scene_openxr.quadPositionZ"
        const val EXTRA_QUAD_ORIENTATION_X = "flutter_scene_openxr.quadOrientationX"
        const val EXTRA_QUAD_ORIENTATION_Y = "flutter_scene_openxr.quadOrientationY"
        const val EXTRA_QUAD_ORIENTATION_Z = "flutter_scene_openxr.quadOrientationZ"
        const val EXTRA_QUAD_ORIENTATION_W = "flutter_scene_openxr.quadOrientationW"
        const val EXTRA_PANEL_SPLIT_PIXELS = "flutter_scene_openxr.panelSplitPixels"
        const val EXTRA_QUAD_HEAD_LOCKED = "flutter_scene_openxr.quadHeadLocked"

        private const val TAG = "FlutterSceneOpenXR"
        private const val CHANNEL_NAME = "dev.bdero.flutter_scene_openxr/session"
        private const val NANOS_PER_SECOND = 1_000_000_000.0
        private const val NANOS_PER_MILLISECOND = 1_000_000.0
        private const val SURFACE_LOG_INTERVAL_NANOS = 5_000_000_000L
        private const val DEFAULT_DART_ENTRYPOINT = "openXrMain"
        private const val DEFAULT_DART_LIBRARY_URI = "package:openxr_quest/open_xr_main.dart"
        private const val STOP_WAIT_LOG_SECONDS = 5L
        private const val UNTAGGED_FRAME = 0L
        private const val MAX_RENDERING_TAGS = 128
        // Stable surface identifiers name the two import queues, not textures.
        // Each acquired swapchain image receives a separate frame token.
        private const val DIRECT_LEFT_EYE_SURFACE = 0x4F58524CL
        private const val DIRECT_RIGHT_EYE_SURFACE = 0x4F585252L
        private const val EXTERNAL_FRAME_DISCARDED = 1
        private const val EXTERNAL_FRAME_ERROR = 3
        private const val DIRECT_CANCEL_WAIT_SECONDS = 2L
        private const val DIRECT_DIAGNOSTIC_FRAME_LIMIT = 3
    }
}
