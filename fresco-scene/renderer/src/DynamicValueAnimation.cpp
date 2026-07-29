#include "FrescoScene/DynamicValueAnimation.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <unordered_set>
#include <utility>

using WallpaperEngine::Data::JSON::JSON;
using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Data::Model::DynamicValueUniquePtr;

namespace FrescoScene {
namespace {

std::mutex animationRegistryMutex;
std::unordered_set<DynamicValueAnimation *> automaticAnimations;

float cubic(float p0, float p1, float p2, float p3, float t) {
  const float oneMinusT = 1.0f - t;
  return oneMinusT * oneMinusT * oneMinusT * p0 +
         3.0f * oneMinusT * oneMinusT * t * p1 + 3.0f * oneMinusT * t * t * p2 +
         t * t * t * p3;
}

float evaluateSegment(const DynamicAnimationKey &left,
                      const DynamicAnimationKey &right, float frame) {
  const float duration = static_cast<float>(right.frame - left.frame);
  if (duration <= 0.0f) {
    return right.value;
  }

  const float linear = std::clamp(
      (frame - static_cast<float>(left.frame)) / duration, 0.0f, 1.0f);
  if (!left.front.enabled && !right.back.enabled) {
    return std::lerp(left.value, right.value, linear);
  }

  const float x0 = static_cast<float>(left.frame);
  const float x3 = static_cast<float>(right.frame);
  const float x1 =
      left.front.enabled ? x0 + left.front.x : x0 + duration / 3.0f;
  const float x2 =
      right.back.enabled ? x3 + right.back.x : x3 - duration / 3.0f;
  const float y0 = left.value;
  const float y3 = right.value;
  const float y1 =
      left.front.enabled ? y0 + left.front.y : std::lerp(y0, y3, 1.0f / 3.0f);
  const float y2 =
      right.back.enabled ? y3 + right.back.y : std::lerp(y0, y3, 2.0f / 3.0f);

  if (!(x0 <= x1 && x1 <= x2 && x2 <= x3)) {
    return std::lerp(left.value, right.value, linear);
  }

  float low = 0.0f;
  float high = 1.0f;
  for (int iteration = 0; iteration < 16; ++iteration) {
    const float middle = (low + high) * 0.5f;
    if (cubic(x0, x1, x2, x3, middle) < frame) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return cubic(y0, y1, y2, y3, (low + high) * 0.5f);
}

float evaluateChannel(const std::vector<DynamicAnimationKey> &keys,
                      float frame) {
  if (frame <= static_cast<float>(keys.front().frame)) {
    return keys.front().value;
  }
  for (std::size_t index = 1; index < keys.size(); ++index) {
    if (frame <= static_cast<float>(keys[index].frame)) {
      return evaluateSegment(keys[index - 1], keys[index], frame);
    }
  }
  return keys.back().value;
}

DynamicAnimationTangent parseTangent(const JSON &key, const char *name) {
  DynamicAnimationTangent result;
  const auto it = key.find(name);
  if (it == key.end() || !it->is_object()) {
    return result;
  }
  result.enabled = it->value("enabled", false);
  result.automatic = it->value("magic", false);
  result.x = it->value("x", 0.0f);
  result.y = it->value("y", 0.0f);
  return result;
}

} // namespace

class AnimatedDynamicValue final : public DynamicValue {
public:
  explicit AnimatedDynamicValue(const JSON &animation) : m_animation(*this) {
    m_animation.parse(animation);
    if (m_animation.m_automatic && m_animation.supported()) {
      std::lock_guard lock(animationRegistryMutex);
      automaticAnimations.insert(&m_animation);
    }
  }

  ~AnimatedDynamicValue() override {
    std::lock_guard lock(animationRegistryMutex);
    automaticAnimations.erase(&m_animation);
  }

  DynamicValueAnimation &animation() { return m_animation; }
  const DynamicValueAnimation &animation() const { return m_animation; }

private:
  DynamicValueAnimation m_animation;
};

DynamicValueAnimation::DynamicValueAnimation(DynamicValue &owner)
    : m_owner(owner) {}

bool DynamicValueAnimation::supported() const {
  return m_state != State::Unsupported;
}

DynamicValueAnimation::State DynamicValueAnimation::state() const {
  return m_state;
}

const std::string &DynamicValueAnimation::diagnostic() const {
  return m_diagnostic;
}

std::size_t DynamicValueAnimation::channelCount() const {
  return m_channels.size();
}

float DynamicValueAnimation::frame() const { return m_frame; }

float DynamicValueAnimation::framesPerSecond() const { return m_fps; }

int DynamicValueAnimation::length() const { return m_length; }

const std::string &DynamicValueAnimation::name() const { return m_name; }

bool DynamicValueAnimation::relative() const { return m_relative; }

const std::optional<float> &DynamicValueAnimation::previewValue() const {
  return m_previewValue;
}

void DynamicValueAnimation::play() {
  if (!supported()) {
    return;
  }
  if (!captureRelativeBase()) {
    return;
  }
  if (m_state == State::Completed) {
    m_frame = 0.0f;
    apply();
  }
  m_state = State::Playing;
}

void DynamicValueAnimation::restart() {
  if (!supported()) {
    return;
  }
  if (!captureRelativeBase()) {
    return;
  }
  m_frame = 0.0f;
  m_state = State::Playing;
  apply();
}

void DynamicValueAnimation::pause() {
  if (m_state == State::Playing) {
    m_state = State::Paused;
  }
}

void DynamicValueAnimation::advance(double seconds) {
  if (m_state != State::Playing || seconds <= 0.0) {
    return;
  }
  if (!captureRelativeBase()) {
    return;
  }

  m_frame += static_cast<float>(seconds * static_cast<double>(m_fps));
  if (m_loop && m_length > 0) {
    m_frame = std::fmod(m_frame, static_cast<float>(m_length));
  } else if (m_frame >= static_cast<float>(m_length)) {
    m_frame = static_cast<float>(m_length);
    m_state = State::Completed;
  }
  apply();
}

void DynamicValueAnimation::parse(const JSON &animation) {
  auto reject = [this](std::string reason) {
    m_channels.clear();
    m_state = State::Unsupported;
    m_diagnostic = std::move(reason);
    // A rejected curve never registers as automatic, so it simply never plays
    // and reports nothing. Hyuga's opening animation is four coordinated
    // curves and a silent rejection of any one of them leaves that layer
    // frozen at its authored static value.
    if (std::getenv("FRESCO_SCENE_ANIMATION_TRACE") != nullptr) {
      std::fprintf(stderr, "dynamicAnimation rejected: %s\n",
                   m_diagnostic.c_str());
    }
  };

  if (!animation.is_object()) {
    reject("dynamic animation must be an object");
    return;
  }
  const auto optionsIt = animation.find("options");
  if (optionsIt == animation.end() || !optionsIt->is_object()) {
    reject("dynamic animation requires object options");
    return;
  }
  const auto &options = *optionsIt;
  for (const auto &[key, unused] : options.items()) {
    (void)unused;
    if (key != "fps" && key != "length" && key != "mode" && key != "name" &&
        key != "startpaused" && key != "wraploop" && key != "children" &&
        key != "events" && key != "parent" && key != "smoothing") {
      reject("unsupported dynamic animation option: " + key);
      return;
    }
  }
  const std::string mode = options.value("mode", std::string());
  if (mode != "single" && mode != "loop") {
    reject("unsupported dynamic animation mode: " + mode);
    return;
  }
  if (options.contains("children") &&
      !(options["children"].is_null() ||
        (options["children"].is_array() && options["children"].empty()))) {
    reject("unsupported dynamic animation option: children");
    return;
  }
  for (const char *unsupported : {"events", "parent", "smoothing"}) {
    if (options.contains(unsupported) && !options[unsupported].is_null()) {
      reject(std::string("unsupported dynamic animation option: ") +
             unsupported);
      return;
    }
  }

  m_fps = options.value("fps", 30.0f);
  m_length = options.value("length", 0);
  if (options.contains("name") && !options["name"].is_string()) {
    reject("dynamic animation name must be a string");
    return;
  }
  m_name = options.value("name", std::string());
  if (!std::isfinite(m_fps) || m_fps <= 0.0f || m_length <= 0) {
    reject("dynamic animation requires positive fps and length");
    return;
  }
  m_loop = mode == "loop" ||
           (options.contains("wraploop") && options["wraploop"].is_boolean() &&
            options["wraploop"].get<bool>());

  std::size_t channelCount = 0;
  while (channelCount < 4 &&
         animation.contains("c" + std::to_string(channelCount))) {
    ++channelCount;
  }
  if (channelCount == 0) {
    reject("dynamic animation requires c0");
    return;
  }
  for (const auto &[key, unused] : animation.items()) {
    (void)unused;
    if (key != "options" && key != "previewvalue" && key != "relative" && key != "c0" &&
        key != "c1" && key != "c2" && key != "c3") {
      reject("unsupported dynamic animation field: " + key);
      return;
    }
  }
  if (animation.contains("relative")) {
    if (!animation["relative"].is_boolean()) {
      reject("dynamic animation relative must be boolean");
      return;
    }
    m_relative = animation["relative"].get<bool>();
  }
  if (m_relative && mode != "single") {
    reject("relative dynamic animation only supports single mode");
    return;
  }
  for (std::size_t channel = channelCount; channel < 4; ++channel) {
    if (animation.contains("c" + std::to_string(channel))) {
      reject("dynamic animation channels must be contiguous from c0");
      return;
    }
  }
  if (animation.contains("previewvalue")) {
    if (!animation["previewvalue"].is_number()) {
      reject("dynamic animation previewvalue must be numeric");
      return;
    }
    m_previewValue = animation["previewvalue"].get<float>();
  }

  m_channels.reserve(channelCount);
  try {
    for (std::size_t channel = 0; channel < channelCount; ++channel) {
      const auto &axis = animation.at("c" + std::to_string(channel));
      if (!axis.is_array() || axis.empty()) {
        reject("dynamic animation channels must be non-empty arrays");
        return;
      }
      std::vector<DynamicAnimationKey> keys;
      keys.reserve(axis.size());
      for (const auto &raw : axis) {
        if (!raw.is_object() || !raw.contains("frame") ||
            !raw.contains("value")) {
          reject("dynamic animation key requires frame and value");
          return;
        }
        for (const auto &[keyName, unused] : raw.items()) {
          (void)unused;
          if (keyName != "frame" && keyName != "value" && keyName != "front" &&
              keyName != "back" && keyName != "lockangle" &&
              keyName != "locklength") {
            reject("unsupported dynamic animation key field: " + keyName);
            return;
          }
        }
        for (const char *side : {"front", "back"}) {
          if (!raw.contains(side)) {
            continue;
          }
          if (!raw[side].is_object()) {
            reject(
                std::string("dynamic animation tangent must be an object: ") +
                side);
            return;
          }
          for (const auto &[tangentKey, unused] : raw[side].items()) {
            (void)unused;
            if (tangentKey != "enabled" && tangentKey != "magic" &&
                tangentKey != "x" && tangentKey != "y") {
              reject("unsupported dynamic animation tangent field: " +
                     tangentKey);
              return;
            }
          }
        }
        DynamicAnimationKey key;
        key.frame = raw.at("frame").get<int>();
        key.value = raw.at("value").get<float>();
        key.lockAngle = raw.value("lockangle", false);
        key.lockLength = raw.value("locklength", false);
        key.front = parseTangent(raw, "front");
        key.back = parseTangent(raw, "back");
        keys.push_back(key);
      }
      std::stable_sort(keys.begin(), keys.end(),
                       [](const auto &left, const auto &right) {
                         return left.frame < right.frame;
                       });
      m_channels.push_back(std::move(keys));
    }
  } catch (const std::exception &error) {
    reject(std::string("invalid dynamic animation value: ") + error.what());
    return;
  }

  m_frame = 0.0f;
  m_automatic = !options.value("startpaused", false);
  m_state = m_automatic ? State::Playing : State::Paused;
  m_diagnostic.clear();
}

bool DynamicValueAnimation::captureRelativeBase() {
  if (!m_relative || m_relativeBaseCaptured) {
    return true;
  }
  switch (m_owner.getType()) {
  case DynamicValue::Float:
    m_relativeBase.assign({m_owner.getFloat()});
    break;
  case DynamicValue::Int:
    m_relativeBase.assign({static_cast<float>(m_owner.getInt())});
    break;
  case DynamicValue::Vec2: {
    const auto value = m_owner.getVec2();
    m_relativeBase.assign({value.x, value.y});
    break;
  }
  case DynamicValue::Vec3: {
    const auto value = m_owner.getVec3();
    m_relativeBase.assign({value.x, value.y, value.z});
    break;
  }
  case DynamicValue::Vec4: {
    const auto value = m_owner.getVec4();
    m_relativeBase.assign({value.x, value.y, value.z, value.w});
    break;
  }
  default:
    m_state = State::Unsupported;
    m_diagnostic = "relative dynamic animation requires a numeric value";
    return false;
  }
  if (m_relativeBase.size() != m_channels.size()) {
    m_relativeBase.clear();
    m_state = State::Unsupported;
    m_diagnostic = "relative dynamic animation channel count does not match its value";
    return false;
  }
  m_relativeBaseCaptured = true;
  return true;
}

void DynamicValueAnimation::apply() {
  if (!supported() || m_channels.empty()) {
    return;
  }
  std::array<float, 4> value{};
  for (std::size_t channel = 0; channel < m_channels.size(); ++channel) {
    value[channel] = evaluateChannel(m_channels[channel], m_frame);
    if (m_relative && m_relativeBaseCaptured) {
      value[channel] += m_relativeBase[channel];
    }
  }
  switch (m_channels.size()) {
  case 1:
    m_owner.update(value[0], DynamicValue::UpdateSource::Script);
    break;
  case 2:
    m_owner.update(glm::vec2(value[0], value[1]),
                   DynamicValue::UpdateSource::Script);
    break;
  case 3:
    m_owner.update(glm::vec3(value[0], value[1], value[2]),
                   DynamicValue::UpdateSource::Script);
    break;
  case 4:
    m_owner.update(glm::vec4(value[0], value[1], value[2], value[3]),
                   DynamicValue::UpdateSource::Script);
    break;
  default:
    break;
  }
}

DynamicValueUniquePtr makeDynamicValue(const JSON *animation) {
  if (animation == nullptr) {
    return std::make_unique<DynamicValue>();
  }
  return std::make_unique<AnimatedDynamicValue>(*animation);
}

DynamicValueAnimation *dynamicValueAnimation(DynamicValue &value) {
  auto *animated = dynamic_cast<AnimatedDynamicValue *>(&value);
  return animated == nullptr ? nullptr : &animated->animation();
}

const DynamicValueAnimation *dynamicValueAnimation(const DynamicValue &value) {
  const auto *animated = dynamic_cast<const AnimatedDynamicValue *>(&value);
  return animated == nullptr ? nullptr : &animated->animation();
}

void advanceAutomaticDynamicValueAnimations(double seconds) {
  if (!std::isfinite(seconds) || seconds <= 0.0) {
    return;
  }
  std::vector<DynamicValueAnimation *> animations;
  {
    std::lock_guard lock(animationRegistryMutex);
    animations.assign(automaticAnimations.begin(), automaticAnimations.end());
  }
  for (DynamicValueAnimation *animation : animations) {
    animation->advance(seconds);
  }
}

std::size_t automaticDynamicValueAnimationCount() {
  std::lock_guard lock(animationRegistryMutex);
  return automaticAnimations.size();
}

} // namespace FrescoScene
