#include "profile_selection.hpp"

#include <librealsense2/rs.hpp>

#include <iostream>
#include <regex>
#include <string>

namespace {

using profile_probe::ProfilePair;
using profile_probe::Stream;
using profile_probe::VideoProfile;

rs2_stream sdk_stream(Stream stream) {
  return stream == Stream::color ? RS2_STREAM_COLOR : RS2_STREAM_DEPTH;
}

VideoProfile describe(const rs2::video_stream_profile &profile) {
  return {profile.stream_type() == RS2_STREAM_COLOR ? Stream::color : Stream::depth,
          profile.stream_index(), profile.width(), profile.height(),
          profile.fps(), static_cast<int>(profile.format()), profile.is_default()};
}

std::string profile_text(const VideoProfile &profile) {
  return std::to_string(profile.width) + "x" + std::to_string(profile.height) +
         "x" + std::to_string(profile.fps) + "/" +
         rs2_format_to_string(static_cast<rs2_format>(profile.format));
}

int sdk_format(const std::string &name) {
  for (int value = 1; value < RS2_FORMAT_COUNT; ++value) {
    if (name == rs2_format_to_string(static_cast<rs2_format>(value)))
      return value;
  }
  throw std::runtime_error("launch-default pixel format unrecognized by installed SDK");
}

bool can_resolve(rs2::context &context, const std::string &serial,
                 const ProfilePair &pair) {
  // Resolving queries the SDK's joint configuration. Never open/start/reset a
  // sensor or modify options; this process exits before the ROS driver starts.
  rs2::pipeline pipeline(context);
  rs2::config config;
  config.disable_all_streams();
  config.enable_device(serial);
  for (const auto &profile : {pair.first, pair.second})
    config.enable_stream(sdk_stream(profile.stream), profile.index, profile.width,
                         profile.height, static_cast<rs2_format>(profile.format),
                         profile.fps);
  if (!config.can_resolve(pipeline))
    return false;
  const auto resolved = config.resolve(pipeline);
  for (const auto &wanted : {pair.first, pair.second}) {
    const auto actual = resolved.get_stream(sdk_stream(wanted.stream), wanted.index)
                            .as<rs2::video_stream_profile>();
    if (!actual || !profile_probe::same_profile(describe(actual), wanted))
      return false;
  }
  return resolved.get_device().get_info(RS2_CAMERA_INFO_SERIAL_NUMBER) == serial;
}

}  // namespace

int main(int argc, char **argv) {
  try {
    if (argc != 4 || !std::regex_match(argv[1], std::regex("[0-9]+")))
      throw std::invalid_argument("usage: realsense-profile-probe POSITIVE_FPS COLOR_FORMAT DEPTH_FORMAT");
    const int requested = std::stoi(argv[1]);
    if (requested <= 0)
      throw std::invalid_argument("requested FPS must be positive");
    rs2::context context;
    const auto devices = context.query_devices();
    if (devices.size() != 1)
      throw std::runtime_error("requires exactly one unselected RealSense device");
    const auto device = devices.front();
    if (!device.supports(RS2_CAMERA_INFO_SERIAL_NUMBER))
      throw std::runtime_error("device serial unavailable");
    const std::string serial = device.get_info(RS2_CAMERA_INFO_SERIAL_NUMBER);
    if (!std::regex_match(serial, std::regex("[A-Za-z0-9_.-]+")))
      throw std::runtime_error("device serial cannot be represented safely");

    std::vector<VideoProfile> profiles;
    for (const auto &sensor : device.query_sensors()) {
      for (const auto &profile : sensor.get_stream_profiles()) {
        if ((profile.stream_type() == RS2_STREAM_COLOR ||
             profile.stream_type() == RS2_STREAM_DEPTH) &&
            profile.is<rs2::video_stream_profile>())
          profiles.push_back(describe(profile.as<rs2::video_stream_profile>()));
      }
    }
    auto color = profile_probe::native_default(profiles, Stream::color);
    auto depth = profile_probe::native_default(profiles, Stream::depth);
    // rs_launch's explicit format defaults override SDK is_default formats.
    // Preserve that unchanged-launch behavior together with native dimensions.
    color.format = sdk_format(argv[2]);
    depth.format = sdk_format(argv[3]);
    std::cerr << "RealSense native defaults: RGB " << profile_text(color)
              << ", depth " << profile_text(depth) << '\n';
    const auto selected = profile_probe::select_pair(profiles, requested,
        [&](const ProfilePair &pair) {
          try {
            return can_resolve(context, serial, pair);
          } catch (const rs2::error &error) {
            std::cerr << "RealSense " << pair.first.fps
                      << " FPS joint resolve rejected: " << error.what() << '\n';
            return false;
          }
        }, color.format, depth.format);
    if (!selected)
      throw std::runtime_error("no joint requested/60/30 FPS profile preserves native defaults");
    if (selected->first.fps != requested)
      std::cerr << "RealSense requested " << requested << " FPS unavailable; using "
                << selected->first.fps << " FPS at unchanged native dimensions/formats\n";

    // One validated, delimiter-separated record; no shell commands are emitted.
    const auto &c = selected->first;
    const auto &d = selected->second;
    std::cout << serial << '|' << c.width << '|' << c.height << '|' << d.width
              << '|' << d.height << '|' << c.fps << '|'
              << rs2_format_to_string(static_cast<rs2_format>(c.format)) << '|'
              << rs2_format_to_string(static_cast<rs2_format>(d.format)) << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "RealSense profile probe: " << error.what() << '\n';
    return 1;
  }
}
