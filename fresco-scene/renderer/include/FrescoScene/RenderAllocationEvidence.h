#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <utility>

namespace FrescoScene {

enum class RenderAllocationKind : std::size_t {
    shader,
    shaderVariable,
    passAttribute,
    passUniform,
    passReferenceUniform,
    copiedUniformValue,
    intermediateFramebuffer,
    intermediateTexture,
    count,
};

struct RenderAllocationCounts {
    std::size_t live = 0;
    std::size_t peak = 0;
    std::size_t allocations = 0;
    std::size_t deallocations = 0;
};

struct RenderAllocationEvidence {
    RenderAllocationCounts shaders;
    RenderAllocationCounts shaderVariables;
    RenderAllocationCounts passAttributes;
    RenderAllocationCounts passUniforms;
    RenderAllocationCounts passReferenceUniforms;
    RenderAllocationCounts copiedUniformValues;
    RenderAllocationCounts intermediateFramebuffers;
    RenderAllocationCounts intermediateTextures;
};

namespace Detail {

struct RenderAllocationCounters {
    std::atomic<std::size_t> live = 0;
    std::atomic<std::size_t> peak = 0;
    std::atomic<std::size_t> allocations = 0;
    std::atomic<std::size_t> deallocations = 0;
};

inline auto& renderAllocationCounters () {
    static std::array<RenderAllocationCounters,
                      static_cast<std::size_t> (RenderAllocationKind::count)> counters;
    return counters;
}

inline void recordRenderAllocation (RenderAllocationKind kind) noexcept {
    auto& counters = renderAllocationCounters ()[static_cast<std::size_t> (kind)];
    const std::size_t live = counters.live.fetch_add (1, std::memory_order_relaxed) + 1;
    counters.allocations.fetch_add (1, std::memory_order_relaxed);
    std::size_t peak = counters.peak.load (std::memory_order_relaxed);
    while (peak < live && !counters.peak.compare_exchange_weak (
                              peak, live, std::memory_order_relaxed
                          )) { }
}

inline void recordRenderDeallocation (RenderAllocationKind kind) noexcept {
    auto& counters = renderAllocationCounters ()[static_cast<std::size_t> (kind)];
    counters.live.fetch_sub (1, std::memory_order_relaxed);
    counters.deallocations.fetch_add (1, std::memory_order_relaxed);
}

inline RenderAllocationCounts renderAllocationCounts (RenderAllocationKind kind) noexcept {
    const auto& counters
        = renderAllocationCounters ()[static_cast<std::size_t> (kind)];
    return {
        .live = counters.live.load (std::memory_order_relaxed),
        .peak = counters.peak.load (std::memory_order_relaxed),
        .allocations = counters.allocations.load (std::memory_order_relaxed),
        .deallocations = counters.deallocations.load (std::memory_order_relaxed),
    };
}

} // namespace Detail

struct RenderAllocationDeleter {
    RenderAllocationKind kind = RenderAllocationKind::shader;

    template <typename T> void operator() (T* value) const noexcept {
        delete value;
        Detail::recordRenderDeallocation (kind);
    }
};

template <typename T>
using TrackedRenderUniquePtr = std::unique_ptr<T, RenderAllocationDeleter>;

template <typename T, typename... Args>
TrackedRenderUniquePtr<T> makeTrackedRenderUnique (
    RenderAllocationKind kind, Args&&... args
) {
    auto value = std::make_unique<T> (std::forward<Args> (args)...);
    Detail::recordRenderAllocation (kind);
    return { value.release (), RenderAllocationDeleter { kind } };
}

template <typename T, typename... Args>
std::shared_ptr<const T> makeTrackedRenderShared (
    RenderAllocationKind kind, Args&&... args
) {
    auto* value = new T (std::forward<Args> (args)...);
    Detail::recordRenderAllocation (kind);
    return std::shared_ptr<const T> (value, RenderAllocationDeleter { kind });
}

[[nodiscard]] inline RenderAllocationEvidence renderAllocationEvidence () noexcept {
    return {
        .shaders = Detail::renderAllocationCounts (RenderAllocationKind::shader),
        .shaderVariables
            = Detail::renderAllocationCounts (RenderAllocationKind::shaderVariable),
        .passAttributes
            = Detail::renderAllocationCounts (RenderAllocationKind::passAttribute),
        .passUniforms
            = Detail::renderAllocationCounts (RenderAllocationKind::passUniform),
        .passReferenceUniforms = Detail::renderAllocationCounts (
            RenderAllocationKind::passReferenceUniform
        ),
        .copiedUniformValues = Detail::renderAllocationCounts (
            RenderAllocationKind::copiedUniformValue
        ),
        .intermediateFramebuffers = Detail::renderAllocationCounts (
            RenderAllocationKind::intermediateFramebuffer
        ),
        .intermediateTextures = Detail::renderAllocationCounts (
            RenderAllocationKind::intermediateTexture
        ),
    };
}

inline void recordRenderAllocation (RenderAllocationKind kind) noexcept {
    Detail::recordRenderAllocation (kind);
}

inline void recordRenderDeallocation (RenderAllocationKind kind) noexcept {
    Detail::recordRenderDeallocation (kind);
}

} // namespace FrescoScene
