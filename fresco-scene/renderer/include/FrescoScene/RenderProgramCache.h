#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>

namespace FrescoScene {

using RenderResourceGeneration = std::uint64_t;

struct RenderResourceLifecycleEvidence {
    std::size_t generationsCreated = 0;
    std::size_t generationsRetired = 0;
    std::size_t liveGenerations = 0;
    std::size_t completionBarriersRequested = 0;
    std::size_t completionBarriersCompleted = 0;
    std::size_t completionBarriersFailed = 0;
    std::size_t retirementsWithoutCompletion = 0;
    std::size_t programPublications = 0;
    std::size_t programDeletions = 0;
    std::size_t programRollbacks = 0;
    std::size_t shaderCompileFailures = 0;
    std::size_t shaderTranslationFailures = 0;
    std::size_t programSetupFailures = 0;
    std::size_t objectSetupFailures = 0;
    RenderResourceGeneration lastCreatedGeneration = 0;
    RenderResourceGeneration lastRetiredGeneration = 0;
    RenderResourceGeneration lastCompletedGeneration = 0;
    RenderResourceGeneration lastPublishedGeneration = 0;
    RenderResourceGeneration lastDeletedGeneration = 0;
    RenderResourceGeneration lastObjectSetupFailureGeneration = 0;
};

class RenderResourceGenerationRegistry {
public:
    explicit RenderResourceGenerationRegistry (
        RenderResourceGeneration nextGeneration = 1
    );

    [[nodiscard]] RenderResourceGeneration registerContext (const void* context);
    [[nodiscard]] RenderResourceGeneration generationFor (const void* context) const;
    [[nodiscard]] RenderResourceGeneration retireContext (
        const void* context
    ) noexcept;

private:
    mutable std::mutex m_mutex;
    std::map<const void*, RenderResourceGeneration> m_generations;
    RenderResourceGeneration m_nextGeneration;
};

class RenderProgramCache {
public:
    using ProgramID = unsigned int;

    explicit RenderProgramCache (std::size_t maximumEntriesPerContext = 64);

    [[nodiscard]] std::shared_ptr<const ProgramID> find (
        RenderResourceGeneration generation,
        const std::string& vertexSource,
        const std::string& fragmentSource
    );
    void insert (
        RenderResourceGeneration generation,
        const std::string& vertexSource,
        const std::string& fragmentSource,
        std::shared_ptr<const ProgramID> program
    );
    void clear (RenderResourceGeneration generation);

    [[nodiscard]] std::size_t size (RenderResourceGeneration generation) const;
    [[nodiscard]] std::size_t insertions (RenderResourceGeneration generation) const;

private:
    using Key = std::tuple<RenderResourceGeneration, std::string, std::string>;

    struct Entry {
        std::shared_ptr<const ProgramID> program;
        std::size_t access = 0;
    };

    void trimGenerationLocked (RenderResourceGeneration generation);

    std::size_t m_maximumEntriesPerContext;
    mutable std::mutex m_mutex;
    std::map<Key, Entry> m_entries;
    std::map<RenderResourceGeneration, std::size_t> m_insertions;
    std::size_t m_access = 0;
};

[[nodiscard]] RenderProgramCache& renderProgramCache ();
[[nodiscard]] RenderResourceGeneration registerRenderResourceContext (const void* context);
[[nodiscard]] RenderResourceGeneration renderResourceGeneration (const void* context);
void retireRenderResourceContext (
    const void* context, bool completionSucceeded
) noexcept;
void clearRenderProgramCache (RenderResourceGeneration generation);
void recordRenderProgramRollback () noexcept;
void recordRenderShaderCompileFailure () noexcept;
void recordRenderShaderTranslationFailure () noexcept;
void recordRenderProgramSetupFailure () noexcept;
void recordRenderObjectSetupFailure (const void* context) noexcept;
void recordRenderProgramDeletion (RenderResourceGeneration generation) noexcept;
[[nodiscard]] RenderResourceLifecycleEvidence renderResourceLifecycleEvidence () noexcept;

}
