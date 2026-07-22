#include "FrescoScene/SceneSoundSemanticCapability.h"
#include "FrescoScene/AudioFloatScript.h"

#include <cassert>
#include <cmath>
#include <string>
#include <vector>

namespace {

void require (bool condition) {
    assert (condition);
}

template <typename Parser>
void rejectSupersets (std::string_view source, Parser parser) {
    constexpr std::string_view extras[] = {
        "\nimport * as WEMath from 'WEMath';",
        "\nconst cursor = input.cursorWorldPosition;",
        "\nshared.unmodeled = true;",
        "\nexport function cursorEnter(event) {}",
        "\nexport function mediaPlaybackChanged(event) {}",
        "\nthisScene.destroyLayer('other');",
        "\nconst t = engine.time;",
        "\nfetch('https://example.invalid');",
    };
    for (const auto extra : extras) {
        require (!parser (std::string (source) + std::string (extra)).has_value ());
    }
}

}

int main () {
    constexpr auto delayed = R"JS(
'use strict';
let songNames = ['first', 'second', 'random'];
export var scriptProperties = createScriptProperties()
    .addCheckbox({name:'enableDelay', value:false})
    .addText({name:'delayTime', value:'1'})
    .finish();
let musicLayers = [], elapsedTime = 0, targetDelay = 0;
export function init() {
    musicLayers = songNames.map(song => thisScene.getLayer(song));
    musicLayers.forEach(song => { if (song && song.stop) song.stop(); });
    const delayValue = parseFloat(scriptProperties.delayTime.trim());
    if (isNaN(delayValue)) console.warn('invalid');
}
export function update() {
    elapsedTime += engine.frametime;
    if (elapsedTime >= targetDelay) playTargetMusic();
}
export function applyUserProperties(changedUserProperties) {
    if (changedUserProperties.music === undefined) return;
    const delayValue = parseFloat(scriptProperties.delayTime.trim()) || 0;
    if (scriptProperties.enableDelay && delayValue > 0) targetDelay = delayValue;
    musicLayers.forEach(song => song.stop());
}
function playTargetMusic() {
    const targetSong = musicLayers[0];
    if (!targetSong.isPlaying()) targetSong.play();
}
)JS";
    const auto delayedCapability
        = FrescoScene::parseDelayedMediaVisibilityCapability (delayed);
    require (delayedCapability.has_value ());
    require (delayedCapability->selectionProperty == "music");
    require (delayedCapability->referencedLayers
             == std::vector<std::string> ({"first", "second", "random"}));
    require (delayedCapability->propertySchema.size () == 2);
    require (delayedCapability->delayEnabledProperty == "enableDelay");
    require (delayedCapability->delaySecondsProperty == "delayTime");
    rejectSupersets (delayed, FrescoScene::parseDelayedMediaVisibilityCapability);

    constexpr auto visibility = R"JS(
'use strict';
let songNames = ['alpha.ogg', 'beta.ogg', 'shuffle'];
export function applyUserProperties(changedUserProperties) {
    if (changedUserProperties.music !== undefined) {
        songNames.forEach(song => song.stop());
        const randomIndex = Math.floor(Math.random() * songNames.length);
        if (!songNames[randomIndex].isPlaying()) songNames[randomIndex].play();
    }
}
export function init() {
    songNames = songNames.map(song => thisScene.getLayer(song));
    songNames.forEach(song => song.stop());
}
)JS";
    const auto visibilityCapability
        = FrescoScene::parseSoundLayerVisibilityCapability (visibility);
    require (visibilityCapability.has_value ());
    require (visibilityCapability->selectionProperty == "music");
    require (visibilityCapability->referencedLayers
             == std::vector<std::string> ({"alpha.ogg", "beta.ogg", "shuffle"}));
    rejectSupersets (visibility, FrescoScene::parseSoundLayerVisibilityCapability);

    constexpr auto cursor = R"JS(
'use strict';
export var scriptProperties = createScriptProperties()
    .addText({name:'count1', value:'1'})
    .addText({name:'voice1', value:'quoted voice one'})
    .addText({name:'count2', value:'2'})
    .addText({name:'voice2', value:'quoted voice two'})
    .addText({name:'waitingtime', value:'0.3'})
    .finish();
let count = 0, waitingtime = 0;
export function cursorClick(event) {
    ++count;
    if (count == scriptProperties.count1)
        thisScene.getLayer(scriptProperties.voice1).play();
    if (count == scriptProperties.count2)
        thisScene.getLayer(scriptProperties.voice2).play();
}
export function update(value) {
    waitingtime += engine.frametime;
    if (waitingtime > scriptProperties.waitingtime) count = 0;
}
)JS";
    const auto cursorCapability
        = FrescoScene::parseCursorClickSoundCapability (cursor);
    require (cursorCapability.has_value ());
    require (cursorCapability->referencedLayers
             == std::vector<std::string> ({"quoted voice one", "quoted voice two"}));
    rejectSupersets (cursor, FrescoScene::parseCursorClickSoundCapability);

    require (FrescoScene::parseSoundControllerCapability (delayed)->kind
             == FrescoScene::SoundControllerCapabilityKind::delayedSelection);
    require (FrescoScene::parseSoundControllerCapability (visibility)->kind
             == FrescoScene::SoundControllerCapabilityKind::visibilitySelection);
    require (FrescoScene::parseSoundControllerCapability (cursor)->kind
             == FrescoScene::SoundControllerCapabilityKind::cursorSingleShot);

    const std::vector controllers {
        *delayedCapability,
        *visibilityCapability,
        *cursorCapability,
    };
    const auto playlistOwnership
        = FrescoScene::soundLayerOwnership ("alpha.ogg", controllers);
    require (playlistOwnership.controllerOwned && playlistOwnership.startPaused);
    const auto cursorOwnership
        = FrescoScene::soundLayerOwnership ("quoted voice one", controllers);
    require (cursorOwnership.controllerOwned && cursorOwnership.startPaused);
    const auto ambientOwnership
        = FrescoScene::soundLayerOwnership ("ambient.mp3", controllers);
    require (!ambientOwnership.controllerOwned && !ambientOwnership.startPaused);

    const auto resolved = FrescoScene::soundLayerOwnership (
        std::vector<std::string> {
            "alpha.ogg", "quoted voice one", "duplicate", "duplicate", "ambient.mp3"
        },
        std::vector {
            *visibilityCapability,
            *cursorCapability,
            FrescoScene::SoundControllerCapability {
                .kind = FrescoScene::SoundControllerCapabilityKind::cursorSingleShot,
                .referencedLayers = {"duplicate", "missing"},
            },
        }
    );
    require (resolved.size () == 5);
    require (resolved[0].controllerOwned && resolved[0].startPaused);
    require (resolved[1].controllerOwned && resolved[1].startPaused);
    require (!resolved[2].controllerOwned && !resolved[3].controllerOwned);
    require (!resolved[4].controllerOwned && !resolved[4].startPaused);

    constexpr auto mono16 = R"JS(
'use strict';
const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
export function update(value) {
    value = (audioBuffer.average[0] || 0.15) * 10;
    return value;
}
)JS";
    const auto first
        = FrescoScene::parseMonoAudioAverageTransformCapability (mono16);
    require (first.has_value ());
    require (first->resolution == 16 && first->bin == 0);
    require (FrescoScene::supportsMonoAudioAverageTransform (mono16));
    require (std::abs (first->fallback - 0.15F) < 0.0001F);
    require (std::abs (first->gain - 10.0F) < 0.0001F);

    constexpr auto mono32 = R"JS(
'use strict';
const spectrum = engine.registerAudioBuffers(32);
export function update(value) {
    value = (spectrum.average[7] || 0.25) * 3.5;
    return value;
}
)JS";
    const auto second
        = FrescoScene::parseMonoAudioAverageTransformCapability (mono32);
    require (second.has_value ());
    require (second->resolution == 32 && second->bin == 7);
    require (!FrescoScene::supportsMonoAudioAverageTransform (mono32));
    require (std::abs (second->fallback - 0.25F) < 0.0001F);
    require (std::abs (second->gain - 3.5F) < 0.0001F);

    require (!FrescoScene::parseMonoAudioAverageTransformCapability (
        std::string (mono16) + " shared.extra = true;"
    ).has_value ());
    require (!FrescoScene::parseMonoAudioAverageTransformCapability (R"JS(
'use strict';
const spectrum = engine.registerAudioBuffers(16);
export function update(value) {
    value = (spectrum.average[16] || 0.25) * 2;
    return value;
}
)JS").has_value ());
    require (!FrescoScene::parseCursorClickSoundCapability (
        std::string (cursor)
        + "\nthisScene.getLayer(dynamicLayerName).play();"
    ).has_value ());
    require (!FrescoScene::parseCursorClickSoundCapability (
        std::string (cursor)
        + "\nfunction spin() { for (;;) {} } spin();"
    ).has_value ());
    require (!FrescoScene::parseCursorClickSoundCapability (
        std::string (cursor)
        + "\nfunction spin() { spin(); } spin();"
    ).has_value ());
    require (!FrescoScene::parseCursorClickSoundCapability (
        std::string (cursor)
        + "\nconst spin = () => spin(); spin();"
    ).has_value ());
    require (!FrescoScene::parseCursorClickSoundCapability (
        std::string (cursor)
        + "\nexport function update(value) { update(value); }"
    ).has_value ());
}
