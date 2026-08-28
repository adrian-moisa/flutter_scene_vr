#include <android/log.h>
#include <android/window.h>
#include <android_native_app_glue.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <jni.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "openxr_runtime_metrics.h"
#include "openxr_panel_controls.h"
#include "openxr_fps_hud.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <vector>
#include <utility>

namespace {

constexpr char kLogTag[] = "FlutterSceneOpenXR";
std::atomic<uint64_t> gPerformanceGeneration{0};
std::atomic<uint64_t> gPanelLayoutGeneration{0};
std::atomic_bool gQuarantinedGpuSession{false};
std::mutex gResolutionMutex;
uint64_t gResolutionRequestId = 0;
std::optional<std::pair<uint64_t, double>> gResolutionRequest;

constexpr float kThumbstickDeadzone = 0.22f;

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, kLogTag, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, kLogTag, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, kLogTag, __VA_ARGS__)

bool CheckXr(XrResult result, const char* operation) {
    if (XR_SUCCEEDED(result)) return true;
    LOGE("%s failed with OpenXR result %d", operation, result);
    return false;
}

bool CheckEgl(bool result, const char* operation) {
    if (result) return true;
    LOGE("%s failed with EGL error 0x%x", operation, eglGetError());
    return false;
}

float ApplyThumbstickDeadzone(float value) {
    const float magnitude = std::abs(value);
    if (magnitude <= kThumbstickDeadzone) return 0;
    const float adjustedMagnitude =
        (magnitude - kThumbstickDeadzone) / (1.0f - kThumbstickDeadzone);
    return std::copysign(adjustedMagnitude, value);
}

struct Swapchain {
    XrSwapchain handle = XR_NULL_HANDLE;
    int32_t width = 0;
    int32_t height = 0;
    std::vector<XrSwapchainImageOpenGLESKHR> images;
    bool hasReleasedImage = false;
};

struct FlutterSurface {
    GLuint texture = 0;
    jobject surfaceTexture = nullptr;
    jobject surface = nullptr;
    std::array<float, 16> textureTransform{};
    int64_t timestamp = 0;
    bool hasFrame = false;
    int32_t stereoWidth = 0;
    int32_t surfaceWidth = 0;
    int32_t surfaceHeight = 0;
};

struct CompositionQuadConfiguration {
    int32_t textureWidth = 0;
    int32_t textureHeight = 0;
    XrExtent2Df size{};
    XrPosef pose{{0, 0, 0, 1}, {0, 0, -1}};
    bool headLocked = false;
    int32_t panelSplitPixels = 0;

    bool Enabled() const {
        return textureWidth > 0 && textureHeight > 0 &&
            size.width > 0 && size.height > 0;
    }
};

struct FlutterTextureUpdate {
    bool latchedNewFrame = false;
    uint64_t viewSequence = 0;
};

enum class ProjectionResult { rendered, skipped, fatal };
enum class DirectEyeRenderResult { presented, discarded, terminalFailure, unresolved };

// One stereo pair is in flight: the XR worker waits while Flutter's threads
// render and report completion through JNI.
// Tokens identify an acquisition, since the runtime reuses texture names.
struct DirectStereoCompletion {
    std::mutex mutex;
    std::condition_variable changed;
    std::array<uint64_t, 2> tokens{};
    std::array<int, 2> statuses{3, 3};
    std::array<bool, 2> completed{};
    bool trace = false;
};

DirectStereoCompletion gDirectStereoCompletion;

void BeginDirectStereoFrame(const std::array<uint64_t, 2>& tokens, bool trace) {
    std::scoped_lock lock(gDirectStereoCompletion.mutex);
    gDirectStereoCompletion.tokens = tokens;
    gDirectStereoCompletion.statuses = {3, 3};
    gDirectStereoCompletion.completed = {false, false};
    gDirectStereoCompletion.trace = trace;
}

std::optional<std::array<int, 2>> WaitForDirectStereoFrame(
    const std::array<uint64_t, 2>& tokens,
    std::chrono::milliseconds timeout) {
    std::unique_lock lock(gDirectStereoCompletion.mutex);
    if (!gDirectStereoCompletion.changed.wait_for(lock, timeout, [tokens] {
            return gDirectStereoCompletion.tokens == tokens &&
                gDirectStereoCompletion.completed[0] &&
                gDirectStereoCompletion.completed[1];
        })) {
        LOGE(
            "Timed out waiting for direct OpenXR stereo tokens %llu/%llu "
            "completed=%d/%d status=%d/%d active=%llu/%llu",
            static_cast<unsigned long long>(tokens[0]),
            static_cast<unsigned long long>(tokens[1]),
            gDirectStereoCompletion.completed[0],
            gDirectStereoCompletion.completed[1],
            gDirectStereoCompletion.statuses[0],
            gDirectStereoCompletion.statuses[1],
            static_cast<unsigned long long>(gDirectStereoCompletion.tokens[0]),
            static_cast<unsigned long long>(gDirectStereoCompletion.tokens[1]));
        return std::nullopt;
    }
    if (gDirectStereoCompletion.trace ||
        gDirectStereoCompletion.statuses[0] != 0 ||
        gDirectStereoCompletion.statuses[1] != 0) {
        LOGI(
            "Direct stereo native completion tokens=%llu/%llu status=%d/%d",
            static_cast<unsigned long long>(tokens[0]),
            static_cast<unsigned long long>(tokens[1]),
            gDirectStereoCompletion.statuses[0],
            gDirectStereoCompletion.statuses[1]);
    }
    return gDirectStereoCompletion.statuses;
}

class StereoSurfaceRenderer {
public:
    explicit StereoSurfaceRenderer(android_app* app) : androidApp_(app) {
        flutterSurface_.textureTransform[0] = 1;
        flutterSurface_.textureTransform[5] = 1;
        flutterSurface_.textureTransform[10] = 1;
        flutterSurface_.textureTransform[15] = 1;
    }

    bool InitializeEgl(const XrGraphicsRequirementsOpenGLESKHR& requirements) {
        display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display_ == EGL_NO_DISPLAY) return CheckEgl(false, "eglGetDisplay");

        EGLint major = 0;
        EGLint minor = 0;
        if (!CheckEgl(eglInitialize(display_, &major, &minor) == EGL_TRUE, "eglInitialize")) {
            return false;
        }
        if (!CheckEgl(eglBindAPI(EGL_OPENGL_ES_API) == EGL_TRUE, "eglBindAPI")) return false;

        const EGLint configAttributes[] = {
            EGL_SURFACE_TYPE,
            EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE,
            EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE,
            8,
            EGL_GREEN_SIZE,
            8,
            EGL_BLUE_SIZE,
            8,
            EGL_ALPHA_SIZE,
            8,
            EGL_NONE,
        };
        EGLint configCount = 0;
        if (!CheckEgl(
                eglChooseConfig(display_, configAttributes, &config_, 1, &configCount) == EGL_TRUE &&
                    configCount > 0,
                "eglChooseConfig")) {
            return false;
        }

        // Texture storage is shared, but FBO names belong to their GLES context.
        // Pass eye textures to Flutter's bridge so it creates its own FBOs;
        // this context's framebuffer is reserved for native UI copies and the HUD.
        const EGLContext flutterShareContext = ReadFlutterShareContext();
        const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        context_ = eglCreateContext(display_, config_, flutterShareContext, contextAttributes);
        if (context_ == EGL_NO_CONTEXT) return CheckEgl(false, "eglCreateContext");

        const EGLint surfaceAttributes[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
        pbuffer_ = eglCreatePbufferSurface(display_, config_, surfaceAttributes);
        if (pbuffer_ == EGL_NO_SURFACE) return CheckEgl(false, "eglCreatePbufferSurface");
        if (!CheckEgl(
                eglMakeCurrent(display_, pbuffer_, pbuffer_, context_) == EGL_TRUE,
                "eglMakeCurrent")) {
            return false;
        }

        EGLint contextVersion = 0;
        eglQueryContext(display_, context_, EGL_CONTEXT_CLIENT_VERSION, &contextVersion);
        const XrVersion version = XR_MAKE_VERSION(contextVersion, 0, 0);
        if (version < requirements.minApiVersionSupported ||
            version > requirements.maxApiVersionSupported) {
            LOGE("OpenGL ES %d is outside the runtime-supported range", contextVersion);
            return false;
        }

        LOGI("Created OpenGL ES %d context", contextVersion);
        directLeftEyeAvailable_ = flutterShareContext != EGL_NO_CONTEXT;
        return InitializeCopyProgram();
    }

    // NativeActivity destruction can already be waiting for this thread, so
    // Java returns a recorded stop result or waits only for a bounded interval.
    bool StopFlutterProducer() {
        if (flutterSurface_.surface == nullptr &&
            flutterSurface_.surfaceTexture == nullptr) return true;
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return false;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID stop =
            env->GetMethodID(activityClass, "stopFlutterStereoSurface", "()Z");
        const bool stopped = stop != nullptr &&
            env->CallBooleanMethod(androidApp_->activity->clazz, stop) == JNI_TRUE;
        const bool failed = ClearJavaException(env, "stopFlutterStereoSurface");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        return stopped && !failed;
    }

    void QuarantineGpuResources() {
        gQuarantinedGpuSession.store(true);
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env != nullptr) {
            // Retain the producer engine too: Activity.onDestroy must not tear
            // down the share group while the unresolved image is quarantined.
            env->NewGlobalRef(androidApp_->activity->clazz);
            const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
            const jmethodID quarantine =
                env->GetMethodID(activityClass, "quarantineOpenXrGpuResources", "()V");
            if (quarantine != nullptr) {
                env->CallVoidMethod(androidApp_->activity->clazz, quarantine);
            }
            ClearJavaException(env, "quarantineOpenXrGpuResources");
            env->DeleteLocalRef(activityClass);
            DetachFromJava(attached);
        }
        LOGE("OpenXR GPU ownership could not be verified; retaining session, "
             "swapchains, surfaces and EGL contexts until process cleanup. "
             "Restart the application process before entering VR again.");
    }

    bool FinishOwnGpuCommands() {
        if (context_ == EGL_NO_CONTEXT) return true;
        if (eglGetCurrentContext() != context_ &&
            eglMakeCurrent(display_, pbuffer_, pbuffer_, context_) != EGL_TRUE) {
            return false;
        }
        glFinish();
        return true;
    }

    void Shutdown() {
        ReleaseFlutterSurface();
        if (quadVertexArray_ != 0) glDeleteVertexArrays(1, &quadVertexArray_);
        if (quadVertexBuffer_ != 0) glDeleteBuffers(1, &quadVertexBuffer_);
        if (copyProgram_ != 0) glDeleteProgram(copyProgram_);
        if (framebuffer_ != 0) glDeleteFramebuffers(1, &framebuffer_);

        if (display_ != EGL_NO_DISPLAY) {
            eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (pbuffer_ != EGL_NO_SURFACE) eglDestroySurface(display_, pbuffer_);
            if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
        }
        pbuffer_ = EGL_NO_SURFACE;
        context_ = EGL_NO_CONTEXT;
        display_ = EGL_NO_DISPLAY;
    }

    XrGraphicsBindingOpenGLESAndroidKHR GraphicsBinding() const {
        XrGraphicsBindingOpenGLESAndroidKHR binding{
            XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
        binding.display = display_;
        binding.config = config_;
        binding.context = context_;
        return binding;
    }

    CompositionQuadConfiguration ReadCompositionQuadConfiguration() const {
        CompositionQuadConfiguration configuration{};
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return configuration;

        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID read = env->GetMethodID(
            activityClass,
            "openXrCompositionQuadConfiguration",
            "()[D");
        if (read != nullptr) {
            const auto values = static_cast<jdoubleArray>(
                env->CallObjectMethod(androidApp_->activity->clazz, read));
            if (!ClearJavaException(env, "read OpenXR composition quad configuration") &&
                values != nullptr && env->GetArrayLength(values) >= 12) {
                std::array<double, 12> packed{};
                env->GetDoubleArrayRegion(values, 0, packed.size(), packed.data());
                configuration.textureWidth = static_cast<int32_t>(packed[0]);
                configuration.textureHeight = static_cast<int32_t>(packed[1]);
                configuration.size = {
                    static_cast<float>(packed[2]),
                    static_cast<float>(packed[3]),
                };
                configuration.pose.position = {
                    static_cast<float>(packed[4]),
                    static_cast<float>(packed[5]),
                    static_cast<float>(packed[6]),
                };
                configuration.pose.orientation = {
                    static_cast<float>(packed[7]),
                    static_cast<float>(packed[8]),
                    static_cast<float>(packed[9]),
                    static_cast<float>(packed[10]),
                };
                configuration.headLocked = packed[11] != 0;
                if (env->GetArrayLength(values) >= 13) {
                    double split = 0;
                    env->GetDoubleArrayRegion(values, 12, 1, &split);
                    if (split > 0 && split < configuration.textureWidth) {
                        configuration.panelSplitPixels = static_cast<int32_t>(split);
                    }
                }
            }
            if (values != nullptr) env->DeleteLocalRef(values);
        }
        ClearJavaException(env, "resolve OpenXR composition quad configuration");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        return configuration;
    }

    bool CreateFlutterSurface(
        int stereoWidth,
        int stereoHeight,
        const CompositionQuadConfiguration& compositionQuad) {
        // The projection layer renders directly into the two OpenXR images.
        // Keep Flutter's ordinary Android surface only for the optional UI
        // quad (or as a 1x1 context keeper when no quad is configured).
        const int surfaceWidth = std::max(
            1,
            compositionQuad.Enabled() ? compositionQuad.textureWidth : 0);
        const int surfaceHeight = std::max(
            1,
            compositionQuad.Enabled() ? compositionQuad.textureHeight : 0);
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return false;

        const jclass surfaceTextureClass = env->FindClass("android/graphics/SurfaceTexture");
        const jclass surfaceClass = env->FindClass("android/view/Surface");
        const jmethodID surfaceTextureConstructor =
            env->GetMethodID(surfaceTextureClass, "<init>", "(I)V");
        const jmethodID setDefaultBufferSize =
            env->GetMethodID(surfaceTextureClass, "setDefaultBufferSize", "(II)V");
        const jmethodID surfaceConstructor =
            env->GetMethodID(surfaceClass, "<init>", "(Landroid/graphics/SurfaceTexture;)V");
        bool success = !ClearJavaException(env, "resolve SurfaceTexture constructors") &&
            surfaceTextureConstructor != nullptr && setDefaultBufferSize != nullptr &&
            surfaceConstructor != nullptr;

        if (success) {
            glGenTextures(1, &flutterSurface_.texture);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, flutterSurface_.texture);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

            const jobject localTexture = env->NewObject(
                surfaceTextureClass,
                surfaceTextureConstructor,
                flutterSurface_.texture);
            env->CallVoidMethod(localTexture, setDefaultBufferSize, surfaceWidth, surfaceHeight);
            const jobject localSurface = env->NewObject(surfaceClass, surfaceConstructor, localTexture);
            success = localTexture != nullptr && localSurface != nullptr &&
                !ClearJavaException(env, "create Flutter stereo Surface");
            if (success) {
                flutterSurface_.surfaceTexture = env->NewGlobalRef(localTexture);
                flutterSurface_.surface = env->NewGlobalRef(localSurface);
            }
            if (localTexture != nullptr) env->DeleteLocalRef(localTexture);
            if (localSurface != nullptr) env->DeleteLocalRef(localSurface);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
        }

        if (success) {
            const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
            const jmethodID start = env->GetMethodID(
                activityClass,
                "startFlutterStereoSurface",
                "(Landroid/view/Surface;Landroid/graphics/SurfaceTexture;IIIIII)V");
            consumeFlutterFrameAvailableMethod_ = env->GetMethodID(
                activityClass,
                "consumeFlutterStereoFrameAvailable",
                "()Z");
            resolveFlutterFrameSequenceMethod_ = env->GetMethodID(
                activityClass,
                "resolveFlutterStereoFrameSequence",
                "(J)J");
            if (start != nullptr && consumeFlutterFrameAvailableMethod_ != nullptr &&
                resolveFlutterFrameSequenceMethod_ != nullptr) {
                env->CallVoidMethod(
                    androidApp_->activity->clazz,
                    start,
                    flutterSurface_.surface,
                    flutterSurface_.surfaceTexture,
                    stereoWidth,
                    stereoHeight,
                    surfaceWidth,
                    surfaceHeight,
                    compositionQuad.Enabled() ? compositionQuad.textureWidth : 0,
                    compositionQuad.Enabled() ? compositionQuad.textureHeight : 0);
            }
            success = start != nullptr && consumeFlutterFrameAvailableMethod_ != nullptr &&
                resolveFlutterFrameSequenceMethod_ != nullptr &&
                !ClearJavaException(env, "startFlutterStereoSurface");
            env->DeleteLocalRef(activityClass);
        }

        env->DeleteLocalRef(surfaceTextureClass);
        env->DeleteLocalRef(surfaceClass);
        DetachFromJava(attached);
        if (success) {
            flutterSurface_.stereoWidth = 0;
            flutterSurface_.surfaceWidth = surfaceWidth;
            flutterSurface_.surfaceHeight = surfaceHeight;
            LOGI(
                "Started Flutter UI surface %dx%d (direct stereo %dx%d)",
                surfaceWidth,
                surfaceHeight,
                stereoWidth,
                stereoHeight);
        }
        return success;
    }

    void PublishViews(
        const std::vector<XrView>& views,
        const std::array<XrVector2f, 2>& thumbsticks,
        const std::array<double, 18>& aims,
        uint64_t sequence,
        const std::optional<std::array<double, 11>>& panelInput) {
        if (views.size() != 2) return;

        std::vector<double> values(panelInput ? 56 : 45);
        values[0] = static_cast<double>(sequence);
        for (size_t eyeIndex = 0; eyeIndex < views.size(); ++eyeIndex) {
            const XrView& view = views[eyeIndex];
            const size_t offset = 1 + eyeIndex * 11;
            values[offset] = view.pose.position.x;
            values[offset + 1] = view.pose.position.y;
            values[offset + 2] = view.pose.position.z;
            values[offset + 3] = view.pose.orientation.x;
            values[offset + 4] = view.pose.orientation.y;
            values[offset + 5] = view.pose.orientation.z;
            values[offset + 6] = view.pose.orientation.w;
            values[offset + 7] = view.fov.angleLeft;
            values[offset + 8] = view.fov.angleRight;
            values[offset + 9] = view.fov.angleUp;
            values[offset + 10] = view.fov.angleDown;
        }
        values[23] = thumbsticks[0].x;
        values[24] = thumbsticks[0].y;
        values[25] = thumbsticks[1].x;
        values[26] = thumbsticks[1].y;
        std::copy(aims.begin(), aims.end(), values.begin() + 27);
        if (panelInput) std::copy(panelInput->begin(), panelInput->end(), values.begin() + 45);

        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID publish = env->GetMethodID(activityClass, "publishOpenXrViews", "([D)V");
        if (publish != nullptr) {
            const jdoubleArray packedViews = env->NewDoubleArray(values.size());
            env->SetDoubleArrayRegion(packedViews, 0, values.size(), values.data());
            env->CallVoidMethod(androidApp_->activity->clazz, publish, packedViews);
            env->DeleteLocalRef(packedViews);
        }
        ClearJavaException(env, "publishOpenXrViews");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
    }

    void PublishPerformance(const std::array<double, 24>& values) {
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID publish = env->GetMethodID(
            activityClass,
            "publishOpenXrPerformance",
            "([D)V");
        if (publish != nullptr) {
            const jdoubleArray packedPerformance = env->NewDoubleArray(values.size());
            env->SetDoubleArrayRegion(
                packedPerformance,
                0,
                values.size(),
                values.data());
            env->CallVoidMethod(
                androidApp_->activity->clazz,
                publish,
                packedPerformance);
            env->DeleteLocalRef(packedPerformance);
        }
        ClearJavaException(env, "publishOpenXrPerformance");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
    }

    void CompleteResolutionChange(uint64_t request, double scale, int width, int height, const char* error) {
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return;
        const jclass type = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID complete = env->GetMethodID(type, "completeOpenXrResolutionChange", "(JDIILjava/lang/String;)V");
        if (complete != nullptr) {
            const jstring message = error == nullptr ? nullptr : env->NewStringUTF(error);
            env->CallVoidMethod(androidApp_->activity->clazz, complete,
                static_cast<jlong>(request), scale, width, height, message);
            if (message != nullptr) env->DeleteLocalRef(message);
        }
        ClearJavaException(env, "completeOpenXrResolutionChange");
        env->DeleteLocalRef(type);
        DetachFromJava(attached);
    }

    bool IsPerformanceLoggingEnabled() const {
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return false;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID query = env->GetMethodID(
            activityClass,
            "isOpenXrPerformanceLoggingEnabled",
            "()Z");
        const bool enabled = query != nullptr &&
            env->CallBooleanMethod(androidApp_->activity->clazz, query) == JNI_TRUE;
        ClearJavaException(env, "query OpenXR performance logging");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        return enabled;
    }

    FlutterTextureUpdate UpdateFlutterTexture() {
        FlutterTextureUpdate result{};
        if (flutterSurface_.surfaceTexture == nullptr) return result;

        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return result;
        bool callbackReportedFrame = false;
        if (consumeFlutterFrameAvailableMethod_ != nullptr) {
            callbackReportedFrame = env->CallBooleanMethod(
                androidApp_->activity->clazz,
                consumeFlutterFrameAvailableMethod_) == JNI_TRUE;
            if (ClearJavaException(env, "consume Flutter stereo frame signal")) {
                callbackReportedFrame = true;
            }
        }
        const bool frameAvailable = !flutterSurface_.hasFrame || callbackReportedFrame;
        if (!frameAvailable) {
            DetachFromJava(attached);
            return result;
        }
        const jclass surfaceTextureClass = env->FindClass("android/graphics/SurfaceTexture");
        const jmethodID update = env->GetMethodID(surfaceTextureClass, "updateTexImage", "()V");
        const jmethodID getTransform =
            env->GetMethodID(surfaceTextureClass, "getTransformMatrix", "([F)V");
        const jmethodID getTimestamp =
            env->GetMethodID(surfaceTextureClass, "getTimestamp", "()J");

        if (!ClearJavaException(env, "resolve SurfaceTexture frame methods") && update != nullptr &&
            getTransform != nullptr && getTimestamp != nullptr) {
            env->CallVoidMethod(flutterSurface_.surfaceTexture, update);
            if (!ClearJavaException(env, "SurfaceTexture.updateTexImage")) {
                const jfloatArray transform = env->NewFloatArray(16);
                env->CallVoidMethod(flutterSurface_.surfaceTexture, getTransform, transform);
                if (!ClearJavaException(env, "SurfaceTexture.getTransformMatrix")) {
                    env->GetFloatArrayRegion(
                        transform,
                        0,
                        16,
                        flutterSurface_.textureTransform.data());
                }
                env->DeleteLocalRef(transform);

                const bool hadFrame = flutterSurface_.hasFrame;
                const int64_t timestamp = env->CallLongMethod(
                    flutterSurface_.surfaceTexture,
                    getTimestamp);
                flutterSurface_.hasFrame = timestamp > 0;
                result.latchedNewFrame = flutterSurface_.hasFrame &&
                    timestamp != flutterSurface_.timestamp;
                if (result.latchedNewFrame && resolveFlutterFrameSequenceMethod_ != nullptr) {
                    const jlong frameSequence = env->CallLongMethod(
                        androidApp_->activity->clazz,
                        resolveFlutterFrameSequenceMethod_,
                        static_cast<jlong>(timestamp));
                    if (!ClearJavaException(env, "resolve Flutter stereo frame sequence") &&
                        frameSequence > 0) {
                        result.viewSequence = static_cast<uint64_t>(frameSequence);
                    }
                }
                flutterSurface_.timestamp = timestamp;
                ClearJavaException(env, "SurfaceTexture.getTimestamp");
                if (!hadFrame && flutterSurface_.hasFrame) {
                    LOGI("Latched the first Flutter UI texture (not a direct eye completion)");
                }
            }
        }

        env->DeleteLocalRef(surfaceTextureClass);
        DetachFromJava(attached);
        return result;
    }

    void CopyCompositionQuadToSwapchain(
        GLuint colorTexture,
        int width,
        int height,
        bool targetIsSrgb) {
        const std::array<float, 4> sourceRect{0, 0, 1, 1};
        CopySurfaceRegionToSwapchain(
            colorTexture,
            width,
            height,
            sourceRect,
            targetIsSrgb);
    }

    void DrawNativeFpsHud(GLuint texture, int fps, bool paused, bool hovered) {
        openxr_panels::DrawFpsHud(framebuffer_, texture, fps, paused, hovered);
    }

    bool HasFlutterFrame() const { return flutterSurface_.hasFrame; }

    bool DirectStereoReady() const {
        if (!directLeftEyeAvailable_) return false;
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return false;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID ready = env->GetMethodID(
            activityClass,
            "isDirectEyeRendererReady",
            "()Z");
        const bool result = ready != nullptr &&
            env->CallBooleanMethod(androidApp_->activity->clazz, ready) == JNI_TRUE;
        ClearJavaException(env, "query direct OpenXR eye readiness");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        return result;
    }

    DirectEyeRenderResult RenderDirectStereo(
        const std::array<GLuint, 2>& colorTextures,
        const std::array<int, 2>& widths,
        const std::array<int, 2>& heights,
        int format,
        const std::array<uint64_t, 2>& frameTokens,
        uint64_t viewSequence) {
        // Limit startup diagnostics independently of the view sequence, which
        // can advance while the Dart renderer is still loading.
        const bool trace = directDiagnosticFrameCount_++ < 3 && IsPerformanceLoggingEnabled();
        BeginDirectStereoFrame(frameTokens, trace);
        if (trace) {
            LOGI(
                "Direct stereo native handoff seq=%llu tokens=%llu/%llu textures=%u/%u",
                static_cast<unsigned long long>(viewSequence),
                static_cast<unsigned long long>(frameTokens[0]),
                static_cast<unsigned long long>(frameTokens[1]),
                colorTextures[0], colorTextures[1]);
        }
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return DirectEyeRenderResult::unresolved;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID render = env->GetMethodID(
            activityClass,
            "renderOpenXrStereo",
            "(IIIIJIIIIJJ)Z");
        const bool queued = render != nullptr &&
            env->CallBooleanMethod(
                androidApp_->activity->clazz,
                render,
                static_cast<jint>(colorTextures[0]),
                static_cast<jint>(widths[0]),
                static_cast<jint>(heights[0]),
                static_cast<jint>(format),
                static_cast<jlong>(frameTokens[0]),
                static_cast<jint>(colorTextures[1]),
                static_cast<jint>(widths[1]),
                static_cast<jint>(heights[1]),
                static_cast<jint>(format),
                static_cast<jlong>(frameTokens[1]),
                static_cast<jlong>(viewSequence)) == JNI_TRUE;
        const bool failed = ClearJavaException(env, "queue direct OpenXR stereo frame");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        if (!queued || failed) {
            LOGE("Direct stereo Kotlin handoff failed queued=%d exception=%d", queued, failed);
            return DirectEyeRenderResult::unresolved;
        }
        const std::optional<std::array<int, 2>> firstCompletion =
            WaitForDirectStereoFrame(frameTokens, std::chrono::seconds(2));
        if (firstCompletion.has_value()) {
            // Engine status 1 means an unsubmitted lease was explicitly
            // discarded. Both eyes are safe to release, but must not be shown
            // or counted as fresh stereo content. Keep UI/session alive.
            if (firstCompletion.value()[0] == 1 && firstCompletion.value()[1] == 1) {
                LOGI("Discarded queued stereo frame during renderer transition");
                return DirectEyeRenderResult::discarded;
            }
            return firstCompletion.value()[0] == 0 && firstCompletion.value()[1] == 0
                ? DirectEyeRenderResult::presented
                : DirectEyeRenderResult::terminalFailure;
        }

        // Force any pending or acquired registry frame to a terminal callback
        // before the OpenXR thread releases or destroys the swapchain image.
        attached = false;
        env = AttachToJava(attached);
        bool cancellationCompleted = false;
        if (env != nullptr) {
            const jclass cancelActivityClass =
                env->GetObjectClass(androidApp_->activity->clazz);
            const jmethodID cancel = env->GetMethodID(
                cancelActivityClass,
                "cancelOpenXrStereoFrame",
                "()Z");
            if (cancel != nullptr) {
                cancellationCompleted = env->CallBooleanMethod(
                    androidApp_->activity->clazz,
                    cancel) == JNI_TRUE;
            }
            ClearJavaException(env, "cancel direct OpenXR stereo frame");
            env->DeleteLocalRef(cancelActivityClass);
            DetachFromJava(attached);
        }
        const std::optional<std::array<int, 2>> cancelledCompletion =
            WaitForDirectStereoFrame(frameTokens, std::chrono::seconds(2));
        if (cancelledCompletion.has_value()) {
            return cancelledCompletion.value()[0] == 0 &&
                    cancelledCompletion.value()[1] == 0
                ? DirectEyeRenderResult::presented
                : DirectEyeRenderResult::terminalFailure;
        }
        LOGE(
            "Direct OpenXR stereo tokens %llu/%llu remained unresolved after cancellation (%s)",
            static_cast<unsigned long long>(frameTokens[0]),
            static_cast<unsigned long long>(frameTokens[1]),
            cancellationCompleted ? "completed" : "failed");
        return DirectEyeRenderResult::unresolved;
    }

private:
    EGLContext ReadFlutterShareContext() const {
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env == nullptr) return EGL_NO_CONTEXT;
        const jclass activityClass = env->GetObjectClass(androidApp_->activity->clazz);
        const jmethodID read = env->GetMethodID(
            activityClass,
            "openGLESExternalContextDescriptor",
            "()[J");
        EGLContext shareContext = EGL_NO_CONTEXT;
        if (read != nullptr) {
            const auto values = static_cast<jlongArray>(
                env->CallObjectMethod(androidApp_->activity->clazz, read));
            if (!ClearJavaException(env, "read Flutter GLES share context") &&
                values != nullptr && env->GetArrayLength(values) == 3) {
                std::array<jlong, 3> packed{};
                env->GetLongArrayRegion(values, 0, packed.size(), packed.data());
                if (reinterpret_cast<EGLDisplay>(packed[0]) == display_) {
                    shareContext = reinterpret_cast<EGLContext>(packed[2]);
                }
            }
            if (values != nullptr) env->DeleteLocalRef(values);
        }
        ClearJavaException(env, "resolve Flutter GLES share context");
        env->DeleteLocalRef(activityClass);
        DetachFromJava(attached);
        return shareContext;
    }

    void CopySurfaceRegionToSwapchain(
        GLuint colorTexture,
        int width,
        int height,
        const std::array<float, 4>& sourceRect,
        bool targetIsSrgb) {
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
        glFramebufferTexture2D(
            GL_FRAMEBUFFER,
            GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D,
            colorTexture,
            0);
        if (!framebufferValidated_) {
            const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (status == GL_FRAMEBUFFER_COMPLETE) {
                LOGI("OpenXR copy framebuffer is complete (%dx%d)", width, height);
            } else {
                LOGE("OpenXR copy framebuffer is incomplete: 0x%x", status);
            }
            framebufferValidated_ = true;
        }

        glViewport(0, 0, width, height);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);

        if (flutterSurface_.hasFrame) {
            glUseProgram(copyProgram_);
            glUniformMatrix4fv(
                textureTransformUniform_,
                1,
                GL_FALSE,
                flutterSurface_.textureTransform.data());
            glUniform4fv(sourceRectUniform_, 1, sourceRect.data());
            glUniform1i(decodeSrgbUniform_, targetIsSrgb ? 1 : 0);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, flutterSurface_.texture);
            glUniform1i(textureUniform_, 0);
            glBindVertexArray(quadVertexArray_);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glBindVertexArray(0);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
        } else {
            glClearColor(0.008f, 0.013f, 0.026f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
        }

        glFlush();
    }

    // Only Flutter's UI atlas uses this copy shader in the direct-eye host.
    // Its Android texture orientation and sRGB conversion must not be applied
    // to scene eyes, whose camera/output passes already handle those contracts.
    bool InitializeCopyProgram() {
        static constexpr char kVertexShader[] = R"(#version 300 es
            layout(location = 0) in vec2 aPosition;
            layout(location = 1) in vec2 aUv;
            uniform mat4 uTextureTransform;
            uniform vec4 uSourceRect;
            out vec2 vUv;
            void main() {
                vec2 sourceUv = vec2(
                    mix(uSourceRect.x, uSourceRect.z, 1.0 - aUv.x),
                    mix(uSourceRect.y, uSourceRect.w, aUv.y));
                vUv = (uTextureTransform * vec4(sourceUv, 0.0, 1.0)).xy;
                gl_Position = vec4(aPosition, 0.0, 1.0);
            }
        )";
        static constexpr char kFragmentShader[] = R"(#version 300 es
            #extension GL_OES_EGL_image_external_essl3 : require
            precision highp float;
            in vec2 vUv;
            uniform samplerExternalOES uTexture;
            uniform bool uDecodeSrgb;
            out vec4 fragColor;

            vec3 srgbToLinear(vec3 value) {
                bvec3 low = lessThanEqual(value, vec3(0.04045));
                vec3 lower = value / 12.92;
                vec3 upper = pow((value + 0.055) / 1.055, vec3(2.4));
                return mix(upper, lower, low);
            }

            void main() {
                vec4 color = texture(uTexture, vUv);
                fragColor = vec4(uDecodeSrgb ? srgbToLinear(color.rgb) : color.rgb, 1.0);
            }
        )";

        const GLuint vertex = CompileShader(GL_VERTEX_SHADER, kVertexShader);
        const GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, kFragmentShader);
        if (vertex == 0 || fragment == 0) return false;

        copyProgram_ = glCreateProgram();
        glAttachShader(copyProgram_, vertex);
        glAttachShader(copyProgram_, fragment);
        glLinkProgram(copyProgram_);
        glDeleteShader(vertex);
        glDeleteShader(fragment);

        GLint linked = GL_FALSE;
        glGetProgramiv(copyProgram_, GL_LINK_STATUS, &linked);
        if (linked != GL_TRUE) {
            std::array<char, 2048> message{};
            glGetProgramInfoLog(copyProgram_, message.size(), nullptr, message.data());
            LOGE("Stereo copy program link failed: %s", message.data());
            return false;
        }

        textureTransformUniform_ = glGetUniformLocation(copyProgram_, "uTextureTransform");
        sourceRectUniform_ = glGetUniformLocation(copyProgram_, "uSourceRect");
        decodeSrgbUniform_ = glGetUniformLocation(copyProgram_, "uDecodeSrgb");
        textureUniform_ = glGetUniformLocation(copyProgram_, "uTexture");

        static constexpr std::array<float, 16> kQuadVertices{
            -1, -1, 0, 0,
            1, -1, 1, 0,
            -1, 1, 0, 1,
            1, 1, 1, 1,
        };
        glGenVertexArrays(1, &quadVertexArray_);
        glBindVertexArray(quadVertexArray_);
        glGenBuffers(1, &quadVertexBuffer_);
        glBindBuffer(GL_ARRAY_BUFFER, quadVertexBuffer_);
        glBufferData(
            GL_ARRAY_BUFFER,
            sizeof(kQuadVertices),
            kQuadVertices.data(),
            GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(
            1,
            2,
            GL_FLOAT,
            GL_FALSE,
            4 * sizeof(float),
            reinterpret_cast<void*>(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glGenFramebuffers(1, &framebuffer_);
        return true;
    }

    GLuint CompileShader(GLenum type, const char* source) {
        const GLuint shader = glCreateShader(type);
        glShaderSource(shader, 1, &source, nullptr);
        glCompileShader(shader);
        GLint compiled = GL_FALSE;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (compiled == GL_TRUE) return shader;

        std::array<char, 2048> message{};
        glGetShaderInfoLog(shader, message.size(), nullptr, message.data());
        LOGE("Stereo copy shader compile failed: %s", message.data());
        glDeleteShader(shader);
        return 0;
    }

    JNIEnv* AttachToJava(bool& attached) const {
        JNIEnv* env = nullptr;
        JavaVM* vm = androidApp_->activity->vm;
        if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
            return env;
        }
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
        attached = true;
        return env;
    }

    void DetachFromJava(bool attached) const {
        if (attached) androidApp_->activity->vm->DetachCurrentThread();
    }

    bool ClearJavaException(JNIEnv* env, const char* operation) const {
        if (!env->ExceptionCheck()) return false;
        LOGE("Java exception during %s", operation);
        env->ExceptionClear();
        return true;
    }

    void ReleaseFlutterSurface() {
        bool attached = false;
        JNIEnv* env = AttachToJava(attached);
        if (env != nullptr) {
            const jclass surfaceClass = env->FindClass("android/view/Surface");
            const jclass surfaceTextureClass = env->FindClass("android/graphics/SurfaceTexture");
            const jmethodID releaseSurface = env->GetMethodID(surfaceClass, "release", "()V");
            const jmethodID releaseTexture =
                env->GetMethodID(surfaceTextureClass, "release", "()V");
            ClearJavaException(env, "resolve Surface release methods");

            if (flutterSurface_.surface != nullptr) {
                if (releaseSurface != nullptr) {
                    env->CallVoidMethod(flutterSurface_.surface, releaseSurface);
                }
                env->DeleteGlobalRef(flutterSurface_.surface);
            }
            if (flutterSurface_.surfaceTexture != nullptr) {
                if (releaseTexture != nullptr) {
                    env->CallVoidMethod(flutterSurface_.surfaceTexture, releaseTexture);
                }
                env->DeleteGlobalRef(flutterSurface_.surfaceTexture);
            }
            ClearJavaException(env, "release Flutter stereo Surface");
            env->DeleteLocalRef(surfaceClass);
            env->DeleteLocalRef(surfaceTextureClass);
            DetachFromJava(attached);
        }

        flutterSurface_.surface = nullptr;
        flutterSurface_.surfaceTexture = nullptr;
        flutterSurface_.timestamp = 0;
        flutterSurface_.hasFrame = false;
        if (flutterSurface_.texture != 0) {
            glDeleteTextures(1, &flutterSurface_.texture);
            flutterSurface_.texture = 0;
        }
    }

    android_app* androidApp_ = nullptr;
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLConfig config_ = nullptr;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface pbuffer_ = EGL_NO_SURFACE;
    GLuint framebuffer_ = 0;
    GLuint copyProgram_ = 0;
    GLuint quadVertexArray_ = 0;
    GLuint quadVertexBuffer_ = 0;
    GLint textureTransformUniform_ = -1;
    GLint sourceRectUniform_ = -1;
    GLint decodeSrgbUniform_ = -1;
    GLint textureUniform_ = -1;
    FlutterSurface flutterSurface_{};
    jmethodID consumeFlutterFrameAvailableMethod_ = nullptr;
    jmethodID resolveFlutterFrameSequenceMethod_ = nullptr;
    bool framebufferValidated_ = false;
    bool directLeftEyeAvailable_ = false;
    uint64_t directDiagnosticFrameCount_ = 0;
};

class OpenXrApp {
public:
    explicit OpenXrApp(android_app* app) : androidApp_(app), renderer_(app) {}

    bool Initialize() {
        if (gQuarantinedGpuSession.load()) {
            LOGE("Cannot open another OpenXR session while GPU resources are quarantined; restart the process.");
            return false;
        }
        performanceLoggingEnabled_ = renderer_.IsPerformanceLoggingEnabled();
        if (!InitializeLoader()) return false;
        if (!CreateInstance()) return false;
        if (!GetSystem()) return false;
        if (!CreateGraphics()) return false;
        if (!CreateSession()) return false;
        if (runtimeMetricsExtensionEnabled_) {
            LOGI("+++ OpenXR runtime GPU/CPU metrics %s",
                 runtimeMetrics_.Enable(instance_, session_) ? "enabled" : "unavailable");
        }
        if (!CreateControllerInput()) return false;
        if (!CreateReferenceSpace()) return false;
        if (!CreateSwapchains()) return false;

        compositionQuadConfiguration_ = renderer_.ReadCompositionQuadConfiguration();
        if (compositionQuadConfiguration_.Enabled() &&
            !CreateUiSwapchain(compositionQuadSwapchain_,
                compositionQuadConfiguration_.textureWidth, compositionQuadConfiguration_.textureHeight)) return false;
        if (compositionQuadConfiguration_.panelSplitPixels > 0) {
            XrSystemProperties properties{XR_TYPE_SYSTEM_PROPERTIES};
            if (!CheckXr(xrGetSystemProperties(instance_, systemId_, &properties), "xrGetSystemProperties") ||
                properties.graphicsProperties.maxLayerCount < 4) {
                LOGE("Movable gallery panels and native FPS toggle require four compositor layers");
                return false;
            }
            if (!CreateUiSwapchain(fpsHudSwapchain_, 460, 130)) return false;
        }

        int stereoWidth = 0;
        int stereoHeight = 0;
        for (const Swapchain& swapchain : swapchains_) {
            stereoWidth = std::max(stereoWidth, swapchain.width * 2);
            stereoHeight = std::max(stereoHeight, swapchain.height);
        }
        if (!renderer_.CreateFlutterSurface(
                stereoWidth,
                stereoHeight,
                compositionQuadConfiguration_)) {
            return false;
        }

        performance_.started = PerformanceClock::now();
        livePerformance_.started = PerformanceClock::now();
        if (performanceLoggingEnabled_) {
            LOGI("+++ OpenXR native performance logging enabled");
        }

        LOGI("OpenXR host initialized with %zu stereo views", swapchains_.size());
        return true;
    }

    void Shutdown() {
        // A timeout or failed unregister never permits the runtime to destroy
        // an image Flutter might still write. These resources use explicit
        // native handles (no destructors release them), so skipping teardown
        // deliberately retains them until process cleanup.
        // Verified unregister is authoritative even if a dispatch never
        // reached Flutter and therefore never produced native token callbacks.
        if (!renderer_.StopFlutterProducer() || !renderer_.FinishOwnGpuCommands()) {
            renderer_.QuarantineGpuResources();
            return;
        }
        if (sessionRunning_ && session_ != XR_NULL_HANDLE) {
            SetPerformanceLevel(XR_PERF_SETTINGS_LEVEL_POWER_SAVINGS_EXT);
            xrEndSession(session_);
            sessionRunning_ = false;
        }
        for (Swapchain& swapchain : swapchains_) {
            if (swapchain.handle != XR_NULL_HANDLE) xrDestroySwapchain(swapchain.handle);
        }
        swapchains_.clear();
        if (compositionQuadSwapchain_.handle != XR_NULL_HANDLE) {
            xrDestroySwapchain(compositionQuadSwapchain_.handle);
        }
        compositionQuadSwapchain_ = {};
        if (fpsHudSwapchain_.handle != XR_NULL_HANDLE) xrDestroySwapchain(fpsHudSwapchain_.handle);
        fpsHudSwapchain_ = {};
        if (viewSpace_ != XR_NULL_HANDLE) xrDestroySpace(viewSpace_);
        if (appSpace_ != XR_NULL_HANDLE) xrDestroySpace(appSpace_);
        for (XrSpace space : aimSpaces_) if (space != XR_NULL_HANDLE) xrDestroySpace(space);
        aimSpaces_ = {XR_NULL_HANDLE, XR_NULL_HANDLE};
        if (aimAction_ != XR_NULL_HANDLE) xrDestroyAction(aimAction_);
        if (triggerAction_ != XR_NULL_HANDLE) xrDestroyAction(triggerAction_);
        if (gripAction_ != XR_NULL_HANDLE) xrDestroyAction(gripAction_);
        aimAction_ = triggerAction_ = gripAction_ = XR_NULL_HANDLE;
        if (thumbstickAction_ != XR_NULL_HANDLE) xrDestroyAction(thumbstickAction_);
        if (controllerActionSet_ != XR_NULL_HANDLE) xrDestroyActionSet(controllerActionSet_);
        if (session_ != XR_NULL_HANDLE) xrDestroySession(session_);
        renderer_.Shutdown();
        if (instance_ != XR_NULL_HANDLE) xrDestroyInstance(instance_);

        appSpace_ = XR_NULL_HANDLE;
        viewSpace_ = XR_NULL_HANDLE;
        thumbstickAction_ = XR_NULL_HANDLE;
        controllerActionSet_ = XR_NULL_HANDLE;
        session_ = XR_NULL_HANDLE;
        instance_ = XR_NULL_HANDLE;
    }

    void PollEvents() {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        while (xrPollEvent(instance_, &event) == XR_SUCCESS) {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                const auto* changed =
                    reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                sessionState_ = changed->state;
                LOGI("OpenXR session state changed to %d", sessionState_);
                HandleSessionState();
            } else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
                shouldExit_ = true;
            }
            event = {XR_TYPE_EVENT_DATA_BUFFER};
        }
    }

    bool RenderFrame() {
        if (!sessionRunning_) return true;

        // The previous frame has completed both GPU leases and xrEndFrame.
        // Resize only here, never while Flutter can still write an eye image.
        std::optional<std::pair<uint64_t, double>> resolution;
        {
            std::scoped_lock lock(gResolutionMutex);
            resolution = std::exchange(gResolutionRequest, std::nullopt);
        }
        if (resolution) {
            const bool applied = resolution->second == eyeRenderScale_ || CreateSwapchains(resolution->second);
            renderer_.CompleteResolutionChange(resolution->first, eyeRenderScale_,
                swapchains_[0].width, swapchains_[0].height,
                applied ? nullptr : "Eye resolution allocation failed; previous resolution retained.");
        }
        const uint64_t generation = gPerformanceGeneration.load();
        if (generation != performanceGeneration_) {
            performanceGeneration_ = generation;
            performance_ = {};
            livePerformance_ = {};
        }
        const auto waitStarted = PerformanceClock::now();
        XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState frameState{XR_TYPE_FRAME_STATE};
        if (!CheckXr(xrWaitFrame(session_, &waitInfo, &frameState), "xrWaitFrame")) return false;
        const auto waitFinished = PerformanceClock::now();

        XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
        if (!CheckXr(xrBeginFrame(session_, &beginInfo), "xrBeginFrame")) return false;
        const auto activeStarted = PerformanceClock::now();

        XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        XrCompositionLayerQuad compositionQuad{XR_TYPE_COMPOSITION_LAYER_QUAD};
        std::array<XrCompositionLayerQuad, 2> panelLayers{};
        XrCompositionLayerQuad fpsLayer{XR_TYPE_COMPOSITION_LAYER_QUAD};
        std::vector<XrCompositionLayerProjectionView> projectionViews;
        std::vector<const XrCompositionLayerBaseHeader*> layers;
        bool fatal = false;
        if (frameState.shouldRender == XR_TRUE) {
            const ProjectionResult result = RenderProjection(
                frameState.predictedDisplayTime,
                projectionViews,
                layer);
            if (result == ProjectionResult::rendered) {
                layers.push_back(
                    reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer));
                if (!firstFrameLogged_) {
                    LOGI("Submitted the first Flutter Scene OpenXR frame");
                    firstFrameLogged_ = true;
                }
            }
            const ProjectionResult quadResult = RenderCompositionQuad(compositionQuad);
            if (quadResult == ProjectionResult::rendered) {
                if (compositionQuadConfiguration_.panelSplitPixels > 0 && panelControls_.initialized) {
                    for (int i=0;i<2;++i) {
                        panelLayers[i] = compositionQuad;
                        panelLayers[i].space = appSpace_;
                        panelLayers[i].pose = panelControls_.panels[i];
                        panelLayers[i].size = panelControls_.sizes[i];
                        const int split = compositionQuadConfiguration_.panelSplitPixels;
                        panelLayers[i].subImage.imageRect.offset.x = i == 0 ? 0 : split;
                        panelLayers[i].subImage.imageRect.extent.width = i == 0 ? split : compositionQuadSwapchain_.width-split;
                    }
                    // Compositor panels have their own depth system: submit far to near.
                    const bool leftFarther = openxr_panels::LengthSquared(openxr_panels::Sub(panelLayers[0].pose.position, panelHead_.position)) >
                        openxr_panels::LengthSquared(openxr_panels::Sub(panelLayers[1].pose.position, panelHead_.position));
                    for (const int i : {leftFarther ? 0 : 1, leftFarther ? 1 : 0})
                        layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&panelLayers[i]));
                } else {
                    layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&compositionQuad));
                }
            }
            const auto hudResult = RenderFpsHud(fpsLayer);
            if (hudResult == ProjectionResult::rendered)
                layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&fpsLayer));
            fatal = quadResult == ProjectionResult::fatal || hudResult == ProjectionResult::fatal;
            fatal = fatal || result == ProjectionResult::fatal;
        }

        XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
        endInfo.displayTime = frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = blendMode_;
        endInfo.layerCount = layers.size();
        endInfo.layers = layers.empty() ? nullptr : layers.data();
        const bool ended = CheckXr(xrEndFrame(session_, &endInfo), "xrEndFrame");
        const double activeMicros = ElapsedMicros(activeStarted, PerformanceClock::now());
        livePerformance_.xrFrames++;
        if (!layers.empty()) livePerformance_.submittedFrames++;
        livePerformance_.activeMicros += activeMicros;
        livePerformance_.maximumActiveMicros =
            std::max(livePerformance_.maximumActiveMicros, activeMicros);
        MaybePublishLivePerformance();
        if (performanceLoggingEnabled_) {
            performance_.xrFrames++;
            if (!layers.empty()) performance_.submittedFrames++;
            performance_.waitMicros += ElapsedMicros(waitStarted, waitFinished);
            performance_.activeMicros += activeMicros;
            performance_.maximumActiveMicros =
                std::max(performance_.maximumActiveMicros, activeMicros);
            MaybeLogPerformance();
        }
        return ended && !fatal;
    }

    bool SessionRunning() const { return sessionRunning_; }
    bool ShouldExit() const { return shouldExit_; }

private:
    using PerformanceClock = std::chrono::steady_clock;

    struct PerformanceWindow {
        PerformanceClock::time_point started = PerformanceClock::now();
        uint64_t xrFrames = 0;
        uint64_t submittedFrames = 0;
        uint64_t newFlutterFrames = 0;
        uint64_t taggedFlutterFrames = 0;
        uint64_t untaggedFlutterFrames = 0;
        uint64_t poseTagMisses = 0;
        uint64_t poseAgeSamples = 0;
        uint64_t maximumPoseAgeFrames = 0;
        double poseAgeFrames = 0;
        uint64_t submittedPoseAgeSamples = 0;
        uint64_t maximumSubmittedPoseAgeFrames = 0;
        double submittedPoseAgeFrames = 0;
        uint64_t directStereoFrames = 0;
        uint64_t reusedSwapchainImages = 0;
        double waitMicros = 0;
        double activeMicros = 0;
        double maximumActiveMicros = 0;
        double publishMicros = 0;
        double latchMicros = 0;
        double swapchainWaitMicros = 0;
        double directRenderMicros = 0;
    };

    struct LivePerformanceWindow {
        PerformanceClock::time_point started = PerformanceClock::now();
        uint64_t xrFrames = 0;
        uint64_t submittedFrames = 0;
        uint64_t newFlutterFrames = 0;
        uint64_t submittedPoseAgeSamples = 0;
        uint64_t maximumSubmittedPoseAgeFrames = 0;
        double submittedPoseAgeFrames = 0;
        double activeMicros = 0;
        double maximumActiveMicros = 0;
        uint64_t directStereoFrames = 0;
        double directRenderMicros = 0;
        double maximumDirectRenderMicros = 0;
    };

    static double ElapsedMicros(
        PerformanceClock::time_point started,
        PerformanceClock::time_point finished) {
        return std::chrono::duration<double, std::micro>(finished - started).count();
    }

    static double MeanMillis(double totalMicros, uint64_t samples) {
        return samples == 0 ? 0 : totalMicros / static_cast<double>(samples) / 1000.0;
    }

    void MaybeLogPerformance() {
        const auto now = PerformanceClock::now();
        const double elapsedSeconds =
            std::chrono::duration<double>(now - performance_.started).count();
        if (elapsedSeconds < 5.0) return;

        const uint64_t reusedFrames = performance_.submittedFrames > performance_.newFlutterFrames
            ? performance_.submittedFrames - performance_.newFlutterFrames
            : 0;
        LOGI(
            "+++ OpenXR native perf | xr_hz=%.1f flutter_texture_hz=%.1f "
            "submitted=%llu reused=%llu tagged=%llu untagged=%llu tag_miss=%llu "
            "texture_pose_age_mean_frames=%.2f texture_pose_age_max_frames=%llu "
            "submit_pose_age_mean_frames=%.2f submit_pose_age_max_frames=%llu "
            "wait_mean_ms=%.2f active_mean_ms=%.2f "
            "active_max_ms=%.2f publish_mean_ms=%.3f latch_mean_ms=%.3f "
            "direct_stereo_frames=%llu swapchain_reuses=%llu "
            "swap_wait_mean_ms=%.3f direct_render_mean_ms=%.3f",
            performance_.xrFrames / elapsedSeconds,
            performance_.newFlutterFrames / elapsedSeconds,
            static_cast<unsigned long long>(performance_.submittedFrames),
            static_cast<unsigned long long>(reusedFrames),
            static_cast<unsigned long long>(performance_.taggedFlutterFrames),
            static_cast<unsigned long long>(performance_.untaggedFlutterFrames),
            static_cast<unsigned long long>(performance_.poseTagMisses),
            performance_.poseAgeSamples == 0
                ? 0
                : performance_.poseAgeFrames /
                    static_cast<double>(performance_.poseAgeSamples),
            static_cast<unsigned long long>(performance_.maximumPoseAgeFrames),
            performance_.submittedPoseAgeSamples == 0
                ? 0
                : performance_.submittedPoseAgeFrames /
                    static_cast<double>(performance_.submittedPoseAgeSamples),
            static_cast<unsigned long long>(performance_.maximumSubmittedPoseAgeFrames),
            MeanMillis(performance_.waitMicros, performance_.xrFrames),
            MeanMillis(performance_.activeMicros, performance_.xrFrames),
            performance_.maximumActiveMicros / 1000.0,
            MeanMillis(performance_.publishMicros, performance_.xrFrames),
            MeanMillis(performance_.latchMicros, performance_.xrFrames),
            static_cast<unsigned long long>(performance_.directStereoFrames),
            static_cast<unsigned long long>(performance_.reusedSwapchainImages),
            MeanMillis(
                performance_.swapchainWaitMicros,
                performance_.directStereoFrames),
            MeanMillis(
                performance_.directRenderMicros,
                performance_.directStereoFrames));
        performance_ = {};
        performance_.started = now;
    }

    // Direct time includes Dart dispatch and the wait for GPU completion.
    // It is not a GPU timer; optional runtime counters report that separately.
    void MaybePublishLivePerformance() {
        const auto now = PerformanceClock::now();
        const double elapsedSeconds =
            std::chrono::duration<double>(now - livePerformance_.started).count();
        if (elapsedSeconds < 1.0) return;

        const uint64_t reusedFrames =
            livePerformance_.submittedFrames > livePerformance_.newFlutterFrames
            ? livePerformance_.submittedFrames - livePerformance_.newFlutterFrames
            : 0;
        const double poseAgeMean = livePerformance_.submittedPoseAgeSamples == 0
            ? 0
            : livePerformance_.submittedPoseAgeFrames /
                static_cast<double>(livePerformance_.submittedPoseAgeSamples);
        float refreshRate = 0;
        if (getDisplayRefreshRate_ != nullptr) {
            if (XR_FAILED(getDisplayRefreshRate_(session_, &refreshRate))) refreshRate = 0;
        }
        const auto runtime = runtimeMetrics_.Sample();
        if (performanceLoggingEnabled_) {
            LOGI("+++ OpenXR runtime perf | app_cpu_ms=%.3f app_gpu_ms=%.3f "
                 "compositor_gpu_ms=%.3f gpu_utilization_percent=%.2f",
                 runtime[0], runtime[1], runtime[2], runtime[3]);
        }
        fpsHudValue_ = std::clamp(static_cast<int>(std::lround(livePerformance_.directStereoFrames / elapsedSeconds)), 0, 999);
        fpsHudDirty_ = true;
        if (performanceLoggingEnabled_) LOGI("+++ OpenXR UI comparison | ui_paused=%d direct_fps=%d ui_texture_hz=%.2f",
            panelControls_.uiPaused, fpsHudValue_, livePerformance_.newFlutterFrames / elapsedSeconds);
        renderer_.PublishPerformance({
            livePerformance_.xrFrames / elapsedSeconds,
            livePerformance_.submittedFrames / elapsedSeconds,
            livePerformance_.newFlutterFrames / elapsedSeconds,
            reusedFrames / elapsedSeconds,
            poseAgeMean,
            static_cast<double>(livePerformance_.maximumSubmittedPoseAgeFrames),
            MeanMillis(livePerformance_.activeMicros, livePerformance_.xrFrames),
            livePerformance_.maximumActiveMicros / 1000.0,
            livePerformance_.directStereoFrames / elapsedSeconds,
            MeanMillis(
                livePerformance_.directRenderMicros,
                livePerformance_.directStereoFrames),
            livePerformance_.maximumDirectRenderMicros / 1000.0,
            static_cast<double>(performanceGeneration_),
            swapchains_.empty() ? 0.0 : static_cast<double>(swapchains_[0].width),
            swapchains_.empty() ? 0.0 : static_cast<double>(swapchains_[0].height),
            static_cast<double>(refreshRate),
            runtime[0], runtime[1], runtime[2], runtime[3],
            static_cast<double>(configurationViews_[0].recommendedImageRectWidth),
            static_cast<double>(configurationViews_[0].recommendedImageRectHeight),
            static_cast<double>(configurationViews_[0].maxImageRectWidth),
            static_cast<double>(configurationViews_[0].maxImageRectHeight),
            eyeRenderScale_,
        });
        livePerformance_ = {};
        livePerformance_.started = now;
    }

    bool InitializeLoader() {
        PFN_xrInitializeLoaderKHR initializeLoader = nullptr;
        const XrResult result = xrGetInstanceProcAddr(
            XR_NULL_HANDLE,
            "xrInitializeLoaderKHR",
            reinterpret_cast<PFN_xrVoidFunction*>(&initializeLoader));
        if (XR_FAILED(result) || initializeLoader == nullptr) {
            LOGE("The Android OpenXR loader does not expose xrInitializeLoaderKHR");
            return false;
        }

        XrLoaderInitInfoAndroidKHR loaderInfo{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
        loaderInfo.applicationVM = androidApp_->activity->vm;
        loaderInfo.applicationContext = androidApp_->activity->clazz;
        return CheckXr(
            initializeLoader(reinterpret_cast<const XrLoaderInitInfoBaseHeaderKHR*>(&loaderInfo)),
            "xrInitializeLoaderKHR");
    }

    bool CreateInstance() {
        uint32_t extensionCount = 0;
        if (!CheckXr(
                xrEnumerateInstanceExtensionProperties(nullptr, 0, &extensionCount, nullptr),
                "xrEnumerateInstanceExtensionProperties")) {
            return false;
        }
        std::vector<XrExtensionProperties> available(extensionCount);
        for (auto& extension : available) extension.type = XR_TYPE_EXTENSION_PROPERTIES;
        if (!CheckXr(
                xrEnumerateInstanceExtensionProperties(
                    nullptr,
                    extensionCount,
                    &extensionCount,
                    available.data()),
                "xrEnumerateInstanceExtensionProperties")) {
            return false;
        }

        const auto hasExtension = [&available](const char* name) {
            return std::any_of(
                available.begin(),
                available.end(),
                [name](const XrExtensionProperties& extension) {
                    return std::strcmp(extension.extensionName, name) == 0;
                });
        };
        const std::array<const char*, 2> required{
            XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,
            XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME,
        };
        for (const char* extension : required) {
            if (!hasExtension(extension)) {
                LOGE("Required OpenXR extension is unavailable: %s", extension);
                return false;
            }
        }
        std::vector<const char*> enabledExtensions(required.begin(), required.end());
        runtimeMetricsExtensionEnabled_ = performanceLoggingEnabled_ &&
            hasExtension(XR_META_PERFORMANCE_METRICS_EXTENSION_NAME);
        if (runtimeMetricsExtensionEnabled_) {
            enabledExtensions.push_back(XR_META_PERFORMANCE_METRICS_EXTENSION_NAME);
        }
        performanceSettingsExtensionEnabled_ =
            hasExtension(XR_EXT_PERFORMANCE_SETTINGS_EXTENSION_NAME);
        if (performanceSettingsExtensionEnabled_) {
            enabledExtensions.push_back(XR_EXT_PERFORMANCE_SETTINGS_EXTENSION_NAME);
        }

        const bool displayRefresh = hasExtension(XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME);
        if (displayRefresh) enabledExtensions.push_back(XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME);

        XrInstanceCreateInfoAndroidKHR androidInfo{
            XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR};
        androidInfo.applicationVM = androidApp_->activity->vm;
        androidInfo.applicationActivity = androidApp_->activity->clazz;

        XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO};
        createInfo.next = &androidInfo;
        createInfo.enabledExtensionCount = enabledExtensions.size();
        createInfo.enabledExtensionNames = enabledExtensions.data();
        std::strncpy(
            createInfo.applicationInfo.applicationName,
            "Flutter Scene OpenXR",
            XR_MAX_APPLICATION_NAME_SIZE - 1);
        std::strncpy(
            createInfo.applicationInfo.engineName,
            "Flutter Scene",
            XR_MAX_ENGINE_NAME_SIZE - 1);
        createInfo.applicationInfo.applicationVersion = 1;
        createInfo.applicationInfo.engineVersion = 1;
        createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
        if (!CheckXr(xrCreateInstance(&createInfo, &instance_), "xrCreateInstance")) return false;

        if (performanceSettingsExtensionEnabled_) {
            const XrResult result = xrGetInstanceProcAddr(
                instance_,
                "xrPerfSettingsSetPerformanceLevelEXT",
                reinterpret_cast<PFN_xrVoidFunction*>(&setPerformanceLevel_));
            if (XR_FAILED(result) || setPerformanceLevel_ == nullptr) {
                performanceSettingsExtensionEnabled_ = false;
                LOGE("OpenXR performance-settings entry point is unavailable");
            }
        }

        if (displayRefresh) {
            xrGetInstanceProcAddr(instance_, "xrGetDisplayRefreshRateFB",
                reinterpret_cast<PFN_xrVoidFunction*>(&getDisplayRefreshRate_));
        }
        XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
        if (CheckXr(xrGetInstanceProperties(instance_, &properties), "xrGetInstanceProperties")) {
            LOGI("Using OpenXR runtime %s", properties.runtimeName);
        }
        return true;
    }

    void SetPerformanceLevel(XrPerfSettingsLevelEXT level) {
        if (!performanceSettingsExtensionEnabled_ || setPerformanceLevel_ == nullptr ||
            session_ == XR_NULL_HANDLE) {
            return;
        }
        const XrResult cpu = setPerformanceLevel_(
            session_,
            XR_PERF_SETTINGS_DOMAIN_CPU_EXT,
            level);
        const XrResult gpu = setPerformanceLevel_(
            session_,
            XR_PERF_SETTINGS_DOMAIN_GPU_EXT,
            level);
        if (XR_FAILED(cpu) || XR_FAILED(gpu)) {
            LOGE(
                "OpenXR performance-level request failed (CPU=%d, GPU=%d)",
                cpu,
                gpu);
            return;
        }
        LOGI(
            "OpenXR CPU/GPU performance level set to %s",
            level == XR_PERF_SETTINGS_LEVEL_SUSTAINED_HIGH_EXT
                ? "sustained-high"
                : "power-savings");
    }

    bool GetSystem() {
        XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
        systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        if (!CheckXr(xrGetSystem(instance_, &systemInfo, &systemId_), "xrGetSystem")) return false;

        uint32_t blendCount = 0;
        if (!CheckXr(
                xrEnumerateEnvironmentBlendModes(
                    instance_,
                    systemId_,
                    viewType_,
                    0,
                    &blendCount,
                    nullptr),
                "xrEnumerateEnvironmentBlendModes")) {
            return false;
        }
        std::vector<XrEnvironmentBlendMode> blendModes(blendCount);
        if (!CheckXr(
                xrEnumerateEnvironmentBlendModes(
                    instance_,
                    systemId_,
                    viewType_,
                    blendCount,
                    &blendCount,
                    blendModes.data()),
                "xrEnumerateEnvironmentBlendModes")) {
            return false;
        }
        blendMode_ = blendModes.empty() ? XR_ENVIRONMENT_BLEND_MODE_OPAQUE : blendModes.front();
        if (std::find(
                blendModes.begin(),
                blendModes.end(),
                XR_ENVIRONMENT_BLEND_MODE_OPAQUE) != blendModes.end()) {
            blendMode_ = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        }
        return true;
    }

    bool CreateGraphics() {
        PFN_xrGetOpenGLESGraphicsRequirementsKHR getRequirements = nullptr;
        if (!CheckXr(
                xrGetInstanceProcAddr(
                    instance_,
                    "xrGetOpenGLESGraphicsRequirementsKHR",
                    reinterpret_cast<PFN_xrVoidFunction*>(&getRequirements)),
                "xrGetOpenGLESGraphicsRequirementsKHR")) {
            return false;
        }

        XrGraphicsRequirementsOpenGLESKHR requirements{
            XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR};
        if (!CheckXr(
                getRequirements(instance_, systemId_, &requirements),
                "xrGetOpenGLESGraphicsRequirementsKHR")) {
            return false;
        }
        return renderer_.InitializeEgl(requirements);
    }

    bool CreateSession() {
        const XrGraphicsBindingOpenGLESAndroidKHR graphicsBinding = renderer_.GraphicsBinding();
        XrSessionCreateInfo createInfo{XR_TYPE_SESSION_CREATE_INFO};
        createInfo.next = &graphicsBinding;
        createInfo.systemId = systemId_;
        return CheckXr(xrCreateSession(instance_, &createInfo, &session_), "xrCreateSession");
    }

    bool CreateControllerInput() {
        XrActionSetCreateInfo actionSetInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
        std::strncpy(
            actionSetInfo.actionSetName,
            "flutter_scene",
            XR_MAX_ACTION_SET_NAME_SIZE - 1);
        std::strncpy(
            actionSetInfo.localizedActionSetName,
            "Flutter Scene",
            XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
        if (!CheckXr(
                xrCreateActionSet(instance_, &actionSetInfo, &controllerActionSet_),
                "xrCreateActionSet")) {
            return false;
        }

        if (!CheckXr(
                xrStringToPath(instance_, "/user/hand/left", &handPaths_[0]),
                "xrStringToPath(left hand)") ||
            !CheckXr(
                xrStringToPath(instance_, "/user/hand/right", &handPaths_[1]),
                "xrStringToPath(right hand)")) {
            return false;
        }

        XrActionCreateInfo thumbstickInfo{XR_TYPE_ACTION_CREATE_INFO};
        thumbstickInfo.actionType = XR_ACTION_TYPE_VECTOR2F_INPUT;
        std::strncpy(
            thumbstickInfo.actionName,
            "thumbsticks",
            XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(
            thumbstickInfo.localizedActionName,
            "Thumbsticks",
            XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        thumbstickInfo.countSubactionPaths = handPaths_.size();
        thumbstickInfo.subactionPaths = handPaths_.data();
        if (!CheckXr(
                xrCreateAction(controllerActionSet_, &thumbstickInfo, &thumbstickAction_),
                "xrCreateAction(thumbsticks)")) {
            return false;
        }

        std::array<XrPath, 2> thumbstickPaths{};
        XrPath touchControllerProfile = XR_NULL_PATH;
        if (!CheckXr(
                xrStringToPath(
                    instance_,
                    "/user/hand/left/input/thumbstick",
                    &thumbstickPaths[0]),
                "xrStringToPath(left thumbstick)") ||
            !CheckXr(
                xrStringToPath(
                    instance_,
                    "/user/hand/right/input/thumbstick",
                    &thumbstickPaths[1]),
                "xrStringToPath(right thumbstick)") ||
            !CheckXr(
                xrStringToPath(
                    instance_,
                    "/interaction_profiles/oculus/touch_controller",
                    &touchControllerProfile),
                "xrStringToPath(Touch controller profile)")) {
            return false;
        }

        XrActionCreateInfo aimInfo{XR_TYPE_ACTION_CREATE_INFO};
        aimInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
        std::strncpy(aimInfo.actionName, "ui_aim", XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(aimInfo.localizedActionName, "UI aim", XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        aimInfo.countSubactionPaths = handPaths_.size();
        aimInfo.subactionPaths = handPaths_.data();
        if (!CheckXr(xrCreateAction(controllerActionSet_, &aimInfo, &aimAction_), "xrCreateAction(aim)")) return false;
        XrActionCreateInfo triggerInfo = aimInfo;
        triggerInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
        std::strncpy(triggerInfo.actionName, "ui_trigger", XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(triggerInfo.localizedActionName, "UI trigger", XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        if (!CheckXr(xrCreateAction(controllerActionSet_, &triggerInfo, &triggerAction_), "xrCreateAction(trigger)")) return false;
        XrActionCreateInfo gripInfo = triggerInfo;
        std::strncpy(gripInfo.actionName, "panel_grip", XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(gripInfo.localizedActionName, "Move floating panel", XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        if (!CheckXr(xrCreateAction(controllerActionSet_, &gripInfo, &gripAction_), "xrCreateAction(grip)")) return false;
        std::array<XrPath, 2> aimPaths{}, triggerPaths{}, gripPaths{};
        for (size_t hand = 0; hand < 2; ++hand) {
            const char* aimPath = hand == 0 ? "/user/hand/left/input/aim/pose" : "/user/hand/right/input/aim/pose";
            const char* triggerPath = hand == 0 ? "/user/hand/left/input/trigger/value" : "/user/hand/right/input/trigger/value";
            if (!CheckXr(xrStringToPath(instance_, aimPath, &aimPaths[hand]), "aim path") ||
                !CheckXr(xrStringToPath(instance_, triggerPath, &triggerPaths[hand]), "trigger path")) return false;
            const char* gripPath = hand == 0 ? "/user/hand/left/input/squeeze/value" : "/user/hand/right/input/squeeze/value";
            if (!CheckXr(xrStringToPath(instance_, gripPath, &gripPaths[hand]), "grip path")) return false;
            XrActionSpaceCreateInfo spaceInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO};
            spaceInfo.action = aimAction_;
            spaceInfo.subactionPath = handPaths_[hand];
            spaceInfo.poseInActionSpace.orientation.w = 1;
            if (!CheckXr(xrCreateActionSpace(session_, &spaceInfo, &aimSpaces_[hand]), "xrCreateActionSpace(aim)")) return false;
        }
        const std::array<XrActionSuggestedBinding, 8> bindings{{
            {thumbstickAction_, thumbstickPaths[0]}, {thumbstickAction_, thumbstickPaths[1]},
            {aimAction_, aimPaths[0]}, {aimAction_, aimPaths[1]},
            {triggerAction_, triggerPaths[0]}, {triggerAction_, triggerPaths[1]},
            {gripAction_, gripPaths[0]}, {gripAction_, gripPaths[1]},
        }};
        XrInteractionProfileSuggestedBinding suggestedBindings{
            XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        suggestedBindings.interactionProfile = touchControllerProfile;
        suggestedBindings.countSuggestedBindings = bindings.size();
        suggestedBindings.suggestedBindings = bindings.data();
        if (!CheckXr(
                xrSuggestInteractionProfileBindings(instance_, &suggestedBindings),
                "xrSuggestInteractionProfileBindings")) {
            return false;
        }

        XrSessionActionSetsAttachInfo attachInfo{
            XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attachInfo.countActionSets = 1;
        attachInfo.actionSets = &controllerActionSet_;
        return CheckXr(
            xrAttachSessionActionSets(session_, &attachInfo),
            "xrAttachSessionActionSets");
    }

    std::array<XrVector2f, 2> ReadThumbsticks() {
        std::array<XrVector2f, 2> thumbsticks{};
        XrActiveActionSet activeActionSet{};
        activeActionSet.actionSet = controllerActionSet_;
        XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO};
        syncInfo.countActiveActionSets = 1;
        syncInfo.activeActionSets = &activeActionSet;
        actionsFocused_ = xrSyncActions(session_, &syncInfo) == XR_SUCCESS &&
            sessionState_ == XR_SESSION_STATE_FOCUSED;
        if (!actionsFocused_) return thumbsticks;

        for (size_t hand = 0; hand < handPaths_.size(); ++hand) {
            XrActionStateGetInfo stateInfo{XR_TYPE_ACTION_STATE_GET_INFO};
            stateInfo.action = thumbstickAction_;
            stateInfo.subactionPath = handPaths_[hand];
            XrActionStateVector2f state{XR_TYPE_ACTION_STATE_VECTOR2F};
            if (XR_SUCCEEDED(xrGetActionStateVector2f(session_, &stateInfo, &state)) &&
                state.isActive) {
                thumbsticks[hand] = {
                    ApplyThumbstickDeadzone(state.currentState.x),
                    ApplyThumbstickDeadzone(state.currentState.y),
                };
            }
        }
        return thumbsticks;
    }

    // Sample both hands in the same LOCAL space and predicted time as the eyes.
    // Native panel hit testing and Dart scene rays must agree on this sample;
    // Dart only intersects the legacy single-quad configuration itself.
    std::array<double, 18> ReadControllerAims(XrTime displayTime) const {
        std::array<double, 18> values{};
        if (!actionsFocused_) return values;
        for (size_t hand = 0; hand < 2; ++hand) {
            XrActionStateGetInfo info{XR_TYPE_ACTION_STATE_GET_INFO};
            info.subactionPath = handPaths_[hand];
            info.action = aimAction_;
            XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE};
            XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
            const XrSpaceLocationFlags valid = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
            if (XR_FAILED(xrGetActionStatePose(session_, &info, &state)) || !state.isActive ||
                XR_FAILED(xrLocateSpace(aimSpaces_[hand], appSpace_, displayTime, &location)) ||
                (location.locationFlags & valid) != valid) continue;
            const size_t offset = hand * 9;
            values[offset] = location.pose.position.x;
            values[offset + 1] = location.pose.position.y;
            values[offset + 2] = location.pose.position.z;
            values[offset + 3] = location.pose.orientation.x;
            values[offset + 4] = location.pose.orientation.y;
            values[offset + 5] = location.pose.orientation.z;
            values[offset + 6] = location.pose.orientation.w;
            values[offset + 7] = 1;
            info.action = triggerAction_;
            XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT};
            if (XR_SUCCEEDED(xrGetActionStateFloat(session_, &info, &trigger)) && trigger.isActive) {
                values[offset + 8] = trigger.currentState;
            }
        }
        return values;
    }

    std::array<float,2> ReadGrips() const {
        std::array<float,2> values{};
        if (!actionsFocused_) return values;
        for (int hand=0;hand<2;++hand) {
            XrActionStateGetInfo info{XR_TYPE_ACTION_STATE_GET_INFO};
            info.action = gripAction_;
            info.subactionPath = handPaths_[hand];
            XrActionStateFloat state{XR_TYPE_ACTION_STATE_FLOAT};
            if (XR_SUCCEEDED(xrGetActionStateFloat(session_, &info, &state)) && state.isActive)
                values[hand] = state.currentState;
        }
        return values;
    }

    bool CreateReferenceSpace() {
        XrReferenceSpaceCreateInfo createInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        createInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        createInfo.poseInReferenceSpace.orientation.w = 1;
        if (!CheckXr(
            xrCreateReferenceSpace(session_, &createInfo, &appSpace_),
            "xrCreateReferenceSpace(LOCAL)")) {
            return false;
        }

        createInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        return CheckXr(
            xrCreateReferenceSpace(session_, &createInfo, &viewSpace_),
            "xrCreateReferenceSpace(VIEW)");
    }

    bool CreateSwapchains(double scale = 1.0) {
        if (!std::isfinite(scale) || scale < 0.5 || scale > 1.5) return false;
        uint32_t viewCount = 0;
        if (!CheckXr(
                xrEnumerateViewConfigurationViews(
                    instance_,
                    systemId_,
                    viewType_,
                    0,
                    &viewCount,
                    nullptr),
                "xrEnumerateViewConfigurationViews")) {
            return false;
        }
        if (viewCount != 2) {
            LOGE("Expected two OpenXR views, got %u", viewCount);
            return false;
        }

        configurationViews_.resize(viewCount);
        for (auto& view : configurationViews_) view.type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
        if (!CheckXr(
                xrEnumerateViewConfigurationViews(
                    instance_,
                    systemId_,
                    viewType_,
                    viewCount,
                    &viewCount,
                    configurationViews_.data()),
                "xrEnumerateViewConfigurationViews")) {
            return false;
        }
        views_.resize(viewCount);
        for (auto& view : views_) view.type = XR_TYPE_VIEW;

        uint32_t formatCount = 0;
        if (!CheckXr(
                xrEnumerateSwapchainFormats(session_, 0, &formatCount, nullptr),
                "xrEnumerateSwapchainFormats")) {
            return false;
        }
        std::vector<int64_t> formats(formatCount);
        if (!CheckXr(
                xrEnumerateSwapchainFormats(
                    session_,
                    formatCount,
                    &formatCount,
                    formats.data()),
                "xrEnumerateSwapchainFormats")) {
            return false;
        }
        colorFormat_ = formats.empty() ? GL_RGBA8 : formats.front();
        for (const int64_t preferred : {
                 static_cast<int64_t>(GL_SRGB8_ALPHA8),
                 static_cast<int64_t>(GL_RGBA8),
             }) {
            if (std::find(formats.begin(), formats.end(), preferred) != formats.end()) {
                colorFormat_ = preferred;
                break;
            }
        }

        std::vector<Swapchain> replacement(viewCount);
        const auto cleanup = [&]() {
            for (auto& eye : replacement)
                if (eye.handle != XR_NULL_HANDLE) xrDestroySwapchain(eye.handle);
        };
        GLint maxTextureSize = 0;
        glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
        for (uint32_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            Swapchain& swapchain = replacement[viewIndex];
            swapchain.width = std::lround(configurationViews_[viewIndex].recommendedImageRectWidth * scale);
            swapchain.height = std::lround(configurationViews_[viewIndex].recommendedImageRectHeight * scale);
            if (swapchain.width > configurationViews_[viewIndex].maxImageRectWidth ||
                swapchain.height > configurationViews_[viewIndex].maxImageRectHeight ||
                swapchain.width > maxTextureSize || swapchain.height > maxTextureSize) {
                cleanup();
                return false;
            }

            XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
            createInfo.format = colorFormat_;
            createInfo.sampleCount = 1;
            createInfo.width = swapchain.width;
            createInfo.height = swapchain.height;
            createInfo.faceCount = 1;
            createInfo.arraySize = 1;
            createInfo.mipCount = 1;
            if (!CheckXr(
                    xrCreateSwapchain(session_, &createInfo, &swapchain.handle),
                    "xrCreateSwapchain")) {
                cleanup();
                return false;
            }

            uint32_t imageCount = 0;
            if (!CheckXr(
                    xrEnumerateSwapchainImages(swapchain.handle, 0, &imageCount, nullptr),
                    "xrEnumerateSwapchainImages")) {
                cleanup();
                return false;
            }
            swapchain.images.resize(imageCount);
            for (auto& image : swapchain.images) {
                image.type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR;
            }
            if (!CheckXr(
                    xrEnumerateSwapchainImages(
                        swapchain.handle,
                        imageCount,
                        &imageCount,
                        reinterpret_cast<XrSwapchainImageBaseHeader*>(
                            swapchain.images.data())),
                    "xrEnumerateSwapchainImages")) {
                cleanup();
                return false;
            }
        }

        // Commit only after both new eyes exist. Allocation failure leaves
        // the currently presented pair usable and returns a UI error.
        swapchains_.swap(replacement);
        cleanup();
        eyeRenderScale_ = scale;

        LOGI(
            "OpenXR eye size %dx%d, color format 0x%llx",
            swapchains_[0].width,
            swapchains_[0].height,
            static_cast<long long>(colorFormat_));
        return true;
    }

    bool CreateUiSwapchain(Swapchain& swapchain, int width, int height) {
        swapchain.width = width;
        swapchain.height = height;

        XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        createInfo.usageFlags =
            XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
        createInfo.format = colorFormat_;
        createInfo.sampleCount = 1;
        createInfo.width = swapchain.width;
        createInfo.height = swapchain.height;
        createInfo.faceCount = 1;
        createInfo.arraySize = 1;
        createInfo.mipCount = 1;
        if (!CheckXr(
                xrCreateSwapchain(session_, &createInfo, &swapchain.handle),
                "xrCreateSwapchain(composition quad)")) {
            return false;
        }

        uint32_t imageCount = 0;
        if (!CheckXr(
                xrEnumerateSwapchainImages(
                    swapchain.handle,
                    0,
                    &imageCount,
                    nullptr),
                "xrEnumerateSwapchainImages(composition quad)")) {
            return false;
        }
        swapchain.images.resize(imageCount);
        for (auto& image : swapchain.images) {
            image.type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR;
        }
        if (!CheckXr(
                xrEnumerateSwapchainImages(
                    swapchain.handle,
                    imageCount,
                    &imageCount,
                    reinterpret_cast<XrSwapchainImageBaseHeader*>(
                        swapchain.images.data())),
                "xrEnumerateSwapchainImages(composition quad)")) {
            return false;
        }

        LOGI(
            "Created OpenXR composition quad swapchain at %dx%d (%.3fm x %.3fm)",
            swapchain.width,
            swapchain.height,
            compositionQuadConfiguration_.size.width,
            compositionQuadConfiguration_.size.height);
        return true;
    }

    ProjectionResult RenderProjection(
        XrTime displayTime,
        std::vector<XrCompositionLayerProjectionView>& projectionViews,
        XrCompositionLayerProjection& layer) {
        XrViewLocateInfo locateInfo{XR_TYPE_VIEW_LOCATE_INFO};
        locateInfo.viewConfigurationType = viewType_;
        locateInfo.displayTime = displayTime;
        locateInfo.space = appSpace_;
        XrViewState viewState{XR_TYPE_VIEW_STATE};
        uint32_t viewCount = 0;
        if (!CheckXr(
                xrLocateViews(
                    session_,
                    &locateInfo,
                    &viewState,
                    views_.size(),
                    &viewCount,
                    views_.data()),
                "xrLocateViews")) {
            return ProjectionResult::fatal;
        }
        if (viewCount != views_.size() ||
            (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) == 0 ||
            (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) == 0) {
            return ProjectionResult::skipped;
        }
        if (viewCount != 2 || swapchains_.size() != 2) {
            LOGE("Direct OpenXR stereo rendering requires exactly two views");
            return ProjectionResult::fatal;
        }

        const uint64_t currentViewSequence = ++viewSequence_;
        RememberViewSample(currentViewSequence);
        const auto publishStarted = PerformanceClock::now();
        const auto thumbsticks = ReadThumbsticks();
        const auto aims = ReadControllerAims(displayTime);
        const bool rendererReady = renderer_.DirectStereoReady();
        std::optional<std::array<double,11>> panelInput;
        if (compositionQuadConfiguration_.panelSplitPixels > 0) {
            const auto now = PerformanceClock::now();
            const float dt = std::clamp(std::chrono::duration<float>(now-panelInputTime_).count(), 0.0f, .25f);
            panelInputTime_ = now;
            panelHead_ = views_[0].pose;
            panelHead_.position = openxr_panels::Scale(openxr_panels::Add(views_[0].pose.position, views_[1].pose.position), .5f);
            const auto layout = gPanelLayoutGeneration.load();
            if (layout != panelLayoutGeneration_) { panelControls_.ResetLayout(); panelLayoutGeneration_ = layout; }
            const bool paused = panelControls_.uiPaused;
            const bool hovered = panelControls_.hudHovered;
            panelControls_.Update(panelHead_, compositionQuadConfiguration_.pose,
                compositionQuadConfiguration_.size, compositionQuadConfiguration_.panelSplitPixels,
                compositionQuadConfiguration_.textureWidth, aims, ReadGrips(), thumbsticks, dt, rendererReady);
            if (paused != panelControls_.uiPaused || hovered != panelControls_.hudHovered) fpsHudDirty_ = true;
            panelInput = panelControls_.Pack(compositionQuadConfiguration_.panelSplitPixels,
                compositionQuadConfiguration_.textureWidth, compositionQuadConfiguration_.textureHeight);
        }
        renderer_.PublishViews(views_, thumbsticks, aims, currentViewSequence, panelInput);
        const auto publishFinished = PerformanceClock::now();
        // UI OFF bypasses SurfaceTexture latching and every Flutter panel copy.
        // The direct eye surfaces and their GPU ownership remain unchanged.
        const FlutterTextureUpdate textureUpdate = panelControls_.uiPaused
            ? FlutterTextureUpdate{} : renderer_.UpdateFlutterTexture();
        latchedNewFlutterFrame_ = textureUpdate.latchedNewFrame;
        const auto latchFinished = PerformanceClock::now();
        if (textureUpdate.latchedNewFrame) livePerformance_.newFlutterFrames++;
        if (performanceLoggingEnabled_) {
            performance_.publishMicros += ElapsedMicros(publishStarted, publishFinished);
            performance_.latchMicros += ElapsedMicros(publishFinished, latchFinished);
            if (textureUpdate.latchedNewFrame) performance_.newFlutterFrames++;
        }
        if (!rendererReady) return ProjectionResult::skipped;

        projectionViews.resize(viewCount);
        std::array<uint32_t, 2> imageIndices{};
        std::array<GLuint, 2> colorTextures{};
        std::array<int, 2> widths{};
        std::array<int, 2> heights{};
        std::array<uint64_t, 2> frameTokens{};
        std::array<bool, 2> acquired{};
        std::array<bool, 2> waited{};

        for (uint32_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            Swapchain& swapchain = swapchains_[viewIndex];
            XrCompositionLayerProjectionView& projectionView = projectionViews[viewIndex];
            projectionView = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
            projectionView.pose = views_[viewIndex].pose;
            projectionView.fov = views_[viewIndex].fov;
            projectionView.subImage.swapchain = swapchain.handle;
            projectionView.subImage.imageRect = {{0, 0}, {swapchain.width, swapchain.height}};
            projectionView.subImage.imageArrayIndex = 0;

            XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            if (!CheckXr(
                    xrAcquireSwapchainImage(
                        swapchain.handle,
                        &acquireInfo,
                        &imageIndices[viewIndex]),
                    "xrAcquireSwapchainImage")) {
                for (uint32_t acquiredIndex = 0;
                     acquiredIndex < viewIndex;
                     ++acquiredIndex) {
                    XrSwapchainImageWaitInfo waitInfo{
                        XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                    waitInfo.timeout = XR_INFINITE_DURATION;
                    if (CheckXr(
                            xrWaitSwapchainImage(
                                swapchains_[acquiredIndex].handle,
                                &waitInfo),
                            "xrWaitSwapchainImage(after peer acquire failure)")) {
                        XrSwapchainImageReleaseInfo releaseInfo{
                            XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                        xrReleaseSwapchainImage(
                            swapchains_[acquiredIndex].handle,
                            &releaseInfo);
                    }
                }
                return ProjectionResult::fatal;
            }
            acquired[viewIndex] = true;
            colorTextures[viewIndex] =
                swapchain.images[imageIndices[viewIndex]].image;
            widths[viewIndex] = swapchain.width;
            heights[viewIndex] = swapchain.height;
            // Encode the eye as well as the pose sequence, so one eye's callback
            // cannot release its peer or a later reuse of the same texture.
            frameTokens[viewIndex] =
                (currentViewSequence << 2u) | static_cast<uint64_t>(viewIndex + 1u);
        }

        const auto swapchainWaitStarted = PerformanceClock::now();
        for (uint32_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            Swapchain& swapchain = swapchains_[viewIndex];
            XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            waitInfo.timeout = XR_INFINITE_DURATION;
            if (!CheckXr(
                    xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                    "xrWaitSwapchainImage")) {
                for (uint32_t acquiredIndex = 0;
                     acquiredIndex < viewCount;
                     ++acquiredIndex) {
                    if (!acquired[acquiredIndex] || !waited[acquiredIndex]) {
                        continue;
                    }
                    XrSwapchainImageReleaseInfo releaseInfo{
                        XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                    xrReleaseSwapchainImage(
                        swapchains_[acquiredIndex].handle,
                        &releaseInfo);
                }
                return ProjectionResult::fatal;
            }
            waited[viewIndex] = true;
        }
        const auto swapchainWaitFinished = PerformanceClock::now();

        const auto directRenderStarted = PerformanceClock::now();
        const DirectEyeRenderResult directResult = renderer_.RenderDirectStereo(
            colorTextures,
            widths,
            heights,
            static_cast<int>(colorFormat_),
            frameTokens,
            currentViewSequence);
        const auto directRenderFinished = PerformanceClock::now();
        if (directResult == DirectEyeRenderResult::unresolved) {
            // One or both images may still be owned by Flutter. Releasing
            // either would permit the runtime to reuse a possibly in-flight
            // target, so leave both acquired and force session teardown.
            return ProjectionResult::fatal;
        }

        bool releasedAll = true;
        for (uint32_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            Swapchain& swapchain = swapchains_[viewIndex];
            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            if (!CheckXr(
                    xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                    "xrReleaseSwapchainImage")) {
                releasedAll = false;
            } else {
                swapchain.hasReleasedImage = true;
            }
        }
        if (!releasedAll || directResult == DirectEyeRenderResult::terminalFailure) {
            return ProjectionResult::fatal;
        }
        if (directResult == DirectEyeRenderResult::discarded) {
            return ProjectionResult::skipped;
        }
        if (performanceLoggingEnabled_) {
            performance_.directStereoFrames++;
            performance_.swapchainWaitMicros +=
                ElapsedMicros(swapchainWaitStarted, swapchainWaitFinished);
            performance_.directRenderMicros +=
                ElapsedMicros(directRenderStarted, directRenderFinished);
        }
        const double directRenderMicros =
            ElapsedMicros(directRenderStarted, directRenderFinished);
        livePerformance_.directStereoFrames++;
        livePerformance_.directRenderMicros += directRenderMicros;
        livePerformance_.maximumDirectRenderMicros = std::max(
            livePerformance_.maximumDirectRenderMicros,
            directRenderMicros);

        layer.space = appSpace_;
        layer.layerFlags = 0;
        layer.viewCount = projectionViews.size();
        layer.views = projectionViews.data();
        return ProjectionResult::rendered;
    }

    ProjectionResult RenderCompositionQuad(XrCompositionLayerQuad& layer) {
        if (panelControls_.uiPaused || !compositionQuadConfiguration_.Enabled() ||
            !renderer_.HasFlutterFrame()) {
            return ProjectionResult::skipped;
        }

        // Re-submit the last released UI image until Flutter paints a new one.
        // Panel poses can still move every XR frame without repainting widgets.
        Swapchain& swapchain = compositionQuadSwapchain_;
        if (latchedNewFlutterFrame_ || !swapchain.hasReleasedImage) {
            uint32_t imageIndex = 0;
            XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            if (!CheckXr(
                    xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &imageIndex),
                    "xrAcquireSwapchainImage(composition quad)")) {
                return ProjectionResult::fatal;
            }

            XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            waitInfo.timeout = XR_INFINITE_DURATION;
            if (!CheckXr(
                    xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                    "xrWaitSwapchainImage(composition quad)")) {
                XrSwapchainImageReleaseInfo releaseInfo{
                    XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                xrReleaseSwapchainImage(swapchain.handle, &releaseInfo);
                return ProjectionResult::fatal;
            }

            renderer_.CopyCompositionQuadToSwapchain(
                swapchain.images[imageIndex].image,
                swapchain.width,
                swapchain.height,
                colorFormat_ == GL_SRGB8_ALPHA8);

            XrSwapchainImageReleaseInfo releaseInfo{
                XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            if (!CheckXr(
                    xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                    "xrReleaseSwapchainImage(composition quad)")) {
                return ProjectionResult::fatal;
            }
            swapchain.hasReleasedImage = true;
        }

        layer.layerFlags = 0;
        layer.space = compositionQuadConfiguration_.headLocked
            ? viewSpace_
            : appSpace_;
        layer.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        layer.subImage.swapchain = swapchain.handle;
        layer.subImage.imageRect = {{0, 0}, {swapchain.width, swapchain.height}};
        layer.subImage.imageArrayIndex = 0;
        layer.pose = compositionQuadConfiguration_.pose;
        layer.size = compositionQuadConfiguration_.size;
        return ProjectionResult::rendered;
    }

    ProjectionResult RenderFpsHud(XrCompositionLayerQuad& layer) {
        auto& swapchain = fpsHudSwapchain_;
        if (swapchain.handle == XR_NULL_HANDLE) return ProjectionResult::skipped;
        if (fpsHudDirty_ || !swapchain.hasReleasedImage) {
            uint32_t index=0;
            XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            if (!CheckXr(xrAcquireSwapchainImage(swapchain.handle, &acquire, &index), "acquire FPS HUD")) return ProjectionResult::fatal;
            XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            wait.timeout = XR_INFINITE_DURATION;
            if (!CheckXr(xrWaitSwapchainImage(swapchain.handle, &wait), "wait FPS HUD")) return ProjectionResult::fatal;
            renderer_.DrawNativeFpsHud(swapchain.images[index].image, fpsHudValue_, panelControls_.uiPaused, panelControls_.hudHovered);
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            if (!CheckXr(xrReleaseSwapchainImage(swapchain.handle, &release), "release FPS HUD")) return ProjectionResult::fatal;
            swapchain.hasReleasedImage = true;
            fpsHudDirty_ = false;
        }
        layer.space = viewSpace_;
        layer.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        layer.subImage.swapchain = swapchain.handle;
        layer.subImage.imageRect = {{0,0},{swapchain.width,swapchain.height}};
        layer.pose = openxr_panels::Controls::hudPose;
        layer.size = openxr_panels::Controls::hudSize;
        return ProjectionResult::rendered;
    }

    // Retained legacy SurfaceTexture pose bookkeeping is not used to submit
    // direct eyes; those retain the exact views from their synchronous XR request.
    struct ViewSample {
        uint64_t sequence = 0;
        std::array<XrView, 2> views{};
    };

    void RememberViewSample(uint64_t sequence) {
        ViewSample& sample = viewSamples_[sequence % viewSamples_.size()];
        sample.sequence = sequence;
        sample.views[0] = views_[0];
        sample.views[1] = views_[1];
    }

    bool ApplyFlutterTexturePose(uint64_t sequence) {
        if (sequence == 0) {
            if (performanceLoggingEnabled_) performance_.untaggedFlutterFrames++;
            return false;
        }

        const ViewSample& sample = viewSamples_[sequence % viewSamples_.size()];
        if (sample.sequence != sequence) {
            if (performanceLoggingEnabled_) performance_.poseTagMisses++;
            return false;
        }

        flutterTextureViews_ = sample.views;
        hasFlutterTextureViews_ = true;
        flutterTextureViewSequence_ = sequence;
        if (performanceLoggingEnabled_) {
            performance_.taggedFlutterFrames++;
            const uint64_t age = viewSequence_ >= sequence ? viewSequence_ - sequence : 0;
            performance_.poseAgeSamples++;
            performance_.poseAgeFrames += static_cast<double>(age);
            performance_.maximumPoseAgeFrames =
                std::max(performance_.maximumPoseAgeFrames, age);
        }
        return true;
    }

    void CopyCurrentViewsToFlutterTexturePose() {
        flutterTextureViews_[0] = views_[0];
        flutterTextureViews_[1] = views_[1];
        hasFlutterTextureViews_ = true;
        flutterTextureViewSequence_ = viewSequence_;
    }

    void HandleSessionState() {
        if (sessionState_ == XR_SESSION_STATE_READY && !sessionRunning_) {
            XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
            beginInfo.primaryViewConfigurationType = viewType_;
            if (CheckXr(xrBeginSession(session_, &beginInfo), "xrBeginSession")) {
                sessionRunning_ = true;
                SetPerformanceLevel(XR_PERF_SETTINGS_LEVEL_SUSTAINED_HIGH_EXT);
            }
        } else if (sessionState_ == XR_SESSION_STATE_STOPPING && sessionRunning_) {
            SetPerformanceLevel(XR_PERF_SETTINGS_LEVEL_POWER_SAVINGS_EXT);
            CheckXr(xrEndSession(session_), "xrEndSession");
            sessionRunning_ = false;
        } else if (
            sessionState_ == XR_SESSION_STATE_EXITING ||
            sessionState_ == XR_SESSION_STATE_LOSS_PENDING) {
            shouldExit_ = true;
        }
    }

    android_app* androidApp_ = nullptr;
    StereoSurfaceRenderer renderer_;
    XrInstance instance_ = XR_NULL_HANDLE;
    XrSystemId systemId_ = XR_NULL_SYSTEM_ID;
    XrSession session_ = XR_NULL_HANDLE;
    XrSpace appSpace_ = XR_NULL_HANDLE;
    XrSpace viewSpace_ = XR_NULL_HANDLE;
    XrActionSet controllerActionSet_ = XR_NULL_HANDLE;
    XrAction thumbstickAction_ = XR_NULL_HANDLE;
    XrAction aimAction_ = XR_NULL_HANDLE;
    XrAction triggerAction_ = XR_NULL_HANDLE;
    XrAction gripAction_ = XR_NULL_HANDLE;
    bool actionsFocused_ = false;
    std::array<XrSpace, 2> aimSpaces_{XR_NULL_HANDLE, XR_NULL_HANDLE};
    uint64_t performanceGeneration_ = 0;
    PFN_xrGetDisplayRefreshRateFB getDisplayRefreshRate_ = nullptr;
    OpenXrRuntimeMetrics runtimeMetrics_;
    bool runtimeMetricsExtensionEnabled_ = false;
    std::array<XrPath, 2> handPaths_{XR_NULL_PATH, XR_NULL_PATH};
    XrSessionState sessionState_ = XR_SESSION_STATE_UNKNOWN;
    XrViewConfigurationType viewType_ = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    XrEnvironmentBlendMode blendMode_ = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    std::vector<XrViewConfigurationView> configurationViews_;
    std::vector<XrView> views_;
    std::vector<Swapchain> swapchains_;
    double eyeRenderScale_ = 1.0;
    Swapchain compositionQuadSwapchain_{};
    Swapchain fpsHudSwapchain_{};
    openxr_panels::Controls panelControls_{};
    XrPosef panelHead_{{0,0,0,1},{0,0,0}};
    PerformanceClock::time_point panelInputTime_ = PerformanceClock::now();
    uint64_t panelLayoutGeneration_ = 0;
    int fpsHudValue_ = 0;
    bool fpsHudDirty_ = true;
    CompositionQuadConfiguration compositionQuadConfiguration_{};
    int64_t colorFormat_ = GL_RGBA8;
    PFN_xrPerfSettingsSetPerformanceLevelEXT setPerformanceLevel_ = nullptr;
    uint64_t viewSequence_ = 0;
    static constexpr size_t kViewSampleCount = 32;
    std::array<ViewSample, kViewSampleCount> viewSamples_{};
    std::array<XrView, 2> flutterTextureViews_{};
    uint64_t flutterTextureViewSequence_ = 0;
    PerformanceWindow performance_{};
    LivePerformanceWindow livePerformance_{};
    bool performanceSettingsExtensionEnabled_ = false;
    bool performanceLoggingEnabled_ = false;
    bool sessionRunning_ = false;
    bool shouldExit_ = false;
    bool firstFrameLogged_ = false;
    bool hasFlutterTextureViews_ = false;
    bool latchedNewFlutterFrame_ = false;
};

struct AndroidLifecycle {
    bool resumed = false;
};

void HandleAppCommand(android_app* app, int32_t command) {
    auto* lifecycle = static_cast<AndroidLifecycle*>(app->userData);
    if (command == APP_CMD_RESUME) lifecycle->resumed = true;
    if (command == APP_CMD_PAUSE || command == APP_CMD_STOP) lifecycle->resumed = false;
}

void DrainLifecycleUntilDestroyed(android_app* app) {
    while (app->destroyRequested == 0) {
        int events = 0;
        android_poll_source* source = nullptr;
        if (ALooper_pollOnce(50, nullptr, &events, reinterpret_cast<void**>(&source)) >= 0 &&
            source != nullptr) {
            source->process(app, source);
        }
    }
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_dev_bdero_flutter_1scene_1openxr_FlutterSceneOpenXrActivity_nativeOnExternalGpuSurfaceFrameReleased(
    JNIEnv*,
    jobject,
    jlong frameToken,
    jint status) {
    std::scoped_lock lock(gDirectStereoCompletion.mutex);
    const uint64_t token = static_cast<uint64_t>(frameToken);
    for (size_t eyeIndex = 0; eyeIndex < 2; ++eyeIndex) {
        if (gDirectStereoCompletion.tokens[eyeIndex] != token) continue;
        gDirectStereoCompletion.statuses[eyeIndex] = status;
        gDirectStereoCompletion.completed[eyeIndex] = true;
        if (gDirectStereoCompletion.trace || status != 0) {
            LOGI("Direct stereo JNI callback token=%llu eye=%zu status=%d",
                 static_cast<unsigned long long>(token), eyeIndex, status);
        }
        gDirectStereoCompletion.changed.notify_all();
        return;
    }
    LOGW("Direct stereo ignored stale callback token=%llu active=%llu/%llu status=%d",
         static_cast<unsigned long long>(token),
         static_cast<unsigned long long>(gDirectStereoCompletion.tokens[0]),
         static_cast<unsigned long long>(gDirectStereoCompletion.tokens[1]), status);
}

extern "C" void android_main(android_app* app) {
    AndroidLifecycle lifecycle{};
    app->userData = &lifecycle;
    app->onAppCmd = HandleAppCommand;
    ANativeActivity_setWindowFlags(app->activity, AWINDOW_FLAG_KEEP_SCREEN_ON, 0);

    {
        std::scoped_lock lock(gResolutionMutex);
        gResolutionRequest.reset();
    }
    OpenXrApp openXr(app);
    if (!openXr.Initialize()) {
        LOGE("OpenXR initialization failed; returning to the flat Flutter preview");
        if (app->destroyRequested == 0) {
            ANativeActivity_finish(app->activity);
            DrainLifecycleUntilDestroyed(app);
        }
        openXr.Shutdown();
        return;
    }

    while (app->destroyRequested == 0 && !openXr.ShouldExit()) {
        for (;;) {
            int events = 0;
            android_poll_source* source = nullptr;
            const int timeout = openXr.SessionRunning() && lifecycle.resumed ? 0 : 50;
            if (ALooper_pollOnce(
                    timeout,
                    nullptr,
                    &events,
                    reinterpret_cast<void**>(&source)) < 0) {
                break;
            }
            if (source != nullptr) source->process(app, source);
            if (app->destroyRequested != 0) break;
        }

        openXr.PollEvents();
        if (openXr.SessionRunning() && lifecycle.resumed && !openXr.RenderFrame()) break;
    }

    if (app->destroyRequested == 0) {
        ANativeActivity_finish(app->activity);
        DrainLifecycleUntilDestroyed(app);
    }
    openXr.Shutdown();
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_bdero_flutter_1scene_1openxr_FlutterSceneOpenXrActivity_nativeResetPerformance(
    JNIEnv*, jobject) {
    return static_cast<jlong>(++gPerformanceGeneration);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_bdero_flutter_1scene_1openxr_FlutterSceneOpenXrActivity_nativeResetPanels(
    JNIEnv*, jobject) {
    gPanelLayoutGeneration.fetch_add(1);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_bdero_flutter_1scene_1openxr_FlutterSceneOpenXrActivity_nativeRequestResolution(
    JNIEnv*, jobject, jdouble scale) {
    std::scoped_lock lock(gResolutionMutex);
    const auto request = ++gResolutionRequestId;
    gResolutionRequest = std::make_pair(request, scale);
    return static_cast<jlong>(request);
}
