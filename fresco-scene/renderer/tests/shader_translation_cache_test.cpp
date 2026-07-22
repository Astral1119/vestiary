#include "FrescoScene/ShaderTranslationCache.h"

#include <atomic>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using FrescoScene::ShaderTranslationCache;

namespace {

void expect (bool condition) {
    if (!condition) {
        throw std::runtime_error (
            "shader translation cache assertion failed"
        );
    }
}

ShaderTranslationCache::Result translated (
    const std::string& suffix,
    int& translationCount
) {
    ++translationCount;
    return { "translated vertex " + suffix, "translated fragment " + suffix };
}

}

int main () {
    ShaderTranslationCache cache (2);
    int translationCount = 0;

    const auto first = cache.resolve (
        "angle-metal-es3",
        "vertex",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("first", translationCount); }
    );
    const auto hit = cache.resolve (
        "angle-metal-es3",
        "vertex",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("unexpected", translationCount); }
    );
    expect (first == hit);
    expect (translationCount == 1);

    const auto otherBackend = cache.resolve (
        "native-opengl-410",
        "vertex",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("native", translationCount); }
    );
    expect (otherBackend != first);
    expect (translationCount == 2);

    const auto otherStage = cache.resolve (
        "native-opengl-410",
        "geometry",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("other stage", translationCount); }
    );
    expect (otherStage != otherBackend);
    expect (translationCount == 3);

    static_cast<void> (cache.resolve (
        "angle-metal-es3",
        "vertex",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("unexpected", translationCount); }
    ));
    static_cast<void> (cache.resolve (
        "angle-metal-es3",
        "vertex",
        "second vertex source",
        "fragment",
        "second fragment source",
        [&] { return translated ("second", translationCount); }
    ));
    expect (cache.size () == 2);
    static_cast<void> (cache.resolve (
        "native-opengl-410",
        "vertex",
        "vertex source",
        "fragment",
        "fragment source",
        [&] { return translated ("native after eviction", translationCount); }
    ));
    expect (translationCount == 6);

    int failureCount = 0;
    ShaderTranslationCache failureCache (2);
    const auto failure = failureCache.resolve (
        "angle-metal-es3",
        "vertex",
        "bad vertex",
        "fragment",
        "bad fragment",
        [&] {
            ++failureCount;
            return ShaderTranslationCache::Result { "", "" };
        }
    );
    const auto cachedFailure = failureCache.resolve (
        "angle-metal-es3",
        "vertex",
        "bad vertex",
        "fragment",
        "bad fragment",
        [&] {
            ++failureCount;
            return translated ("unexpected recovery", translationCount);
        }
    );
    expect (failure == cachedFailure);
    expect (failure.first.empty () && failure.second.empty ());
    expect (failureCount == 1);

    int unwindCount = 0;
    try {
        static_cast<void> (failureCache.resolve (
            "angle-metal-es3",
            "vertex",
            "throwing vertex",
            "fragment",
            "throwing fragment",
            [&] () -> ShaderTranslationCache::Result {
                ++unwindCount;
                throw std::runtime_error ("translator failed");
            }
        ));
        expect (false);
    } catch (const std::runtime_error&) {
    }
    expect (failureCache.size () == 1);
    const auto recovered = failureCache.resolve (
        "angle-metal-es3",
        "vertex",
        "throwing vertex",
        "fragment",
        "throwing fragment",
        [&] {
            ++unwindCount;
            return translated ("recovered", translationCount);
        }
    );
    expect (!recovered.first.empty () && !recovered.second.empty ());
    expect (unwindCount == 2);

    ShaderTranslationCache concurrentCache (2);
    std::atomic<int> concurrentTranslations = 0;
    std::atomic<int> concurrentFailures = 0;
    std::vector<std::thread> threads;
    for (int index = 0; index < 8; ++index) {
        threads.emplace_back ([&] {
            const auto result = concurrentCache.resolve (
                "angle-metal-es3",
                "vertex",
                "shared vertex",
                "fragment",
                "shared fragment",
                [&] {
                    ++concurrentTranslations;
                    return ShaderTranslationCache::Result {
                        "shared translated vertex",
                        "shared translated fragment"
                    };
                }
            );
            if (result.first != "shared translated vertex"
                || result.second != "shared translated fragment") {
                ++concurrentFailures;
            }
        });
    }
    for (auto& thread : threads) {
        thread.join ();
    }
    expect (concurrentTranslations == 1);
    expect (concurrentFailures == 0);

    failureCache.clear ();
    expect (failureCache.size () == 0);

    std::cout
        << "shader translation cache: hits, isolation, LRU, failures, unwind, and concurrency passed\n";
}
