#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <deque>
#include <iterator>
#include <optional>
#include <string>
#include <utility>

namespace vision_debug {

using DisplayClock = std::chrono::steady_clock;

enum class WideFrameSource { Waiting, Debug, Raw, Stale };

struct WideFrameKey {
  std::int64_t stamp_ns{0};
  std::string frame_id;
  std::uint32_t width{0};
  std::uint32_t height{0};

  bool operator==(const WideFrameKey &other) const {
    return stamp_ns == other.stamp_ns && frame_id == other.frame_id &&
           width == other.width && height == other.height;
  }
};

template <typename ImageOwner> struct WidePresentation {
  WideFrameSource source{WideFrameSource::Waiting};
  ImageOwner image{};
  std::uint64_t generation{0};
  double age_s{0.0};
};

// Own whole source images: an annotation can replace only its own raw frame.
// The delay allows inference to catch up without replaying a backlog when it
// cannot. ImageOwner must retain the image's pixel storage.
template <typename ImageOwner> class BufferedWideDisplay {
public:
  static constexpr std::size_t kPendingLimit = 8;
  static constexpr auto kPresentationDelay = std::chrono::milliseconds(100);
  static constexpr double kMaxAgeS = 1.0;

  bool add(WideFrameKey key, WideFrameSource source, ImageOwner image,
           DisplayClock::time_point received_at) {
    expire_session(received_at);
    if (source != WideFrameSource::Raw && source != WideFrameSource::Debug) {
      return false;
    }
    if (shown_.has_value()) {
      if (key.stamp_ns < shown_->frame.key.stamp_ns) {
        return false;
      }
      if (key.stamp_ns == shown_->frame.key.stamp_ns) {
        if (!(key == shown_->frame.key) || source != WideFrameSource::Debug) {
          return false;
        }
        // Clear the same source frame even when the camera has stopped.
        // A late raw must not hide debug; this update needs no second delay.
        shown_ = Shown{Frame{std::move(key), std::move(image), received_at,
                             ++generation_}, source};
        last_received_at_ = received_at;
        return true;
      }
    }
    auto group = std::find_if(pending_.begin(), pending_.end(),
                             [&key](const Group &candidate) {
                               return candidate.key == key;
                             });
    if (group == pending_.end()) {
      // Equal stamps cannot associate incompatible frame metadata.
      const auto conflict = std::find_if(
          pending_.begin(), pending_.end(), [&key](const Group &candidate) {
            return candidate.key.stamp_ns == key.stamp_ns;
          });
      if (conflict != pending_.end()) {
        return false;
      }
      pending_.push_back(Group{key, received_at, std::nullopt, std::nullopt});
      group = std::prev(pending_.end());
    }
    auto &destination = source == WideFrameSource::Debug ? group->debug
                                                       : group->raw;
    destination = Frame{std::move(key), std::move(image), received_at,
                        ++generation_};
    last_received_at_ = received_at;
    while (pending_.size() > kPendingLimit) {
      const auto oldest = std::min_element(
          pending_.begin(), pending_.end(), [](const Group &left,
                                              const Group &right) {
            return left.key.stamp_ns < right.key.stamp_ns;
          });
      pending_.erase(oldest);
    }
    return true;
  }

  WidePresentation<ImageOwner> select(DisplayClock::time_point now) {
    expire_session(now);
    std::optional<Shown> newest_due;
    for (const auto &group : pending_) {
      if (now - group.first_received_at < kPresentationDelay) {
        continue;
      }
      const auto choice = fresh_choice(group, now);
      if (choice.has_value() &&
          (!newest_due.has_value() ||
           choice->frame.key.stamp_ns > newest_due->frame.key.stamp_ns)) {
        newest_due = choice;
      }
    }
    if (newest_due.has_value()) {
      shown_ = std::move(newest_due);
      const auto stamp = shown_->frame.key.stamp_ns;
      pending_.erase(std::remove_if(pending_.begin(), pending_.end(),
                                    [stamp](const Group &group) {
                                      return group.key.stamp_ns <= stamp;
                                    }), pending_.end());
    }
    if (shown_.has_value() && is_fresh(shown_->frame, now)) {
      return {shown_->source, shown_->frame.image, shown_->frame.generation,
              age(shown_->frame.received_at, now)};
    }
    if (!last_received_at_.has_value() || !pending_.empty()) {
      return {};
    }
    return {WideFrameSource::Stale, ImageOwner{}, 0,
            age(*last_received_at_, now)};
  }

  std::size_t pending_size() const { return pending_.size(); }

private:
  struct Frame {
    WideFrameKey key;
    ImageOwner image;
    DisplayClock::time_point received_at;
    std::uint64_t generation;
  };
  struct Group {
    WideFrameKey key;
    DisplayClock::time_point first_received_at;
    std::optional<Frame> raw;
    std::optional<Frame> debug;
  };
  struct Shown {
    Frame frame;
    WideFrameSource source;
  };

  static double age(DisplayClock::time_point received_at,
                    DisplayClock::time_point now) {
    return std::max(0.0,
                    std::chrono::duration<double>(now - received_at).count());
  }
  static bool is_fresh(const Frame &frame, DisplayClock::time_point now) {
    return age(frame.received_at, now) <= kMaxAgeS;
  }
  static std::optional<Shown> fresh_choice(const Group &group,
                                          DisplayClock::time_point now) {
    if (group.debug.has_value() && is_fresh(*group.debug, now)) {
      return Shown{*group.debug, WideFrameSource::Debug};
    }
    if (group.raw.has_value() && is_fresh(*group.raw, now)) {
      return Shown{*group.raw, WideFrameSource::Raw};
    }
    return std::nullopt;
  }
  void expire_session(DisplayClock::time_point now) {
    if (last_received_at_.has_value() &&
        age(*last_received_at_, now) > kMaxAgeS) {
      // A fully expired stream can restart with a new clock baseline.
      pending_.clear();
      shown_.reset();
    }
  }

  std::deque<Group> pending_;
  std::optional<Shown> shown_;
  std::optional<DisplayClock::time_point> last_received_at_;
  std::uint64_t generation_{0};
};

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
