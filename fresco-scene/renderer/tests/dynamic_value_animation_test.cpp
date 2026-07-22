#include "FrescoScene/DynamicValueAnimation.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Data/Parsers/DynamicValueParser.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>
#include <string>

using FrescoScene::DynamicValueAnimation;
using FrescoScene::advanceAutomaticDynamicValueAnimations;
using FrescoScene::dynamicValueAnimation;
using FrescoScene::makeDynamicValue;
using WallpaperEngine::Data::JSON::JSON;
using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Data::Model::Properties;
using WallpaperEngine::Data::Parsers::DynamicValueParser;

namespace {

bool near(float left, float right) { return std::abs(left - right) < 0.001f; }

JSON scalarCurve(bool startPaused = true) {
  auto result = JSON::parse(R"({
        "c0": [
            {"frame": 0, "value": 0, "front": {"enabled": true, "x": 1, "y": 0},
             "back": {"enabled": true, "x": -1, "y": 0},
             "lockangle": true, "locklength": true},
            {"frame": 30, "value": 1, "front": {"enabled": true, "x": 1, "y": 0},
             "back": {"enabled": true, "x": -1, "y": 0},
             "lockangle": true, "locklength": true}
        ],
        "options": {"fps": 30, "length": 30, "mode": "single",
                    "startpaused": true, "wraploop": null}
    })");
  result["options"]["startpaused"] = startPaused;
  return result;
}

} // namespace

int main() {
  auto plain = makeDynamicValue(nullptr);
  assert(dynamicValueAnimation(*plain) == nullptr);

  auto parserCurve = scalarCurve();
  auto parsed = DynamicValueParser::parse(
      JSON{{"value", 0.0f}, {"animation", parserCurve}}, Properties{}, false);
  assert(dynamicValueAnimation(*parsed) != nullptr);
  assert(dynamicValueAnimation(*parsed)->channelCount() == 1);

  auto automaticJson = scalarCurve(false);
  auto automatic = makeDynamicValue(&automaticJson);
  automatic->update(0.0f, DynamicValue::UpdateSource::Initialization);
  advanceAutomaticDynamicValueAnimations(0.5);
  assert(near(dynamicValueAnimation(*automatic)->frame(), 15.0f));
  assert(automatic->getFloat() > 0.0f && automatic->getFloat() < 1.0f);

  auto scalarJson = scalarCurve();
  auto scalar = makeDynamicValue(&scalarJson);
  scalar->update(0.0f, DynamicValue::UpdateSource::Initialization);
  auto *scalarAnimation = dynamicValueAnimation(*scalar);
  assert(scalarAnimation != nullptr);
  assert(scalarAnimation->supported());
  assert(scalarAnimation->state() == DynamicValueAnimation::State::Paused);
  assert(scalarAnimation->channelCount() == 1);
  assert(near(scalarAnimation->framesPerSecond(), 30.0f));
  assert(scalarAnimation->length() == 30);
  assert(!scalarAnimation->previewValue().has_value());
  assert(scalarAnimation->name().empty());
  assert(!scalarAnimation->relative());

  scalarAnimation->play();
  scalarAnimation->advance(0.5);
  assert(scalarAnimation->state() == DynamicValueAnimation::State::Playing);
  assert(near(scalarAnimation->frame(), 15.0f));
  assert(scalar->getFloat() > 0.0f && scalar->getFloat() < 1.0f);
  const float pausedValue = scalar->getFloat();
  scalarAnimation->pause();
  scalarAnimation->advance(0.25);
  assert(near(scalar->getFloat(), pausedValue));
  scalarAnimation->play();
  scalarAnimation->advance(0.5);
  assert(scalarAnimation->state() == DynamicValueAnimation::State::Completed);
  assert(near(scalar->getFloat(), 1.0f));
  scalarAnimation->play();
  assert(scalarAnimation->state() == DynamicValueAnimation::State::Playing);
  assert(near(scalarAnimation->frame(), 0.0f));
  assert(near(scalar->getFloat(), 0.0f));

  auto vectorJson = JSON::parse(R"({
        "c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 10}],
        "c1": [{"frame": 0, "value": 50}, {"frame": 30, "value": 0}],
        "options": {"fps": 30, "length": 30, "mode": "single", "wraploop": null}
    })");
  auto vector = makeDynamicValue(&vectorJson);
  vector->update(glm::vec2(0.0f), DynamicValue::UpdateSource::Initialization);
  auto *vectorAnimation = dynamicValueAnimation(*vector);
  assert(vectorAnimation != nullptr && vectorAnimation->channelCount() == 2);
  vectorAnimation->restart();
  vectorAnimation->advance(0.5);
  assert(near(vector->getVec2().x, 5.0f));
  assert(near(vector->getVec2().y, 25.0f));

  auto relativeJson = JSON::parse(R"({
        "c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 10}],
        "c1": [{"frame": 0, "value": 0}, {"frame": 30, "value": -20}],
        "c2": [{"frame": 0, "value": 0}, {"frame": 30, "value": 0}],
        "options": {"fps": 30, "length": 30, "mode": "single",
                    "name": "poke", "startpaused": true, "wraploop": null},
        "relative": true
    })");
  auto relative = makeDynamicValue(&relativeJson);
  relative->update(
      glm::vec3(100.0f, 200.0f, 3.0f),
      DynamicValue::UpdateSource::Initialization);
  auto *relativeAnimation = dynamicValueAnimation(*relative);
  assert(relativeAnimation != nullptr && relativeAnimation->supported());
  assert(relativeAnimation->name() == "poke");
  assert(relativeAnimation->relative());
  relativeAnimation->play();
  relativeAnimation->advance(0.5);
  assert(near(relative->getVec3().x, 105.0f));
  assert(near(relative->getVec3().y, 190.0f));
  assert(near(relative->getVec3().z, 3.0f));

  auto relativeAutoJson = relativeJson;
  relativeAutoJson["options"]["startpaused"] = false;
  relativeAutoJson["options"]["children"] = JSON::array();
  auto relativeAuto = makeDynamicValue(&relativeAutoJson);
  relativeAuto->update(
      glm::vec3(20.0f, 40.0f, 6.0f),
      DynamicValue::UpdateSource::Initialization);
  assert(dynamicValueAnimation(*relativeAuto)->supported());
  advanceAutomaticDynamicValueAnimations(0.5);
  assert(near(relativeAuto->getVec3().x, 25.0f));
  assert(near(relativeAuto->getVec3().y, 30.0f));
  assert(near(relativeAuto->getVec3().z, 6.0f));

  auto childAnimationJson = relativeAutoJson;
  childAnimationJson["options"]["children"].push_back(JSON::object());
  auto childAnimation = makeDynamicValue(&childAnimationJson);
  assert(!dynamicValueAnimation(*childAnimation)->supported());
  assert(dynamicValueAnimation(*childAnimation)->diagnostic().find(
             "option: children") != std::string::npos);

  auto relativeMismatchJson = relativeJson;
  relativeMismatchJson.erase("c2");
  auto relativeMismatch = makeDynamicValue(&relativeMismatchJson);
  relativeMismatch->update(
      glm::vec3(1.0f), DynamicValue::UpdateSource::Initialization);
  dynamicValueAnimation(*relativeMismatch)->play();
  assert(!dynamicValueAnimation(*relativeMismatch)->supported());
  assert(dynamicValueAnimation(*relativeMismatch)->diagnostic().find("channel count") !=
         std::string::npos);

  auto invalidNameJson = scalarCurve();
  invalidNameJson["options"]["name"] = 3;
  auto invalidName = makeDynamicValue(&invalidNameJson);
  assert(!dynamicValueAnimation(*invalidName)->supported());
  assert(dynamicValueAnimation(*invalidName)->diagnostic().find("name must be") !=
         std::string::npos);

  auto previewJson = scalarCurve();
  previewJson["previewvalue"] = 0.25f;
  auto preview = makeDynamicValue(&previewJson);
  assert(dynamicValueAnimation(*preview)->previewValue().value() == 0.25f);

  auto unsupportedJson = scalarCurve();
  unsupportedJson["options"]["mode"] = "mirror";
  auto unsupported = makeDynamicValue(&unsupportedJson);
  const auto *unsupportedAnimation = dynamicValueAnimation(*unsupported);
  assert(unsupportedAnimation != nullptr && !unsupportedAnimation->supported());
  assert(unsupportedAnimation->diagnostic().find("mode: mirror") !=
         std::string::npos);

  auto eventsJson = scalarCurve();
  eventsJson["options"]["events"] = JSON::array();
  auto events = makeDynamicValue(&eventsJson);
  const auto *eventsAnimation = dynamicValueAnimation(*events);
  assert(eventsAnimation != nullptr && !eventsAnimation->supported());
  assert(eventsAnimation->diagnostic().find("option: events") !=
         std::string::npos);

  auto unknownJson = scalarCurve();
  unknownJson["options"]["rate"] = 2.0f;
  auto unknown = makeDynamicValue(&unknownJson);
  assert(!dynamicValueAnimation(*unknown)->supported());
  assert(dynamicValueAnimation(*unknown)->diagnostic().find("option: rate") !=
         std::string::npos);

  return 0;
}
