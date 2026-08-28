#pragma once

#include <openxr/openxr.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

// Reads runtime-owned frame costs once per HUD sample, separately from bridge
// wall time and Flutter's UI raster time. These are diagnostics, never inputs
// to rendering policy: the runtime owns their measurement intervals.
class OpenXrRuntimeMetrics {
public:
    bool Enable(XrInstance instance, XrSession session) {
        PFN_xrEnumeratePerformanceMetricsCounterPathsMETA enumerate = nullptr;
        PFN_xrSetPerformanceMetricsStateMETA setState = nullptr;
        if (XR_FAILED(xrGetInstanceProcAddr(instance,
                "xrEnumeratePerformanceMetricsCounterPathsMETA",
                reinterpret_cast<PFN_xrVoidFunction*>(&enumerate))) ||
            XR_FAILED(xrGetInstanceProcAddr(instance,
                "xrSetPerformanceMetricsStateMETA",
                reinterpret_cast<PFN_xrVoidFunction*>(&setState))) ||
            XR_FAILED(xrGetInstanceProcAddr(instance,
                "xrQueryPerformanceMetricsCounterMETA",
                reinterpret_cast<PFN_xrVoidFunction*>(&query_))) ||
            enumerate == nullptr || setState == nullptr || query_ == nullptr) {
            return false;
        }

        uint32_t count = 0;
        if (XR_FAILED(enumerate(instance, 0, &count, nullptr))) return false;
        std::vector<XrPath> available(count);
        if (count == 0 ||
            XR_FAILED(enumerate(instance, count, &count, available.data()))) {
            return false;
        }
        available.resize(count);
        constexpr std::array<const char*, 4> names{
            "/perfmetrics_meta/app/cpu_frametime",
            "/perfmetrics_meta/app/gpu_frametime",
            "/perfmetrics_meta/compositor/gpu_frametime",
            "/perfmetrics_meta/device/gpu_utilization",
        };
        for (size_t i = 0; i < names.size(); ++i) {
            XrPath path = XR_NULL_PATH;
            if (XR_SUCCEEDED(xrStringToPath(instance, names[i], &path)) &&
                std::find(available.begin(), available.end(), path) != available.end()) {
                paths_[i] = path;
            }
        }
        XrPerformanceMetricsStateMETA state{XR_TYPE_PERFORMANCE_METRICS_STATE_META};
        state.enabled = XR_TRUE;
        if (XR_FAILED(setState(session, &state))) return false;
        session_ = session;
        return true;
    }

    // Negative values mean unavailable, never zero cost. Validate each sample
    // independently so an unsupported counter or a tracking transition cannot
    // leave an old value looking current. No metric calls occur when disabled.
    std::array<double, 4> Sample() const {
        std::array<double, 4> values{-1, -1, -1, -1};
        if (session_ == XR_NULL_HANDLE || query_ == nullptr) return values;
        for (size_t i = 0; i < paths_.size(); ++i) {
            if (paths_[i] == XR_NULL_PATH) continue;
            XrPerformanceMetricsCounterMETA counter{XR_TYPE_PERFORMANCE_METRICS_COUNTER_META};
            if (XR_FAILED(query_(session_, paths_[i], &counter))) continue;
            const auto unit = i == 3
                ? XR_PERFORMANCE_METRICS_COUNTER_UNIT_PERCENTAGE_META
                : XR_PERFORMANCE_METRICS_COUNTER_UNIT_MILLISECONDS_META;
            if (counter.counterUnit != unit) continue;
            double value = -1;
            if (counter.counterFlags & XR_PERFORMANCE_METRICS_COUNTER_FLOAT_VALUE_VALID_BIT_META) {
                value = counter.floatValue;
            } else if (counter.counterFlags & XR_PERFORMANCE_METRICS_COUNTER_UINT_VALUE_VALID_BIT_META) {
                value = counter.uintValue;
            }
            if (std::isfinite(value) && value >= 0) values[i] = value;
        }
        return values;
    }

private:
    XrSession session_ = XR_NULL_HANDLE;
    PFN_xrQueryPerformanceMetricsCounterMETA query_ = nullptr;
    std::array<XrPath, 4> paths_{};
};
