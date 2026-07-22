#include "FrescoScene/ParticleBlueprintCache.h"

#include <iostream>
#include <stdexcept>
#include <string>

using FrescoScene::ImmutableJSONBlueprintCache;
using FrescoScene::instantiateParticleChildObject;

namespace {

void expect (bool condition) {
    if (!condition) {
        throw std::runtime_error ("particle blueprint cache assertion failed");
    }
}

}

int main () {
    ImmutableJSONBlueprintCache cache (2);
    int ownerA = 0;
    int ownerB = 0;
    int assetsA = 0;
    int assetsB = 0;
    int loads = 0;
    std::string value = R"({"generation":1,"values":[1,2,3]})";
    const auto loader = [&] (const std::string&) {
        ++loads;
        return value;
    };

    const auto first = cache.load (&ownerA, &assetsA, "particle.json", loader);
    const auto repeated = cache.load (&ownerA, &assetsA, "particle.json", loader);
    expect (first == repeated);
    expect (loads == 1);

    const auto otherOwner = cache.load (&ownerB, &assetsA, "particle.json", loader);
    expect (otherOwner != first);
    expect (loads == 2);

    const auto otherAssets = cache.load (&ownerA, &assetsB, "particle.json", loader);
    expect (otherAssets != first);
    expect (cache.size () == 2);

    value = R"({"generation":2})";
    ImmutableJSONBlueprintCache reloadGeneration (2);
    const auto reloaded = reloadGeneration.load (
        &ownerA, &assetsA, "particle.json", loader
    );
    expect ((*reloaded)["generation"] == 2);

    int failedLoads = 0;
    try {
        static_cast<void> (cache.load (
            &ownerA,
            &assetsA,
            "broken.json",
            [&failedLoads] (const std::string&) -> std::string {
                ++failedLoads;
                throw std::runtime_error ("injected load failure");
            }
        ));
    } catch (const std::runtime_error&) {
    }
    expect (failedLoads == 1);
    expect (cache.size () <= 2);

    const ImmutableJSONBlueprintCache::JSON objectBlueprint = {
        {"id", 0},
        {"particle", "particle.json"},
        {"visible", true},
    };
    auto instanceA = instantiateParticleChildObject (
        objectBlueprint, -1, "1 2 3", "1 1 1", "0 0 0"
    );
    auto instanceB = instantiateParticleChildObject (
        objectBlueprint, -2, "4 5 6", "2 2 2", "0 90 0"
    );
    instanceA["visible"] = false;
    expect (objectBlueprint["id"] == 0);
    expect (objectBlueprint["visible"] == true);
    expect (instanceA["id"] == -1);
    expect (instanceB["id"] == -2);
    expect (instanceB["visible"] == true);
    expect (instanceA["origin"] != instanceB["origin"]);

    std::cout << "particle blueprint cache: identity, bounds, reload, unwind, and fresh objects passed\n";
}
