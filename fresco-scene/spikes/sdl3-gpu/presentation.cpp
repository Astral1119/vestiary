#include <SDL3/SDL.h>

#include "PresentationScheduler.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

using fresco::sdl3_spike::PresentationCompletion;
using fresco::sdl3_spike::PresentationScheduler;
using fresco::sdl3_spike::SchedulerDecision;

constexpr SDL_GPUTextureFormat kReadbackFormat =
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;

struct Counters {
    std::uint32_t windowsCreated = 0;
    std::uint32_t windowsDestroyed = 0;
    std::uint32_t devicesCreated = 0;
    std::uint32_t devicesDestroyed = 0;
    std::uint32_t windowsClaimed = 0;
    std::uint32_t windowsReleased = 0;
    std::uint32_t commandBuffersAcquired = 0;
    std::uint32_t commandBuffersSubmitted = 0;
    std::uint32_t swapchainAcquisitions = 0;
    std::uint32_t presents = 0;
    std::uint32_t fencesCreated = 0;
    std::uint32_t fencesWaited = 0;
    std::uint32_t fencesReleased = 0;
    std::uint32_t texturesCreated = 0;
    std::uint32_t texturesReleased = 0;
    std::uint32_t transfersCreated = 0;
    std::uint32_t transfersReleased = 0;
    std::uint32_t resizeRetirementsAfterCompletion = 0;
};

struct Output {
    std::string identity;
    std::filesystem::path path;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
};

struct Presented {
    Output output;
    PresentationCompletion completion;
};

struct WindowEvidence {
    std::string videoDriver;
    std::string gpuDriver;
    int initialLogicalWidth = 0;
    int initialLogicalHeight = 0;
    int initialPixelWidth = 0;
    int initialPixelHeight = 0;
    bool sdrSupported = false;
    bool vsyncSupported = false;
    bool immediateSupported = false;
    bool mailboxSupported = false;
    SDL_GPUTextureFormat format = SDL_GPU_TEXTUREFORMAT_INVALID;
};

[[noreturn]] void fail(const char* operation) {
    throw std::runtime_error(std::string(operation) + ": " + SDL_GetError());
}

std::string boolJson(bool value) { return value ? "true" : "false"; }

std::string jsonEscape(std::string_view input) {
    std::ostringstream output;
    for (const char value : input) {
        switch (value) {
        case '\\': output << "\\\\"; break;
        case '"': output << "\\\""; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default: output << value; break;
        }
    }
    return output.str();
}

template <typename Value>
void optionalJson(std::ostringstream& output, const std::optional<Value>& value) {
    if (value.has_value()) output << *value;
    else output << "null";
}

std::string textureFormatName(SDL_GPUTextureFormat format) {
    switch (format) {
    case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM: return "bgra8unorm";
    case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB: return "bgra8unorm-srgb";
    case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM: return "rgba8unorm";
    case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB: return "rgba8unorm-srgb";
    case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT: return "rgba16float";
    case SDL_GPU_TEXTUREFORMAT_R10G10B10A2_UNORM: return "r10g10b10a2unorm";
    default: return "other-" + std::to_string(static_cast<int>(format));
    }
}

std::string countersJson(const Counters& value, std::size_t decisionCount) {
    std::ostringstream output;
    output << "{\"windowsCreated\":" << value.windowsCreated
        << ",\"windowsDestroyed\":" << value.windowsDestroyed
        << ",\"devicesCreated\":" << value.devicesCreated
        << ",\"devicesDestroyed\":" << value.devicesDestroyed
        << ",\"windowsClaimed\":" << value.windowsClaimed
        << ",\"windowsReleased\":" << value.windowsReleased
        << ",\"evaluations\":" << decisionCount
        << ",\"schedulerDecisions\":" << decisionCount
        << ",\"commandBuffersAcquired\":" << value.commandBuffersAcquired
        << ",\"commandBuffersSubmitted\":" << value.commandBuffersSubmitted
        << ",\"swapchainAcquisitions\":" << value.swapchainAcquisitions
        << ",\"presents\":" << value.presents
        << ",\"fencesCreated\":" << value.fencesCreated
        << ",\"fencesWaited\":" << value.fencesWaited
        << ",\"fencesReleased\":" << value.fencesReleased
        << ",\"texturesCreated\":" << value.texturesCreated
        << ",\"texturesReleased\":" << value.texturesReleased
        << ",\"transfersCreated\":" << value.transfersCreated
        << ",\"transfersReleased\":" << value.transfersReleased
        << ",\"resizeRetirementsAfterCompletion\":"
        << value.resizeRetirementsAfterCompletion << "}";
    return output.str();
}

std::string gpuCountersJson(const Counters& value) {
    std::ostringstream output;
    output << "{\"commandBuffersAcquired\":"
        << value.commandBuffersAcquired
        << ",\"commandBuffersSubmitted\":"
        << value.commandBuffersSubmitted
        << ",\"swapchainAcquisitions\":" << value.swapchainAcquisitions
        << ",\"presents\":" << value.presents
        << ",\"fencesCreated\":" << value.fencesCreated
        << ",\"fencesWaited\":" << value.fencesWaited
        << ",\"fencesReleased\":" << value.fencesReleased
        << ",\"texturesCreated\":" << value.texturesCreated
        << ",\"texturesReleased\":" << value.texturesReleased
        << ",\"transfersCreated\":" << value.transfersCreated
        << ",\"transfersReleased\":" << value.transfersReleased
        << ",\"resizeRetirementsAfterCompletion\":"
        << value.resizeRetirementsAfterCompletion << "}";
    return output.str();
}

class PresentationHarness {
public:
    explicit PresentationHarness(const char* title) {
        started_ = std::chrono::steady_clock::now();
        const char* videoDriver = SDL_GetCurrentVideoDriver();
        if (videoDriver == nullptr) fail("SDL_GetCurrentVideoDriver");
        evidence_.videoDriver = videoDriver;
        if (evidence_.videoDriver != "cocoa") {
            throw std::runtime_error("presentation spike requires Cocoa video");
        }
        device_ = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, "metal");
        if (device_ == nullptr) fail("SDL_CreateGPUDevice");
        ++counters_.devicesCreated;
        const char* gpuDriver = SDL_GetGPUDeviceDriver(device_);
        if (gpuDriver == nullptr) fail("SDL_GetGPUDeviceDriver");
        evidence_.gpuDriver = gpuDriver;
        if (evidence_.gpuDriver != "metal") {
            throw std::runtime_error("presentation spike requires Metal GPU");
        }
        window_ = SDL_CreateWindow(
            title, 320, 180,
            SDL_WINDOW_HIDDEN | SDL_WINDOW_RESIZABLE |
                SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (window_ == nullptr) fail("SDL_CreateWindow");
        ++counters_.windowsCreated;
        if (!SDL_ClaimWindowForGPUDevice(device_, window_)) {
            fail("SDL_ClaimWindowForGPUDevice");
        }
        ++counters_.windowsClaimed;
        evidence_.sdrSupported = SDL_WindowSupportsGPUSwapchainComposition(
            device_, window_, SDL_GPU_SWAPCHAINCOMPOSITION_SDR);
        evidence_.vsyncSupported = SDL_WindowSupportsGPUPresentMode(
            device_, window_, SDL_GPU_PRESENTMODE_VSYNC);
        evidence_.immediateSupported = SDL_WindowSupportsGPUPresentMode(
            device_, window_, SDL_GPU_PRESENTMODE_IMMEDIATE);
        evidence_.mailboxSupported = SDL_WindowSupportsGPUPresentMode(
            device_, window_, SDL_GPU_PRESENTMODE_MAILBOX);
        if (!evidence_.sdrSupported || !evidence_.vsyncSupported) {
            throw std::runtime_error("required SDR/vsync swapchain is unsupported");
        }
        if (!SDL_SetGPUSwapchainParameters(
                device_, window_, SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
                SDL_GPU_PRESENTMODE_VSYNC)) {
            fail("SDL_SetGPUSwapchainParameters");
        }
        if (!SDL_SetGPUAllowedFramesInFlight(device_, 1)) {
            fail("SDL_SetGPUAllowedFramesInFlight");
        }
        evidence_.format = SDL_GetGPUSwapchainTextureFormat(device_, window_);
        if (!SDL_GetWindowSize(
                window_, &evidence_.initialLogicalWidth,
                &evidence_.initialLogicalHeight)) {
            fail("SDL_GetWindowSize");
        }
        if (!SDL_GetWindowSizeInPixels(
                window_, &evidence_.initialPixelWidth,
                &evidence_.initialPixelHeight)) {
            fail("SDL_GetWindowSizeInPixels");
        }
    }

    PresentationHarness(const PresentationHarness&) = delete;
    PresentationHarness& operator=(const PresentationHarness&) = delete;

    ~PresentationHarness() {
        if (!shutdown_) shutdownNoThrow();
    }

    Presented present(
        PresentationScheduler& scheduler,
        std::uint32_t requestedSequence,
        const std::filesystem::path& outputDirectory,
        std::string identity,
        SDL_FColor color,
        bool retainReadback) {
        const auto authorization = scheduler.authorize(requestedSequence);
        const auto& decision = authorization.decision();
        if (decision.sequence != requestedSequence) {
            throw std::logic_error("scheduler returned a mismatched authorization");
        }
        SDL_GPUCommandBuffer* command = SDL_AcquireGPUCommandBuffer(device_);
        if (command == nullptr) fail("SDL_AcquireGPUCommandBuffer");
        ++counters_.commandBuffersAcquired;
        SDL_GPUTexture* swapchain = nullptr;
        std::uint32_t width = 0;
        std::uint32_t height = 0;
        if (!SDL_WaitAndAcquireGPUSwapchainTexture(
                command, window_, &swapchain, &width, &height)) {
            fail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        if (swapchain == nullptr) {
            throw std::runtime_error("hidden Cocoa window exposed no swapchain");
        }
        ++counters_.swapchainAcquisitions;
        replaceReadbackTarget(width, height);

        SDL_GPUColorTargetInfo targets[2]{};
        targets[0].texture = swapchain;
        targets[0].clear_color = color;
        targets[0].load_op = SDL_GPU_LOADOP_CLEAR;
        targets[0].store_op = SDL_GPU_STOREOP_STORE;
        targets[1].texture = readbackTarget_;
        targets[1].clear_color = color;
        targets[1].load_op = SDL_GPU_LOADOP_CLEAR;
        targets[1].store_op = SDL_GPU_STOREOP_STORE;
        for (const auto& target : targets) {
            SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(
                command, &target, 1, nullptr);
            if (pass == nullptr) fail("SDL_BeginGPURenderPass");
            SDL_EndGPURenderPass(pass);
        }

        SDL_GPUTransferBuffer* transfer = nullptr;
        const std::uint32_t byteCount = width * height * 4;
        if (retainReadback) {
            const SDL_GPUTransferBufferCreateInfo transferInfo{
                SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, byteCount, 0};
            transfer = SDL_CreateGPUTransferBuffer(device_, &transferInfo);
            if (transfer == nullptr) fail("SDL_CreateGPUTransferBuffer");
            ++counters_.transfersCreated;
            SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(command);
            if (copy == nullptr) fail("SDL_BeginGPUCopyPass");
            const SDL_GPUTextureRegion source{
                readbackTarget_, 0, 0, 0, 0, 0, width, height, 1};
            const SDL_GPUTextureTransferInfo destination{
                transfer, 0, width, height};
            SDL_DownloadFromGPUTexture(copy, &source, &destination);
            SDL_EndGPUCopyPass(copy);
        }

        lastSubmissionCompleted_ = false;
        SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(command);
        if (fence == nullptr) fail("SDL_SubmitGPUCommandBufferAndAcquireFence");
        ++counters_.commandBuffersSubmitted;
        ++counters_.presents;
        ++counters_.fencesCreated;
        if (!SDL_WaitForGPUFences(device_, true, &fence, 1)) {
            fail("SDL_WaitForGPUFences");
        }
        ++counters_.fencesWaited;
        SDL_ReleaseGPUFence(device_, fence);
        ++counters_.fencesReleased;
        lastSubmissionCompleted_ = true;

        Output output{std::move(identity), {}, width, height};
        if (retainReadback) {
            void* mapped = SDL_MapGPUTransferBuffer(device_, transfer, false);
            if (mapped == nullptr) fail("SDL_MapGPUTransferBuffer");
            output.path = outputDirectory / (output.identity + ".bgra");
            std::ofstream stream(output.path, std::ios::binary);
            if (!stream) throw std::runtime_error("cannot create readback");
            stream.write(static_cast<const char*>(mapped), byteCount);
            if (!stream) throw std::runtime_error("cannot write readback");
            SDL_UnmapGPUTransferBuffer(device_, transfer);
            SDL_ReleaseGPUTransferBuffer(device_, transfer);
            ++counters_.transfersReleased;
        }
        const auto observed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started_).count();
        const PresentationCompletion completion{
            counters_.commandBuffersSubmitted, width, height,
            static_cast<std::uint64_t>(observed)};
        scheduler.complete(authorization, completion);
        return {output, completion};
    }

    std::array<int, 4> resize(int width, int height) {
        if (!SDL_SetWindowSize(window_, width, height)) fail("SDL_SetWindowSize");
        if (!SDL_SyncWindow(window_)) fail("SDL_SyncWindow");
        SDL_PumpEvents();
        int logicalWidth = 0;
        int logicalHeight = 0;
        int pixelWidth = 0;
        int pixelHeight = 0;
        if (!SDL_GetWindowSize(window_, &logicalWidth, &logicalHeight)) {
            fail("SDL_GetWindowSize(resize)");
        }
        if (!SDL_GetWindowSizeInPixels(window_, &pixelWidth, &pixelHeight)) {
            fail("SDL_GetWindowSizeInPixels(resize)");
        }
        return {logicalWidth, logicalHeight, pixelWidth, pixelHeight};
    }

    void shutdown() {
        if (!SDL_WaitForGPUIdle(device_)) fail("SDL_WaitForGPUIdle");
        releaseReadbackTarget(false);
        SDL_ReleaseWindowFromGPUDevice(device_, window_);
        ++counters_.windowsReleased;
        SDL_DestroyWindow(window_);
        window_ = nullptr;
        ++counters_.windowsDestroyed;
        SDL_DestroyGPUDevice(device_);
        device_ = nullptr;
        ++counters_.devicesDestroyed;
        shutdown_ = true;
    }

    const Counters& counters() const { return counters_; }
    const WindowEvidence& windowEvidence() const { return evidence_; }

private:
    void replaceReadbackTarget(std::uint32_t width, std::uint32_t height) {
        if (readbackTarget_ != nullptr && width_ == width && height_ == height) {
            return;
        }
        if (readbackTarget_ != nullptr) {
            if (!lastSubmissionCompleted_) {
                throw std::runtime_error("readback target retired before completion");
            }
            releaseReadbackTarget(true);
        }
        const SDL_GPUTextureCreateInfo info{
            SDL_GPU_TEXTURETYPE_2D, kReadbackFormat,
            SDL_GPU_TEXTUREUSAGE_COLOR_TARGET, width, height, 1, 1,
            SDL_GPU_SAMPLECOUNT_1, 0};
        readbackTarget_ = SDL_CreateGPUTexture(device_, &info);
        if (readbackTarget_ == nullptr) fail("SDL_CreateGPUTexture");
        ++counters_.texturesCreated;
        width_ = width;
        height_ = height;
    }

    void releaseReadbackTarget(bool resize) {
        if (readbackTarget_ == nullptr) return;
        SDL_ReleaseGPUTexture(device_, readbackTarget_);
        readbackTarget_ = nullptr;
        ++counters_.texturesReleased;
        width_ = 0;
        height_ = 0;
        if (resize) ++counters_.resizeRetirementsAfterCompletion;
    }

    void shutdownNoThrow() noexcept {
        if (device_ != nullptr) {
            SDL_WaitForGPUIdle(device_);
            releaseReadbackTarget(false);
            if (window_ != nullptr) {
                SDL_ReleaseWindowFromGPUDevice(device_, window_);
                SDL_DestroyWindow(window_);
            }
            SDL_DestroyGPUDevice(device_);
        }
        shutdown_ = true;
    }

    SDL_GPUDevice* device_ = nullptr;
    SDL_Window* window_ = nullptr;
    SDL_GPUTexture* readbackTarget_ = nullptr;
    std::uint32_t width_ = 0;
    std::uint32_t height_ = 0;
    bool lastSubmissionCompleted_ = true;
    bool shutdown_ = false;
    Counters counters_;
    WindowEvidence evidence_;
    std::chrono::steady_clock::time_point started_;
};

std::string outputJson(const Output& output) {
    std::ostringstream value;
    value << "{\"identity\":\"" << jsonEscape(output.identity)
        << "\",\"evidenceRole\":\"mirrored-render-oracle\""
        << ",\"path\":\"" << jsonEscape(output.path.string())
        << "\",\"width\":" << output.width
        << ",\"height\":" << output.height << "}";
    return value.str();
}

std::string windowJson(const WindowEvidence& value) {
    std::ostringstream output;
    output << "{\"videoDriver\":\"" << jsonEscape(value.videoDriver)
        << "\",\"gpuDriver\":\"" << jsonEscape(value.gpuDriver)
        << "\",\"createdHidden\":true"
        << ",\"resizable\":true,\"highPixelDensity\":true"
        << ",\"initialLogicalWidth\":" << value.initialLogicalWidth
        << ",\"initialLogicalHeight\":" << value.initialLogicalHeight
        << ",\"initialPixelWidth\":" << value.initialPixelWidth
        << ",\"initialPixelHeight\":" << value.initialPixelHeight
        << ",\"support\":{\"sdr\":" << boolJson(value.sdrSupported)
        << ",\"vsync\":" << boolJson(value.vsyncSupported)
        << ",\"immediate\":" << boolJson(value.immediateSupported)
        << ",\"mailbox\":" << boolJson(value.mailboxSupported)
        << "},\"selectedComposition\":\"sdr\""
        << ",\"selectedPresentMode\":\"vsync\""
        << ",\"swapchainFormat\":\""
        << textureFormatName(value.format) << "\"}";
    return output.str();
}

std::string schedulerJson(const PresentationScheduler& scheduler) {
    std::ostringstream output;
    output << "{\"inputEvents\":[";
    const auto& inputs = scheduler.inputEvents();
    for (std::size_t index = 0; index < inputs.size(); ++index) {
        if (index != 0) output << ",";
        const auto& event = inputs[index];
        output << "{\"sequence\":" << event.sequence
            << ",\"appliedAtNanoseconds\":" << event.appliedAtNanoseconds
            << ",\"kind\":\"" << jsonEscape(event.kind)
            << "\",\"reason\":\"" << jsonEscape(event.reason)
            << "\",\"targetNanoseconds\":";
        optionalJson(output, event.targetNanoseconds);
        output << ",\"requestedFpsCeiling\":" << event.requestedFpsCeiling
            << ",\"policyRevisionAfter\":" << event.policyRevisionAfter
            << ",\"nextWakeAfterNanoseconds\":";
        optionalJson(output, event.nextWakeAfterNanoseconds);
        output << "}";
    }
    output << "],\"decisions\":[";
    const auto& decisions = scheduler.decisions();
    for (std::size_t index = 0; index < decisions.size(); ++index) {
        if (index != 0) output << ",";
        const auto& decision = decisions[index];
        output << "{\"sequence\":" << decision.sequence
            << ",\"kind\":\"present\""
            << ",\"semanticNanoseconds\":" << decision.semanticNanoseconds
            << ",\"reasons\":[";
        for (std::size_t reason = 0; reason < decision.reasons.size(); ++reason) {
            if (reason != 0) output << ",";
            output << "\"" << jsonEscape(decision.reasons[reason]) << "\"";
        }
        output << "]"
            << ",\"policyRevision\":" << decision.policyRevision
            << ",\"fpsCeiling\":" << decision.fpsCeiling
            << ",\"periodNanoseconds\":" << decision.periodNanoseconds
            << ",\"nextWakeAfterNanoseconds\":";
        optionalJson(output, decision.nextWakeAfterNanoseconds);
        output << ",\"completion\":";
        if (!decision.completion.has_value()) {
            output << "null";
        } else {
            const auto& completion = *decision.completion;
            output << "{\"submissionOrdinal\":"
                << completion.submissionOrdinal
                << ",\"width\":" << completion.width
                << ",\"height\":" << completion.height
                << ",\"wallObservedAtNanoseconds\":"
                << completion.wallObservedAtNanoseconds << "}";
        }
        output << "}";
    }
    output << "],\"finalState\":{\"nowNanoseconds\":"
        << scheduler.nowNanoseconds()
        << ",\"fpsCeiling\":" << scheduler.fpsCeiling()
        << ",\"periodNanoseconds\":" << scheduler.periodNanoseconds()
        << ",\"continuousLease\":" << boolJson(scheduler.continuousLease())
        << ",\"paused\":" << boolJson(scheduler.paused())
        << ",\"nextWakeNanoseconds\":";
    optionalJson(output, scheduler.nextWakeNanoseconds());
    output << "}}";
    return output.str();
}

template <typename Presenter>
void advance(
    PresentationScheduler& scheduler,
    std::uint64_t targetNanoseconds,
    Presenter&& presenter) {
    scheduler.beginAdvance(targetNanoseconds);
    while (const auto decision = scheduler.nextDecision()) {
        presenter(*decision);
    }
}

struct WorkloadResult { std::string json; };

std::string runAuthorizationProbe(
    const std::filesystem::path& outputDirectory,
    const std::string& probe) {
    PresentationHarness harness("Fresco SDL3 authorization probe");
    PresentationScheduler scheduler;
    const SDL_FColor color{0.1F, 0.2F, 0.3F, 1.0F};
    scheduler.configureStaticPolicy(60);
    scheduler.invalidate("constructor", "constructor-invalidation");
    scheduler.beginAdvance(0);
    const auto first = scheduler.nextDecision();
    if (!first.has_value()) {
        throw std::logic_error("authorization probe has no first decision");
    }

    std::uint32_t requestedSequence = first->sequence;
    if (probe == "zero") {
        requestedSequence = 0;
    } else if (probe == "forged-999") {
        requestedSequence = 999;
    } else if (probe == "duplicate-current") {
        static_cast<void>(scheduler.authorize(first->sequence));
    } else if (probe == "stale-prior" || probe == "already-completed") {
        harness.present(
            scheduler, first->sequence, outputDirectory,
            "probe-prior", color, false);
        if (scheduler.nextDecision().has_value()) {
            throw std::logic_error("authorization probe advance did not settle");
        }
        if (probe == "stale-prior") {
            scheduler.invalidate("property-invalidation");
            scheduler.beginAdvance(1);
            const auto second = scheduler.nextDecision();
            if (!second.has_value() || second->sequence != 2) {
                throw std::logic_error("authorization probe has no second decision");
            }
        }
        requestedSequence = first->sequence;
    } else {
        throw std::logic_error("unknown authorization probe");
    }

    const Counters before = harness.counters();
    bool rejected = false;
    std::string error;
    try {
        harness.present(
            scheduler, requestedSequence, outputDirectory,
            "probe-rejected", color, false);
    } catch (const std::logic_error& caught) {
        rejected = true;
        error = caught.what();
    }
    const Counters after = harness.counters();
    const std::string beforeJson = gpuCountersJson(before);
    const std::string afterJson = gpuCountersJson(after);
    harness.shutdown();
    std::ostringstream result;
    result << "{\"schemaVersion\":1,\"mode\":\"authorization-probe\""
        << ",\"probe\":\"" << jsonEscape(probe)
        << "\",\"requestedSequence\":" << requestedSequence
        << ",\"rejected\":" << boolJson(rejected)
        << ",\"error\":\"" << jsonEscape(error)
        << "\",\"before\":" << beforeJson
        << ",\"after\":" << afterJson
        << ",\"gpuCountersUnchanged\":"
        << boolJson(beforeJson == afterJson) << "}";
    return result.str();
}

WorkloadResult runStatic(
    const std::filesystem::path& outputDirectory,
    const std::string& faultMode) {
    PresentationHarness harness("Fresco SDL3 static presentation spike");
    PresentationScheduler scheduler(faultMode);
    const SDL_FColor initial{0.1F, 0.2F, 0.3F, 1.0F};
    const SDL_FColor property{0.3F, 0.2F, 0.1F, 1.0F};
    std::vector<Output> outputs;
    auto present = [&](const SchedulerDecision& decision) {
        const bool constructor = decision.sequence == 1;
        auto result = harness.present(
            scheduler, decision.sequence, outputDirectory,
            constructor ? "static-constructor" :
                decision.sequence == 2 ? "static-property" : "static-resize",
            constructor ? initial : property, true);
        outputs.push_back(result.output);
        return result.completion;
    };

    scheduler.configureStaticPolicy(60);
    scheduler.invalidate("constructor", "constructor-invalidation");
    advance(scheduler, 0, present);
    advance(scheduler, 400000000ULL, present);
    advance(scheduler, 400000001ULL, present);
    scheduler.invalidate("property-invalidation");
    advance(scheduler, 400000001ULL, present);
    advance(scheduler, 700000001ULL, present);
    advance(scheduler, 700000002ULL, present);
    const auto resized = harness.resize(480, 270);
    scheduler.invalidate("resize-invalidation", "resize");
    advance(scheduler, 700000002ULL, present);
    if (faultMode == "presentation-without-decision") {
        SchedulerDecision unbacked;
        unbacked.sequence = 999;
        harness.present(
            scheduler, unbacked.sequence, outputDirectory,
            "unbacked", property, false);
    }
    harness.shutdown();

    std::ostringstream outputsJson;
    outputsJson << "[";
    for (std::size_t index = 0; index < outputs.size(); ++index) {
        if (index != 0) outputsJson << ",";
        outputsJson << outputJson(outputs[index]);
    }
    outputsJson << "]";
    std::ostringstream json;
    json << "{\"identity\":\"static-no-media\""
        << ",\"manifestVersion\":1,\"criteriaVersion\":\"static-baseline-v1\""
        << ",\"semanticClock\":\"deterministic-virtual-nanoseconds\""
        << ",\"wallClockRole\":\"event-order-observation-only-not-performance\""
        << ",\"window\":" << windowJson(harness.windowEvidence())
        << ",\"scheduler\":" << schedulerJson(scheduler)
        << ",\"resizeEvidence\":{\"requestedLogicalWidth\":480"
        << ",\"requestedLogicalHeight\":270"
        << ",\"actualLogicalWidth\":" << resized[0]
        << ",\"actualLogicalHeight\":" << resized[1]
        << ",\"actualPixelWidth\":" << resized[2]
        << ",\"actualPixelHeight\":" << resized[3] << "}"
        << ",\"outputs\":" << outputsJson.str()
        << ",\"lifecycle\":"
        << countersJson(harness.counters(), scheduler.decisions().size()) << "}";
    return {json.str()};
}

WorkloadResult runContinuous(
    const std::filesystem::path& outputDirectory,
    const std::string& faultMode) {
    PresentationHarness harness("Fresco SDL3 continuous presentation spike");
    PresentationScheduler scheduler(faultMode);
    const SDL_FColor color{0.1F, 0.2F, 0.3F, 1.0F};
    std::vector<Output> outputs;
    auto present = [&](const SchedulerDecision& decision) {
        std::string identity = "continuous-unretained";
        bool retain = false;
        if (decision.sequence == 12) {
            identity = "continuous-fps-15";
            retain = true;
        } else if (decision.sequence == 30) {
            identity = "continuous-fps-30";
            retain = true;
        } else if (decision.sequence == 57) {
            identity = "continuous-fps-60";
            retain = true;
        } else if (decision.sequence == 78) {
            identity = "continuous-resume";
            retain = true;
        }
        auto result = harness.present(
            scheduler, decision.sequence, outputDirectory,
            std::move(identity), color, retain);
        if (retain) outputs.push_back(result.output);
        return result.completion;
    };

    scheduler.startContinuousLease(15);
    advance(scheduler, 800000000ULL, present);
    scheduler.retime(30);
    advance(scheduler, 1400000000ULL, present);
    scheduler.retime(60);
    scheduler.invalidate("scene-property");
    advance(scheduler, 1850000000ULL, present);
    scheduler.pause();
    advance(scheduler, 2150000000ULL, present);
    scheduler.resume();
    advance(scheduler, 2500000000ULL, present);
    harness.shutdown();

    std::ostringstream outputsJson;
    outputsJson << "[";
    for (std::size_t index = 0; index < outputs.size(); ++index) {
        if (index != 0) outputsJson << ",";
        outputsJson << outputJson(outputs[index]);
    }
    outputsJson << "]";
    std::ostringstream json;
    json << "{\"identity\":\"continuous-animation\""
        << ",\"manifestVersion\":1,\"criteriaVersion\":\"continuous-cadence-v1\""
        << ",\"semanticClock\":\"deterministic-virtual-nanoseconds\""
        << ",\"wallClockRole\":\"event-order-observation-only-not-performance\""
        << ",\"window\":" << windowJson(harness.windowEvidence())
        << ",\"scheduler\":" << schedulerJson(scheduler)
        << ",\"outputs\":" << outputsJson.str()
        << ",\"lifecycle\":"
        << countersJson(harness.counters(), scheduler.decisions().size()) << "}";
    return {json.str()};
}

int run(int argc, char** argv) {
    std::filesystem::path outputDirectory;
    std::string faultMode;
    std::string authorizationProbe;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--output" && index + 1 < argc) {
            outputDirectory = argv[++index];
        } else if (argument == "--fault" && index + 1 < argc) {
            faultMode = argv[++index];
        } else if (argument == "--authorization-probe" && index + 1 < argc) {
            authorizationProbe = argv[++index];
        } else {
            throw std::runtime_error("unknown or incomplete argument");
        }
    }
    if (outputDirectory.empty()) {
        throw std::runtime_error("presentation run requires --output");
    }
    const std::array<std::string_view, 7> faults{{
        "early-wake", "stale-fps-after-retime", "pause-wake",
        "duplicate-uncoalesced", "altered-decision-timestamp",
        "missing-reason", "presentation-without-decision"}};
    if (!faultMode.empty() &&
        std::find(faults.begin(), faults.end(), faultMode) == faults.end()) {
        throw std::runtime_error("unknown fault mode");
    }
    std::filesystem::create_directories(outputDirectory);
    if (!SDL_Init(SDL_INIT_VIDEO)) fail("SDL_Init");
    if (!authorizationProbe.empty()) {
        const auto result = runAuthorizationProbe(
            outputDirectory, authorizationProbe);
        SDL_Quit();
        std::cout << result << "\n";
        return 0;
    }
    const auto staticResult = runStatic(outputDirectory, faultMode);
    const auto continuousResult = runContinuous(outputDirectory, faultMode);
    SDL_Quit();
    std::cout << "{\"schemaVersion\":2,\"mode\":\"presentation-scheduling\""
        << ",\"sdlVersion\":\"" << SDL_MAJOR_VERSION << "."
        << SDL_MINOR_VERSION << "." << SDL_MICRO_VERSION << "\""
        << ",\"schedulerIdentity\":\"standalone-virtual-state-machine-v2\""
        << ",\"authorizationIdentity\":\"scheduler-owned-one-shot-v1\""
        << ",\"semanticTimeDistinctFromWallTime\":true"
        << ",\"performanceClaim\":false"
        << ",\"drawablePixelClaim\":false"
        << ",\"retainedFrameRole\":\"mirrored-render-oracle\""
        << ",\"faultMode\":\""
        << jsonEscape(faultMode.empty() ? "none" : faultMode) << "\""
        << ",\"workloads\":[" << staticResult.json << ","
        << continuousResult.json << "]}\n";
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        return run(argc, argv);
    } catch (const std::exception& error) {
        std::cerr << "fresco SDL3 presentation spike: " << error.what() << "\n";
        SDL_Quit();
        return 1;
    }
}
