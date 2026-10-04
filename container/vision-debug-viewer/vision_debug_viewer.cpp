#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <exception>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

#include <builtin_interfaces/msg/time.hpp>
#include <cv_bridge/cv_bridge.h>
#include <opencv2/core.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/image_encodings.hpp>
#include <sensor_msgs/msg/camera_info.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/point_cloud.hpp>

#include "wide_display_state.hpp"

namespace {

using SteadyClock = std::chrono::steady_clock;
using Image = sensor_msgs::msg::Image;
using CameraInfo = sensor_msgs::msg::CameraInfo;
using PointCloud = sensor_msgs::msg::PointCloud;

constexpr char kWindowName[] = "26Fly RealSense / selected target debug";
constexpr char kWideWindowName[] = "26Fly Wide camera / mission debug";
constexpr char kExpectedTargetFrame[] = "target_camera_optical_frame";
constexpr std::size_t kFrameBufferLimit = 30;
constexpr double kAnnotatedFrameMaxAgeS = 1.0;

std::int64_t stamp_to_nanoseconds(const builtin_interfaces::msg::Time &stamp) {
  return static_cast<std::int64_t>(stamp.sec) * 1000000000LL +
         static_cast<std::int64_t>(stamp.nanosec);
}

bool finite_positive(double value) {
  return std::isfinite(value) && value > 0.0;
}

void put_status_line(cv::Mat &image, const std::string &text, int row,
                     const cv::Scalar &color = cv::Scalar(255, 255, 255)) {
  const int y = 28 + row * 25;
  cv::putText(image, text, cv::Point(12, y), cv::FONT_HERSHEY_SIMPLEX, 0.62,
              cv::Scalar(0, 0, 0), 4, cv::LINE_AA);
  cv::putText(image, text, cv::Point(12, y), cv::FONT_HERSHEY_SIMPLEX, 0.62,
              color, 1, cv::LINE_AA);
}

int probe_gui() {
  const char *display = std::getenv("DISPLAY");
  const char *authority = std::getenv("XAUTHORITY");
  if (display == nullptr || std::string(display).empty()) {
    std::cerr << "ERROR: DISPLAY is empty. Run the host debug wrapper from the "
                 "GUI session.\n";
    return 2;
  }
  if (authority == nullptr || std::string(authority).empty()) {
    std::cerr << "ERROR: XAUTHORITY is empty. The host wrapper must inject a "
                 "temporary cookie.\n";
    return 2;
  }

  try {
    const std::string probe_window = "__26fly_gui_probe__";
    cv::namedWindow(probe_window, cv::WINDOW_AUTOSIZE);
    cv::imshow(probe_window, cv::Mat::zeros(16, 16, CV_8UC3));
    cv::waitKey(50);
    cv::destroyWindow(probe_window);
  } catch (const cv::Exception &exception) {
    std::cerr << "ERROR: OpenCV HighGUI cannot connect to " << display << ": "
              << exception.what() << '\n';
    return 2;
  }

  std::cout << "GUI probe passed for DISPLAY=" << display << '\n';
  return 0;
}

struct Intrinsics {
  bool valid{false};
  double fx{0.0};
  double fy{0.0};
  double cx{0.0};
  double cy{0.0};
  std::uint32_t width{0};
  std::uint32_t height{0};
  std::string frame_id;
};

struct ColorFrame {
  std::int64_t stamp_ns{0};
  cv::Mat image;
  std::string frame_id;
  Intrinsics intrinsics;
};

struct AnnotatedFrame {
  std::int64_t stamp_ns{0};
  cv::Mat image;
  std::string frame_id;
  SteadyClock::time_point received_at{};
};

struct TargetObservation {
  std::int64_t stamp_ns{0};
  double x{0.0};
  double y{0.0};
  double z{0.0};
  double confidence{0.0};
  SteadyClock::time_point received_at{};
};

class VisionDebugViewer final : public rclcpp::Node {
public:
  VisionDebugViewer() : Node("vision_debug_viewer") {
    declare_parameter<std::string>("color_topic",
                                   "/camera/camera/color/image_raw");
    declare_parameter<std::string>("camera_info_topic",
                                   "/camera/camera/color/camera_info");
    declare_parameter<std::string>("observation_topic", "/target_observation");
    declare_parameter<std::string>("annotated_topic", "/detect/debug/image");
    declare_parameter<double>("target_timeout_s", 1.0);
    declare_parameter<bool>("display_wide", false);
    declare_parameter<std::string>("wide_raw_topic",
                                   "/control/widecam/image_raw");
    declare_parameter<std::string>("wide_debug_topic",
                                   "/control/widecam/debug_image");

    target_timeout_s_ = get_parameter("target_timeout_s").as_double();
    display_wide_ = get_parameter("display_wide").as_bool();
    if (!finite_positive(target_timeout_s_)) {
      throw std::invalid_argument("target_timeout_s must be positive");
    }

    const auto sensor_qos = rclcpp::SensorDataQoS().keep_last(5);
    color_subscription_ = create_subscription<Image>(
        get_parameter("color_topic").as_string(), sensor_qos,
        std::bind(&VisionDebugViewer::on_color, this, std::placeholders::_1));
    annotated_subscription_ = create_subscription<Image>(
        get_parameter("annotated_topic").as_string(), sensor_qos,
        std::bind(&VisionDebugViewer::on_annotated, this,
                  std::placeholders::_1));
    camera_info_subscription_ = create_subscription<CameraInfo>(
        get_parameter("camera_info_topic").as_string(), sensor_qos,
        std::bind(&VisionDebugViewer::on_camera_info, this,
                  std::placeholders::_1));

    auto observation_qos = rclcpp::QoS(rclcpp::KeepLast(1));
    observation_qos.best_effort().durability_volatile();
    observation_subscription_ = create_subscription<PointCloud>(
        get_parameter("observation_topic").as_string(), observation_qos,
        std::bind(&VisionDebugViewer::on_observation, this,
                  std::placeholders::_1));

    if (display_wide_) {
      auto wide_qos = rclcpp::QoS(rclcpp::KeepLast(1));
      wide_qos.best_effort().durability_volatile();
      wide_raw_subscription_ = create_subscription<Image>(
          get_parameter("wide_raw_topic").as_string(), wide_qos,
          [this](const Image::ConstSharedPtr message) {
            on_wide_image(message, vision_debug::WideFrameSource::Raw, "raw");
          });
      wide_debug_subscription_ = create_subscription<Image>(
          get_parameter("wide_debug_topic").as_string(), wide_qos,
          [this](const Image::ConstSharedPtr message) {
            on_wide_image(message, vision_debug::WideFrameSource::Debug,
                          "debug");
          });
    }

    cv::namedWindow(kWindowName, cv::WINDOW_NORMAL);
    window_created_ = true;
    if (display_wide_) {
      try {
        cv::namedWindow(kWideWindowName, cv::WINDOW_NORMAL);
        wide_window_created_ = true;
      } catch (...) {
        destroy_window(kWindowName, window_created_);
        throw;
      }
    }
    RCLCPP_INFO(
        get_logger(),
        "Viewer started. Matched detector frames show all boxes and classes; "
        "the selected target centre is overlaid. Wide camera display: %s. "
        "Press q or Esc, or close either window, to exit.",
        display_wide_ ? "enabled" : "disabled");
  }

  ~VisionDebugViewer() override {
    destroy_window(kWideWindowName, wide_window_created_);
    destroy_window(kWindowName, window_created_);
  }

  bool render() {
    // Check before imshow: imshow can recreate a window that the user closed.
    if (!windows_are_open()) {
      return false;
    }
    cv::Mat color_view;
    const ColorFrame *selected_color =
        color_frames_.empty() ? nullptr : &color_frames_.back();
    const AnnotatedFrame *selected_annotation = nullptr;
    bool target_is_fresh = false;
    bool target_is_matched = false;
    const auto now = SteadyClock::now();

    // Prefer the latest fresh detector frame that matches a raw RGB frame.
    for (auto annotated = annotated_frames_.rbegin();
         annotated != annotated_frames_.rend(); ++annotated) {
      const double age_s =
          std::chrono::duration<double>(now - annotated->received_at).count();
      if (age_s > kAnnotatedFrameMaxAgeS) {
        continue;
      }
      const auto match = std::find_if(
          color_frames_.rbegin(), color_frames_.rend(),
          [&annotated](const ColorFrame &frame) {
            return frame.stamp_ns == annotated->stamp_ns &&
                   frame.frame_id == annotated->frame_id &&
                   frame.image.size() == annotated->image.size();
          });
      if (match != color_frames_.rend()) {
        selected_color = &(*match);
        selected_annotation = &(*annotated);
        break;
      }
    }

    if (target_.has_value()) {
      const double age_s =
          std::chrono::duration<double>(now - target_->received_at).count();
      target_is_fresh = age_s <= target_timeout_s_;
      if (target_is_fresh && selected_annotation == nullptr) {
        const auto match =
            std::find_if(color_frames_.rbegin(), color_frames_.rend(),
                         [this](const ColorFrame &frame) {
                           return frame.stamp_ns == target_->stamp_ns;
                         });
        if (match != color_frames_.rend()) {
          selected_color = &(*match);
        }
      }
      target_is_matched =
          target_is_fresh && selected_color != nullptr &&
          selected_color->stamp_ns == target_->stamp_ns;
    }

    if (selected_color == nullptr) {
      color_view = cv::Mat::zeros(480, 640, CV_8UC3);
      put_status_line(color_view, "Waiting for RealSense color frames...", 0,
                      cv::Scalar(0, 255, 255));
    } else {
      color_view = selected_annotation != nullptr
                       ? selected_annotation->image.clone()
                       : selected_color->image.clone();
      draw_target_overlay(color_view, *selected_color, target_is_fresh,
                          target_is_matched, selected_annotation != nullptr);
    }

    cv::imshow(kWindowName, color_view);
    if (display_wide_) {
      render_wide(now);
    }
    const int key = cv::waitKey(1) & 0xff;
    if (key == 'q' || key == 27) {
      return false;
    }
    return windows_are_open();
  }

private:
  static void destroy_window(const char *name, bool &created) noexcept {
    if (!created) {
      return;
    }
    try {
      cv::destroyWindow(name);
    } catch (const cv::Exception &) {
    }
    created = false;
  }

  bool window_is_open(const char *name, bool &was_visible) {
    try {
      return vision_debug::window_is_open(
          cv::getWindowProperty(name, cv::WND_PROP_VISIBLE), was_visible);
    } catch (const cv::Exception &exception) {
      if (was_visible) {
        RCLCPP_INFO(get_logger(), "Debug window closed: %s (%s)", name,
                    exception.what());
        return false;
      }
      return true;
    }
  }

  bool windows_are_open() {
    return window_is_open(kWindowName, window_was_visible_) &&
           (!display_wide_ ||
            window_is_open(kWideWindowName, wide_window_was_visible_));
  }

  void render_wide(SteadyClock::time_point now) {
    const auto choice = wide_frames_.select(now);
    const auto stale_second =
        choice.source == vision_debug::WideFrameSource::Stale
            ? static_cast<std::int64_t>(std::floor(choice.age_s))
            : -1;
    if (last_wide_source_ == choice.source &&
        last_wide_generation_ == choice.generation &&
        last_wide_stale_second_ == stale_second) {
      return;
    }

    cv::Mat output;
    if (choice.image) {
      output = choice.image->image;
    } else {
      output = cv::Mat::zeros(480, 640, CV_8UC3);
      if (choice.source == vision_debug::WideFrameSource::Waiting) {
        put_status_line(output, "Waiting for wide camera mission frames...", 0,
                        cv::Scalar(0, 255, 255));
      } else {
        put_status_line(output,
                        cv::format("STALE - last wide frame %.0f s ago",
                                   std::floor(choice.age_s)),
                        0, cv::Scalar(0, 165, 255));
      }
    }
    cv::imshow(kWideWindowName, output);
    last_wide_source_ = choice.source;
    last_wide_generation_ = choice.generation;
    last_wide_stale_second_ = stale_second;
  }

  void on_wide_image(const Image::ConstSharedPtr message,
                     vision_debug::WideFrameSource source,
                     const char *source_name) {
    try {
      auto next =
          cv_bridge::toCvShare(message, sensor_msgs::image_encodings::BGR8);
      if (next->image.empty()) {
        throw std::invalid_argument("image has no pixels");
      }
      wide_frames_.add({stamp_to_nanoseconds(message->header.stamp),
                        message->header.frame_id, message->width,
                        message->height},
                       source, std::move(next), SteadyClock::now());
    } catch (const std::exception &exception) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Cannot convert wide %s image: %s", source_name,
                           exception.what());
    }
  }

  void on_camera_info(const CameraInfo::ConstSharedPtr message) {
    Intrinsics next;
    next.fx = message->k[0];
    next.fy = message->k[4];
    next.cx = message->k[2];
    next.cy = message->k[5];
    next.width = message->width;
    next.height = message->height;
    next.frame_id = message->header.frame_id;
    next.valid = finite_positive(next.fx) && finite_positive(next.fy) &&
                 std::isfinite(next.cx) && std::isfinite(next.cy) &&
                 next.width > 0 && next.height > 0 && !next.frame_id.empty();
    if (!next.valid) {
      RCLCPP_WARN_THROTTLE(
          get_logger(), *get_clock(), 2000,
          "Ignoring CameraInfo with invalid intrinsics or dimensions");
      return;
    }
    latest_intrinsics_ = next;
  }

  void on_color(const Image::ConstSharedPtr message) {
    try {
      ColorFrame frame;
      frame.stamp_ns = stamp_to_nanoseconds(message->header.stamp);
      frame.frame_id = message->header.frame_id;
      frame.image =
          cv_bridge::toCvCopy(message, sensor_msgs::image_encodings::BGR8)
              ->image;
      frame.intrinsics = latest_intrinsics_;
      if (frame.intrinsics.frame_id != message->header.frame_id) {
        frame.intrinsics.valid = false;
      }
      color_frames_.push_back(std::move(frame));
      while (color_frames_.size() > kFrameBufferLimit) {
        color_frames_.pop_front();
      }
    } catch (const std::exception &exception) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Cannot convert color image: %s", exception.what());
    }
  }

  void on_annotated(const Image::ConstSharedPtr message) {
    try {
      AnnotatedFrame frame;
      frame.stamp_ns = stamp_to_nanoseconds(message->header.stamp);
      frame.frame_id = message->header.frame_id;
      frame.image =
          cv_bridge::toCvCopy(message, sensor_msgs::image_encodings::BGR8)
              ->image;
      frame.received_at = SteadyClock::now();
      annotated_frames_.push_back(std::move(frame));
      while (annotated_frames_.size() > kFrameBufferLimit) {
        annotated_frames_.pop_front();
      }
    } catch (const std::exception &exception) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Cannot convert detector image: %s",
                           exception.what());
    }
  }

  void on_observation(const PointCloud::ConstSharedPtr message) {
    if (message->header.frame_id != kExpectedTargetFrame ||
        message->points.size() != 1) {
      RCLCPP_WARN_THROTTLE(
          get_logger(), *get_clock(), 2000,
          "Ignoring target observation with unexpected frame or point count");
      return;
    }

    std::optional<double> confidence;
    for (const auto &channel : message->channels) {
      if (channel.name == "confidence" && channel.values.size() == 1) {
        confidence = channel.values.front();
        break;
      }
    }
    const auto &point = message->points.front();
    if (!confidence.has_value() || !std::isfinite(*confidence) ||
        !std::isfinite(point.x) || !std::isfinite(point.y) ||
        !finite_positive(point.z)) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Ignoring malformed target observation");
      return;
    }

    target_ = TargetObservation{stamp_to_nanoseconds(message->header.stamp),
                                point.x,
                                point.y,
                                point.z,
                                *confidence,
                                SteadyClock::now()};
  }

  std::optional<cv::Point> projected_target(const ColorFrame &frame) const {
    if (!target_.has_value() || !frame.intrinsics.valid ||
        frame.intrinsics.width !=
            static_cast<std::uint32_t>(frame.image.cols) ||
        frame.intrinsics.height !=
            static_cast<std::uint32_t>(frame.image.rows)) {
      return std::nullopt;
    }
    const int u = static_cast<int>(std::lround(
        frame.intrinsics.fx * target_->x / target_->z + frame.intrinsics.cx));
    const int v = static_cast<int>(std::lround(
        frame.intrinsics.fy * target_->y / target_->z + frame.intrinsics.cy));
    if (u < 0 || v < 0 || u >= frame.image.cols || v >= frame.image.rows) {
      return std::nullopt;
    }
    return cv::Point(u, v);
  }

  void draw_target_overlay(cv::Mat &image, const ColorFrame &frame,
                           bool target_is_fresh, bool target_is_matched,
                           bool annotated_is_matched) const {
    put_status_line(image,
                    annotated_is_matched
                        ? "RealSense color + detector output"
                        : "RealSense color (waiting for matched detector frame)",
                    0, cv::Scalar(255, 255, 0));
    if (!target_is_fresh) {
      put_status_line(image, "NO RECENT TARGET", 1, cv::Scalar(0, 165, 255));
      return;
    }
    if (!target_is_matched) {
      put_status_line(image, "UNMATCHED TARGET TIMESTAMP - overlay suppressed",
                      1, cv::Scalar(0, 0, 255));
      return;
    }

    const auto pixel = projected_target(frame);
    if (!pixel.has_value()) {
      put_status_line(image,
                      "TARGET CANNOT BE PROJECTED WITH THIS FRAME'S INTRINSICS",
                      1, cv::Scalar(0, 0, 255));
      return;
    }

    cv::drawMarker(image, *pixel, cv::Scalar(0, 255, 0), cv::MARKER_CROSS, 30,
                   3, cv::LINE_AA);
    cv::circle(image, *pixel, 14, cv::Scalar(0, 255, 0), 2, cv::LINE_AA);
    put_status_line(image,
                    cv::format("SELECTED TARGET  conf=%.3f  pixel=(%d,%d)",
                               target_->confidence, pixel->x, pixel->y),
                    1, cv::Scalar(0, 255, 0));
    put_status_line(image,
                    cv::format("camera XYZ = (%.3f, %.3f, %.3f) m", target_->x,
                               target_->y, target_->z),
                    2, cv::Scalar(0, 255, 0));
  }

  rclcpp::Subscription<Image>::SharedPtr color_subscription_;
  rclcpp::Subscription<Image>::SharedPtr annotated_subscription_;
  rclcpp::Subscription<CameraInfo>::SharedPtr camera_info_subscription_;
  rclcpp::Subscription<PointCloud>::SharedPtr observation_subscription_;
  rclcpp::Subscription<Image>::SharedPtr wide_raw_subscription_;
  rclcpp::Subscription<Image>::SharedPtr wide_debug_subscription_;
  std::deque<ColorFrame> color_frames_;
  std::deque<AnnotatedFrame> annotated_frames_;
  Intrinsics latest_intrinsics_;
  std::optional<TargetObservation> target_;
  vision_debug::BufferedWideDisplay<cv_bridge::CvImageConstPtr> wide_frames_;
  std::optional<vision_debug::WideFrameSource> last_wide_source_;
  std::uint64_t last_wide_generation_{0};
  std::int64_t last_wide_stale_second_{-1};
  double target_timeout_s_{1.0};
  bool display_wide_{false};
  bool window_created_{false};
  bool window_was_visible_{false};
  bool wide_window_created_{false};
  bool wide_window_was_visible_{false};
};

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--probe-gui") {
    return probe_gui();
  }

  try {
    rclcpp::init(argc, argv);
    auto viewer = std::make_shared<VisionDebugViewer>();
    rclcpp::executors::SingleThreadedExecutor executor;
    executor.add_node(viewer);
    rclcpp::WallRate frame_rate(30.0);
    while (rclcpp::ok()) {
      executor.spin_some(std::chrono::milliseconds(5));
      if (!viewer->render()) {
        break;
      }
      frame_rate.sleep();
    }
    executor.remove_node(viewer);
    viewer.reset();
    rclcpp::shutdown();
    return 0;
  } catch (const cv::Exception &exception) {
    std::cerr << "ERROR: vision debug GUI failed: " << exception.what() << '\n';
  } catch (const std::exception &exception) {
    std::cerr << "ERROR: vision debug viewer failed: " << exception.what()
              << '\n';
  }

  if (rclcpp::ok()) {
    rclcpp::shutdown();
  }
  return 2;
}
