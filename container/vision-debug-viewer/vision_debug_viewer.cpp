#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <exception>
#include <functional>
#include <iostream>
#include <limits>
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

namespace {

using SteadyClock = std::chrono::steady_clock;
using Image = sensor_msgs::msg::Image;
using CameraInfo = sensor_msgs::msg::CameraInfo;
using PointCloud = sensor_msgs::msg::PointCloud;

constexpr char kWindowName[] = "26Fly RealSense / selected target debug";
constexpr char kExpectedTargetFrame[] = "target_camera_optical_frame";
constexpr std::size_t kFrameBufferLimit = 30;

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
  Intrinsics intrinsics;
};

struct DepthFrame {
  std::int64_t stamp_ns{0};
  cv::Mat metres;
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
    declare_parameter<std::string>(
        "depth_topic", "/camera/camera/aligned_depth_to_color/image_raw");
    declare_parameter<std::string>("camera_info_topic",
                                   "/camera/camera/color/camera_info");
    declare_parameter<std::string>("observation_topic", "/target_observation");
    declare_parameter<double>("target_timeout_s", 1.0);
    declare_parameter<double>("max_depth_m", 8.0);
    declare_parameter<double>("max_color_depth_skew_s", 0.04);
    declare_parameter<bool>("display_depth", true);

    target_timeout_s_ = get_parameter("target_timeout_s").as_double();
    max_depth_m_ = get_parameter("max_depth_m").as_double();
    const double max_color_depth_skew_s =
        get_parameter("max_color_depth_skew_s").as_double();
    display_depth_ = get_parameter("display_depth").as_bool();
    if (!finite_positive(target_timeout_s_) || !finite_positive(max_depth_m_) ||
        !std::isfinite(max_color_depth_skew_s) ||
        max_color_depth_skew_s < 0.0 || max_color_depth_skew_s > 10.0) {
      throw std::invalid_argument(
          "target_timeout_s and max_depth_m must be positive, and "
          "max_color_depth_skew_s must be finite and between 0 and 10 seconds");
    }
    max_color_depth_skew_ns_ =
        static_cast<std::int64_t>(std::llround(max_color_depth_skew_s * 1e9));

    const auto sensor_qos = rclcpp::SensorDataQoS().keep_last(5);
    color_subscription_ = create_subscription<Image>(
        get_parameter("color_topic").as_string(), sensor_qos,
        std::bind(&VisionDebugViewer::on_color, this, std::placeholders::_1));
    depth_subscription_ = create_subscription<Image>(
        get_parameter("depth_topic").as_string(), sensor_qos,
        std::bind(&VisionDebugViewer::on_depth, this, std::placeholders::_1));
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

    cv::namedWindow(kWindowName, cv::WINDOW_NORMAL);
    window_created_ = true;
    RCLCPP_INFO(
        get_logger(),
        "Viewer started. It displays the selected target centre only; the "
        "detector "
        "does not publish bounding boxes or classes. Press q or Esc to exit.");
  }

  ~VisionDebugViewer() override {
    if (window_created_) {
      try {
        cv::destroyWindow(kWindowName);
      } catch (const cv::Exception &) {
      }
    }
  }

  bool render() {
    cv::Mat color_view;
    const ColorFrame *selected_color = nullptr;
    bool target_is_fresh = false;
    bool target_is_matched = false;

    if (!color_frames_.empty()) {
      selected_color = &color_frames_.back();
    }

    if (target_.has_value()) {
      const double age_s = std::chrono::duration<double>(SteadyClock::now() -
                                                         target_->received_at)
                               .count();
      target_is_fresh = age_s <= target_timeout_s_;
      if (target_is_fresh) {
        const auto match =
            std::find_if(color_frames_.rbegin(), color_frames_.rend(),
                         [this](const ColorFrame &frame) {
                           return frame.stamp_ns == target_->stamp_ns;
                         });
        if (match != color_frames_.rend()) {
          selected_color = &(*match);
          target_is_matched = true;
        }
      }
    }

    if (selected_color == nullptr) {
      color_view = cv::Mat::zeros(480, 640, CV_8UC3);
      put_status_line(color_view, "Waiting for RealSense color frames...", 0,
                      cv::Scalar(0, 255, 255));
    } else {
      color_view = selected_color->image.clone();
      draw_target_overlay(color_view, *selected_color, target_is_fresh,
                          target_is_matched);
    }

    cv::Mat output = color_view;
    if (display_depth_ && selected_color != nullptr) {
      const DepthFrame *depth = nearest_depth(selected_color->stamp_ns);
      if (depth != nullptr) {
        cv::Mat depth_view = colorize_depth(depth->metres);
        const bool same_dimensions = depth_view.size() == color_view.size();
        if (!same_dimensions) {
          cv::resize(depth_view, depth_view, color_view.size(), 0.0, 0.0,
                     cv::INTER_NEAREST);
          put_status_line(depth_view,
                          "DEPTH SIZE MISMATCH - resized for display", 0,
                          cv::Scalar(0, 0, 255));
        } else {
          put_status_line(depth_view, "Aligned depth", 0,
                          cv::Scalar(255, 255, 0));
        }
        if (same_dimensions && target_is_fresh && target_is_matched) {
          draw_depth_target(depth_view, depth->metres, *selected_color);
        }
        cv::hconcat(color_view, depth_view, output);
      } else {
        put_status_line(output, "No aligned depth frame within configured skew",
                        4, cv::Scalar(0, 165, 255));
      }
    }

    cv::imshow(kWindowName, output);
    const int key = cv::waitKey(1) & 0xff;
    if (key == 'q' || key == 27) {
      return false;
    }
    try {
      const double visibility =
          cv::getWindowProperty(kWindowName, cv::WND_PROP_VISIBLE);
      if (visibility >= 1.0) {
        window_was_visible_ = true;
        return true;
      }
      if (visibility < 0.0) {
        return true;
      }
      return !window_was_visible_;
    } catch (const cv::Exception &exception) {
      RCLCPP_WARN(get_logger(), "Debug window was closed: %s",
                  exception.what());
      return false;
    }
  }

private:
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

  void on_depth(const Image::ConstSharedPtr message) {
    double scale = 0.0;
    if (message->encoding == sensor_msgs::image_encodings::TYPE_16UC1 ||
        message->encoding == sensor_msgs::image_encodings::MONO16) {
      scale = 0.001;
    } else if (message->encoding == sensor_msgs::image_encodings::TYPE_32FC1 ||
               message->encoding == sensor_msgs::image_encodings::TYPE_64FC1) {
      scale = 1.0;
    } else {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Unsupported depth encoding: %s",
                           message->encoding.c_str());
      return;
    }

    try {
      DepthFrame frame;
      frame.stamp_ns = stamp_to_nanoseconds(message->header.stamp);
      cv_bridge::toCvShare(message)->image.convertTo(frame.metres, CV_32FC1,
                                                     scale);
      depth_frames_.push_back(std::move(frame));
      while (depth_frames_.size() > kFrameBufferLimit) {
        depth_frames_.pop_front();
      }
    } catch (const std::exception &exception) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "Cannot convert depth image: %s", exception.what());
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
                           bool target_is_fresh, bool target_is_matched) const {
    put_status_line(image, "RealSense color + detector output", 0,
                    cv::Scalar(255, 255, 0));
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

  void draw_depth_target(cv::Mat &depth_view, const cv::Mat &depth_metres,
                         const ColorFrame &color_frame) const {
    const auto pixel = projected_target(color_frame);
    if (!pixel.has_value() || pixel->x >= depth_metres.cols ||
        pixel->y >= depth_metres.rows) {
      return;
    }
    cv::drawMarker(depth_view, *pixel, cv::Scalar(255, 255, 255),
                   cv::MARKER_CROSS, 30, 3, cv::LINE_AA);
    const float measured_depth = depth_metres.at<float>(pixel->y, pixel->x);
    if (std::isfinite(measured_depth) && measured_depth > 0.0F) {
      put_status_line(
          depth_view,
          cv::format("depth pixel=%.3fm  observation Z=%.3fm  delta=%.3fm",
                     measured_depth, target_->z, measured_depth - target_->z),
          1, cv::Scalar(255, 255, 255));
    }
  }

  const DepthFrame *nearest_depth(std::int64_t color_stamp_ns) const {
    const DepthFrame *best = nullptr;
    std::int64_t best_delta = std::numeric_limits<std::int64_t>::max();
    for (const auto &depth : depth_frames_) {
      const std::int64_t delta = std::llabs(depth.stamp_ns - color_stamp_ns);
      if (delta < best_delta) {
        best = &depth;
        best_delta = delta;
      }
    }
    return best_delta <= max_color_depth_skew_ns_ ? best : nullptr;
  }

  cv::Mat colorize_depth(const cv::Mat &metres) const {
    cv::Mat safe = metres.clone();
    const cv::Mat valid =
        (safe > 0.0F) & (safe <= static_cast<float>(max_depth_m_));
    safe.setTo(0.0F, ~valid);
    cv::Mat scaled;
    safe.convertTo(scaled, CV_8UC1, 255.0 / max_depth_m_);
    cv::Mat colorized;
    cv::applyColorMap(scaled, colorized, cv::COLORMAP_TURBO);
    colorized.setTo(cv::Scalar(0, 0, 0), ~valid);
    return colorized;
  }

  rclcpp::Subscription<Image>::SharedPtr color_subscription_;
  rclcpp::Subscription<Image>::SharedPtr depth_subscription_;
  rclcpp::Subscription<CameraInfo>::SharedPtr camera_info_subscription_;
  rclcpp::Subscription<PointCloud>::SharedPtr observation_subscription_;
  std::deque<ColorFrame> color_frames_;
  std::deque<DepthFrame> depth_frames_;
  Intrinsics latest_intrinsics_;
  std::optional<TargetObservation> target_;
  double target_timeout_s_{1.0};
  double max_depth_m_{8.0};
  std::int64_t max_color_depth_skew_ns_{40000000};
  bool display_depth_{true};
  bool window_created_{false};
  bool window_was_visible_{false};
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
