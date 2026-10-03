#pragma once

#include <algorithm>
#include <chrono>
#include <optional>

namespace vision_debug {

using DisplayClock = std::chrono::steady_clock;

enum class WideFrameSource { Waiting, Debug, Raw, Stale };

struct WideFrameChoice {
  WideFrameSource source{WideFrameSource::Waiting};
  double age_s{0.0};
};

// The debug topic contains a complete image. Its receipt age, rather than a
// match with the separately rate-limited raw topic, determines its usability.
inline WideFrameChoice choose_wide_frame(
    const std::optional<DisplayClock::time_point> &raw_received_at,
    const std::optional<DisplayClock::time_point> &debug_received_at,
    DisplayClock::time_point now, double max_age_s) {
  const auto age = [now](DisplayClock::time_point received_at) {
    return std::max(0.0,
                    std::chrono::duration<double>(now - received_at).count());
  };
  if (debug_received_at.has_value() && age(*debug_received_at) <= max_age_s) {
    return {WideFrameSource::Debug, age(*debug_received_at)};
  }
  if (raw_received_at.has_value() && age(*raw_received_at) <= max_age_s) {
    return {WideFrameSource::Raw, age(*raw_received_at)};
  }
  if (!raw_received_at.has_value() && !debug_received_at.has_value()) {
    return {};
  }
  const auto latest_received_at =
      raw_received_at.has_value() && debug_received_at.has_value()
          ? std::max(*raw_received_at, *debug_received_at)
          : (raw_received_at.has_value() ? *raw_received_at : *debug_received_at);
  return {WideFrameSource::Stale, age(latest_received_at)};
}

// Some HighGUI backends briefly report a non-visible window before its first
// event processing. Once it has appeared, zero/negative visibility means closed.
inline bool window_is_open(double visibility, bool &was_visible) {
  if (visibility >= 1.0) {
    was_visible = true;
    return true;
  }
  return !was_visible;
}

} // namespace vision_debug
