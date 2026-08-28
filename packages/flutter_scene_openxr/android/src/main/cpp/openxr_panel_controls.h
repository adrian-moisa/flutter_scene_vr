#pragma once

#include <openxr/openxr.h>
#include <algorithm>
#include <array>
#include <cmath>

namespace openxr_panels {

inline XrVector3f Add(XrVector3f a, XrVector3f b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
inline XrVector3f Scale(XrVector3f v, float s) { return {v.x*s, v.y*s, v.z*s}; }
inline XrVector3f Sub(XrVector3f a, XrVector3f b) { return Add(a, Scale(b, -1)); }
inline float LengthSquared(XrVector3f v) { return v.x*v.x + v.y*v.y + v.z*v.z; }
inline XrQuaternionf Inverse(XrQuaternionf q) { return {-q.x, -q.y, -q.z, q.w}; }
inline XrVector3f Rotate(XrQuaternionf q, XrVector3f v) {
    const XrVector3f t{2*(q.y*v.z-q.z*v.y), 2*(q.z*v.x-q.x*v.z), 2*(q.x*v.y-q.y*v.x)};
    return {v.x+q.w*t.x+q.y*t.z-q.z*t.y,
            v.y+q.w*t.y+q.z*t.x-q.x*t.z,
            v.z+q.w*t.z+q.x*t.y-q.y*t.x};
}
inline XrQuaternionf Yaw(float radians) { return {0, std::sin(radians/2), 0, std::cos(radians/2)}; }

struct Hit {
    int panel = -1;
    float distance = 8;
    XrVector3f local{};
};

// One definition drives native hit testing AND compositor submission. Flutter
// only receives atlas pixels; it never estimates the moved panel's transform.
class Controls {
public:
    // Half the previous width and height, above the right panel's default
    // placement. Keep it head-relative and reachable when Flutter UI is off.
    // The compositor and controller hit test both use this same rectangle.
    static constexpr XrExtent2Df hudSize{.23f, .065f};
    static constexpr XrPosef hudPose{{0,0,0,1}, {.46f,.22f,-1.0f}};
    std::array<XrPosef, 2> panels{};
    std::array<XrExtent2Df, 2> sizes{};
    std::array<XrVector2f, 2> navigation{};
    std::array<Hit, 2> hits{};
    bool uiPaused = false;
    bool hudHovered = false;
    bool initialized = false;

    void ResetLayout() { initialized = false; Cancel(); }
    void Cancel() {
        grabs_ = {};
        gripHeld_ = triggerHeld_ = hudCaptured_ = trackingValid_ = {};
        triggerNeedsRelease_ = {};
        hits = {};
        navigation = {};
    }

    void Update(const XrPosef& head, const XrPosef& initial,
                XrExtent2Df totalSize, int split, int width,
                const std::array<double,18>& aims,
                const std::array<float,2>& grips,
                const std::array<XrVector2f,2>& sticks,
                float dt, bool ready) {
        if (!initialized) {
            const float fraction = static_cast<float>(split)/width;
            sizes = {{{totalSize.width*fraction,totalSize.height},
                      {totalSize.width*(1-fraction),totalSize.height}}};
            const auto direction = Rotate(head.orientation, {0,0,-1});
            const auto orientation = Yaw(std::atan2(-direction.x, -direction.z));
            for (int panel=0; panel<2; ++panel) {
                // Leave the center of the scene open; keep settled panels fixed.
                auto offset = initial.position;
                offset.x += panel == 0 ? -.65f : .65f;
                panels[panel] = {orientation, Add(head.position, Rotate(orientation, offset))};
            }
            initialized = true;
        }
        if (!ready) uiPaused = false; // A renderer error must restore recovery UI.
        navigation = sticks;
        hits = {};
        hudHovered = false;
        bool toggled = false;
        const XrPosef hud{head.orientation, Add(head.position, Rotate(head.orientation, hudPose.position))};
        for (int hand=0; hand<2; ++hand) {
            const int offset=hand*9;
            if (aims[offset+7] == 0) {
                grabs_[hand] = {};
                gripHeld_[hand] = triggerHeld_[hand] = hudCaptured_[hand] = false;
                trackingValid_[hand] = false;
                navigation[hand] = {};
                continue;
            }
            const XrVector3f origin{static_cast<float>(aims[offset]), static_cast<float>(aims[offset+1]), static_cast<float>(aims[offset+2])};
            const XrQuaternionf orientation{static_cast<float>(aims[offset+3]), static_cast<float>(aims[offset+4]), static_cast<float>(aims[offset+5]), static_cast<float>(aims[offset+6])};
            const auto direction = Rotate(orientation, {0,0,-1});
            const bool trigger = aims[offset+8] > (triggerHeld_[hand] ? .35 : .65);
            const bool grip = grips[hand] > (gripHeld_[hand] ? .35f : .65f);
            const bool triggerPressed = trackingValid_[hand] && trigger && !triggerHeld_[hand];
            const bool gripPressed = trackingValid_[hand] && grip && !gripHeld_[hand];
            if (!trackingValid_[hand]) triggerNeedsRelease_[hand] = trigger;
            if (!trigger) triggerNeedsRelease_[hand] = false;
            trackingValid_[hand] = true;
            triggerHeld_[hand] = trigger;
            gripHeld_[hand] = grip;
            if (!trigger) hudCaptured_[hand] = false;
            if (!grip || uiPaused) grabs_[hand] = {};

            const Hit hudHit = Intersect(2, hud, hudSize, origin, direction);
            if (grabs_[hand].panel < 0 && hudHit.panel >= 0) {
                hudHovered = true;
                navigation[hand] = {};
                if (triggerPressed && !grip && ready && !toggled) {
                    uiPaused = !uiPaused;
                    hudCaptured_[hand] = true;
                    // Resuming UI must not turn the other hand's already-held
                    // trigger into a fresh widget click.
                    triggerNeedsRelease_ = {true, true};
                    grabs_ = {};
                    hits = {};
                    toggled = true;
                }
                continue; // The HUD is submitted last, above all panels.
            }
            if (hudCaptured_[hand]) { navigation[hand] = {}; continue; }
            if (uiPaused) continue;

            Hit nearest;
            for (int panel=0; panel<2; ++panel) {
                const Hit hit = Intersect(panel, panels[panel], sizes[panel], origin, direction);
                if (hit.panel >= 0 && hit.distance < nearest.distance) nearest = hit;
            }
            if (gripPressed && !trigger && nearest.panel >= 0 &&
                grabs_[1-hand].panel != nearest.panel) {
                // Visual Space's absolute anchor: retain the actual grabbed
                // pixel and its distance, never feed back moving-panel UV deltas.
                grabs_[hand] = nearest;
            }
            auto& grab = grabs_[hand];
            if (grab.panel >= 0) {
                grab.distance = std::clamp(grab.distance + sticks[hand].y*1.2f*dt, .35f, 6.0f);
                const auto anchor = Add(origin, Scale(direction, grab.distance));
                auto& panel = panels[grab.panel];
                for (int pass=0; pass<2; ++pass) {
                    const auto candidate = Sub(anchor, Rotate(panel.orientation, grab.local));
                    const auto towardHead = Sub(head.position, candidate);
                    panel.orientation = Yaw(std::atan2(towardHead.x, towardHead.z));
                }
                panel.position = Sub(anchor, Rotate(panel.orientation, grab.local));
            } else if (!grip && !triggerNeedsRelease_[hand]) {
                hits[hand] = nearest;
            }
            if (nearest.panel >= 0 || grip) navigation[hand] = {};
        }
        if (grabs_[0].panel >= 0 || grabs_[1].panel >= 0) navigation = {};
        if (uiPaused) hits = {};
    }

    // Optional extension after the legacy 45 values: pause, two panel/pixel
    // triples, then the two arbitrated navigation sticks. Same frame/poses.
    std::array<double,11> Pack(int split, int width, int height) const {
        std::array<double,11> result{};
        result[0] = uiPaused ? 1 : 0;
        for (int hand=0; hand<2; ++hand) {
            const auto& hit = hits[hand];
            const int at=1+hand*3;
            result[at] = hit.panel;
            if (hit.panel < 0) continue;
            const int pixels = hit.panel == 0 ? split : width-split;
            result[at+1] = (hit.panel == 0 ? 0 : split) + (hit.local.x/sizes[hit.panel].width+.5f)*pixels;
            result[at+2] = (.5f-hit.local.y/sizes[hit.panel].height)*height;
        }
        result[7]=navigation[0].x; result[8]=navigation[0].y;
        result[9]=navigation[1].x; result[10]=navigation[1].y;
        return result;
    }

private:
    std::array<Hit,2> grabs_{};
    std::array<bool,2> gripHeld_{}, triggerHeld_{}, hudCaptured_{}, trackingValid_{}, triggerNeedsRelease_{};

    static Hit Intersect(int index, const XrPosef& pose, XrExtent2Df size,
                         XrVector3f origin, XrVector3f direction) {
        const auto inverse=Inverse(pose.orientation);
        origin=Rotate(inverse, Sub(origin, pose.position));
        direction=Rotate(inverse, direction);
        if (direction.z >= -.00001f) return {};
        const float distance=-origin.z/direction.z;
        if (distance<=0 || distance>8) return {};
        const auto local=Add(origin, Scale(direction,distance));
        if (std::abs(local.x)>size.width/2 || std::abs(local.y)>size.height/2) return {};
        return {index,distance,local};
    }
};
} // namespace openxr_panels
