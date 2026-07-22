#include "FrescoScene/RenderProgramCache.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace FrescoScene {

namespace {
std::mutex lifecycleMutex;
RenderResourceLifecycleEvidence lifecycle;

void incrementSaturating (std::size_t& value) noexcept {
    if (value != std::numeric_limits<std::size_t>::max ()) { ++value; }
}
}

RenderResourceGenerationRegistry::RenderResourceGenerationRegistry (
    RenderResourceGeneration nextGeneration
) : m_nextGeneration (nextGeneration) {
    if (nextGeneration == 0) {
        throw std::overflow_error ("render resource generation exhausted");
    }
}

RenderResourceGeneration RenderResourceGenerationRegistry::registerContext (
    const void* context
) {
    if (context == nullptr) {
        throw std::invalid_argument ("render resource context must be non-null");
    }
    std::scoped_lock lock (m_mutex);
    if (m_nextGeneration == 0) {
        throw std::overflow_error ("render resource generation exhausted");
    }
    if (m_generations.contains (context)) {
        throw std::logic_error ("render resource context already registered");
    }
    const auto generation = m_nextGeneration;
    if (generation == std::numeric_limits<RenderResourceGeneration>::max ()) {
        m_nextGeneration = 0;
    } else {
        ++m_nextGeneration;
    }
    m_generations.emplace (context, generation);
    return generation;
}

RenderResourceGeneration RenderResourceGenerationRegistry::generationFor (
    const void* context
) const {
    std::scoped_lock lock (m_mutex);
    const auto found = m_generations.find (context);
    if (found == m_generations.end ()) {
        throw std::logic_error ("render resource context is not registered");
    }
    return found->second;
}

RenderResourceGeneration RenderResourceGenerationRegistry::retireContext (
    const void* context
) noexcept {
    std::scoped_lock lock (m_mutex);
    const auto found = m_generations.find (context);
    if (found == m_generations.end ()) { return 0; }
    const auto generation = found->second;
    m_generations.erase (found);
    return generation;
}

RenderProgramCache::RenderProgramCache (
    std::size_t maximumEntriesPerContext
) : m_maximumEntriesPerContext (maximumEntriesPerContext) {
    if (maximumEntriesPerContext == 0) {
        throw std::invalid_argument ("program cache capacity must be positive");
    }
}

std::shared_ptr<const RenderProgramCache::ProgramID> RenderProgramCache::find (
    RenderResourceGeneration generation,
    const std::string& vertexSource,
    const std::string& fragmentSource
) {
    if (generation == 0) {
        return nullptr;
    }
    const Key key { generation, vertexSource, fragmentSource };
    std::scoped_lock lock (m_mutex);
    const auto found = m_entries.find (key);
    if (found == m_entries.end ()) {
        return nullptr;
    }
    found->second.access = ++m_access;
    return found->second.program;
}

void RenderProgramCache::insert (
    RenderResourceGeneration generation,
    const std::string& vertexSource,
    const std::string& fragmentSource,
    std::shared_ptr<const ProgramID> program
) {
    if (generation == 0 || program == nullptr) {
        throw std::invalid_argument ("program cache entry must be complete");
    }
    const Key key { generation, vertexSource, fragmentSource };
    std::scoped_lock lock (m_mutex);
    m_entries.insert_or_assign (
        key,
        Entry { .program = std::move (program), .access = ++m_access }
    );
    auto& insertions = m_insertions[generation];
    if (insertions != std::numeric_limits<std::size_t>::max ()) {
        ++insertions;
    }
    trimGenerationLocked (generation);
    {
        std::scoped_lock lifecycleLock (lifecycleMutex);
        incrementSaturating (lifecycle.programPublications);
        lifecycle.lastPublishedGeneration = generation;
    }
}

void RenderProgramCache::clear (RenderResourceGeneration generation) {
    std::scoped_lock lock (m_mutex);
    std::erase_if (m_entries, [generation] (const auto& entry) {
        return std::get<0> (entry.first) == generation;
    });
    m_insertions.erase (generation);
}

std::size_t RenderProgramCache::insertions (RenderResourceGeneration generation) const {
    std::scoped_lock lock (m_mutex);
    const auto found = m_insertions.find (generation);
    return found == m_insertions.end () ? 0 : found->second;
}

std::size_t RenderProgramCache::size (RenderResourceGeneration generation) const {
    std::scoped_lock lock (m_mutex);
    return static_cast<std::size_t> (std::ranges::count_if (
        m_entries,
        [generation] (const auto& entry) {
            return std::get<0> (entry.first) == generation;
        }
    ));
}

void RenderProgramCache::trimGenerationLocked (RenderResourceGeneration generation) {
    while (static_cast<std::size_t> (std::ranges::count_if (
        m_entries,
        [generation] (const auto& entry) {
            return std::get<0> (entry.first) == generation;
        }
    )) > m_maximumEntriesPerContext) {
        auto oldest = m_entries.end ();
        for (auto iterator = m_entries.begin (); iterator != m_entries.end (); ++iterator) {
            if (std::get<0> (iterator->first) == generation
                && (oldest == m_entries.end ()
                    || iterator->second.access < oldest->second.access)) {
                oldest = iterator;
            }
        }
        m_entries.erase (oldest);
    }
}

RenderProgramCache& renderProgramCache () {
    // Explicit context teardown owns GL deletion. Leaking the empty registry avoids
    // process-exit destruction issuing GL calls after all contexts are gone.
    static auto* cache = new RenderProgramCache ();
    return *cache;
}

RenderResourceGenerationRegistry& generationRegistry () {
    static auto* registry = new RenderResourceGenerationRegistry ();
    return *registry;
}

RenderResourceGeneration registerRenderResourceContext (const void* context) {
    const auto generation = generationRegistry ().registerContext (context);
    std::scoped_lock lock (lifecycleMutex);
    if (lifecycle.liveGenerations == std::numeric_limits<std::size_t>::max ()) {
        static_cast<void> (generationRegistry ().retireContext (context));
        throw std::overflow_error ("live render resource generation count exhausted");
    }
    incrementSaturating (lifecycle.generationsCreated);
    ++lifecycle.liveGenerations;
    lifecycle.lastCreatedGeneration = generation;
    return generation;
}

RenderResourceGeneration renderResourceGeneration (const void* context) {
    return generationRegistry ().generationFor (context);
}

void retireRenderResourceContext (
    const void* context, bool completionSucceeded
) noexcept {
    const auto generation = generationRegistry ().retireContext (context);
    if (generation == 0) { return; }
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.completionBarriersRequested);
    if (completionSucceeded) {
        incrementSaturating (lifecycle.completionBarriersCompleted);
        lifecycle.lastCompletedGeneration = generation;
    } else {
        incrementSaturating (lifecycle.completionBarriersFailed);
        incrementSaturating (lifecycle.retirementsWithoutCompletion);
    }
    incrementSaturating (lifecycle.generationsRetired);
    if (lifecycle.liveGenerations > 0) { --lifecycle.liveGenerations; }
    lifecycle.lastRetiredGeneration = generation;
}

void clearRenderProgramCache (RenderResourceGeneration generation) {
    renderProgramCache ().clear (generation);
}

void recordRenderProgramRollback () noexcept {
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.programRollbacks);
}

void recordRenderShaderCompileFailure () noexcept {
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.shaderCompileFailures);
}

void recordRenderShaderTranslationFailure () noexcept {
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.shaderTranslationFailures);
}

void recordRenderProgramSetupFailure () noexcept {
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.programSetupFailures);
}

void recordRenderObjectSetupFailure (const void* context) noexcept {
    RenderResourceGeneration generation = 0;
    try { generation = generationRegistry ().generationFor (context); }
    catch (...) { return; }
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.objectSetupFailures);
    lifecycle.lastObjectSetupFailureGeneration = generation;
}

void recordRenderProgramDeletion (RenderResourceGeneration generation) noexcept {
    std::scoped_lock lock (lifecycleMutex);
    incrementSaturating (lifecycle.programDeletions);
    lifecycle.lastDeletedGeneration = generation;
}

RenderResourceLifecycleEvidence renderResourceLifecycleEvidence () noexcept {
    std::scoped_lock lock (lifecycleMutex);
    return lifecycle;
}

}
