#pragma once

#include "WallpaperEngine/Data/JSON.h"
#include "WallpaperEngine/Data/Model/Types.h"

#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace WallpaperEngine::Data::Model {
class DynamicValue;
}

namespace FrescoScene {

struct DynamicAnimationTangent {
  bool enabled = false;
  bool automatic = false;
  float x = 0.0f;
  float y = 0.0f;
};

struct DynamicAnimationKey {
  int frame = 0;
  float value = 0.0f;
  bool lockAngle = false;
  bool lockLength = false;
  DynamicAnimationTangent front;
  DynamicAnimationTangent back;
};

class DynamicValueAnimation {
public:
  enum class State {
    Paused,
    Playing,
    Completed,
    Unsupported,
  };

  [[nodiscard]] bool supported() const;
  [[nodiscard]] State state() const;
  [[nodiscard]] const std::string &diagnostic() const;
  [[nodiscard]] std::size_t channelCount() const;
  [[nodiscard]] float frame() const;
  [[nodiscard]] float framesPerSecond() const;
  [[nodiscard]] int length() const;
  [[nodiscard]] const std::string &name() const;
  [[nodiscard]] bool relative() const;
  [[nodiscard]] const std::optional<float> &previewValue() const;

  // play resumes a paused curve and restarts a completed curve.
  void play();
  void restart();
  void pause();
  void advance(double seconds);

private:
  friend class AnimatedDynamicValue;

  explicit DynamicValueAnimation(
      WallpaperEngine::Data::Model::DynamicValue &owner);
  void parse(const WallpaperEngine::Data::JSON::JSON &animation);
  bool captureRelativeBase();
  void apply();

  WallpaperEngine::Data::Model::DynamicValue &m_owner;
  std::vector<std::vector<DynamicAnimationKey>> m_channels;
  State m_state = State::Unsupported;
  std::string m_diagnostic = "dynamic animation was not parsed";
  float m_fps = 30.0f;
  int m_length = 0;
  float m_frame = 0.0f;
  bool m_loop = false;
  bool m_relative = false;
  bool m_automatic = false;
  bool m_relativeBaseCaptured = false;
  std::string m_name;
  std::vector<float> m_relativeBase;
  std::optional<float> m_previewValue;
};

// DynamicValueParser uses this factory so curve lifetime follows the parsed
// DynamicValue. Callers that do not carry an authored animation receive the
// upstream DynamicValue implementation unchanged.
WallpaperEngine::Data::Model::DynamicValueUniquePtr
makeDynamicValue(const WallpaperEngine::Data::JSON::JSON *animation);

DynamicValueAnimation *
dynamicValueAnimation(WallpaperEngine::Data::Model::DynamicValue &value);
const DynamicValueAnimation *
dynamicValueAnimation(const WallpaperEngine::Data::Model::DynamicValue &value);

// Advances authored, non-start-paused curves once per scene tick. Start-paused
// curves retain their explicit script-controlled lifecycle.
void advanceAutomaticDynamicValueAnimations(double seconds);
[[nodiscard]] std::size_t automaticDynamicValueAnimationCount();

} // namespace FrescoScene
