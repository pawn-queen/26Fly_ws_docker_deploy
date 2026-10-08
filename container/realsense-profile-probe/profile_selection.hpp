#pragma once

#include <algorithm>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

namespace profile_probe {

enum class Stream { color, depth };

struct VideoProfile {
  Stream stream;
  int index;
  int width;
  int height;
  int fps;
  int format;
  bool is_default;
};

inline bool same_profile(const VideoProfile &a, const VideoProfile &b) {
  return a.stream == b.stream && a.index == b.index && a.width == b.width &&
         a.height == b.height && a.fps == b.fps && a.format == b.format;
}

// An absent/ambiguous native default cannot safely stand in for the ROS default.
inline VideoProfile native_default(const std::vector<VideoProfile> &profiles,
                                   Stream stream) {
  std::optional<VideoProfile> result;
  for (const auto &profile : profiles) {
    if (profile.stream != stream || profile.index != 0 || !profile.is_default)
      continue;
    if (result && !same_profile(*result, profile))
      throw std::runtime_error("ambiguous native default profile");
    result = profile;
  }
  if (!result)
    throw std::runtime_error("native RGB/depth default profile unavailable");
  return *result;
}

inline std::vector<int> candidate_rates(int requested) {
  if (requested <= 0)
    throw std::invalid_argument("requested FPS must be positive");
  std::vector<int> rates{requested};
  for (const int fallback : {60, 30}) {
    if (fallback <= requested &&
        std::find(rates.begin(), rates.end(), fallback) == rates.end())
      rates.push_back(fallback);
  }
  return rates;
}

using ProfilePair = std::pair<VideoProfile, VideoProfile>;

template <class CanResolve>
std::optional<ProfilePair> select_pair(const std::vector<VideoProfile> &profiles,
                                     int requested, CanResolve can_resolve,
                                     std::optional<int> color_format = std::nullopt,
                                     std::optional<int> depth_format = std::nullopt) {
  auto color = native_default(profiles, Stream::color);
  auto depth = native_default(profiles, Stream::depth);
  if (color_format)
    color.format = *color_format;
  if (depth_format)
    depth.format = *depth_format;
  const auto supports = [&](const VideoProfile &wanted) {
    return std::any_of(profiles.begin(), profiles.end(), [&](const auto &p) {
      return same_profile(p, wanted);
    });
  };
  if (!supports(color) || !supports(depth))
    throw std::runtime_error("launch-default format not supported at native default dimensions/FPS");
  for (const int fps : candidate_rates(requested)) {
    auto pair = ProfilePair{color, depth};
    pair.first.fps = pair.second.fps = fps;
    if (supports(pair.first) && supports(pair.second) && can_resolve(pair))
      return pair;
  }
  return std::nullopt;
}

}  // namespace profile_probe
