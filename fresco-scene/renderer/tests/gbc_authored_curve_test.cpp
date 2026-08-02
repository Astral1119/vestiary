// GBC Subaru 3448290956 is the only fixture in the corpus that keyframes
// geometry, and its face was the standing reason to suspect authored curves.
// Keyframed property curves were recorded as unimplemented on 2026-07-27,
// with this fixture's left eye-white as the evidence. The curves are in
// fact parsed and evaluated; the diagnosis was made by grepping the upstream
// tree, which has no keyframe support, rather than the patched build, which
// does — GeneratedPatches.cmake rewrites DynamicValueParser to call
// FrescoScene::makeDynamicValue.
//
// The curves below are the fixture's own, read out of scene.pkg. Values are
// verbatim; per-key Bezier tangents are dropped where a test does not turn on
// them, since the shape being pinned here is relative offsetting, channel
// count, and paused-versus-automatic lifecycle rather than interpolation.
//
// What this pins is that the two mechanisms behave as authored. It says
// nothing about the other two mechanisms serving this face — puppet meshes and
// scripted origins — which remain undiagnosed.

#include "FrescoScene/DynamicValueAnimation.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>

using FrescoScene::DynamicValueAnimation;
using FrescoScene::advanceAutomaticDynamicValueAnimations;
using FrescoScene::dynamicValueAnimation;
using FrescoScene::makeDynamicValue;
using WallpaperEngine::Data::JSON::JSON;
using WallpaperEngine::Data::Model::DynamicValue;

namespace {

bool near(float left, float right) { return std::abs(left - right) < 0.01f; }

// Object 3 「頭」, property `origin`. An entrance: the head arrives from far
// below and settles by frame 40, then holds to the end of its 120-frame length.
// `wraploop` is null and the mode is single, so it must not swoop again.
JSON headOrigin() {
  return JSON::parse(R"({
        "c0": [{"frame": 0, "value": -10.05041},
               {"frame": 25, "value": -1.86157},
               {"frame": 40, "value": -2.1540501},
               {"frame": 120, "value": -2.1540501}],
        "c1": [{"frame": 0, "value": -1021.2269},
               {"frame": 25, "value": 93.153},
               {"frame": 40, "value": 5.28},
               {"frame": 120, "value": 5.28}],
        "c2": [{"frame": 25, "value": 0},
               {"frame": 120, "value": 0}],
        "options": {"fps": 30, "length": 120, "mode": "single",
                    "name": "yidong", "wraploop": null},
        "relative": true
    })");
}

// Object 2 「左眼白」, property `origin`. A click interaction — 点击動画 — and
// so start-paused. Every c0 and c2 key is zero and c1 begins at zero, which is
// the detail the 2026-07-27 entry turned on: at rest this curve contributes no
// offset, so following it and resting at the static fallback put the eye-white
// in exactly the same place.
JSON eyeWhiteOrigin() {
  return JSON::parse(R"({
        "c0": [{"frame": 7, "value": 0}, {"frame": 33, "value": 0},
               {"frame": 49, "value": 0}, {"frame": 60, "value": 0},
               {"frame": 72, "value": 0}, {"frame": 90, "value": 0}],
        "c1": [{"frame": 7, "value": 0}, {"frame": 33, "value": -338.206},
               {"frame": 49, "value": -338.206}, {"frame": 60, "value": -280},
               {"frame": 72, "value": -280}, {"frame": 90, "value": 0}],
        "c2": [{"frame": 7, "value": 0}, {"frame": 33, "value": 0},
               {"frame": 49, "value": 0}, {"frame": 60, "value": 0},
               {"frame": 72, "value": 0}, {"frame": 90, "value": 0}],
        "options": {"fps": 30, "length": 90, "mode": "single",
                    "name": "dianji", "startpaused": true, "wraploop": null},
        "relative": true
    })");
}

// Object 3 「頭」, property `scale`. A ±0.1 wobble that returns to zero, which
// is only a wobble if the offsets are added to the authored scale rather than
// replacing it.
JSON headScale() {
  return JSON::parse(R"({
        "c0": [{"frame": 0, "value": 0}, {"frame": 28, "value": -0.1},
               {"frame": 43, "value": 0.1}, {"frame": 55, "value": 0}],
        "c1": [{"frame": 0, "value": 0}, {"frame": 28, "value": 0.1},
               {"frame": 43, "value": -0.1}, {"frame": 55, "value": 0}],
        "c2": [{"frame": 0, "value": 0}, {"frame": 28, "value": 0},
               {"frame": 43, "value": 0}, {"frame": 55, "value": 0}],
        "options": {"fps": 30, "length": 55, "mode": "single",
                    "wraploop": null},
        "relative": true
    })");
}

} // namespace

int main() {
  // Three channels against a vec3 is the shape no other fixture uses, and a
  // channel-count mismatch against the value is a documented rejection.
  auto originJson = headOrigin();
  auto origin = makeDynamicValue(&originJson);
  origin->update(glm::vec3(-18.06604f, 31.07446f, 0.0f),
                 DynamicValue::UpdateSource::Initialization);
  auto *originCurve = dynamicValueAnimation(*origin);
  assert(originCurve != nullptr);
  assert(originCurve->supported());
  assert(originCurve->channelCount() == 3);
  assert(originCurve->relative());
  // No startpaused, so it plays without anything asking it to.
  assert(originCurve->state() == DynamicValueAnimation::State::Playing);

  // Frame 40 of 30fps is 1.3333s. The head should have arrived: y is the
  // authored 31.07446 plus the curve's 5.28.
  advanceAutomaticDynamicValueAnimations(40.0 / 30.0);
  assert(near(originCurve->frame(), 40.0f));
  assert(near(origin->getVec3().x, -18.06604f + -2.1540501f));
  assert(near(origin->getVec3().y, 31.07446f + 5.28f));
  assert(near(origin->getVec3().z, 0.0f));

  // Past its length it completes and holds. A curve that looped here would
  // send the head back below the screen every four seconds.
  advanceAutomaticDynamicValueAnimations(120.0 / 30.0);
  assert(originCurve->state() == DynamicValueAnimation::State::Completed);
  assert(near(originCurve->frame(), 120.0f));
  assert(near(origin->getVec3().y, 31.07446f + 5.28f));

  // The eye-white is start-paused, so it holds its authored origin and
  // contributes nothing until a click plays it.
  auto eyeJson = eyeWhiteOrigin();
  auto eye = makeDynamicValue(&eyeJson);
  eye->update(glm::vec3(3.10315f, -226.51782f, 0.0f),
              DynamicValue::UpdateSource::Initialization);
  auto *eyeCurve = dynamicValueAnimation(*eye);
  assert(eyeCurve != nullptr);
  assert(eyeCurve->supported());
  assert(eyeCurve->state() == DynamicValueAnimation::State::Paused);
  advanceAutomaticDynamicValueAnimations(1.0);
  assert(near(eyeCurve->frame(), 0.0f));
  assert(near(eye->getVec3().y, -226.51782f));

  // Played, it dips and returns. A start-paused curve never joins the
  // automatic registry even once it is playing, so it is advanced directly —
  // which is what SceneScriptEngine does for the script profiles that drive
  // named animations. Advancing only the automatic set leaves it at frame 0.
  eyeCurve->play();
  advanceAutomaticDynamicValueAnimations(1.0);
  assert(near(eyeCurve->frame(), 0.0f));

  // Frame 33 is the bottom of the dip.
  eyeCurve->advance(33.0 / 30.0);
  assert(near(eyeCurve->frame(), 33.0f));
  assert(near(eye->getVec3().y, -226.51782f + -338.206f));
  // ...and frame 90 returns it to where it started.
  eyeCurve->advance((90.0 - 33.0) / 30.0);
  assert(near(eyeCurve->frame(), 90.0f));
  assert(near(eye->getVec3().y, -226.51782f));
  assert(near(eye->getVec3().x, 3.10315f));

  // Scale offsets add to the authored scale. Replacing it would collapse the
  // head to a tenth of its size at frame 28 rather than shrinking it by 0.1.
  auto scaleJson = headScale();
  auto scale = makeDynamicValue(&scaleJson);
  scale->update(glm::vec3(0.93263f, 1.06737f, 1.0f),
                DynamicValue::UpdateSource::Initialization);
  auto *scaleCurve = dynamicValueAnimation(*scale);
  assert(scaleCurve != nullptr);
  assert(scaleCurve->supported());
  advanceAutomaticDynamicValueAnimations(28.0 / 30.0);
  assert(near(scale->getVec3().x, 0.93263f - 0.1f));
  assert(near(scale->getVec3().y, 1.06737f + 0.1f));
  assert(near(scale->getVec3().z, 1.0f));
  // Back to the authored scale by the end.
  advanceAutomaticDynamicValueAnimations((55.0 - 28.0) / 30.0);
  assert(near(scale->getVec3().x, 0.93263f));
  assert(near(scale->getVec3().y, 1.06737f));

  return 0;
}
