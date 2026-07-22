#include "FrescoScene/RenderProgramCache.h"

#include <iostream>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

using FrescoScene::RenderProgramCache;
using FrescoScene::RenderResourceGenerationRegistry;

static_assert (noexcept (FrescoScene::retireRenderResourceContext (
    nullptr, false
)));

namespace {

void expect (bool condition) {
    if (!condition) {
        throw std::runtime_error ("render program cache assertion failed");
    }
}

std::shared_ptr<const RenderProgramCache::ProgramID> compileProgram (
    unsigned int identifier,
    int& compileCount,
    int& deleteCount
) {
    ++compileCount;
    return std::shared_ptr<const RenderProgramCache::ProgramID> (
        new RenderProgramCache::ProgramID (identifier),
        [&deleteCount] (const auto* program) {
            ++deleteCount;
            delete program;
        }
    );
}

}

int main () {
    RenderProgramCache cache (2);
    constexpr std::uint64_t generationA = 1;
    constexpr std::uint64_t generationB = 2;
    int compileCount = 0;
    int deleteCount = 0;

    auto first = compileProgram (1, compileCount, deleteCount);
    cache.insert (generationA, "vertex", "fragment", first);
    expect (cache.insertions (generationA) == 1);
    first.reset ();
    expect (cache.find (generationA, "vertex", "fragment") != nullptr);
    expect (compileCount == 1);
    expect (deleteCount == 0);

    auto second = compileProgram (2, compileCount, deleteCount);
    cache.insert (generationA, "vertex-2", "fragment", second);
    second.reset ();
    static_cast<void> (cache.find (generationA, "vertex", "fragment"));
    auto third = compileProgram (3, compileCount, deleteCount);
    cache.insert (generationA, "vertex-3", "fragment", third);
    expect (cache.insertions (generationA) == 3);
    third.reset ();
    expect (cache.size (generationA) == 2);
    expect (cache.find (generationA, "vertex-2", "fragment") == nullptr);
    expect (deleteCount == 1);

    auto isolated = compileProgram (4, compileCount, deleteCount);
    cache.insert (generationB, "vertex", "fragment", isolated);
    expect (cache.insertions (generationB) == 1);
    isolated.reset ();
    expect (cache.find (generationB, "vertex", "fragment") != nullptr);
    expect (cache.find (generationA, "vertex", "fragment") != nullptr);

    cache.clear (generationA);
    expect (cache.size (generationA) == 0);
    expect (cache.insertions (generationA) == 0);
    expect (cache.size (generationB) == 1);
    expect (deleteCount == 3);

    cache.clear (generationB);
    expect (deleteCount == 4);
    expect (cache.find (generationB, "vertex", "fragment") == nullptr);

    auto afterGap = compileProgram (5, compileCount, deleteCount);
    cache.insert (generationA, "vertex", "fragment", afterGap);
    afterGap.reset ();
    expect (compileCount == 5);
    expect (cache.find (generationA, "vertex", "fragment") != nullptr);
    cache.clear (generationA);
    expect (deleteCount == 5);

    RenderProgramCache ownershipCache (1);
    int ownershipCompiles = 0;
    int ownershipDeletes = 0;
    auto evictedProgram = compileProgram (
        10, ownershipCompiles, ownershipDeletes
    );
    ownershipCache.insert (generationA, "evicted", "fragment", evictedProgram);
    evictedProgram.reset ();
    auto activeHandle = ownershipCache.find (generationA, "evicted", "fragment");
    auto replacement = compileProgram (11, ownershipCompiles, ownershipDeletes);
    ownershipCache.insert (generationA, "replacement", "fragment", replacement);
    replacement.reset ();
    expect (ownershipDeletes == 0);
    ownershipCache.clear (generationA);
    expect (ownershipDeletes == 1);
    expect (*activeHandle == 10);
    activeHandle.reset ();
    expect (ownershipDeletes == 2);

    auto oldSameKey = compileProgram (12, ownershipCompiles, ownershipDeletes);
    ownershipCache.insert (generationA, "same", "fragment", oldSameKey);
    oldSameKey.reset ();
    auto retainedOld = ownershipCache.find (generationA, "same", "fragment");
    auto newSameKey = compileProgram (13, ownershipCompiles, ownershipDeletes);
    ownershipCache.insert (generationA, "same", "fragment", newSameKey);
    expect (ownershipCache.insertions (generationA) == 2);
    newSameKey.reset ();
    expect (ownershipDeletes == 2);
    retainedOld.reset ();
    expect (ownershipDeletes == 3);
    expect (*ownershipCache.find (generationA, "same", "fragment") == 13);
    ownershipCache.clear (generationA);
    expect (ownershipDeletes == 4);

    int reusedAddress = 0;
    RenderResourceGenerationRegistry registry;
    const auto firstGeneration = registry.registerContext (&reusedAddress);
    expect (registry.retireContext (&reusedAddress) == firstGeneration);
    const auto secondGeneration = registry.registerContext (&reusedAddress);
    expect (secondGeneration > firstGeneration);
    expect (registry.retireContext (&reusedAddress) == secondGeneration);
    expect (registry.retireContext (&reusedAddress) == 0);

    RenderResourceGenerationRegistry exhausted (
        std::numeric_limits<std::uint64_t>::max ()
    );
    int finalContext = 0;
    int overflowContext = 0;
    expect (exhausted.registerContext (&finalContext)
        == std::numeric_limits<std::uint64_t>::max ());
    bool overflowFailedClosed = false;
    try { static_cast<void> (exhausted.registerContext (&overflowContext)); }
    catch (const std::overflow_error&) { overflowFailedClosed = true; }
    expect (overflowFailedClosed);

    std::cout << "render program cache: generations, gaps, LRU, isolation, active ownership, teardown, and overflow passed\n";
}
