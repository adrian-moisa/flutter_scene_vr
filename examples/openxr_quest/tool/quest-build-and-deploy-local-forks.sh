#!/usr/bin/env bash
set -euo pipefail

# Uses the local Flutter Engine and this workspace's Flutter Scene packages.
# Every path and engine target remains overridable for another local checkout.

quest_step() {
	printf '\n[%s/6] %s\n' "$1" "$2"
}

if ! command -v adb >/dev/null 2>&1; then
	printf 'ADB is not installed or unavailable on PATH.\n' >&2
	exit 1
fi

quest_flutter="${QUEST_FLUTTER:-/Users/adrian/flutter/bin/flutter}"
if ! command -v "$quest_flutter" >/dev/null 2>&1; then
	printf 'The local Flutter fork is unavailable: %s\n' "$quest_flutter" >&2
	exit 1
fi

quest_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
quest_app_dir="$(cd "$quest_script_dir/.." && pwd)"
quest_workspace_dir="$(cd "$quest_app_dir/../.." && pwd)"
quest_target=lib/main.dart
quest_build_mode="${QUEST_BUILD_MODE:-profile}"
quest_perf_logs="${QUEST_PERF_LOGS:-1}"
# Use the demo's original filtered directional shadows on the direct-eye path.
# Set QUEST_SHADOWS=0 to compare against the no-shadow baseline.
quest_shadows="${QUEST_SHADOWS:-1}"
quest_local_engine_src_path="${QUEST_LOCAL_ENGINE_SRC_PATH:-/Users/adrian/flutter/engine/src}"
quest_local_engine="${QUEST_LOCAL_ENGINE:-android_profile_arm64}"
quest_local_engine_host="${QUEST_LOCAL_ENGINE_HOST:-host_profile_arm64}"
quest_local_flutter_gpu="$quest_local_engine_src_path/flutter/lib/gpu"
case "$quest_build_mode" in
	debug | profile | release) ;;
	*)
		printf 'QUEST_BUILD_MODE must be debug, profile, or release; received: %s\n' "$quest_build_mode" >&2
		exit 1
		;;
esac
case "$quest_perf_logs" in
	0 | 1) ;;
	*)
		printf 'QUEST_PERF_LOGS must be 0 or 1; received: %s\n' "$quest_perf_logs" >&2
		exit 1
		;;
esac
case "$quest_shadows" in
	0 | 1) ;;
	*)
		printf 'QUEST_SHADOWS must be 0 or 1; received: %s\n' "$quest_shadows" >&2
		exit 1
		;;
esac
quest_local_engine_out="$quest_local_engine_src_path/out/$quest_local_engine"
quest_local_engine_host_out="$quest_local_engine_src_path/out/$quest_local_engine_host"
quest_local_engine_library="$quest_local_engine_out/lib.stripped/libflutter.so"
quest_local_engine_embedding="$quest_local_engine_out/flutter_embedding_${quest_build_mode}.jar"
quest_local_engine_archives="$quest_local_engine_out/arm64_v8a_${quest_build_mode}.jar"
quest_local_engine_snapshot="$quest_local_engine_host_out/gen_snapshot"
quest_local_engine_font_subset="$quest_local_engine_host_out/font-subset"
if [[ ! -f "$quest_local_engine_library" ||
	! -f "$quest_local_engine_embedding" ||
	! -f "$quest_local_engine_archives" ||
	! -x "$quest_local_engine_snapshot" ||
	! -x "$quest_local_engine_font_subset" ]]; then
	printf '%s\n' \
		'The required local Flutter Engine artifacts are missing.' \
		"Device library: $quest_local_engine_library" \
		"Embedding JAR:  $quest_local_engine_embedding" \
		"ARM64 JAR:      $quest_local_engine_archives" \
		"Host snapshot:  $quest_local_engine_snapshot" \
		"Font subset:    $quest_local_engine_font_subset" \
		'Build both targets using DIRECT_SWAPCHAIN_RENDERING.md before deploying.' >&2
	exit 1
fi
if ! grep -Fqx "flutter_runtime_mode = \"$quest_build_mode\"" "$quest_local_engine_out/args.gn" ||
	! grep -Fqx "flutter_runtime_mode = \"$quest_build_mode\"" "$quest_local_engine_host_out/args.gn"; then
	printf '%s\n' \
		"The selected local engine outputs do not match QUEST_BUILD_MODE=$quest_build_mode." \
		"Device engine: $quest_local_engine_out" \
		"Host engine:   $quest_local_engine_host_out" \
		'Choose matching QUEST_LOCAL_ENGINE and QUEST_LOCAL_ENGINE_HOST targets.' >&2
	exit 1
fi
quest_apk="$quest_app_dir/build/app/outputs/flutter-apk/app-$quest_build_mode.apk"
quest_package="dev.bdero.flutter_scene_openxr_example"
quest_activity="dev.bdero.flutter_scene_openxr.FlutterSceneOpenXrActivity"
quest_quad_texture_width=1200
quest_quad_texture_height=900
quest_quad_width_metres=1.2
quest_quad_height_metres=0.9
quest_quad_y=-0.25
quest_quad_z=-1.4
quest_entrypoint=openXrMain
quest_library_uri=package:openxr_quest/open_xr_main.dart

quest_step 1 "Finding a USB-connected Meta Quest"
quest_devices="$(adb devices -l)"
printf '%s\n' "$quest_devices"

quest_serial="${ANDROID_SERIAL:-}"
if [[ -z "$quest_serial" ]]; then
	quest_serial="$(
		printf '%s\n' "$quest_devices" |
			awk '$2 == "device" && /usb:/ && /model:Quest|product:eureka|product:hollywood|product:seacliff/ { print $1; exit }'
	)"
fi

if [[ -z "$quest_serial" ]]; then
	printf 'No authorized Meta Quest was found over USB. Check the cable and USB debugging prompt.\n' >&2
	exit 1
fi

export ANDROID_SERIAL="$quest_serial"
printf 'Using Quest: %s\n' "$quest_serial"

if [[ " ${JAVA_TOOL_OPTIONS:-} " != *" --enable-native-access=ALL-UNNAMED "* ]]; then
	export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }--enable-native-access=ALL-UNNAMED"
fi

cd "$quest_app_dir"

quest_step 2 "Resolving local Flutter Scene dependencies"
# --local-engine selects native artifacts, not the Dart SDK package sources.
# Keep this machine-specific dependency override out of the integrated helper
# and out of Git. Never replace an existing override file owned by the developer.
quest_gpu_overrides="$quest_workspace_dir/pubspec_overrides.yaml"
if [[ ! -f "$quest_local_flutter_gpu/pubspec.yaml" ]]; then
	printf 'The local Flutter GPU package is missing: %s\n' "$quest_local_flutter_gpu" >&2
	exit 1
fi
if [[ ! -e "$quest_gpu_overrides" ]]; then
	quest_gpu_yaml_path="${quest_local_flutter_gpu//\'/\'\'}"
	(
		set -o noclobber
		printf "# Local-only dependency selection for the custom Quest engine; ignored by Git.\ndependency_overrides:\n  flutter_gpu:\n    path: '%s'\n" \
			"$quest_gpu_yaml_path" > "$quest_gpu_overrides"
	)
fi
printf 'Local dependency overrides: %s\n' "$quest_gpu_overrides"
"$quest_flutter" pub get

quest_step 3 "Building the ARM64 $quest_build_mode APK with local forks"
quest_flutter_build_args=(
	--local-engine-src-path "$quest_local_engine_src_path"
	--local-engine "$quest_local_engine"
	--local-engine-host "$quest_local_engine_host"
	build apk "--$quest_build_mode" --target-platform android-arm64 --no-pub --target "$quest_target"
)
if [[ "$quest_perf_logs" == "1" ]]; then
	quest_flutter_build_args+=(
		--dart-define=FLUTTER_SCENE_OPENXR_PERF_LOGS=true
		--dart-define=FLUTTER_SCENE_PROFILE=true
	)
fi
if [[ "$quest_shadows" == "0" ]]; then
	quest_flutter_build_args+=(
		--dart-define=FLUTTER_SCENE_OPENXR_DISABLE_SHADOWS=true
	)
fi
"$quest_flutter" "${quest_flutter_build_args[@]}"

if [[ ! -f "$quest_apk" ]]; then
	printf 'Expected APK was not created: %s\n' "$quest_apk" >&2
	exit 1
fi

quest_step 4 "Stopping the previous demo"
adb shell am force-stop "$quest_package"

quest_step 5 "Installing the fresh APK"
adb install -r "$quest_apk"

quest_step 6 "Launching the immersive OpenXR activity"
quest_launch_args=(
	shell am start -W -n "$quest_package/$quest_activity"
    --es flutter_scene_openxr.dartEntrypoint "$quest_entrypoint"
    --es flutter_scene_openxr.dartLibraryUri "$quest_library_uri"
	--ei flutter_scene_openxr.quadTextureWidth "$quest_quad_texture_width"
	--ei flutter_scene_openxr.quadTextureHeight "$quest_quad_texture_height"
	--ef flutter_scene_openxr.quadWidthMeters "$quest_quad_width_metres"
	--ef flutter_scene_openxr.quadHeightMeters "$quest_quad_height_metres"
	--ef flutter_scene_openxr.quadPositionY "$quest_quad_y"
	--ef flutter_scene_openxr.quadPositionZ "$quest_quad_z"
	--ef flutter_scene_openxr.quadOrientationW 1.0
	--ez flutter_scene_openxr.quadHeadLocked false
	--ei flutter_scene_openxr.panelSplitPixels 560
)
if [[ "$quest_perf_logs" == "1" ]]; then
	quest_launch_args+=(--ez flutter_scene_openxr.performanceLogging true)
fi
adb "${quest_launch_args[@]}"

printf '\nFlutter Scene OpenXR local-forks deployment complete.\n'
printf 'Device: %s\n' "$quest_serial"
printf 'APK: %s\n' "$quest_apk"
printf 'Performance logs: %s\n' "$quest_perf_logs"
printf 'Gallery: VR includes the original demo. Other entries keep authored quality.\n'
printf 'VR directional shadows: %s\n' "$quest_shadows"
printf 'Local Flutter: %s\n' "$quest_flutter"
printf 'Local engine: %s/%s (host %s)\n' \
	"$quest_local_engine_src_path" "$quest_local_engine" "$quest_local_engine_host"
if [[ "$quest_perf_logs" == "1" ]]; then
	printf '%s\n' "Live metrics: adb logcat -v brief --regex '\\+\\+\\+|FPS=|performance level'"
fi
