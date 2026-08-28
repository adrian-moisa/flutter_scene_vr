cmake_minimum_required(VERSION 3.22.1)

project(flutter_scene_openxr LANGUAGES C CXX)

find_package(OpenXR REQUIRED CONFIG)

add_library(
    native_app_glue
    STATIC
    "${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c"
)
target_include_directories(
    native_app_glue
    PUBLIC
    "${ANDROID_NDK}/sources/android/native_app_glue"
)

add_library(
    flutter_scene_openxr
    SHARED
    flutter_scene_openxr.cpp
)

target_compile_features(flutter_scene_openxr PRIVATE cxx_std_17)
target_compile_definitions(
    flutter_scene_openxr
    PRIVATE
    XR_USE_GRAPHICS_API_OPENGL_ES
    XR_USE_PLATFORM_ANDROID
)
target_link_options(flutter_scene_openxr PRIVATE "-uANativeActivity_onCreate")

find_library(android_library android REQUIRED)
find_library(egl_library EGL REQUIRED)
find_library(gles_library GLESv3 REQUIRED)
find_library(log_library log REQUIRED)

target_link_libraries(
    flutter_scene_openxr
    PRIVATE
    OpenXR::openxr_loader
    native_app_glue
    ${android_library}
    ${egl_library}
    ${gles_library}
    ${log_library}
)
