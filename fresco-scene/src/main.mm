/*
 * Fresco scene helper
 *
 * Copyright (C) 2026 astral (github.com/Astral1119)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 */

#import <AppKit/AppKit.h>
#ifndef FRESCO_SCENE_ANGLE_RUNTIME
#import <OpenGL/gl3.h>
#endif

#include "WallpaperEngine/Data/Assets/Package.h"
#include "WallpaperEngine/Data/Parsers/PackageParser.h"
#include "FrescoScene/AudioFloatScript.h"
#include "FrescoScene/AudioLifecycleClassifier.h"
#include "FrescoScene/MediaLifecycleClassifier.h"
#include "FrescoScene/SceneScriptCompatibility.h"

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
#include "FrescoScene/RendererSession.h"
#include "FrescoScene/RuntimeFrameCoordinator.h"
#include "FrescoScene/SceneScriptStoragePool.h"
#endif

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <poll.h>
#include <unistd.h>

namespace {

constexpr NSInteger protocolVersion = 1;
constexpr const char* helperVersion = "0.1.0";

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
std::unique_ptr<FrescoScene::RendererSession> activeRenderer;
std::unique_ptr<FrescoScene::RuntimeFrameCoordinator> activeFrameCoordinator;
std::optional<std::chrono::steady_clock::time_point> activeFrameEpoch;
std::optional<double> activeScriptTimerDueMilliseconds;
FrescoScene::SceneScriptStoragePool scriptStoragePool;
std::string activeRendererAssignment;
std::map<std::string, std::string> activeInactiveCameraGates;
NSInteger activePolicyRevision = 0;
NSArray<NSString*>* activePolicyReasonTokens = @[];
bool activeFrameScheduleChanged = false;
bool activeStaticPresentOnChange = false;
bool activeTrackedParticleLifecycle = false;
bool activeTrackedMediaLifecycle = false;
bool activeTrackedAudioLifecycle = false;
bool activeStaticDirty = false;
#endif

const std::vector<std::string>& requiredAssetFiles () {
    static const std::vector<std::string> files = {
        "shaders/generic4.vert",
        "shaders/generic4.frag",
        "shaders/genericimage2.vert",
        "shaders/genericimage2.frag",
        "shaders/genericimage3.vert",
        "shaders/genericimage3.frag",
        "shaders/genericimage4.vert",
        "shaders/genericimage4.frag",
        "shaders/genericparticle.vert",
        "shaders/genericparticle.frag",
        "materials/particle/halo.tex",
    };
    return files;
}

using WallpaperEngine::Data::Assets::Package;
using WallpaperEngine::Data::Parsers::PackageParser;

NSString* toNSString (const std::string& value) {
    return [[NSString alloc] initWithBytes:value.data ()
                                    length:value.size ()
                                  encoding:NSUTF8StringEncoding];
}

std::string toString (NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string () : std::string (
        utf8, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
    );
}

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
bool legacyFrameLoopEnabled () {
    static const bool enabled
        = std::getenv ("FRESCO_SCENE_LEGACY_FRAME_LOOP") != nullptr;
    return enabled;
}

void resetActiveFrameScheduling () {
    activeFrameCoordinator.reset ();
    activeFrameEpoch.reset ();
    activeScriptTimerDueMilliseconds.reset ();
    activeTrackedParticleLifecycle = false;
    activeTrackedMediaLifecycle = false;
    activeTrackedAudioLifecycle = false;
}

void synchronizeCoordinatorTime () {
    if (activeFrameCoordinator == nullptr || !activeFrameEpoch.has_value ()) {
        return;
    }
    const auto elapsed = std::chrono::duration_cast<FrescoScene::MonotonicTime> (
        std::chrono::steady_clock::now () - *activeFrameEpoch
    );
    activeFrameCoordinator->setTime (std::max (
        elapsed, FrescoScene::MonotonicTime {}
    ));
}

void invalidateCoordinator (
    FrescoScene::ProducerId producer,
    FrescoScene::ChangeReasonId reason
) {
    if (activeFrameCoordinator != nullptr) {
        (void)activeFrameCoordinator->invalidate (producer, reason);
    }
}

void synchronizeScriptTimerDeadline (
    const FrescoScene::FrameEvidence* frameEvidence = nullptr
) {
    if (activeFrameCoordinator == nullptr || activeRenderer == nullptr) {
        return;
    }
    const auto metrics = activeRenderer->metrics ();
    const auto& timers = frameEvidence != nullptr
        ? frameEvidence->scriptTimers : metrics.scriptTimers;
    const double scriptTimeMilliseconds = frameEvidence != nullptr
        ? frameEvidence->scriptTimeMilliseconds : metrics.scriptTimeMilliseconds;
    if (timers.pending == 0
        || !timers.nextDueMilliseconds.has_value ()) {
        activeFrameCoordinator->setScriptTimerDeadline (std::nullopt);
        activeScriptTimerDueMilliseconds.reset ();
        return;
    }
    if (activeScriptTimerDueMilliseconds
        == timers.nextDueMilliseconds) {
        return;
    }
    const double remainingMilliseconds = std::max (
        0.0,
        *timers.nextDueMilliseconds - scriptTimeMilliseconds
    );
    const auto remaining = std::chrono::duration_cast<
        FrescoScene::MonotonicTime
    > (std::chrono::duration<double, std::milli> (remainingMilliseconds));
    activeFrameCoordinator->setScriptTimerDeadline (
        activeFrameCoordinator->time () + remaining
    );
    activeScriptTimerDueMilliseconds
        = timers.nextDueMilliseconds;
}

void synchronizeParticleActivityLease () {
    if (activeFrameCoordinator == nullptr || activeRenderer == nullptr
        || !activeTrackedParticleLifecycle) {
        return;
    }
    activeFrameCoordinator->setParticleContinuousRequired (
        activeRenderer->metrics ().particles.continuousRequired
    );
}

void synchronizeMediaFrameDeadline () {
    if (activeFrameCoordinator == nullptr || activeRenderer == nullptr
        || !activeTrackedMediaLifecycle) {
        return;
    }
    const auto prepared = activeRenderer->prepareMediaFrames ();
    if (prepared.frameReady > 0) {
        activeFrameCoordinator->setMediaFrameDeadline (std::nullopt);
        (void)activeFrameCoordinator->invalidateMediaFrameReady ();
        return;
    }
    if (prepared.stalled > 0) {
        if (prepared.terminalStall) {
            invalidateCoordinator (
                FrescoScene::ChangeProducers::media,
                FrescoScene::ChangeReasons::timeAdvanced
            );
        }
        return;
    }
    if (prepared.terminalStall) {
        activeFrameCoordinator->setMediaFrameDeadline (std::nullopt);
        return;
    }
    if (!prepared.nextWakeSeconds.has_value ()) {
        activeFrameCoordinator->setMediaFrameDeadline (std::nullopt);
        return;
    }
    const double delaySeconds = *prepared.nextWakeSeconds;
    const auto delay = std::chrono::duration_cast<FrescoScene::MonotonicTime> (
        std::chrono::duration<double> (delaySeconds)
    );
    activeFrameCoordinator->setMediaFrameDeadline (
        activeFrameCoordinator->time () + std::max (
            delay, FrescoScene::MonotonicTime (1)
        )
    );
}

void synchronizeAudioEnvelopeDeadline () {
    if (activeFrameCoordinator == nullptr || activeRenderer == nullptr
        || !activeTrackedAudioLifecycle) {
        return;
    }
    const auto metrics = activeRenderer->metrics ();
    if (!metrics.audioEnvelopeContinuousRequired) {
        activeFrameCoordinator->setAudioEnvelopeDeadline (std::nullopt);
        return;
    }
    if (activeFrameCoordinator->evidence ().audioEnvelopeDeadlineActive) {
        return;
    }
    activeFrameCoordinator->setAudioEnvelopeDeadline (
        activeFrameCoordinator->time ()
            + std::chrono::duration_cast<FrescoScene::MonotonicTime> (
                activeRenderer->frameInterval ()
            )
    );
}

NSString* schedulingMode () {
    if (activeStaticPresentOnChange) {
        return @"static-present-on-change";
    }
    if (activeTrackedParticleLifecycle) {
        return @"tracked-particle-lifecycle";
    }
    if (activeTrackedMediaLifecycle) {
        return @"tracked-media-lifecycle";
    }
    if (activeTrackedAudioLifecycle) {
        return @"tracked-audio-lifecycle";
    }
    return @"legacy-continuous";
}

NSString* schedulingMechanism () {
    return activeFrameCoordinator != nullptr
        ? @"change-index-v1" : @"legacy-frame-loop";
}

template<typename Value, std::size_t Capacity, typename Transform>
NSArray* fixedEvidenceValues (
    const FrescoScene::FixedEvidenceItems<Value, Capacity>& items,
    Transform transform
) {
    NSMutableArray* values = [NSMutableArray arrayWithCapacity:items.count];
    for (std::size_t index = 0; index < items.count; ++index) {
        [values addObject:transform (items.values[index])];
    }
    return values;
}

template<typename Value, std::size_t Capacity, typename Transform>
NSDictionary* fixedEvidencePayload (
    const FrescoScene::FixedEvidenceItems<Value, Capacity>& items,
    Transform transform
) {
    return @{
        @"values": fixedEvidenceValues (items, transform),
        @"count": @(items.count),
        @"truncated": @(items.truncated),
    };
}

id optionalTimePayload (
    const std::optional<FrescoScene::MonotonicTime>& value
) {
    return value.has_value () ? @(value->count ()) : [NSNull null];
}

NSDictionary* coordinatorEvidencePayload () {
    if (activeFrameCoordinator == nullptr) {
        return nil;
    }
    const auto& evidence = activeFrameCoordinator->evidence ();
    NSMutableArray* reasonCounts = [NSMutableArray arrayWithCapacity:
        evidence.reasonCounts.size ()];
    for (const std::uint64_t count : evidence.reasonCounts) {
        [reasonCounts addObject:@(count)];
    }

    id lastDecision = [NSNull null];
    if (evidence.lastDecision.has_value ()) {
        const auto& decision = *evidence.lastDecision;
        lastDecision = @{
            @"sequence": @(decision.sequence),
            @"timeNanoseconds": @(decision.time.count ()),
            @"evaluate": @(decision.evaluate),
            @"missedDeadline": @(decision.missedDeadline),
            @"earliestRequiredWork": decision.earliestRequiredWork.has_value ()
                ? @(static_cast<std::uint8_t> (
                    *decision.earliestRequiredWork
                )) : [NSNull null],
            @"damage": decision.damagePresent ? @{
                @"conservativeUnknown": @(
                    decision.damageConservativeUnknown
                ),
                @"expansion": decision.damageConservativeUnknown
                    ? @"full-frame" : @"identifiers-only",
                @"affectedIDs": fixedEvidencePayload (
                    decision.affectedDamageIds,
                    [] (auto value) { return @(value); }
                ),
            } : [NSNull null],
            @"nextWakeNanoseconds": optionalTimePayload (decision.nextWake),
            @"reasons": fixedEvidencePayload (decision.reasons, [] (auto value) {
                return @(static_cast<std::uint16_t> (value));
            }),
            @"readyChanges": fixedEvidencePayload (
                decision.readyChanges, [] (auto value) { return @(value); }
            ),
            @"producers": fixedEvidencePayload (decision.producers, [] (auto value) {
                return @(value.value);
            }),
            @"producerEvaluations": fixedEvidencePayload (
                decision.producerEvaluations,
                [] (auto value) { return @(value.value); }
            ),
            @"leaseOccurrences": fixedEvidencePayload (
                decision.leaseOccurrences, [] (const auto& value) {
                    return @{
                        @"id": @(value.id),
                        @"generation": @(value.generation),
                        @"mode": @(static_cast<std::uint8_t> (value.mode)),
                        @"scheduledTimeNanoseconds": @(
                            value.scheduledTime.count ()
                        ),
                    };
                }
            ),
        };
    }

    id lastCompletion = [NSNull null];
    if (evidence.lastCompletion.has_value ()) {
        const auto& completion = *evidence.lastCompletion;
        lastCompletion = @{
            @"decisionSequence": @(completion.decisionSequence),
            @"evaluated": @(completion.evaluated),
            @"presented": @(completion.presented),
            @"result": @(static_cast<std::uint16_t> (completion.result)),
            @"acknowledgedChanges": fixedEvidencePayload (
                completion.acknowledgedChanges,
                [] (auto value) { return @(value); }
            ),
        };
    }

    return @{
        @"invalidations": @(evidence.invalidations),
        @"scriptTimerDeadlineSchedules": @(
            evidence.scriptTimerDeadlineSchedules
        ),
        @"scriptTimerDeadlineReleases": @(
            evidence.scriptTimerDeadlineReleases
        ),
        @"particleLeaseAcquisitions": @(
            evidence.particleLeaseAcquisitions
        ),
        @"particleLeaseReleases": @(evidence.particleLeaseReleases),
        @"mediaFrameDeadlineSchedules": @(
            evidence.mediaFrameDeadlineSchedules
        ),
        @"mediaFrameDeadlineReplacements": @(
            evidence.mediaFrameDeadlineReplacements
        ),
        @"mediaFrameDeadlineReleases": @(
            evidence.mediaFrameDeadlineReleases
        ),
        @"mediaFrameDeadlineActive": @(
            evidence.mediaFrameDeadlineActive
        ),
        @"mediaFrameReadyInvalidations": @(
            evidence.mediaFrameReadyInvalidations
        ),
        @"mediaFrameReadyPresentations": @(
            evidence.mediaFrameReadyPresentations
        ),
        @"lastMediaFrameReadyRevision": evidence.lastMediaFrameReadyRevision
            .has_value () ? @(*evidence.lastMediaFrameReadyRevision)
                          : [NSNull null],
        @"lastPresentedMediaFrameReadyRevision": evidence
            .lastPresentedMediaFrameReadyRevision.has_value ()
                ? @(*evidence.lastPresentedMediaFrameReadyRevision)
                : [NSNull null],
        @"lastMediaFrameReadyDecisionSequence": evidence
            .lastMediaFrameReadyDecisionSequence.has_value ()
                ? @(*evidence.lastMediaFrameReadyDecisionSequence)
                : [NSNull null],
        @"audioEnvelopeDeadlineSchedules": @(
            evidence.audioEnvelopeDeadlineSchedules
        ),
        @"audioEnvelopeDeadlineReplacements": @(
            evidence.audioEnvelopeDeadlineReplacements
        ),
        @"audioEnvelopeDeadlineReleases": @(
            evidence.audioEnvelopeDeadlineReleases
        ),
        @"audioEnvelopeDeadlineActive": @(
            evidence.audioEnvelopeDeadlineActive
        ),
        @"audioReadyInvalidations": @(evidence.audioReadyInvalidations),
        @"audioReadyPresentations": @(evidence.audioReadyPresentations),
        @"lastAudioReadyRevision": evidence.lastAudioReadyRevision.has_value ()
            ? @(*evidence.lastAudioReadyRevision) : [NSNull null],
        @"lastPresentedAudioReadyRevision": evidence
            .lastPresentedAudioReadyRevision.has_value ()
                ? @(*evidence.lastPresentedAudioReadyRevision)
                : [NSNull null],
        @"lastAudioReadyDecisionSequence": evidence
            .lastAudioReadyDecisionSequence.has_value ()
                ? @(*evidence.lastAudioReadyDecisionSequence)
                : [NSNull null],
        @"decisions": @(evidence.decisions),
        @"evaluations": @(evidence.evaluations),
        @"presentations": @(evidence.presentations),
        @"presentationSuppressions": @(evidence.presentationSuppressions),
        @"notEvaluated": @(evidence.notEvaluated),
        @"externalPresentations": @(evidence.externalPresentations),
        @"missedDeadlines": @(evidence.missedDeadlines),
        @"reasonCounts": reasonCounts,
        @"nextWakeNanoseconds": optionalTimePayload (evidence.nextWake),
        @"lastDecision": lastDecision,
        @"lastCompletion": lastCompletion,
    };
}

NSString* toNSStringView (std::string_view value) {
    return [[NSString alloc] initWithBytes:value.data ()
                                    length:value.size ()
                                  encoding:NSUTF8StringEncoding];
}

NSDictionary* shaderTargetPayload (const FrescoScene::ShaderTarget& target) {
    return @{
        @"language": toNSStringView (target.language),
        @"version": @(target.version),
        @"profile": toNSStringView (FrescoScene::shaderProfileName (target.profile)),
    };
}

NSDictionary* renderResourceLifecyclePayload (
    const FrescoScene::RenderResourceLifecycleEvidence& evidence
) {
    return @{
        @"generationsCreated": @(evidence.generationsCreated),
        @"generationsRetired": @(evidence.generationsRetired),
        @"liveGenerations": @(evidence.liveGenerations),
        @"completionBarriersRequested": @(evidence.completionBarriersRequested),
        @"completionBarriersCompleted": @(evidence.completionBarriersCompleted),
        @"completionBarriersFailed": @(evidence.completionBarriersFailed),
        @"retirementsWithoutCompletion": @(
            evidence.retirementsWithoutCompletion
        ),
        @"programPublications": @(evidence.programPublications),
        @"programDeletions": @(evidence.programDeletions),
        @"programRollbacks": @(evidence.programRollbacks),
        @"shaderCompileFailures": @(evidence.shaderCompileFailures),
        @"shaderTranslationFailures": @(evidence.shaderTranslationFailures),
        @"programSetupFailures": @(evidence.programSetupFailures),
        @"objectSetupFailures": @(evidence.objectSetupFailures),
        @"lastCreatedGeneration": @(evidence.lastCreatedGeneration),
        @"lastRetiredGeneration": @(evidence.lastRetiredGeneration),
        @"lastCompletedGeneration": @(evidence.lastCompletedGeneration),
        @"lastPublishedGeneration": @(evidence.lastPublishedGeneration),
        @"lastDeletedGeneration": @(evidence.lastDeletedGeneration),
        @"lastObjectSetupFailureGeneration": @(
            evidence.lastObjectSetupFailureGeneration
        ),
    };
}

NSDictionary* scriptTimerPayload (
    const FrescoScene::SceneScriptTimerEvidence& evidence
) {
    const auto optionalNumber = [] (const std::optional<double>& value) -> id {
        return value.has_value () ? @(*value) : [NSNull null];
    };
    return @{
        @"scheduled": @(evidence.scheduled),
        @"fired": @(evidence.fired),
        @"cancelled": @(evidence.cancelled),
        @"pending": @(evidence.pending),
        @"nextDueMilliseconds": optionalNumber (
            evidence.nextDueMilliseconds
        ),
        @"currentTimeMilliseconds": optionalNumber (
            evidence.currentTimeMilliseconds
        ),
        @"lastScheduledDelayMilliseconds": optionalNumber (
            evidence.lastScheduledDelayMilliseconds
        ),
        @"lastFiredDueMilliseconds": optionalNumber (
            evidence.lastFiredDueMilliseconds
        ),
        @"lastFiredAtMilliseconds": optionalNumber (
            evidence.lastFiredAtMilliseconds
        ),
    };
}

NSDictionary* particleRuntimePayload (
    const FrescoScene::ParticleRuntimeEvidence& evidence
) {
    return @{
        @"systems": @(evidence.systems),
        @"finiteSystems": @(evidence.finiteSystems),
        @"unknownSystems": @(evidence.unknownSystems),
        @"minimumSeed": @(evidence.minimumSeed),
        @"maximumSeed": @(evidence.maximumSeed),
        @"continuousRequired": @(evidence.continuousRequired),
        @"quiescent": @(evidence.quiescent),
        @"updates": @(evidence.updates),
        @"catchUpFrames": @(evidence.catchUpFrames),
        @"requestedMilliseconds": @(evidence.requestedMilliseconds),
        @"simulatedMilliseconds": @(evidence.simulatedMilliseconds),
        @"droppedMilliseconds": @(evidence.droppedMilliseconds),
        @"maximumRequestedMilliseconds": @(
            evidence.maximumRequestedMilliseconds
        ),
        @"maximumSimulatedMilliseconds": @(
            evidence.maximumSimulatedMilliseconds
        ),
        @"emitted": @(evidence.emitted),
        @"live": @(evidence.live),
        @"peakLive": @(evidence.peakLive),
        @"poolCapacity": @(evidence.poolCapacity),
        @"poolResizes": @(evidence.poolResizes),
        @"resourceInitializations": @(evidence.resourceInitializations),
        @"stateHash": @(evidence.stateHash),
    };
}

NSArray* scriptedDynamicFloatPayload (
    const std::vector<FrescoScene::ScriptedDynamicFloatEvidence>& values
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:values.size ()];
    for (const auto& value : values) {
        [result addObject:@{
            @"key": toNSString (value.key),
            @"value": @(value.value),
            @"updates": @(value.updates),
            @"changes": @(value.changes),
        }];
    }
    return result;
}

NSArray* numberPayload (const std::vector<double>& values) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:values.size ()];
    for (const double value : values) {
        [result addObject:@(value)];
    }
    return result;
}

NSDictionary* allocationCountsPayload (
    const FrescoScene::RenderAllocationCounts& counts
) {
    return @{
        @"live": @(counts.live),
        @"peak": @(counts.peak),
        @"allocations": @(counts.allocations),
        @"deallocations": @(counts.deallocations),
    };
}

NSDictionary* renderAllocationPayload (
    const FrescoScene::RenderAllocationEvidence& evidence
) {
    return @{
        @"shaders": allocationCountsPayload (evidence.shaders),
        @"shaderVariables": allocationCountsPayload (evidence.shaderVariables),
        @"passAttributes": allocationCountsPayload (evidence.passAttributes),
        @"passUniforms": allocationCountsPayload (evidence.passUniforms),
        @"passReferenceUniforms": allocationCountsPayload (
            evidence.passReferenceUniforms
        ),
        @"copiedUniformValues": allocationCountsPayload (
            evidence.copiedUniformValues
        ),
        @"intermediateFramebuffers": allocationCountsPayload (
            evidence.intermediateFramebuffers
        ),
        @"intermediateTextures": allocationCountsPayload (
            evidence.intermediateTextures
        ),
    };
}

NSDictionary* effectRenderPayload (
    const FrescoScene::EffectRenderEvidence& evidence
) {
    NSMutableArray* passes = [NSMutableArray arrayWithCapacity:
        evidence.orderedPasses.size ()];
    for (const auto& pass : evidence.orderedPasses) {
        [passes addObject:@{
            @"objectID": @(pass.objectId),
            @"shader": toNSString (pass.shader),
            @"authoredTarget": toNSString (pass.authoredTarget),
            @"drawTarget": toNSString (pass.drawTarget),
            @"input": toNSString (pass.input),
            @"previousInput": @(pass.previousInput),
            @"blendingMode": @(pass.blendingMode),
            @"truncatedTokens": @(pass.truncatedTokens),
        }];
    }
    return @{
        @"orderedPasses": passes,
        @"truncatedPasses": @(evidence.truncatedPasses),
    };
}

NSArray* pixelProbePayload (
    const std::vector<FrescoScene::PixelProbeEvidence>& probes
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:probes.size ()];
    for (const auto& probe : probes) {
        [result addObject:@{
            @"identity": toNSString (probe.identity),
            @"normalized": @[@(probe.xMilli), @(probe.yMilli)],
            @"pixel": @[@(probe.x), @(probe.y)],
            @"rgba": @[@(probe.rgba[0]), @(probe.rgba[1]),
                        @(probe.rgba[2]), @(probe.rgba[3])],
        }];
    }
    return result;
}

NSArray* pixelRegionPayload (
    const std::vector<FrescoScene::PixelRegionEvidence>& regions
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:regions.size ()];
    for (const auto& region : regions) {
        [result addObject:@{
            @"identity": toNSString (region.identity),
            @"normalized": @[@(region.leftMilli), @(region.bottomMilli),
                              @(region.rightMilli), @(region.topMilli)],
            @"pixels": @[@(region.left), @(region.bottom),
                          @(region.right), @(region.top)],
            @"pixelCount": @(region.pixels),
            @"varyingPixels": @(region.varyingPixels),
            @"pixelRGBTotal": @(region.pixelRGBTotal),
            @"pixelRGBAHash": @(region.pixelRGBAHash),
        }];
    }
    return result;
}

NSArray* propertyScriptPayload (
    const std::vector<FrescoScene::PropertyScriptEvidence>& scripts
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:scripts.size ()];
    for (const auto& script : scripts) {
        [result addObject:@{
            @"key": toNSString (script.key),
            @"profile": toNSString (script.profile),
            @"objectId": @(script.objectId),
            @"property": toNSString (script.property),
            @"value": @(script.value),
            @"initialized": @(script.initialized),
            @"seededDelaySeconds": @(script.seededDelaySeconds),
            @"targetDelaySeconds": @(script.targetDelaySeconds),
            @"propertyApplications": @(script.propertyApplications),
            @"updates": @(script.updates),
        }];
    }
    return result;
}

NSArray* textEffectChainPayload (
    const std::vector<FrescoScene::TextEffectChainEvidence>& chains
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:chains.size ()];
    for (const auto& chain : chains) {
        NSMutableArray* active = [NSMutableArray arrayWithCapacity:
            chain.activeEffectIds.size ()];
        for (const int effectId : chain.activeEffectIds) {
            [active addObject:@(effectId)];
        }
        NSMutableArray* blocking = [NSMutableArray arrayWithCapacity:
            chain.blockingEffectIds.size ()];
        for (const int effectId : chain.blockingEffectIds) {
            [blocking addObject:@(effectId)];
        }
        [result addObject:@{
            @"objectID": @(chain.objectId),
            @"mode": toNSStringView (FrescoScene::textEffectChainModeName (
                chain.mode
            )),
            @"reason": toNSStringView (chain.reason),
            @"activeEffectIDs": active,
            @"blockingEffectIDs": blocking,
            @"firstBlockingEffectID": chain.firstBlockingEffectId.has_value ()
                ? @(chain.firstBlockingEffectId.value ()) : [NSNull null],
            @"firstBlockingStage": toNSStringView (
                FrescoScene::textEffectBlockerStageName (chain.firstBlockingStage)
            ),
            @"supportedActiveEffects": @(chain.supportedActiveEffects),
        }];
    }
    return result;
}

NSArray* soundControlPayload (
    const std::vector<FrescoScene::SoundControlEvidence>& controls
) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:controls.size ()];
    for (const auto& control : controls) {
        [result addObject:@{
            @"id": @(control.id),
            @"name": toNSString (control.name),
            @"playing": @(control.playing),
            @"requestedPlaying": @(control.requestedPlaying),
            @"playerConstructed": @(control.playerConstructed),
            @"activeAsset": control.activeAsset.has_value ()
                ? toNSString (*control.activeAsset) : [NSNull null],
            @"error": toNSString (control.error),
            @"playRequests": @(control.playRequests),
            @"pauseRequests": @(control.pauseRequests),
            @"stopRequests": @(control.stopRequests),
        }];
    }
    return result;
}

NSArray<NSString*>* schedulingReasonTokens (
    NSDictionary* message, NSString** validationError
) {
    id rawTokens = message[@"reasonTokens"];
    if (rawTokens == nil) {
        return @[];
    }
    if (![rawTokens isKindOfClass:[NSArray class]]) {
        *validationError = @"scheduling policy reasonTokens must be an array";
        return nil;
    }
    NSMutableArray<NSString*>* tokens = [NSMutableArray array];
    for (id token in static_cast<NSArray*> (rawTokens)) {
        if (![token isKindOfClass:[NSString class]]) {
            *validationError
                = @"scheduling policy reasonTokens must contain only strings";
            return nil;
        }
        [tokens addObject:token];
    }
    return tokens;
}

bool schedulingInteger (
    NSDictionary* message,
    NSString* key,
    bool required,
    double defaultValue,
    double minimum,
    double maximum,
    double& result,
    NSString** validationError
) {
    id rawValue = message[key];
    if (rawValue == nil && !required) {
        result = defaultValue;
        return true;
    }
    const bool boolean = rawValue != nil
        && CFGetTypeID ((__bridge CFTypeRef) rawValue) == CFBooleanGetTypeID ();
    const double value = [rawValue isKindOfClass:[NSNumber class]] && !boolean
        ? [rawValue doubleValue] : NAN;
    if (![rawValue isKindOfClass:[NSNumber class]] || boolean
        || !std::isfinite (value) || std::floor (value) != value
        || value < minimum || value > maximum) {
        *validationError = [NSString stringWithFormat:
            @"scheduling policy %@ must be an integer from %.0f through %.0f",
            key, minimum, maximum
        ];
        return false;
    }
    result = value;
    return true;
}

bool schedulingPolicyPayload (
    NSDictionary* message,
    double& fpsCeiling,
    NSInteger& policyRevision,
    NSArray<NSString*>** reasonTokens,
    NSString** validationError
) {
    double fps = 0.0;
    if (!schedulingInteger (
            message, @"fpsCeiling", true, 0.0, 1.0, 240.0,
            fps, validationError
        )) {
        return false;
    }
    double revision = 0.0;
    if (!schedulingInteger (
            message, @"policyRevision", true, 0.0, 0.0,
            static_cast<double> (NSIntegerMax), revision, validationError
        )) {
        return false;
    }
    NSArray<NSString*>* parsedTokens = schedulingReasonTokens (
        message, validationError
    );
    if (parsedTokens == nil) {
        return false;
    }
    fpsCeiling = fps;
    policyRevision = static_cast<NSInteger> (revision);
    *reasonTokens = parsedTokens;
    return true;
}
#endif

void emitEvent (NSString* type, NSString* assignmentID, NSDictionary* payload = @{}) {
    NSMutableDictionary* event = [payload mutableCopy];
    event[@"protocolVersion"] = @(protocolVersion);
    event[@"type"] = type;
    event[@"assignmentID"] = assignmentID != nil ? assignmentID : @"";

    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:event options:0 error:&error];
    if (data == nil) {
        std::cerr << "cannot serialize protocol event: "
                  << toString (error.localizedDescription) << '\n';
        return;
    }

    std::cout.write (static_cast<const char*> (data.bytes),
                     static_cast<std::streamsize> (data.length));
    std::cout.put ('\n');
    std::cout.flush ();
}

NSDictionary* parseMessage (const std::string& line, NSError** error) {
    NSData* data = [NSData dataWithBytes:line.data () length:line.size ()];
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSString* messageString (NSDictionary* message, NSString* key) {
    id value = message[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
double messageNumber (NSDictionary* message, NSString* key, double fallback) {
    id value = message[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

bool messageBool (NSDictionary* message, NSString* key, bool fallback) {
    id value = message[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

std::uint16_t normalizedPixelCoordinate (NSDictionary* value, NSString* key) {
    id raw = value[key];
    const bool boolean = raw != nil
        && CFGetTypeID ((__bridge CFTypeRef) raw) == CFBooleanGetTypeID ();
    const double coordinate = [raw isKindOfClass:[NSNumber class]] && !boolean
        ? [raw doubleValue] : NAN;
    if (!std::isfinite (coordinate) || std::floor (coordinate) != coordinate
        || coordinate < 0.0 || coordinate > 1000.0) {
        throw std::runtime_error (
            "pixel evidence coordinates must be integers between 0 and 1000"
        );
    }
    return static_cast<std::uint16_t> (coordinate);
}

std::string pixelEvidenceIdentity (NSDictionary* value) {
    id raw = value[@"identity"];
    if (![raw isKindOfClass:[NSString class]]) {
        throw std::runtime_error ("pixel evidence identity must be a string");
    }
    return toString (static_cast<NSString*> (raw));
}

std::vector<FrescoScene::PixelProbeRequest> parsePixelProbes (id raw) {
    if (raw == nil) {
        return {};
    }
    if (![raw isKindOfClass:[NSArray class]]) {
        throw std::runtime_error ("pixelProbes must be an array");
    }
    std::vector<FrescoScene::PixelProbeRequest> result;
    for (id entry in static_cast<NSArray*> (raw)) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            throw std::runtime_error ("pixelProbes entries must be objects");
        }
        NSDictionary* value = static_cast<NSDictionary*> (entry);
        result.push_back ({
            .identity = pixelEvidenceIdentity (value),
            .xMilli = normalizedPixelCoordinate (value, @"xMilli"),
            .yMilli = normalizedPixelCoordinate (value, @"yMilli"),
        });
    }
    return result;
}

std::vector<FrescoScene::PixelRegionRequest> parsePixelRegions (id raw) {
    if (raw == nil) {
        return {};
    }
    if (![raw isKindOfClass:[NSArray class]]) {
        throw std::runtime_error ("pixelRegions must be an array");
    }
    std::vector<FrescoScene::PixelRegionRequest> result;
    for (id entry in static_cast<NSArray*> (raw)) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            throw std::runtime_error ("pixelRegions entries must be objects");
        }
        NSDictionary* value = static_cast<NSDictionary*> (entry);
        result.push_back ({
            .identity = pixelEvidenceIdentity (value),
            .leftMilli = normalizedPixelCoordinate (value, @"leftMilli"),
            .bottomMilli = normalizedPixelCoordinate (value, @"bottomMilli"),
            .rightMilli = normalizedPixelCoordinate (value, @"rightMilli"),
            .topMilli = normalizedPixelCoordinate (value, @"topMilli"),
        });
    }
    return result;
}

WallpaperEngine::Audio::UserPropertyBatch parseUserProperties (id rawProperties) {
    WallpaperEngine::Audio::UserPropertyBatch result;
    constexpr NSUInteger maximumDiagnostics = 16;
    auto diagnose = [&result] (NSString* message) {
        if (result.diagnostics.size () < maximumDiagnostics) {
            result.diagnostics.push_back (toString (message));
        }
    };
    if (rawProperties == nil) {
        return result;
    }
    if (![rawProperties isKindOfClass:[NSDictionary class]]) {
        result.received = 1;
        result.ignored = 1;
        diagnose (@"user properties must be an object");
        return result;
    }
    NSDictionary* properties = rawProperties;
    result.received = properties.count;
    for (id rawKey in properties) {
        if (![rawKey isKindOfClass:[NSString class]]) {
            ++result.ignored;
            diagnose (@"user property keys must be strings");
            continue;
        }
        NSString* key = rawKey;
        id rawSetting = properties[key];
        if (![rawSetting isKindOfClass:[NSDictionary class]]) {
            ++result.ignored;
            diagnose ([NSString stringWithFormat:@"invalid user property: %@", key]);
            continue;
        }
        NSDictionary* setting = rawSetting;
        id rawValue = setting[@"value"];
        if (setting.count != 1) {
            ++result.ignored;
            diagnose ([NSString stringWithFormat:@"invalid user property: %@", key]);
            continue;
        }
        if ([rawValue isKindOfClass:[NSString class]]) {
            result.values.insert_or_assign (
                toString (key), toString ((NSString*) rawValue)
            );
            continue;
        }
        if (![rawValue isKindOfClass:[NSNumber class]]) {
            ++result.ignored;
            diagnose ([NSString stringWithFormat:@"invalid user property: %@", key]);
            continue;
        }
        if (CFGetTypeID ((__bridge CFTypeRef) rawValue) == CFBooleanGetTypeID ()) {
            result.values.insert_or_assign (toString (key), [rawValue boolValue]);
            continue;
        }
        const double value = [rawValue doubleValue];
        if (std::isfinite (value)) {
            result.values.insert_or_assign (toString (key), value);
        } else {
            ++result.ignored;
            diagnose ([NSString stringWithFormat:@"invalid user property: %@", key]);
        }
    }
    return result;
}

NSDictionary* soundPropertyEvidencePayload (
    const WallpaperEngine::Audio::SoundPropertyEvidence& evidence
) {
    NSMutableArray* diagnostics = [NSMutableArray array];
    for (const auto& diagnostic : evidence.diagnostics) {
        [diagnostics addObject:toNSString (diagnostic)];
    }
    return @{
        @"received": @(evidence.received),
        @"appliedProperties": @(evidence.appliedProperties),
        @"appliedSoundLayers": @(evidence.appliedSoundLayers),
        @"acceptedScriptProperties": @(evidence.acceptedScriptProperties),
        @"queuedPropertyScripts": @(evidence.queuedPropertyScripts),
        @"ignored": @(evidence.ignored),
        @"diagnostics": diagnostics,
    };
}

bool parseAudioSpectrum (
    NSDictionary* message,
    std::array<float, 128>& spectrum,
    NSString** validationError
) {
    id rawValues = message[@"values"];
    if (![rawValues isKindOfClass:[NSArray class]]) {
        *validationError = @"audio spectrum values must be an array";
        return false;
    }
    NSArray* values = rawValues;
    if (values.count != spectrum.size ()) {
        *validationError = @"audio spectrum must contain exactly 128 values";
        return false;
    }
    for (NSUInteger index = 0; index < values.count; ++index) {
        id rawValue = values[index];
        if (
            ![rawValue isKindOfClass:[NSNumber class]]
            || CFGetTypeID ((__bridge CFTypeRef) rawValue) == CFBooleanGetTypeID ()
        ) {
            *validationError = @"audio spectrum values must be numbers";
            return false;
        }
        const double value = [rawValue doubleValue];
        if (!std::isfinite (value) || value < 0.0 || value > 1.0) {
            *validationError = @"audio spectrum values must be finite numbers from 0 through 1";
            return false;
        }
        spectrum[index] = static_cast<float> (value);
    }
    return true;
}

bool parseMediaSessionEvent (
    NSDictionary* message,
    FrescoScene::MediaSessionEvent& event,
    NSString** validationError
) {
    id rawKind = message[@"kind"];
    id rawPayload = message[@"payload"];
    if (![rawKind isKindOfClass:[NSString class]]
        || ![rawPayload isKindOfClass:[NSDictionary class]]) {
        *validationError = @"media session requires string kind and object payload";
        return false;
    }
    NSString* kind = rawKind;
    NSDictionary* payload = rawPayload;
    auto stringValue = [&payload, validationError] (
        NSString* key, std::string& result
    ) {
        id rawValue = payload[key];
        if (rawValue == nil) {
            result.clear ();
            return true;
        }
        if (![rawValue isKindOfClass:[NSString class]]) {
            *validationError = [NSString stringWithFormat:
                @"media session %@ must be a string", key];
            return false;
        }
        result = toString ((NSString*) rawValue);
        return true;
    };

    if ([kind isEqualToString:@"status"]) {
        id enabled = payload[@"enabled"];
        if (![enabled isKindOfClass:[NSNumber class]]
            || CFGetTypeID ((__bridge CFTypeRef) enabled) != CFBooleanGetTypeID ()) {
            *validationError = @"media session status enabled must be a boolean";
            return false;
        }
        event.kind = FrescoScene::MediaSessionEventKind::status;
        event.available = [enabled boolValue];
        return true;
    }
    if ([kind isEqualToString:@"playback"]) {
        id state = payload[@"state"];
        if (![state isKindOfClass:[NSNumber class]]
            || CFGetTypeID ((__bridge CFTypeRef) state) == CFBooleanGetTypeID ()) {
            *validationError = @"media session playback state must be 0, 1, or 2";
            return false;
        }
        const NSInteger value = [state integerValue];
        if (value < 0 || value > 2 || [state doubleValue] != value) {
            *validationError = @"media session playback state must be 0, 1, or 2";
            return false;
        }
        event.kind = FrescoScene::MediaSessionEventKind::playback;
        event.playback = static_cast<FrescoScene::MediaPlaybackState> (value);
        return true;
    }
    if ([kind isEqualToString:@"properties"]) {
        event.kind = FrescoScene::MediaSessionEventKind::properties;
        return stringValue (@"title", event.title)
            && stringValue (@"artist", event.artist)
            && stringValue (@"albumTitle", event.album);
    }
    if ([kind isEqualToString:@"timeline"]) {
        id position = payload[@"position"];
        id duration = payload[@"duration"];
        if (![position isKindOfClass:[NSNumber class]]
            || ![duration isKindOfClass:[NSNumber class]]
            || CFGetTypeID ((__bridge CFTypeRef) position) == CFBooleanGetTypeID ()
            || CFGetTypeID ((__bridge CFTypeRef) duration) == CFBooleanGetTypeID ()
            || !std::isfinite ([position doubleValue])
            || !std::isfinite ([duration doubleValue])
            || [position doubleValue] < 0.0
            || [duration doubleValue] < 0.0) {
            *validationError = @"media session timeline must contain nonnegative finite position and duration";
            return false;
        }
        event.kind = FrescoScene::MediaSessionEventKind::timeline;
        event.positionSeconds = [position doubleValue];
        event.durationSeconds = [duration doubleValue];
        return true;
    }
    if ([kind isEqualToString:@"thumbnail"]) {
        event.kind = FrescoScene::MediaSessionEventKind::thumbnail;
        std::string uri;
        if (!stringValue (@"thumbnail", uri)) {
            return false;
        }
        if (uri.empty ()) {
            event.thumbnail = std::nullopt;
            return true;
        }
        FrescoScene::MediaThumbnail thumbnail { .uri = std::move (uri) };
        if (!stringValue (@"primaryColor", thumbnail.primaryColor)
            || !stringValue (@"secondaryColor", thumbnail.secondaryColor)
            || !stringValue (@"tertiaryColor", thumbnail.tertiaryColor)
            || !stringValue (@"textColor", thumbnail.textColor)
            || !stringValue (@"highContrastColor", thumbnail.highContrastColor)) {
            return false;
        }
        event.thumbnail = std::move (thumbnail);
        return true;
    }
    *validationError = @"unknown media session kind";
    return false;
}
#endif

uint32_t readLittleUInt32 (std::istream& input) {
    unsigned char bytes[4] = {};
    input.read (reinterpret_cast<char*> (bytes), sizeof (bytes));
    if (input.gcount () != static_cast<std::streamsize> (sizeof (bytes))) {
        throw std::runtime_error ("truncated package header");
    }
    return static_cast<uint32_t> (bytes[0])
        | static_cast<uint32_t> (bytes[1]) << 8U
        | static_cast<uint32_t> (bytes[2]) << 16U
        | static_cast<uint32_t> (bytes[3]) << 24U;
}

std::string validatePackageTable (const std::filesystem::path& path,
                                  uint64_t packageBytes) {
    std::ifstream input (path, std::ios::binary);
    if (!input) {
        throw std::runtime_error ("cannot open package");
    }

    const uint32_t length = readLittleUInt32 (input);
    if (length < 4 || length > 64) {
        throw std::runtime_error ("invalid package header length");
    }

    std::string header (length, '\0');
    input.read (header.data (), static_cast<std::streamsize> (header.size ()));
    if (input.gcount () != static_cast<std::streamsize> (header.size ())) {
        throw std::runtime_error ("truncated package header");
    }
    if (!header.starts_with ("PKGV")) {
        throw std::runtime_error ("package header does not start with PKGV");
    }

    const uint32_t fileCount = readLittleUInt32 (input);
    if (fileCount > 1'000'000) {
        throw std::runtime_error ("package file count exceeds safety limit");
    }

    std::vector<std::pair<uint32_t, uint32_t>> entries;
    entries.reserve (fileCount);
    for (uint32_t index = 0; index < fileCount; ++index) {
        const uint32_t nameLength = readLittleUInt32 (input);
        if (nameLength > 1'048'576) {
            throw std::runtime_error ("package filename exceeds safety limit");
        }
        const auto beforeName = input.tellg ();
        if (beforeName < 0
            || static_cast<uint64_t> (beforeName) + nameLength + 8 > packageBytes) {
            throw std::runtime_error ("truncated package file table");
        }
        input.seekg (static_cast<std::streamoff> (nameLength), std::ios::cur);
        const uint32_t offset = readLittleUInt32 (input);
        const uint32_t entryLength = readLittleUInt32 (input);
        entries.emplace_back (offset, entryLength);
    }

    const auto basePosition = input.tellg ();
    if (basePosition < 0) {
        throw std::runtime_error ("invalid package file table");
    }
    const uint64_t baseOffset = static_cast<uint64_t> (basePosition);
    for (const auto& [offset, entryLength] : entries) {
        const uint64_t start = baseOffset + offset;
        const uint64_t end = start + entryLength;
        if (start > packageBytes || end < start || end > packageBytes) {
            throw std::runtime_error ("package entry lies outside the file");
        }
    }
    return header;
}

std::filesystem::path resolvePackagePath (NSString* rawPath) {
    if (rawPath == nil || rawPath.length == 0) {
        throw std::runtime_error ("inspect requires path");
    }

    std::filesystem::path path (toString (rawPath));
    std::error_code error;
    if (std::filesystem::is_directory (path, error)) {
        path /= "scene.pkg";
    }
    if (error) {
        throw std::runtime_error ("cannot inspect package path");
    }

    const auto canonical = std::filesystem::canonical (path, error);
    if (error || !std::filesystem::is_regular_file (canonical, error)) {
        throw std::runtime_error ("scene.pkg is not a readable regular file");
    }
    return canonical;
}

NSData* readEntry (Package& package,
                   const WallpaperEngine::Data::Assets::FileEntry& entry,
                   uint64_t packageBytes) {
    const uint64_t start = static_cast<uint64_t> (package.baseOffset) + entry.offset;
    const uint64_t end = start + entry.length;
    if (start > packageBytes || end < start || end > packageBytes) {
        throw std::runtime_error ("package entry lies outside the file");
    }

    std::vector<char> buffer (entry.length);
    package.file->base ().clear ();
    package.file->base ().seekg (static_cast<std::streamoff> (start), std::ios::beg);
    package.file->next (buffer.data (), buffer.size ());
    if (package.file->base ().gcount () != static_cast<std::streamsize> (buffer.size ())) {
        throw std::runtime_error ("truncated package entry");
    }
    return [NSData dataWithBytes:buffer.data () length:buffer.size ()];
}

id parseJSONEntry (Package& package,
                   const WallpaperEngine::Data::Assets::FileEntry& entry,
                   uint64_t packageBytes,
                   bool required) {
    NSData* data = readEntry (package, entry, packageBytes);
    NSError* error = nil;
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (document == nil && required) {
        throw std::runtime_error (
            "cannot parse scene.json: " + toString (error.localizedDescription)
        );
    }
    return document;
}

NSInteger countScripts (id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary* dictionary = value;
        NSInteger result = [dictionary[@"script"] isKindOfClass:[NSString class]] ? 1 : 0;
        for (id child in dictionary.allValues) {
            result += countScripts (child);
        }
        return result;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSInteger result = 0;
        for (id child in static_cast<NSArray*> (value)) {
            result += countScripts (child);
        }
        return result;
    }
    return 0;
}

void increment (NSMutableDictionary* counts, NSString* key) {
    counts[key] = @([counts[key] integerValue] + 1);
}

NSDictionary* inspectPackage (NSString* rawPath) {
    const std::filesystem::path path = resolvePackagePath (rawPath);
    const uint64_t packageBytes = std::filesystem::file_size (path);
    const std::string version = validatePackageTable (path, packageBytes);

    auto stream = std::make_shared<std::ifstream> (path, std::ios::binary);
    auto package = PackageParser::parse (stream);

    id scene = nil;
    NSInteger puppetModels = 0;
    NSInteger shaderFiles = 0;
    NSInteger audioFiles = 0;
    NSMutableSet* emptyCameraPaths = [NSMutableSet set];
    NSMutableDictionary* inactiveCameraGates = [NSMutableDictionary dictionary];

    for (const auto& file : package->files) {
        NSString* filename = toNSString (file->filename);
        NSString* lower = filename.lowercaseString;
        if ([lower hasSuffix:@".vert"] || [lower hasSuffix:@".frag"]) {
            shaderFiles += 1;
        }
        if ([lower hasSuffix:@".mp3"] || [lower hasSuffix:@".ogg"]
            || [lower hasSuffix:@".flac"] || [lower hasSuffix:@".wav"]) {
            audioFiles += 1;
        }
        if ([filename isEqualToString:@"scene.json"]) {
            scene = parseJSONEntry (*package, *file, packageBytes, true);
        } else if ([filename hasPrefix:@"scripts/camera_paths_"]
                   && [lower hasSuffix:@".json"]) {
            id document = parseJSONEntry (*package, *file, packageBytes, false);
            if ([document isKindOfClass:[NSDictionary class]]
                && [document[@"paths"] isKindOfClass:[NSArray class]]
                && [document[@"paths"] count] == 0) {
                [emptyCameraPaths addObject:filename];
            }
        } else if ([filename hasPrefix:@"models/"] && [lower hasSuffix:@".json"]) {
            id document = parseJSONEntry (*package, *file, packageBytes, false);
            if ([document isKindOfClass:[NSDictionary class]]
                && [document[@"puppet"] isKindOfClass:[NSString class]]) {
                puppetModels += 1;
            }
        }
    }

    if (![scene isKindOfClass:[NSDictionary class]]) {
        throw std::runtime_error ("package has no scene.json object");
    }
    const NSInteger scriptValues = countScripts (scene);

    id objectValue = scene[@"objects"];
    NSArray* objects = [objectValue isKindOfClass:[NSArray class]] ? objectValue : @[];
    NSMutableDictionary* objectTypes = [NSMutableDictionary dictionary];
    NSInteger effects = 0;
    NSInteger volumeLights = 0;
    NSInteger textScriptValues = 0;
    NSInteger audioFloatScriptValues = 0;
    NSSet* effectQuadFields = [NSSet setWithArray:@[
        @"shape", @"effects", @"id", @"name", @"dependencies", @"parent",
        @"origin", @"scale", @"angles", @"visible", @"locktransforms",
        @"disablepropagation",
        @"castshadow", @"alpha", @"color", @"horizontalalign", @"alignment",
        @"parallaxDepth", @"colorBlendMode", @"brightness",
    ]];

    for (id value in objects) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary* object = value;
        if ([object[@"image"] isKindOfClass:[NSString class]]) {
            increment (objectTypes, @"image");
        }
        if ([object[@"particle"] isKindOfClass:[NSString class]]
            || [object[@"particle"] isKindOfClass:[NSDictionary class]]) {
            increment (objectTypes, @"particle");
        }
        if ([object[@"model"] isKindOfClass:[NSString class]]) {
            increment (objectTypes, @"model");
        }
        if ([object[@"sound"] isKindOfClass:[NSArray class]]) {
            increment (objectTypes, @"sound");
        }
        if (object[@"text"] != nil) {
            increment (objectTypes, @"text");
            textScriptValues += countScripts (object[@"text"]);
        }
        if (object[@"light"] != nil) {
            increment (objectTypes, @"light");
        }
        if (object[@"shape"] != nil) {
            NSSet* objectFields = [NSSet setWithArray:object.allKeys];
            const bool effectQuad = [object[@"shape"] isKindOfClass:[NSString class]]
                && [object[@"shape"] isEqualToString:@"quad"]
                && [objectFields isSubsetOfSet:effectQuadFields]
                && [object[@"effects"] isKindOfClass:[NSArray class]]
                && [object[@"effects"] count] > 0
                && object[@"light"] == nil
                && object[@"camera"] == nil
                && object[@"model"] == nil
                && ![object[@"castshadow"] boolValue];
            if (effectQuad) {
                increment (objectTypes, @"effectQuad");
            } else {
                volumeLights += 1;
            }
        }
        if (object[@"camera"] != nil) {
            NSDictionary* origin = [object[@"origin"] isKindOfClass:[NSDictionary class]]
                ? object[@"origin"] : nil;
            NSString* originScript = [origin[@"script"] isKindOfClass:[NSString class]]
                ? origin[@"script"] : nil;
            NSString* path = [object[@"path"] isKindOfClass:[NSString class]]
                ? object[@"path"] : nil;
            const int objectID = [object[@"id"] intValue];
            const auto compatibility = originScript == nil
                ? FrescoScene::SceneScriptCompatibility {}
                : FrescoScene::classifyScenePropertyScript (
                    "origin_" + std::to_string (objectID),
                    FrescoScene::SceneScriptValueKind::vector3,
                    toString (originScript)
                );
            const bool camera2D = [object[@"camera"] isEqualToString:@"default"]
                && path != nil && [emptyCameraPaths containsObject:path]
                && (object[@"queuemode"] == nil
                    || [object[@"queuemode"] isEqualToString:@"random"])
                && compatibility.supported
                && compatibility.profile == "generic-canvas-origin-v1";
            id visible = object[@"visible"];
            NSDictionary* visibleSetting = [visible isKindOfClass:[NSDictionary class]]
                ? visible : nil;
            NSString* visibilityGate
                = [visibleSetting[@"user"] isKindOfClass:[NSString class]]
                ? visibleSetting[@"user"] : nil;
            const bool inactiveByDefault
                = ([visible isKindOfClass:[NSNumber class]] && ![visible boolValue])
                || (visibilityGate != nil
                    && [visibleSetting[@"value"] isKindOfClass:[NSNumber class]]
                    && ![visibleSetting[@"value"] boolValue]);
            if (camera2D) {
                increment (objectTypes, @"camera2D");
            } else if (inactiveByDefault) {
                increment (objectTypes, @"inactiveCamera");
                if (visibilityGate != nil) {
                    inactiveCameraGates[visibilityGate] = [NSString stringWithFormat:
                        @"camera %d is property-gated off; enabling it is unsupported because only canvas-origin scripted 2D cameras are implemented",
                        objectID
                    ];
                }
            } else {
                increment (objectTypes, @"camera");
            }
        }
        if ([object[@"effects"] isKindOfClass:[NSArray class]]) {
            effects += [object[@"effects"] count];
        }
        if ([object[@"animationlayers"] isKindOfClass:[NSArray class]]) {
            for (id layerValue in object[@"animationlayers"]) {
                if (![layerValue isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                id rate = static_cast<NSDictionary*> (layerValue)[@"rate"];
                NSString* source = [rate isKindOfClass:[NSDictionary class]]
                    && [rate[@"script"] isKindOfClass:[NSString class]]
                    ? rate[@"script"]
                    : nil;
                if (source != nil
                    && FrescoScene::supportsMonoAudioAverageTransform (
                        toString (source)
                    )) {
                    audioFloatScriptValues += 1;
                }
            }
        }
    }

    NSMutableArray* hardUnsupported = [NSMutableArray array];
    for (NSString* type in @[@"model", @"light"]) {
        if ([objectTypes[type] integerValue] > 0) {
            [hardUnsupported addObject:type];
        }
    }

    NSMutableArray* deferred = [NSMutableArray array];
    if ([objectTypes[@"camera"] integerValue] > 0) {
        [deferred addObject:@"camera"];
    }
    if (volumeLights > 0) {
        [deferred addObject:@"volumeLight"];
    }
#ifndef FRESCO_SCENE_RENDERER_AVAILABLE
    if ([objectTypes[@"sound"] integerValue] > 0) {
        [deferred addObject:@"sound"];
    }
#endif
    const NSInteger deferredScriptValues = std::max<NSInteger> (
        0, scriptValues - textScriptValues - audioFloatScriptValues
    );
    if (deferredScriptValues > 0) {
        [deferred addObject:@"sceneScript"];
    }
#if !defined(FRESCO_SCENE_RENDERER_AVAILABLE)
    if (puppetModels > 0) {
        [deferred addObject:@"puppetAnimation"];
    }
#else
    if (puppetModels > 0) {
        [deferred addObject:@"puppetSimulation"];
    }
#endif

    NSMutableArray* warnings = [NSMutableArray array];
    if (deferred.count > 0) {
        if ([deferred containsObject:@"camera"]) {
            [warnings addObject:@"camera objects are parsed but not rendered by the 2D helper"];
        }
        if ([deferred containsObject:@"volumeLight"]) {
            [warnings addObject:@"volume-light shape objects are not yet rendered"];
        }
    }
#if !defined(FRESCO_SCENE_RENDERER_AVAILABLE)
    if (puppetModels > 0) {
        [warnings addObject:@"puppet animation layers are not yet applied"];
    }
#else
    if (puppetModels > 0) {
        [warnings addObject:@"puppet bone simulation and active IK remain deferred"];
    }
#endif
#ifndef FRESCO_SCENE_RENDERER_AVAILABLE
    if ([objectTypes[@"sound"] integerValue] > 0) {
        [warnings addObject:
            @"sound playback is experimental and unadvertised; random and multi-asset modes remain deferred"];
    }
#endif
    if (deferredScriptValues > 0) {
        [warnings addObject:[NSString stringWithFormat:
            @"%ld other SceneScript dynamic values are not yet evaluated",
            static_cast<long> (deferredScriptValues)
        ]];
    }

    NSDictionary* statistics = @{
        @"packageVersion": toNSString (version),
        @"bytes": @(packageBytes),
        @"files": @(package->files.size ()),
        @"objects": @(objects.count),
        @"objectTypes": objectTypes,
        @"effects": @(effects),
        @"shaderFiles": @(shaderFiles),
        @"puppetModels": @(puppetModels),
        @"audioFiles": @(audioFiles),
        @"scriptValues": @(scriptValues),
        @"textScriptValues": @(textScriptValues),
        @"audioFloatScriptValues": @(audioFloatScriptValues),
        @"deferredScriptValues": @(deferredScriptValues),
    };

    return @{
        @"path": toNSString (path.string ()),
        @"supported2D": @(hardUnsupported.count == 0),
        @"hardUnsupportedTypes": hardUnsupported,
        @"deferredTypes": deferred,
        @"warnings": warnings,
        @"inactiveCameraGates": inactiveCameraGates,
        @"package": statistics,
    };
}

bool hasAssetSentinel (const std::filesystem::path& root) {
    std::error_code error;
    return std::filesystem::is_regular_file (
        root / requiredAssetFiles ().front (), error
    );
}

NSDictionary* validateAssets (NSString* rawPath) {
    if (rawPath == nil || rawPath.length == 0) {
        throw std::runtime_error ("validate-assets requires path");
    }

    std::error_code error;
    std::filesystem::path root = std::filesystem::canonical (
        std::filesystem::path (toString (rawPath)), error
    );
    if (error || !std::filesystem::is_directory (root, error)) {
        throw std::runtime_error ("asset root is not a readable directory");
    }

    if (!hasAssetSentinel (root)
        && std::filesystem::is_directory (root / "assets", error)) {
        root = std::filesystem::canonical (root / "assets", error);
        if (error) {
            throw std::runtime_error ("cannot resolve assets subdirectory");
        }
    }

    NSMutableArray* required = [NSMutableArray array];
    NSMutableArray* missing = [NSMutableArray array];
    for (const std::string& relative : requiredAssetFiles ()) {
        NSString* name = toNSString (relative);
        [required addObject:name];
        const std::filesystem::path file = root / relative;
        error.clear ();
        const bool regular = std::filesystem::is_regular_file (file, error);
        const uint64_t bytes = regular ? std::filesystem::file_size (file, error) : 0;
        if (error || !regular || bytes == 0) {
            [missing addObject:name];
        }
    }

    return @{
        @"path": toNSString (root.string ()),
        @"profile": @"fixture-corpus-2d-v1",
        @"valid": @(missing.count == 0),
        @"required": required,
        @"missing": missing,
    };
}

#ifndef FRESCO_SCENE_ANGLE_RUNTIME
NSString* openGLString (GLenum name) {
    const GLubyte* value = glGetString (name);
    return value == nullptr
        ? @""
        : [NSString stringWithUTF8String:reinterpret_cast<const char*> (value)];
}

NSDictionary* probeOpenGL () {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize,
        static_cast<NSOpenGLPixelFormatAttribute> (24),
        NSOpenGLPFAAlphaSize,
        static_cast<NSOpenGLPixelFormatAttribute> (8),
        NSOpenGLPFADepthSize,
        static_cast<NSOpenGLPixelFormatAttribute> (24),
        NSOpenGLPFAOpenGLProfile,
        static_cast<NSOpenGLPixelFormatAttribute> (NSOpenGLProfileVersion4_1Core),
        static_cast<NSOpenGLPixelFormatAttribute> (0),
    };
    NSOpenGLPixelFormat* format = [[NSOpenGLPixelFormat alloc]
        initWithAttributes:attributes];
    if (format == nil) {
        throw std::runtime_error ("cannot create an OpenGL 4.1 core pixel format");
    }

    const NSRect frame = NSMakeRect (0, 0, 16, 16);
    NSWindow* window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.level = static_cast<NSWindowLevel> (
        CGWindowLevelForKey (kCGDesktopIconWindowLevelKey) - 1
    );
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorStationary
        | NSWindowCollectionBehaviorIgnoresCycle;
    window.ignoresMouseEvents = YES;
    window.opaque = YES;
    window.backgroundColor = NSColor.blackColor;
    window.releasedWhenClosed = NO;

    NSOpenGLView* view = [[NSOpenGLView alloc] initWithFrame:frame pixelFormat:format];
    window.contentView = view;
    NSOpenGLContext* context = view.openGLContext;
    if (context == nil) {
        throw std::runtime_error ("cannot create an OpenGL 4.1 core context");
    }
    [context makeCurrentContext];
    [context update];

    GLint major = 0;
    GLint minor = 0;
    GLint profile = 0;
    GLint flags = 0;
    glGetIntegerv (GL_MAJOR_VERSION, &major);
    glGetIntegerv (GL_MINOR_VERSION, &minor);
    glGetIntegerv (GL_CONTEXT_PROFILE_MASK, &profile);
    glGetIntegerv (GL_CONTEXT_FLAGS, &flags);
    if (major < 4 || (major == 4 && minor < 1)
        || (profile & GL_CONTEXT_CORE_PROFILE_BIT) == 0) {
        [NSOpenGLContext clearCurrentContext];
        throw std::runtime_error ("created context is not OpenGL 4.1 core");
    }

    GLuint texture = 0;
    GLuint framebuffer = 0;
    glGenTextures (1, &texture);
    glBindTexture (GL_TEXTURE_2D, texture);
    glTexImage2D (
        GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr
    );
    glGenFramebuffers (1, &framebuffer);
    glBindFramebuffer (GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D (
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0
    );
    const GLenum framebufferStatus = glCheckFramebufferStatus (GL_FRAMEBUFFER);
    if (framebufferStatus != GL_FRAMEBUFFER_COMPLETE) {
        glDeleteFramebuffers (1, &framebuffer);
        glDeleteTextures (1, &texture);
        [NSOpenGLContext clearCurrentContext];
        throw std::runtime_error ("OpenGL proof framebuffer is incomplete");
    }

    glViewport (0, 0, 16, 16);
    glClearColor (0.25F, 0.5F, 0.75F, 1.0F);
    glClear (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glReadBuffer (GL_COLOR_ATTACHMENT0);
    GLubyte pixel[4] = {};
    glReadPixels (8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    const GLenum error = glGetError ();
    glBindFramebuffer (GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers (1, &framebuffer);
    glDeleteTextures (1, &texture);

    NSDictionary* result = @{
        @"major": @(major),
        @"minor": @(minor),
        @"coreProfile": @YES,
        @"forwardCompatible": @((flags & GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT) != 0),
        @"version": openGLString (GL_VERSION),
        @"vendor": openGLString (GL_VENDOR),
        @"renderer": openGLString (GL_RENDERER),
        @"pixel": @[@(pixel[0]), @(pixel[1]), @(pixel[2]), @(pixel[3])],
        @"glError": @(error),
        @"framebufferComplete": @(framebufferStatus == GL_FRAMEBUFFER_COMPLETE),
        @"windowLevel": @(window.level),
        @"ordered": @(window.isVisible),
    };

    [NSOpenGLContext clearCurrentContext];
    [window orderOut:nil];
    [window close];
    return result;
}
#endif

bool handleMessage (NSDictionary* message) {
    NSString* assignmentValue = messageString (message, @"assignmentID");
    NSString* assignmentID = assignmentValue != nil ? assignmentValue : @"";
    id version = message[@"protocolVersion"];
    if (![version isKindOfClass:[NSNumber class]]
        || [version integerValue] != protocolVersion) {
        emitEvent (@"fatal", assignmentID, @{
            @"code": @"protocol-version",
            @"message": @"protocolVersion must be 1",
            @"scope": @"assignment",
        });
        return true;
    }

    if (assignmentID.length == 0) {
        emitEvent (@"warning", @"", @{
            @"code": @"invalid-message",
            @"message": @"assignmentID must be a non-empty string",
        });
        return true;
    }

    NSString* type = messageString (message, @"type");
    if (type == nil) {
        emitEvent (@"warning", assignmentID, @{
            @"code": @"invalid-message",
            @"message": @"message type must be a string",
        });
        return true;
    }

    if ([type isEqualToString:@"hello"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        const auto& backend = FrescoScene::backendIdentity (
            FrescoScene::configuredBackend ()
        );
#endif
        NSMutableArray* capabilities = [NSMutableArray arrayWithArray:@[
            @"inspect-package",
            @"validate-assets",
#ifndef FRESCO_SCENE_ANGLE_RUNTIME
            @"probe-opengl-4.1",
#endif
            @"explicit-3d-diagnostics",
            @"heartbeat",
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
            @"render-image",
            @"render-particle",
            @"render-effect",
            @"render-text",
            @"script-text",
            @"script-audio-float-16-average0",
            @"audio-spectrum",
            @"media-session-v1",
            @"media-video-seek-v1",
            @"frame-difference-evidence",
            @"pause-resume",
            @"mute-unmute",
            @"sound-volume-properties",
            @"sound-cursor-click",
            @"cursor-hit-test-v1",
            @"show-hide",
            @"runtime-metrics",
            @"scheduling-policy-v1",
#endif
        ]];
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (WallpaperEngine::Audio::soundPlaybackEnabled ()) {
            [capabilities addObject:@"sound-playback"];
        }
#endif
        emitEvent (@"hello", assignmentID, @{
            @"helperVersion": toNSString (helperVersion),
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
            @"renderer": toNSStringView (backend.renderer),
            @"backend": toNSStringView (backend.id),
            @"graphicsAPI": toNSStringView (backend.graphicsAPI),
            @"shaderTarget": shaderTargetPayload (backend.shaderTarget),
#else
            @"renderer": @"unavailable",
#endif
            @"capabilities": capabilities,
        });
        return true;
    }

    if ([type isEqualToString:@"ping"]) {
        emitEvent (@"heartbeat", assignmentID);
        return true;
    }

    if ([type isEqualToString:@"audio-spectrum"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        std::array<float, 128> spectrum = {};
        NSString* validationError = nil;
        if (!parseAudioSpectrum (message, spectrum, &validationError)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-audio-spectrum",
                @"message": validationError,
            });
            return true;
        }
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"audio spectrum requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"audio spectrum assignment does not own the active renderer",
            });
            return true;
        }
        const auto evidence = activeRenderer->setAudioSpectrum (spectrum);
        if (evidence.changed) {
            if (activeFrameCoordinator != nullptr
                && activeTrackedAudioLifecycle) {
                (void)activeFrameCoordinator->invalidateAudioReady ();
            } else if (activeFrameCoordinator != nullptr) {
                invalidateCoordinator (
                    FrescoScene::ChangeProducers::audio,
                    FrescoScene::ChangeReasons::externalEvent
                );
            } else {
                activeStaticDirty = true;
            }
        }
        emitEvent (@"audio-spectrum-applied", assignmentID, @{
            @"changed": @(evidence.changed),
            @"inputs": @(evidence.inputs),
            @"changes": @(evidence.changes),
            @"spectrumHash": @(evidence.spectrumHash),
            @"vectorHash": @(evidence.vectorHash),
            @"vectorAverage0": @(evidence.vectorAverage0),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"audio spectrum requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"scheduling-policy"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        double fpsCeiling = 0.0;
        NSInteger policyRevision = 0;
        NSArray<NSString*>* reasonTokens = nil;
        NSString* validationError = nil;
        if (!schedulingPolicyPayload (
                message, fpsCeiling, policyRevision, &reasonTokens,
                &validationError
            )) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-scheduling-policy",
                @"message": validationError,
            });
            return true;
        }
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"scheduling policy requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"scheduling policy assignment does not own the active renderer",
            });
            return true;
        }
        const double activeFPS = activeRenderer->metrics ().targetFPS;
        if (policyRevision < activePolicyRevision) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"stale-scheduling-policy",
                @"message": @"scheduling policy revision is older than the applied revision",
            });
            return true;
        }
        if (policyRevision == activePolicyRevision) {
            if (fpsCeiling != activeFPS
                || ![reasonTokens isEqualToArray:activePolicyReasonTokens]) {
                emitEvent (@"warning", assignmentID, @{
                    @"code": @"conflicting-scheduling-policy",
                    @"message": @"scheduling policy revision conflicts with the applied payload",
                });
                return true;
            }
            emitEvent (@"scheduling-policy-applied", assignmentID, @{
                @"fpsCeiling": @(activeFPS),
                @"policyRevision": @(activePolicyRevision),
                @"reasonTokens": activePolicyReasonTokens,
            });
            return true;
        }
        activeRenderer->setFramesPerSecond (fpsCeiling);
        if (activeFrameCoordinator != nullptr) {
            activeFrameCoordinator->setFramesPerSecond (
                static_cast<std::uint32_t> (fpsCeiling)
            );
        }
        activePolicyRevision = policyRevision;
        activePolicyReasonTokens = [reasonTokens copy];
        if (activeFrameCoordinator == nullptr) {
            activeFrameScheduleChanged = true;
        }
        emitEvent (@"scheduling-policy-applied", assignmentID, @{
            @"fpsCeiling": @(fpsCeiling),
            @"policyRevision": @(activePolicyRevision),
            @"reasonTokens": activePolicyReasonTokens,
        });
#else
        emitEvent (@"fatal", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"this build inspects scene packages but does not render them",
            @"scope": @"assignment",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"media-session"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        FrescoScene::MediaSessionEvent mediaEvent;
        NSString* validationError = nil;
        if (!parseMediaSessionEvent (message, mediaEvent, &validationError)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-media-session",
                @"message": validationError,
            });
            return true;
        }
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"media session requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"media session assignment does not own the active renderer",
            });
            return true;
        }
        const auto evidence = activeRenderer->setMediaSession (mediaEvent);
        invalidateCoordinator (
            FrescoScene::ChangeProducers::media,
            FrescoScene::ChangeReasons::externalEvent
        );
        emitEvent (@"media-session-applied", assignmentID, @{
            @"kind": toNSString (FrescoScene::mediaSessionEventName (mediaEvent.kind)),
            @"events": @(evidence.events),
            @"revision": @(evidence.revision),
            @"available": @(evidence.available),
            @"playbackState": @(static_cast<int> (evidence.playback)),
                @"hasThumbnail": @(evidence.hasThumbnail),
                @"artworkReady": @(evidence.artworkReady),
                @"artworkRevision": @(evidence.artworkRevision),
                @"artworkRGBAHash": @(evidence.artworkRGBAHash),
                @"artworkError": toNSString (evidence.artworkError),
            });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"media session requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"media-video"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"media video control requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"media video control assignment does not own the active renderer",
            });
            return true;
        }
        NSString* action = [message[@"action"] isKindOfClass:[NSString class]]
            ? message[@"action"] : nil;
        id rawPosition = message[@"positionSeconds"];
        const bool booleanPosition = rawPosition != nil
            && CFGetTypeID ((__bridge CFTypeRef) rawPosition)
                == CFBooleanGetTypeID ();
        const double position = [rawPosition isKindOfClass:[NSNumber class]]
            && !booleanPosition ? [rawPosition doubleValue] : NAN;
        if (![action isEqualToString:@"seek"] || !std::isfinite (position)
            || position < 0.0) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-media-video-control",
                @"message": @"media-video requires action seek and a finite nonnegative positionSeconds",
            });
            return true;
        }
        const std::size_t players = activeRenderer->seekMediaTextures (position);
        NSString* deadlineMutation = @"legacy-invalidation";
        bool deadlineArmed = false;
        if (activeFrameCoordinator != nullptr && activeTrackedMediaLifecycle) {
            const auto before = activeFrameCoordinator->evidence ();
            activeFrameCoordinator->setMediaFrameDeadline (
                activeFrameCoordinator->time ()
            );
            const auto& after = activeFrameCoordinator->evidence ();
            deadlineArmed = after.mediaFrameDeadlineActive;
            if (after.mediaFrameDeadlineReplacements
                == before.mediaFrameDeadlineReplacements + 1
                && after.mediaFrameDeadlineSchedules
                    == before.mediaFrameDeadlineSchedules) {
                deadlineMutation = @"replaced";
            } else if (after.mediaFrameDeadlineSchedules
                == before.mediaFrameDeadlineSchedules + 1
                && after.mediaFrameDeadlineReplacements
                    == before.mediaFrameDeadlineReplacements) {
                deadlineMutation = @"scheduled";
            } else if (after.mediaFrameDeadlineSchedules
                    == before.mediaFrameDeadlineSchedules
                && after.mediaFrameDeadlineReplacements
                    == before.mediaFrameDeadlineReplacements) {
                deadlineMutation = @"retained";
            } else {
                deadlineMutation = @"inconsistent";
            }
        } else {
            invalidateCoordinator (
                FrescoScene::ChangeProducers::media,
                FrescoScene::ChangeReasons::timeAdvanced
            );
        }
        emitEvent (@"media-video-applied", assignmentID, @{
            @"action": @"seek",
            @"positionSeconds": @(position),
            @"players": @(players),
            @"deadlineMutation": deadlineMutation,
            @"deadlineArmed": @(deadlineArmed),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"media video control requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"cursor-down"]
        || [type isEqualToString:@"cursor-move"]
        || [type isEqualToString:@"cursor-up"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"cursor input requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"cursor input assignment does not own the active renderer",
            });
            return true;
        }
        NSString* phase = [type substringFromIndex:[@"cursor-" length]];
        const auto handled = activeRenderer->cursorEvent (
            toString (phase),
            static_cast<float> (messageNumber (message, @"x", 0.0)),
            static_cast<float> (messageNumber (message, @"y", 0.0))
        );
        if (handled) {
            invalidateCoordinator (
                FrescoScene::ChangeProducers::script,
                FrescoScene::ChangeReasons::externalEvent
            );
        }
        emitEvent (@"cursor-event-dispatched", assignmentID, @{
            @"phase": phase,
            @"handled": @(handled),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"cursor input requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"cursor-click"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"cursor click requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"cursor click assignment does not own the active renderer",
            });
            return true;
        }
        id rawObjectID = message[@"objectID"];
        id rawX = message[@"x"];
        id rawY = message[@"y"];
        const bool locating = rawObjectID == nil;
        if (locating
            && (![rawX isKindOfClass:[NSNumber class]]
                || ![rawY isKindOfClass:[NSNumber class]])) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-cursor-click",
                @"message": @"cursor click needs an objectID or scene x and y",
            });
            return true;
        }
        if (!locating && ![rawObjectID isKindOfClass:[NSNumber class]]) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"invalid-cursor-click",
                @"message": @"cursor click objectID must be an integer",
            });
            return true;
        }
        const int objectID = locating ? 0 : [rawObjectID intValue];
        std::optional<double> monotonicMilliseconds = std::nullopt;
        id rawMonotonicMilliseconds = message[@"monotonicMilliseconds"];
        if (rawMonotonicMilliseconds != nil) {
            if (![rawMonotonicMilliseconds isKindOfClass:[NSNumber class]]
                || !std::isfinite ([rawMonotonicMilliseconds doubleValue])) {
                emitEvent (@"warning", assignmentID, @{
                    @"code": @"invalid-cursor-click",
                    @"message": @"cursor click monotonicMilliseconds must be finite",
                });
                return true;
            }
            monotonicMilliseconds = [rawMonotonicMilliseconds doubleValue];
        }
        std::vector<int> reached;
        if (locating) {
            reached = activeRenderer->cursorClickAt (
                static_cast<float> ([rawX doubleValue]),
                static_cast<float> ([rawY doubleValue]),
                monotonicMilliseconds
            );
        } else if (activeRenderer->cursorClick (objectID, monotonicMilliseconds)) {
            reached.push_back (objectID);
        }
        const bool handled = !reached.empty ();
        if (handled) {
            invalidateCoordinator (
                FrescoScene::ChangeProducers::script,
                FrescoScene::ChangeReasons::externalEvent
            );
        }
        NSMutableArray* reachedIDs = [NSMutableArray arrayWithCapacity:reached.size ()];
        for (const int identifier : reached) {
            [reachedIDs addObject:@(identifier)];
        }
        emitEvent (@"cursor-clicked", assignmentID, @{
            @"objectID": @(reached.empty () ? objectID : reached.front ()),
            @"objectIDs": reachedIDs,
            @"handled": @(handled),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"cursor click requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"capture-frame-difference"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"frame difference requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"frame difference assignment does not own the active renderer",
            });
            return true;
        }
        const FrescoScene::FrameDifferenceEvidence difference =
            activeRenderer->captureFrameDifference ();
        if (difference.presented && activeFrameCoordinator != nullptr) {
            synchronizeCoordinatorTime ();
            activeFrameCoordinator->observeExternalPresentation (
                activeFrameCoordinator->time ()
            );
        }
        const FrescoScene::FrameEvidence& evidence = difference.frame;
        emitEvent (@"frame-difference", assignmentID, @{
            @"backend": toNSStringView (evidence.backend),
            @"graphicsAPI": toNSStringView (evidence.graphicsAPI),
            @"shaderTarget": shaderTargetPayload (evidence.shaderTarget),
            @"width": @(evidence.width),
            @"height": @(evidence.height),
            @"frames": @(evidence.frames),
            @"presented": @(difference.presented),
            @"range": @[@(evidence.minimum), @(evidence.maximum)],
            @"varyingPixels": @(evidence.varyingPixels),
            @"pixelRGBTotal": @(evidence.pixelRGBTotal),
            @"pixelRGBAHash": @(evidence.pixelRGBAHash),
            @"pixelProbes": pixelProbePayload (evidence.pixelProbes),
            @"pixelRegions": pixelRegionPayload (evidence.pixelRegions),
            @"effectRender": effectRenderPayload (evidence.effectRender),
            @"textEffectChains": textEffectChainPayload (evidence.textEffectChains),
            @"changedPixels": @(difference.changedPixels),
            @"maximumChannelDelta": @(difference.maximumChannelDelta),
            @"totalChannelDelta": @(difference.totalChannelDelta),
            @"scriptLayers": @(evidence.scriptLayers),
            @"scriptUpdates": @(evidence.scriptUpdates),
            @"scriptTextChanges": @(evidence.scriptTextChanges),
            @"mediaPropertyScripts": @(evidence.mediaPropertyScripts),
            @"mediaPropertyScriptDispatches": @(
                evidence.mediaPropertyScriptDispatches
            ),
            @"mediaPlaybackScriptDispatches": @(
                evidence.mediaPlaybackScriptDispatches
            ),
            @"mediaTimelineScriptDispatches": @(
                evidence.mediaTimelineScriptDispatches
            ),
            @"mediaThumbnailScriptDispatches": @(
                evidence.mediaThumbnailScriptDispatches
            ),
            @"mediaPropertyScriptErrors": @(evidence.mediaPropertyScriptErrors),
            @"scriptedDynamicFloats": scriptedDynamicFloatPayload (
                evidence.scriptedDynamicFloats
            ),
            @"scriptedDynamicFloatUpdates": @(
                evidence.scriptedDynamicFloatUpdates
            ),
            @"scriptedDynamicFloatChanges": @(
                evidence.scriptedDynamicFloatChanges
            ),
            @"scriptErrors": @(evidence.scriptErrors),
            @"propertyScripts": propertyScriptPayload (evidence.propertyScripts),
            @"propertyScriptControllers": @(evidence.propertyScriptControllers),
            @"propertyScriptInitializations": @(
                evidence.propertyScriptInitializations
            ),
            @"propertyScriptPropertyApplications": @(
                evidence.propertyScriptPropertyApplications
            ),
            @"propertyScriptUpdates": @(evidence.propertyScriptUpdates),
            @"propertyScriptErrors": @(evidence.propertyScriptErrors),
            @"genericPropertyScripts": @(evidence.genericPropertyScripts),
            @"continuousGenericPropertyScripts": @(
                evidence.continuousGenericPropertyScripts
            ),
            @"genericPropertyScriptUpdates": @(
                evidence.genericPropertyScriptUpdates
            ),
            @"genericPropertyScriptChanges": @(
                evidence.genericPropertyScriptChanges
            ),
            @"genericPropertyScriptErrors": @(
                evidence.genericPropertyScriptErrors
            ),
            @"audioVectorScripts": @(evidence.audioVectorScripts),
            @"exactTrackedAudioVectorScripts": @(
                evidence.exactTrackedAudioVectorScripts
            ),
            @"audioVectorValueX": @(evidence.audioVectorValueX),
            @"audioVectorScriptUpdates": @(evidence.audioVectorScriptUpdates),
            @"audioVectorScriptChanges": @(evidence.audioVectorScriptChanges),
            @"namedAnimationTargetPlays": @(evidence.namedAnimationTargetPlays),
            @"namedAnimationActive": @(evidence.namedAnimationActive),
            @"namedAnimationFrameTotal": @(evidence.namedAnimationFrameTotal),
            @"camera2DActive": @(evidence.camera2DActive),
            @"camera2DCenter": @[
                @(evidence.camera2DCenterX), @(evidence.camera2DCenterY)
            ],
            @"camera2DZoom": @(evidence.camera2DZoom),
            @"sceneZoomActive": @(evidence.sceneZoomActive),
            @"sceneZoom": @(evidence.sceneZoom),
            @"pointerPosition": @[
                @(evidence.pointerPositionX), @(evidence.pointerPositionY)
            ],
            @"soundControls": soundControlPayload (evidence.soundControls),
            @"drawComplete": @(evidence.drawComplete),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"frame difference requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"capture-puppet-evidence"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"puppet evidence requires a loaded renderer",
            });
            return true;
        }
        if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"puppet evidence assignment does not own the active renderer",
            });
            return true;
        }
        const FrescoScene::PuppetRenderEvidence evidence =
            activeRenderer->puppetEvidence ();
        emitEvent (@"puppet-evidence", assignmentID, @{
            @"loadedMeshes": @(evidence.loadedMeshes),
            @"loadedVertices": @(evidence.loadedVertices),
            @"loadedMasks": @(evidence.loadedMasks),
            @"loadedAttachments": @(evidence.loadedAttachments),
            @"simulationEnabledBoneCount": @(
                evidence.simulationEnabledBoneCount
            ),
            @"activeIKBoneCount": @(evidence.activeIKBoneCount),
            @"secondaryMotionSteps": @(evidence.secondaryMotionSteps),
            @"secondaryMotionChanges": @(evidence.secondaryMotionChanges),
            @"deformationUploads": @(evidence.deformationUploads),
            @"deformationChanges": @(evidence.deformationChanges),
            @"maskPasses": @(evidence.maskPasses),
            @"attachmentResolutions": @(evidence.attachmentResolutions),
        });
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"puppet evidence requires a renderer-enabled build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"stop"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        resetActiveFrameScheduling ();
        activeRenderer.reset ();
        activeRendererAssignment.clear ();
        activeInactiveCameraGates.clear ();
        const auto mediaLifecycle =
            FrescoScene::globalMediaTextureLifecycleEvidence ();
        const auto renderAllocations = FrescoScene::renderAllocationEvidence ();
        emitEvent (@"stopped", assignmentID, @{
            @"mediaTextureLifecycle": @{
                @"livePlayers": @(mediaLifecycle.livePlayers),
                @"constructions": @(mediaLifecycle.constructions),
                @"destructions": @(mediaLifecycle.destructions),
            },
            @"renderAllocations": renderAllocationPayload (renderAllocations),
            @"renderResourceLifecycle": renderResourceLifecyclePayload (
                FrescoScene::renderResourceLifecycleEvidence ()
            ),
        });
#else
        emitEvent (@"stopped", assignmentID);
#endif
        return false;
    }

    if ([type isEqualToString:@"inspect"]) {
        try {
            NSDictionary* result = inspectPackage (messageString (message, @"path"));
            NSString* eventType = [result[@"supported2D"] boolValue]
                ? @"inspected"
                : @"unsupported";
            emitEvent (eventType, assignmentID, result);
        } catch (const std::exception& error) {
            emitEvent (@"fatal", assignmentID, @{
                @"code": @"inspect-failed",
                @"message": toNSString (error.what ()),
                @"scope": @"assignment",
            });
        }
        return true;
    }

    if ([type isEqualToString:@"validate-assets"]) {
        try {
            NSDictionary* result = validateAssets (messageString (message, @"path"));
            NSString* eventType = [result[@"valid"] boolValue]
                ? @"assets-validated"
                : @"assets-invalid";
            emitEvent (eventType, assignmentID, result);
        } catch (const std::exception& error) {
            NSString* path = messageString (message, @"path");
            emitEvent (@"assets-invalid", assignmentID, @{
                @"path": path != nil ? path : @"",
                @"profile": @"fixture-corpus-2d-v1",
                @"valid": @NO,
                @"required": @[],
                @"missing": @[],
                @"message": toNSString (error.what ()),
            });
        }
        return true;
    }

    if ([type isEqualToString:@"probe-opengl"]) {
#ifndef FRESCO_SCENE_ANGLE_RUNTIME
        try {
            emitEvent (@"opengl-probed", assignmentID, probeOpenGL ());
        } catch (const std::exception& error) {
            emitEvent (@"fatal", assignmentID, @{
                @"code": @"opengl-probe-failed",
                @"message": toNSString (error.what ()),
                @"scope": @"assignment",
            });
        }
#else
        emitEvent (@"warning", assignmentID, @{
            @"code": @"unknown-command",
            @"message": @"probe-opengl is unavailable in an ANGLE build",
        });
#endif
        return true;
    }

    if ([type isEqualToString:@"load"]) {
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        const bool hadActiveRenderer = activeRenderer != nullptr;
        try {
            NSDictionary* inspection = inspectPackage (messageString (message, @"path"));
            if (![inspection[@"supported2D"] boolValue]) {
                emitEvent (@"unsupported", assignmentID, inspection);
                return true;
            }

            const bool staticContentRequested = messageBool (
                message, @"staticContent", false
            );
            NSDictionary* packageStatistics = inspection[@"package"];
            NSDictionary* objectTypes = packageStatistics[@"objectTypes"];
            const NSInteger inspectedObjects
                = [packageStatistics[@"objects"] integerValue];
            const bool staticContentShapeProven
                = [objectTypes[@"text"] integerValue] == inspectedObjects
                && [packageStatistics[@"effects"] integerValue] == 0
                && [packageStatistics[@"shaderFiles"] integerValue] == 0
                && [packageStatistics[@"puppetModels"] integerValue] == 0
                && [packageStatistics[@"audioFiles"] integerValue] == 0;
            if (staticContentRequested && !staticContentShapeProven) {
                emitEvent (@"fatal", assignmentID, @{
                    @"code": @"static-content-unproven",
                    @"message": @"present-on-change requires an inspected empty or text-only scene with no effects, shaders, puppets, or audio",
                    @"scope": @"assignment",
                });
                return true;
            }

            NSDictionary* assets = validateAssets (messageString (message, @"assetRoot"));
            if (![assets[@"valid"] boolValue]) {
                emitEvent (@"fatal", assignmentID, @{
                    @"code": @"renderer-assets-invalid",
                    @"message": @"official asset validation failed before renderer startup",
                    @"scope": @"assignment",
                });
                return true;
            }

            const std::filesystem::path package = resolvePackagePath (
                messageString (message, @"path")
            );
            NSString* policyValidationError = nil;
            double loadFPS = 60.0;
            double loadPolicyRevision = 0.0;
            NSArray<NSString*>* loadPolicyReasonTokens = nil;
            const bool validLoadPolicy = schedulingInteger (
                    message, @"fps", false, 60.0, 1.0, 240.0,
                    loadFPS, &policyValidationError
                )
                && schedulingInteger (
                    message, @"policyRevision", false, 0.0, 0.0,
                    static_cast<double> (NSIntegerMax), loadPolicyRevision,
                    &policyValidationError
                )
                && (loadPolicyReasonTokens = schedulingReasonTokens (
                    message, &policyValidationError
                )) != nil;
            if (!validLoadPolicy) {
                emitEvent (@"fatal", assignmentID, @{
                    @"code": @"invalid-scheduling-policy",
                    @"message": policyValidationError,
                    @"scope": @"assignment",
                });
                return true;
            }
            FrescoScene::RendererConfiguration configuration {
                .projectRoot = package.parent_path (),
                .assetRoot = std::filesystem::path (toString (assets[@"path"])),
                .scriptStoragePool = &scriptStoragePool,
                .scriptStorageIdentity = package.generic_string (),
                .x = messageNumber (message, @"x", 0.0),
                .y = messageNumber (message, @"y", 0.0),
                .width = messageNumber (message, @"width", 1280.0),
                .height = messageNumber (message, @"height", 720.0),
                .framesPerSecond = loadFPS,
                .evidenceFrames = static_cast<uint32_t> (
                    messageNumber (message, @"evidenceFrames", 0.0)
                ),
                .collectRenderDurationSamples = messageBool (
                    message, @"collectRenderDurationSamples", false
                ),
                .visible = messageBool (message, @"visible", true),
                .muted = messageBool (message, @"muted", true),
                .initialUserProperties = parseUserProperties (
                    message[@"userProperties"]
                ),
                .pixelProbes = parsePixelProbes (message[@"pixelProbes"]),
                .pixelRegions = parsePixelRegions (message[@"pixelRegions"]),
                // Live scenes (the supervisor sets realtimeClock) advance the
                // animation clock by real elapsed time, so shaders, particles,
                // and puppets run at wall-clock speed regardless of the frame-
                // rate ceiling. Tests and evidence runs omit the field and keep
                // the fixed step, which renders unpaced yet reproducibly. The
                // capture-frame-difference evidence path forces fixed-step
                // internally regardless, so hashes are unaffected either way.
                .clockMode = messageBool (message, @"realtimeClock", false)
                    ? FrescoScene::RendererClockMode::RealTime
                    : FrescoScene::RendererClockMode::FixedStep,
            };
            auto renderer = std::make_unique<FrescoScene::RendererSession> (configuration);
            const FrescoScene::FrameEvidence evidence = renderer->firstFrameEvidence ();
            const FrescoScene::RendererMetrics initialMetrics = renderer->metrics ();
            const NSInteger authoredScriptValues
                = [packageStatistics[@"scriptValues"] integerValue];
            const bool scriptsTrackedOnChange
                = authoredScriptValues == 0
                || (evidence.genericPropertyScripts
                        == static_cast<std::size_t> (authoredScriptValues)
                    && evidence.continuousGenericPropertyScripts == 0
                    && evidence.deferredScriptValues == 0);
            if (staticContentRequested && !scriptsTrackedOnChange) {
                emitEvent (@"fatal", assignmentID, @{
                    @"code": @"static-content-unproven",
                    @"message": @"present-on-change requires every authored script to be classified as event, property, or timer driven",
                    @"scope": @"assignment",
                });
                return true;
            }
            const NSInteger inspectedParticles
                = [objectTypes[@"particle"] integerValue];
            const bool finiteParticleShapeProven
                = inspectedObjects > 0
                && inspectedParticles == inspectedObjects
                && [packageStatistics[@"effects"] integerValue] == 0
                && [packageStatistics[@"shaderFiles"] integerValue] == 0
                && [packageStatistics[@"puppetModels"] integerValue] == 0
                && [packageStatistics[@"audioFiles"] integerValue] == 0
                && authoredScriptValues == 0;
            const bool finiteParticleRuntimeProven
                = initialMetrics.particles.systems
                    == static_cast<std::size_t> (inspectedParticles)
                && initialMetrics.particles.finiteSystems
                    == initialMetrics.particles.systems
                && initialMetrics.particles.unknownSystems == 0;
            const bool trackedParticleLifecycle
                = !staticContentRequested
                && finiteParticleShapeProven
                && finiteParticleRuntimeProven;
            const bool mediaOnlyProven
                = FrescoScene::qualifiesForTrackedMediaLifecycle ({
                    .objects = static_cast<std::size_t> (inspectedObjects),
                    .imageObjects = static_cast<std::size_t> (
                        [objectTypes[@"image"] integerValue]
                    ),
                    .objectTypeKinds = objectTypes.count,
                    .effects = static_cast<std::size_t> (
                        [packageStatistics[@"effects"] integerValue]
                    ),
                    .shaderFiles = static_cast<std::size_t> (
                        [packageStatistics[@"shaderFiles"] integerValue]
                    ),
                    .puppetModels = static_cast<std::size_t> (
                        [packageStatistics[@"puppetModels"] integerValue]
                    ),
                    .audioFiles = static_cast<std::size_t> (
                        [packageStatistics[@"audioFiles"] integerValue]
                    ),
                    .scriptValues = static_cast<std::size_t> (
                        authoredScriptValues
                    ),
                    .players = initialMetrics.mediaTextures.players,
                    .referencedPlayers
                        = initialMetrics.mediaTextures.referencedPlayers,
                    .fallbackPlayers
                        = initialMetrics.mediaTextures.fallbackPlayers,
                    .automaticDynamicValueAnimations
                        = initialMetrics.automaticDynamicValueAnimations,
                });
            const bool trackedMediaLifecycle
                = !staticContentRequested
                && !trackedParticleLifecycle
                && mediaOnlyProven;
            const bool audioOnlyProven
                = FrescoScene::qualifiesTrackedAudioLifecycle ({
                    .objects = static_cast<std::size_t> (inspectedObjects),
                    .supportedConsumerObjects = static_cast<std::size_t> (
                        [objectTypes[@"image"] integerValue]
                        + [objectTypes[@"text"] integerValue]
                    ),
                    .objectTypeKinds = objectTypes.count,
                    .effects = static_cast<std::size_t> (
                        [packageStatistics[@"effects"] integerValue]
                    ),
                    .shaderFiles = static_cast<std::size_t> (
                        [packageStatistics[@"shaderFiles"] integerValue]
                    ),
                    .puppetModels = static_cast<std::size_t> (
                        [packageStatistics[@"puppetModels"] integerValue]
                    ),
                    .audioFiles = static_cast<std::size_t> (
                        [packageStatistics[@"audioFiles"] integerValue]
                    ),
                    .scriptValues = static_cast<std::size_t> (
                        authoredScriptValues
                    ),
                    .genericPropertyScripts
                        = initialMetrics.genericPropertyScripts,
                    .continuousGenericPropertyScripts
                        = initialMetrics.continuousGenericPropertyScripts,
                    .audioVectorScripts = initialMetrics.audioVectorScripts,
                    .exactTrackedAudioVectorScripts
                        = initialMetrics.exactTrackedAudioVectorScripts,
                    .deferredScriptValues
                        = initialMetrics.deferredScriptValues,
                    .automaticDynamicValueAnimations
                        = initialMetrics.automaticDynamicValueAnimations,
                });
            const bool trackedAudioLifecycle
                = !staticContentRequested
                && !trackedParticleLifecycle
                && !trackedMediaLifecycle
                && audioOnlyProven;
            const FrescoScene::PuppetRenderEvidence puppetEvidence
                = renderer->puppetEvidence ();
            activeRenderer = std::move (renderer);
            activeRenderer->setTrackedMediaLifecycle (trackedMediaLifecycle);
            activeRenderer->setTrackedAudioLifecycle (trackedAudioLifecycle);
            activeRendererAssignment = toString (assignmentID);
            activePolicyRevision = static_cast<NSInteger> (loadPolicyRevision);
            activePolicyReasonTokens = [loadPolicyReasonTokens copy];
            resetActiveFrameScheduling ();
            if (!legacyFrameLoopEnabled ()) {
                activeFrameEpoch = std::chrono::steady_clock::now ();
                activeFrameCoordinator = std::make_unique<
                    FrescoScene::RuntimeFrameCoordinator
                > (FrescoScene::RuntimeFrameCoordinatorConfiguration {
                    .provenStatic = staticContentRequested
                        || trackedParticleLifecycle || trackedMediaLifecycle
                        || trackedAudioLifecycle,
                    .active = activeRenderer->active (),
                    .framesPerSecond = static_cast<std::uint32_t> (loadFPS),
                });
                activeFrameCoordinator->observeExternalPresentation (
                    FrescoScene::MonotonicTime {}
                );
                synchronizeScriptTimerDeadline (&evidence);
            }
            activeFrameScheduleChanged = legacyFrameLoopEnabled ();
            activeStaticPresentOnChange = staticContentRequested
                && !legacyFrameLoopEnabled ();
            activeTrackedParticleLifecycle = trackedParticleLifecycle
                && !legacyFrameLoopEnabled ();
            activeTrackedMediaLifecycle = trackedMediaLifecycle
                && !legacyFrameLoopEnabled ();
            activeTrackedAudioLifecycle = trackedAudioLifecycle
                && !legacyFrameLoopEnabled ();
            synchronizeParticleActivityLease ();
            synchronizeMediaFrameDeadline ();
            synchronizeAudioEnvelopeDeadline ();
            activeStaticDirty = false;
            activeInactiveCameraGates.clear ();
            NSDictionary* inspectedCameraGates
                = [inspection[@"inactiveCameraGates"] isKindOfClass:[NSDictionary class]]
                ? inspection[@"inactiveCameraGates"] : @{};
            for (NSString* gate in inspectedCameraGates) {
                activeInactiveCameraGates.insert_or_assign (
                    toString (gate), toString (inspectedCameraGates[gate])
                );
            }
            const NSInteger runtimeDeferredScriptValues
                = static_cast<NSInteger> (evidence.deferredScriptValues);
            if (runtimeDeferredScriptValues > 0
                && activeFrameCoordinator != nullptr) {
                invalidateCoordinator (
                    FrescoScene::ChangeProducers::unknown,
                    FrescoScene::ChangeReasons::unknown
                );
            }
            NSMutableArray* runtimeWarnings = [inspection[@"warnings"] mutableCopy];
            NSIndexSet* staleScriptWarnings = [runtimeWarnings indexesOfObjectsPassingTest:
                ^BOOL (id value, NSUInteger index, BOOL* stop) {
                    static_cast<void> (index);
                    static_cast<void> (stop);
                    return [value isKindOfClass:[NSString class]]
                        && [value containsString:@"SceneScript dynamic values"];
                }
            ];
            [runtimeWarnings removeObjectsAtIndexes:staleScriptWarnings];
            NSIndexSet* stalePuppetWarnings = [runtimeWarnings indexesOfObjectsPassingTest:
                ^BOOL (id value, NSUInteger index, BOOL* stop) {
                    static_cast<void> (index);
                    static_cast<void> (stop);
                    return [value isKindOfClass:[NSString class]]
                        && [value containsString:@"puppet bone simulation"];
                }
            ];
            [runtimeWarnings removeObjectsAtIndexes:stalePuppetWarnings];
            if (puppetEvidence.simulationEnabledBoneCount > 0
                && (puppetEvidence.secondaryMotionSteps == 0
                    || puppetEvidence.secondaryMotionChanges == 0)) {
                [runtimeWarnings addObject:[NSString stringWithFormat:
                    @"puppet secondary motion lacks independent changes (simulation-enabled bones=%zu)",
                    puppetEvidence.simulationEnabledBoneCount
                ]];
            }
            if (puppetEvidence.activeIKBoneCount > 0) {
                [runtimeWarnings addObject:[NSString stringWithFormat:
                    @"puppet active IK remains deferred (active IK bones=%zu)",
                    puppetEvidence.activeIKBoneCount
                ]];
            }
            if (evidence.camera2DActive) {
                NSIndexSet* staleCameraWarnings
                    = [runtimeWarnings indexesOfObjectsPassingTest:
                        ^BOOL (id value, NSUInteger index, BOOL* stop) {
                            static_cast<void> (index);
                            static_cast<void> (stop);
                            return [value isKindOfClass:[NSString class]]
                                && [value containsString:
                                    @"camera objects are parsed but not rendered"];
                        }
                    ];
                [runtimeWarnings removeObjectsAtIndexes:staleCameraWarnings];
            }
            NSDictionary* initialProperties
                = [message[@"userProperties"] isKindOfClass:[NSDictionary class]]
                ? message[@"userProperties"] : nil;
            NSDictionary* inactiveCameraGates
                = [inspection[@"inactiveCameraGates"] isKindOfClass:[NSDictionary class]]
                ? inspection[@"inactiveCameraGates"] : @{};
            for (NSString* gate in inactiveCameraGates) {
                NSDictionary* setting
                    = [initialProperties[gate] isKindOfClass:[NSDictionary class]]
                    ? initialProperties[gate] : nil;
                if ([setting[@"value"] isKindOfClass:[NSNumber class]]
                    && [setting[@"value"] boolValue]) {
                    [runtimeWarnings addObject:inactiveCameraGates[gate]];
                }
            }
            if (runtimeDeferredScriptValues > 0) {
                [runtimeWarnings addObject:[NSString stringWithFormat:
                    @"%ld instantiated SceneScript dynamic values are not yet evaluated",
                    static_cast<long> (runtimeDeferredScriptValues)
                ]];
            }
            const NSInteger untrackedParticleSystems
                = static_cast<NSInteger> (
                    initialMetrics.particles.unknownSystems
                );
            if (inspectedParticles > 0 && !trackedParticleLifecycle
                && untrackedParticleSystems > 0) {
                [runtimeWarnings addObject:[NSString stringWithFormat:
                    @"%ld particle systems have unknown lifecycle and remain continuously scheduled",
                    static_cast<long> (untrackedParticleSystems)
                ]];
            }
            emitEvent (@"ready", assignmentID, @{
                @"renderer": toNSStringView (FrescoScene::backendIdentity (
                    configuration.backend
                ).renderer),
                @"backend": toNSStringView (evidence.backend),
                @"graphicsAPI": toNSStringView (evidence.graphicsAPI),
                @"shaderTarget": shaderTargetPayload (evidence.shaderTarget),
                @"width": @(evidence.width),
                @"height": @(evidence.height),
                @"projection": @{
                    @"width": @(evidence.projectionWidth),
                    @"height": @(evidence.projectionHeight),
                },
                @"display": @{
                    @"logicalWidth": @(evidence.logicalWidth),
                    @"logicalHeight": @(evidence.logicalHeight),
                    @"pixelWidth": @(evidence.width),
                    @"pixelHeight": @(evidence.height),
                    @"scaleMilli": @(evidence.scaleMilli),
                    @"maximumRefreshMilliHertz": @(
                        evidence.maximumRefreshMilliHertz
                    ),
                    @"colorSpace": toNSString (evidence.colorSpace),
                },
                @"programCacheEntries": @(evidence.programCacheEntries),
                @"programCacheInsertions": @(
                    evidence.programCacheInsertions
                ),
                @"resourceGeneration": @(evidence.resourceGeneration),
                @"renderResourceLifecycle": renderResourceLifecyclePayload (
                    FrescoScene::renderResourceLifecycleEvidence ()
                ),
                @"scriptTimers": scriptTimerPayload (evidence.scriptTimers),
                @"scriptTimeMilliseconds": @(evidence.scriptTimeMilliseconds),
                @"targetFPS": @(configuration.framesPerSecond),
                @"policyRevision": @(activePolicyRevision),
                @"reasonTokens": activePolicyReasonTokens,
                @"schedulingMode": schedulingMode (),
                @"schedulingMechanism": schedulingMechanism (),
                @"schedulingEvidence": activeFrameCoordinator != nullptr
                    ? coordinatorEvidencePayload () : [NSNull null],
                @"frames": @(evidence.frames),
                @"range": @[@(evidence.minimum), @(evidence.maximum)],
                @"varyingPixels": @(evidence.varyingPixels),
                @"pixelRGBTotal": @(evidence.pixelRGBTotal),
                @"pixelRGBAHash": @(evidence.pixelRGBAHash),
                @"pixelProbes": pixelProbePayload (evidence.pixelProbes),
                @"pixelRegions": pixelRegionPayload (evidence.pixelRegions),
                @"effectRender": effectRenderPayload (evidence.effectRender),
                @"textEffectChains": textEffectChainPayload (
                    evidence.textEffectChains
                ),
                @"scriptLayers": @(evidence.scriptLayers),
                @"scriptUpdates": @(evidence.scriptUpdates),
                @"scriptTextChanges": @(evidence.scriptTextChanges),
                @"mediaPropertyScripts": @(evidence.mediaPropertyScripts),
                @"mediaPropertyScriptDispatches": @(
                    evidence.mediaPropertyScriptDispatches
                ),
                @"mediaPlaybackScriptDispatches": @(
                    evidence.mediaPlaybackScriptDispatches
                ),
                @"mediaTimelineScriptDispatches": @(
                    evidence.mediaTimelineScriptDispatches
                ),
                @"mediaThumbnailScriptDispatches": @(
                    evidence.mediaThumbnailScriptDispatches
                ),
                @"mediaPropertyScriptErrors": @(
                    evidence.mediaPropertyScriptErrors
                ),
                @"scriptedDynamicFloats": scriptedDynamicFloatPayload (
                    evidence.scriptedDynamicFloats
                ),
                @"scriptedDynamicFloatUpdates": @(
                    evidence.scriptedDynamicFloatUpdates
                ),
                @"scriptedDynamicFloatChanges": @(
                    evidence.scriptedDynamicFloatChanges
                ),
                @"scriptErrors": @(evidence.scriptErrors),
                @"soundVolumeBindings": @(evidence.soundVolumeBindings),
                @"soundVolumeProperties": @(evidence.soundVolumeProperties),
                @"initialUserProperties": soundPropertyEvidencePayload (
                    evidence.initialUserProperties
                ),
                @"propertyScripts": propertyScriptPayload (evidence.propertyScripts),
                @"propertyScriptControllers": @(evidence.propertyScriptControllers),
                @"propertyScriptInitializations": @(
                    evidence.propertyScriptInitializations
                ),
                @"propertyScriptPropertyApplications": @(
                    evidence.propertyScriptPropertyApplications
                ),
                @"propertyScriptUpdates": @(evidence.propertyScriptUpdates),
                @"propertyScriptErrors": @(evidence.propertyScriptErrors),
                @"genericPropertyScripts": @(evidence.genericPropertyScripts),
                @"continuousGenericPropertyScripts": @(
                    evidence.continuousGenericPropertyScripts
                ),
                @"genericPropertyScriptUpdates": @(
                    evidence.genericPropertyScriptUpdates
                ),
                @"genericPropertyScriptChanges": @(
                    evidence.genericPropertyScriptChanges
                ),
                @"genericPropertyScriptErrors": @(
                    evidence.genericPropertyScriptErrors
                ),
                @"audioVectorScripts": @(evidence.audioVectorScripts),
                @"exactTrackedAudioVectorScripts": @(
                    evidence.exactTrackedAudioVectorScripts
                ),
                @"audioVectorValueX": @(evidence.audioVectorValueX),
                @"audioVectorScriptUpdates": @(evidence.audioVectorScriptUpdates),
                @"audioVectorScriptChanges": @(evidence.audioVectorScriptChanges),
                @"namedAnimationTargetPlays": @(evidence.namedAnimationTargetPlays),
                @"namedAnimationActive": @(evidence.namedAnimationActive),
                @"namedAnimationFrameTotal": @(evidence.namedAnimationFrameTotal),
                @"camera2DActive": @(evidence.camera2DActive),
                @"camera2DCenter": @[
                    @(evidence.camera2DCenterX), @(evidence.camera2DCenterY)
                ],
                @"camera2DZoom": @(evidence.camera2DZoom),
                @"sceneZoomActive": @(evidence.sceneZoomActive),
                @"sceneZoom": @(evidence.sceneZoom),
                @"cursorScripts": @(evidence.cursorScripts),
                @"pointerPosition": @[
                    @(evidence.pointerPositionX), @(evidence.pointerPositionY)
                ],
                @"deferredScriptValues": @(runtimeDeferredScriptValues),
                @"soundControls": soundControlPayload (evidence.soundControls),
                @"drawComplete": @(evidence.drawComplete),
                @"ordered": @(evidence.ordered),
                @"windowLevel": @(evidence.windowLevel),
                @"warnings": runtimeWarnings,
            });
        } catch (const std::exception& error) {
            if (!hadActiveRenderer) {
                resetActiveFrameScheduling ();
                activeRenderer.reset ();
                activeRendererAssignment.clear ();
                activeInactiveCameraGates.clear ();
            }
            emitEvent (@"fatal", assignmentID, @{
                @"code": @"renderer-load-failed",
                @"message": toNSString (error.what ()),
                @"scope": hadActiveRenderer ? @"assignment" : @"process",
                @"renderResourceLifecycle": renderResourceLifecyclePayload (
                    FrescoScene::renderResourceLifecycleEvidence ()
                ),
            });
            return hadActiveRenderer;
        }
#else
        emitEvent (@"fatal", assignmentID, @{
            @"code": @"renderer-unavailable",
            @"message": @"this build inspects scene packages but does not render them",
            @"scope": @"assignment",
        });
#endif
        return true;
    }

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
    if ([type isEqualToString:@"pause"] || [type isEqualToString:@"resume"]) {
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"pause and resume require a loaded renderer",
            });
        } else if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"pause and resume assignment does not own the active renderer",
            });
        } else {
            const bool paused = [type isEqualToString:@"pause"];
            activeRenderer->setPaused (paused);
            if (activeFrameCoordinator != nullptr) {
                activeFrameCoordinator->setActive (activeRenderer->active ());
                if (paused && activeTrackedMediaLifecycle) {
                    activeFrameCoordinator->setMediaFrameDeadline (
                        std::nullopt
                    );
                } else if (!paused) {
                    invalidateCoordinator (
                        FrescoScene::ChangeProducers::supervisor,
                        FrescoScene::ChangeReasons::policyChanged
                    );
                    synchronizeMediaFrameDeadline ();
                }
                if (paused && activeTrackedAudioLifecycle) {
                    activeFrameCoordinator->setAudioEnvelopeDeadline (
                        std::nullopt
                    );
                } else if (!paused) {
                    synchronizeAudioEnvelopeDeadline ();
                }
            }
            emitEvent (paused ? @"paused" : @"resumed", assignmentID);
        }
        return true;
    }

    if ([type isEqualToString:@"mute"] || [type isEqualToString:@"unmute"]) {
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"mute and unmute require a loaded renderer",
            });
        } else if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"mute and unmute assignment does not own the active renderer",
            });
        } else {
            const bool muted = [type isEqualToString:@"mute"];
            activeRenderer->setMuted (muted);
            emitEvent (muted ? @"muted" : @"unmuted", assignmentID);
        }
        return true;
    }

    if ([type isEqualToString:@"hide"] || [type isEqualToString:@"show"]) {
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"hide and show require a loaded renderer",
            });
        } else if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"hide and show assignment does not own the active renderer",
            });
        } else {
            const bool visible = [type isEqualToString:@"show"];
            activeRenderer->setVisible (visible);
            if (activeFrameCoordinator != nullptr) {
                activeFrameCoordinator->setActive (activeRenderer->active ());
                if (!visible && activeTrackedMediaLifecycle) {
                    activeFrameCoordinator->setMediaFrameDeadline (
                        std::nullopt
                    );
                } else if (visible) {
                    invalidateCoordinator (
                        FrescoScene::ChangeProducers::supervisor,
                        FrescoScene::ChangeReasons::policyChanged
                    );
                    synchronizeMediaFrameDeadline ();
                }
                if (!visible && activeTrackedAudioLifecycle) {
                    activeFrameCoordinator->setAudioEnvelopeDeadline (
                        std::nullopt
                    );
                } else if (visible) {
                    synchronizeAudioEnvelopeDeadline ();
                }
            }
            emitEvent (visible ? @"shown" : @"hidden", assignmentID);
        }
        return true;
    }

    if ([type isEqualToString:@"user-properties"]) {
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"user properties require a loaded renderer",
            });
        } else if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"user properties assignment does not own the active renderer",
            });
        } else {
            const auto properties = parseUserProperties (message[@"properties"]);
            const auto evidence = activeRenderer->setUserProperties (properties);
            if (activeFrameCoordinator != nullptr) {
                invalidateCoordinator (
                    FrescoScene::ChangeProducers::script,
                    FrescoScene::ChangeReasons::propertyChanged
                );
            } else {
                activeStaticDirty = true;
            }
            NSMutableDictionary* payload
                = [soundPropertyEvidencePayload (evidence) mutableCopy];
            NSMutableArray* warnings = [NSMutableArray array];
            NSDictionary* rawProperties
                = [message[@"properties"] isKindOfClass:[NSDictionary class]]
                ? message[@"properties"] : nil;
            for (const auto& [gate, diagnostic] : activeInactiveCameraGates) {
                NSString* key = toNSString (gate);
                NSDictionary* setting
                    = [rawProperties[key] isKindOfClass:[NSDictionary class]]
                    ? rawProperties[key] : nil;
                if ([setting[@"value"] isKindOfClass:[NSNumber class]]
                    && [setting[@"value"] boolValue]) {
                    [warnings addObject:toNSString (diagnostic)];
                }
            }
            payload[@"warnings"] = warnings;
            emitEvent (
                @"user-properties-applied", assignmentID,
                payload
            );
        }
        return true;
    }

    if ([type isEqualToString:@"metrics"]) {
        if (activeRenderer == nullptr) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"renderer-not-loaded",
                @"message": @"metrics requires a loaded renderer",
            });
        } else if (activeRendererAssignment != toString (assignmentID)) {
            emitEvent (@"warning", assignmentID, @{
                @"code": @"assignment-mismatch",
                @"message": @"metrics assignment does not own the active renderer",
            });
        } else {
            const FrescoScene::RendererMetrics metrics = activeRenderer->metrics ();
            emitEvent (@"metrics", assignmentID, @{
                @"backend": toNSStringView (metrics.backend),
                @"graphicsAPI": toNSStringView (metrics.graphicsAPI),
                @"shaderTarget": shaderTargetPayload (metrics.shaderTarget),
                @"programCacheEntries": @(metrics.programCacheEntries),
                @"programCacheInsertions": @(
                    metrics.programCacheInsertions
                ),
                @"resourceGeneration": @(metrics.resourceGeneration),
                @"renderResourceLifecycle": renderResourceLifecyclePayload (
                    metrics.resourceLifecycle
                ),
                @"scriptTimers": scriptTimerPayload (metrics.scriptTimers),
                @"scriptTimeMilliseconds": @(metrics.scriptTimeMilliseconds),
                @"deferredScriptValues": @(metrics.deferredScriptValues),
                @"frames": @(metrics.frames),
                @"targetFPS": @(metrics.targetFPS),
                @"policyRevision": @(activePolicyRevision),
                @"reasonTokens": activePolicyReasonTokens,
                @"schedulingMode": schedulingMode (),
                @"schedulingMechanism": schedulingMechanism (),
                @"schedulingEvidence": activeFrameCoordinator != nullptr
                    ? coordinatorEvidencePayload () : [NSNull null],
                @"elapsedMilliseconds": @(metrics.elapsedMilliseconds),
                @"sceneClockSeconds": @(metrics.sceneClockSeconds),
                @"averageFrameIntervalMilliseconds": @(
                    metrics.averageFrameIntervalMilliseconds
                ),
                @"maximumFrameIntervalMilliseconds": @(
                    metrics.maximumFrameIntervalMilliseconds
                ),
                @"averageRenderMilliseconds": @(metrics.averageRenderMilliseconds),
                @"maximumRenderMilliseconds": @(metrics.maximumRenderMilliseconds),
                @"renderDurationSamplesMilliseconds": numberPayload (
                    metrics.renderDurationSamplesMilliseconds
                ),
                @"renderAllocations": renderAllocationPayload (
                    metrics.renderAllocations
                ),
                @"effectRender": effectRenderPayload (metrics.effectRender),
                @"missedFrameIntervals": @(metrics.missedFrameIntervals),
                @"textEffectChains": textEffectChainPayload (
                    metrics.textEffectChains
                ),
                @"scriptLayers": @(metrics.scriptLayers),
                @"scriptUpdates": @(metrics.scriptUpdates),
                @"scriptTextChanges": @(metrics.scriptTextChanges),
                @"mediaPropertyScripts": @(metrics.mediaPropertyScripts),
                @"mediaPropertyScriptDispatches": @(
                    metrics.mediaPropertyScriptDispatches
                ),
                @"mediaPlaybackScriptDispatches": @(
                    metrics.mediaPlaybackScriptDispatches
                ),
                @"mediaTimelineScriptDispatches": @(
                    metrics.mediaTimelineScriptDispatches
                ),
                @"mediaThumbnailScriptDispatches": @(
                    metrics.mediaThumbnailScriptDispatches
                ),
                @"mediaPropertyScriptErrors": @(metrics.mediaPropertyScriptErrors),
                @"scriptedDynamicFloats": scriptedDynamicFloatPayload (
                    metrics.scriptedDynamicFloats
                ),
                @"scriptedDynamicFloatUpdates": @(
                    metrics.scriptedDynamicFloatUpdates
                ),
                @"scriptedDynamicFloatChanges": @(
                    metrics.scriptedDynamicFloatChanges
                ),
                @"scriptErrors": @(metrics.scriptErrors),
                @"scriptStorageKeys": @(metrics.scriptStorageKeys),
                @"scriptStorageBytes": @(metrics.scriptStorageBytes),
                @"soundVolumeBindings": @(metrics.soundVolumeBindings),
                @"soundVolumeProperties": @(metrics.soundVolumeProperties),
                @"propertyScripts": propertyScriptPayload (metrics.propertyScripts),
                @"propertyScriptControllers": @(metrics.propertyScriptControllers),
                @"propertyScriptInitializations": @(
                    metrics.propertyScriptInitializations
                ),
                @"propertyScriptPropertyApplications": @(
                    metrics.propertyScriptPropertyApplications
                ),
                @"propertyScriptUpdates": @(metrics.propertyScriptUpdates),
                @"propertyScriptErrors": @(metrics.propertyScriptErrors),
                @"genericPropertyScripts": @(metrics.genericPropertyScripts),
                @"continuousGenericPropertyScripts": @(
                    metrics.continuousGenericPropertyScripts
                ),
                @"genericPropertyScriptUpdates": @(
                    metrics.genericPropertyScriptUpdates
                ),
                @"genericPropertyScriptChanges": @(
                    metrics.genericPropertyScriptChanges
                ),
                @"genericPropertyScriptErrors": @(
                    metrics.genericPropertyScriptErrors
                ),
                @"audioVectorScripts": @(metrics.audioVectorScripts),
                @"exactTrackedAudioVectorScripts": @(
                    metrics.exactTrackedAudioVectorScripts
                ),
                @"audioVectorValueX": @(metrics.audioVectorValueX),
                @"audioVectorScriptUpdates": @(metrics.audioVectorScriptUpdates),
                @"audioVectorScriptChanges": @(metrics.audioVectorScriptChanges),
                @"audioSpectrumInputs": @(metrics.audioSpectrumInputs),
                @"audioSpectrumChanges": @(metrics.audioSpectrumChanges),
                @"audioSpectrumHash": @(metrics.audioSpectrumHash),
                @"audioVectorHash": @(metrics.audioVectorHash),
                @"audioVectorAverage0": @(metrics.audioVectorAverage0),
                @"audioEnvelopeContinuousRequired": @(
                    metrics.audioEnvelopeContinuousRequired
                ),
                @"namedAnimationTargetPlays": @(metrics.namedAnimationTargetPlays),
                @"namedAnimationActive": @(metrics.namedAnimationActive),
                @"automaticDynamicValueAnimations": @(
                    metrics.automaticDynamicValueAnimations
                ),
                @"namedAnimationFrameTotal": @(metrics.namedAnimationFrameTotal),
                @"camera2DActive": @(metrics.camera2DActive),
                @"camera2DCenter": @[
                    @(metrics.camera2DCenterX), @(metrics.camera2DCenterY)
                ],
                @"camera2DZoom": @(metrics.camera2DZoom),
                @"sceneZoomActive": @(metrics.sceneZoomActive),
                @"sceneZoom": @(metrics.sceneZoom),
                @"soundControls": soundControlPayload (metrics.soundControls),
                @"mediaTextures": @{
                    @"players": @(metrics.mediaTextures.players),
                    @"referencedPlayers": @(
                        metrics.mediaTextures.referencedPlayers
                    ),
                    @"temporallyActivePlayers": @(
                        metrics.mediaTextures.temporallyActivePlayers
                    ),
                    @"scriptControlledPlayers": @(
                        metrics.mediaTextures.scriptControlledPlayers
                    ),
                    @"scriptPlayingPlayers": @(
                        metrics.mediaTextures.scriptPlayingPlayers
                    ),
                    @"scriptPausedPlayers": @(
                        metrics.mediaTextures.scriptPausedPlayers
                    ),
                    @"minimumDecodesPerPlayer": @(
                        metrics.mediaTextures.minimumDecodesPerPlayer
                    ),
                    @"maximumDecodesPerPlayer": @(
                        metrics.mediaTextures.maximumDecodesPerPlayer
                    ),
                    @"decodes": @(metrics.mediaTextures.decodes),
                    @"uploadedBytes": @(metrics.mediaTextures.uploadedBytes),
                    @"surfaceBlitUploads": @(
                        metrics.mediaTextures.surfaceBlitUploads
                    ),
                    @"framePreparationMilliseconds": @(
                        metrics.mediaTextures.framePreparationMilliseconds
                    ),
                    @"frameUploadMilliseconds": @(
                        metrics.mediaTextures.frameUploadMilliseconds
                    ),
                    @"decodeMilliseconds": @(
                        metrics.mediaTextures.decodeMilliseconds
                    ),
                    @"uploadSubmissionMilliseconds": @(
                        metrics.mediaTextures.uploadSubmissionMilliseconds
                    ),
                    @"decodeAttempts": @(metrics.mediaTextures.decodeAttempts),
                    @"decodedFrames": @(metrics.mediaTextures.decodedFrames),
                    @"frameReadyEvents": @(
                        metrics.mediaTextures.frameReadyEvents
                    ),
                    @"stalledFrames": @(metrics.mediaTextures.stalledFrames),
                    @"wrapDiscardedFrames": @(
                        metrics.mediaTextures.wrapDiscardedFrames
                    ),
                    @"frameUploads": @(metrics.mediaTextures.frameUploads),
                    @"pendingFrames": @(metrics.mediaTextures.pendingFrames),
                    @"seekRequests": @(metrics.mediaTextures.seekRequests),
                    @"fallbackPlayers": @(metrics.mediaTextures.fallbackPlayers),
                    @"globalLivePlayers": @(
                        metrics.mediaTextures.globalLivePlayers
                    ),
                    @"globalPlayerConstructions": @(
                        metrics.mediaTextures.globalPlayerConstructions
                    ),
                    @"globalPlayerDestructions": @(
                        metrics.mediaTextures.globalPlayerDestructions
                    ),
                    @"lastDecodedFrameHash": @(
                        metrics.mediaTextures.lastDecodedFrameHash
                    ),
                    @"decodedFrameSequenceHash": @(
                        metrics.mediaTextures.decodedFrameSequenceHash
                    ),
                    @"lastDecodedPresentationSeconds": @(
                        metrics.mediaTextures.lastDecodedPresentationSeconds
                    ),
                    @"endOfStreamPlayers": @(
                        metrics.mediaTextures.endOfStreamPlayers
                    ),
                },
                @"particleSimulationSteps": @(metrics.particleSimulationSteps),
                @"particles": particleRuntimePayload (metrics.particles),
                @"active": @(metrics.active),
                @"paused": @(metrics.paused),
                @"muted": @(metrics.muted),
                @"visible": @(metrics.visible),
            });
        }
        return true;
    }
#endif

    emitEvent (@"warning", assignmentID, @{
        @"code": @"unknown-command",
        @"message": [@"unknown command: " stringByAppendingString:type],
    });
    return true;
}

} // namespace

int main () {
    @autoreleasepool {
        std::string inputBuffer;
        bool running = true;
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        auto nextFrame = std::chrono::steady_clock::now ();
#endif

        while (running) {
            int timeout = -1;
#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
            if (inputBuffer.empty () && activeRenderer != nullptr) {
                if (!activeRenderer->active ()
                    && activeFrameCoordinator == nullptr) {
                    timeout = 100;
                } else if (activeRenderer->active ()
                           && activeFrameCoordinator != nullptr) {
                    synchronizeCoordinatorTime ();
                    timeout = activeFrameCoordinator
                        ->pollTimeoutMilliseconds ().value_or (-1);
                } else if (activeRenderer->active ()
                           && (!activeStaticPresentOnChange
                               || activeStaticDirty)) {
                    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds> (
                        nextFrame - std::chrono::steady_clock::now ()
                    );
                    timeout = std::max (0, static_cast<int> (remaining.count ()));
                }
            }
#endif

            pollfd input = {
                .fd = STDIN_FILENO,
                .events = POLLIN,
                .revents = 0,
            };
            const int pollResult = poll (&input, 1, timeout);
            if (pollResult < 0 && errno != EINTR) {
                return 1;
            }
            if (pollResult > 0 && (input.revents & (POLLIN | POLLHUP)) != 0) {
                bool inputEnded = false;
                bool drainInput = true;
                while (running && drainInput) {
                    std::array<char, 8192> buffer = {};
                    const ssize_t count = read (
                        STDIN_FILENO, buffer.data (), buffer.size ()
                    );
                    if (count == 0) {
                        inputEnded = true;
                        break;
                    }
                    if (count < 0) {
                        if (errno == EINTR) {
                            continue;
                        }
                        if (errno != EAGAIN) {
                            return 1;
                        }
                        break;
                    }
                    inputBuffer.append (
                        buffer.data (), static_cast<std::size_t> (count)
                    );
                    std::size_t newline = std::string::npos;
                    while (running
                           && (newline = inputBuffer.find ('\n')) != std::string::npos) {
                        const std::string line = inputBuffer.substr (0, newline);
                        inputBuffer.erase (0, newline + 1);
                        @autoreleasepool {
                            NSError* error = nil;
                            NSDictionary* message = parseMessage (line, &error);
                            if (message == nil) {
                                emitEvent (@"warning", @"", @{
                                    @"code": @"invalid-json",
                                    @"message": error.localizedDescription != nil
                                        ? error.localizedDescription
                                        : @"message is not an object",
                                });
                            } else {
                                running = handleMessage (message);
                            }
                        }
                    }

                    pollfd queuedInput = {
                        .fd = STDIN_FILENO,
                        .events = POLLIN,
                        .revents = 0,
                    };
                    int queuedResult = 0;
                    do {
                        queuedResult = poll (&queuedInput, 1, 0);
                    } while (queuedResult < 0 && errno == EINTR);
                    if (queuedResult < 0) {
                        return 1;
                    }
                    drainInput = queuedResult > 0
                        && (queuedInput.revents & (POLLIN | POLLHUP)) != 0;
                }
                if (inputEnded) {
                    break;
                }
            }

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
            if (running && inputBuffer.empty () && activeRenderer != nullptr
                && activeFrameCoordinator != nullptr
                && activeRenderer->active ()) {
                try {
                    synchronizeCoordinatorTime ();
                    activeFrameCoordinator->setActive (activeRenderer->active ());
                    synchronizeMediaFrameDeadline ();
                    synchronizeAudioEnvelopeDeadline ();
                    const FrescoScene::FrameDecision decision
                        = activeFrameCoordinator->decide ();
                    if (decision.evaluate) {
                        const FrescoScene::FrameRenderResult result
                            = activeRenderer->renderFrame ();
                        (void)activeFrameCoordinator->completeRendered (
                            decision, result
                        );
                        if (std::ranges::any_of (
                                decision.leaseOccurrences,
                                [] (const auto& occurrence) {
                                    return occurrence.mode
                                        == FrescoScene::LeaseMode::at;
                                }
                            )) {
                            activeScriptTimerDueMilliseconds.reset ();
                        }
                        synchronizeScriptTimerDeadline ();
                        synchronizeParticleActivityLease ();
                        if (std::ranges::any_of (
                                decision.leaseOccurrences,
                                [] (const auto& occurrence) {
                                    return occurrence.id == 4;
                                }
                            )) {
                            activeFrameCoordinator->setMediaFrameDeadline (
                                std::nullopt
                            );
                        }
                        synchronizeMediaFrameDeadline ();
                        if (std::ranges::any_of (
                                decision.leaseOccurrences,
                                [] (const auto& occurrence) {
                                    return occurrence.id == 5;
                                }
                            )) {
                            activeFrameCoordinator->setAudioEnvelopeDeadline (
                                std::nullopt
                            );
                        }
                        synchronizeAudioEnvelopeDeadline ();
                    } else {
                        (void)activeFrameCoordinator->completeNotEvaluated (
                            decision
                        );
                    }
                } catch (const std::exception& error) {
                    emitEvent (
                        @"fatal", toNSString (activeRendererAssignment), @{
                            @"code": @"renderer-frame-failed",
                            @"message": toNSString (error.what ()),
                            @"scope": @"process",
                        }
                    );
                    resetActiveFrameScheduling ();
                    activeRenderer.reset ();
                    return 1;
                }
            } else if (running && inputBuffer.empty ()
                       && activeFrameCoordinator == nullptr
                       && activeRenderer != nullptr
                       && activeRenderer->active ()) {
                if (activeFrameScheduleChanged) {
                    nextFrame = std::chrono::steady_clock::now ()
                        + activeRenderer->frameInterval ();
                    activeFrameScheduleChanged = false;
                }
                const auto now = std::chrono::steady_clock::now ();
                if ((!activeStaticPresentOnChange || activeStaticDirty)
                    && now >= nextFrame) {
                    try {
                        activeRenderer->renderFrame ();
                    } catch (const std::exception& error) {
                        emitEvent (
                            @"fatal", toNSString (activeRendererAssignment), @{
                                @"code": @"renderer-frame-failed",
                                @"message": toNSString (error.what ()),
                                @"scope": @"process",
                            }
                        );
                        resetActiveFrameScheduling ();
                        activeRenderer.reset ();
                        return 1;
                    }
                    activeStaticDirty = false;
                    const auto frameInterval = activeRenderer->frameInterval ();
                    nextFrame += frameInterval;
                    if (nextFrame < now) {
                        nextFrame = now + frameInterval;
                    }
                }
            } else {
                nextFrame = std::chrono::steady_clock::now ();
            }
#endif
        }

#ifdef FRESCO_SCENE_RENDERER_AVAILABLE
        resetActiveFrameScheduling ();
        activeRenderer.reset ();
#endif
    }
    return 0;
}
