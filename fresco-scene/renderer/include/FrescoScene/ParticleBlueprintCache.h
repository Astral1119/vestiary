#pragma once

#include "WallpaperEngine/Data/JSON.h"

#include <cstddef>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>

namespace WallpaperEngine::Data::Model {
struct Project;
}

namespace FrescoScene {

class ImmutableJSONBlueprintCache {
public:
    using JSON = WallpaperEngine::Data::JSON::JSON;
    using Loader = std::function<std::string (const std::string&)>;

    explicit ImmutableJSONBlueprintCache (std::size_t maximumEntries = 128);

    [[nodiscard]] std::shared_ptr<const JSON> load (
        const void* owner,
        const void* assetSource,
        const std::string& assetIdentity,
        const Loader& loader
    );

    [[nodiscard]] std::size_t size () const;

private:
    using Key = std::tuple<const void*, const void*, std::string>;

    struct Entry {
        std::shared_ptr<const JSON> blueprint;
        std::size_t access = 0;
    };

    void trimLocked ();

    std::size_t m_maximumEntries;
    mutable std::mutex m_mutex;
    std::map<Key, Entry> m_entries;
    std::size_t m_access = 0;
};

class ParticleBlueprintResolutionScope {
public:
    ParticleBlueprintResolutionScope (
        ImmutableJSONBlueprintCache& cache,
        const void* owner,
        const WallpaperEngine::Data::Model::Project& project
    );
    ~ParticleBlueprintResolutionScope ();

    ParticleBlueprintResolutionScope (const ParticleBlueprintResolutionScope&) = delete;
    ParticleBlueprintResolutionScope& operator= (const ParticleBlueprintResolutionScope&) = delete;

private:
    friend std::shared_ptr<const ImmutableJSONBlueprintCache::JSON>
    loadParticleBlueprintAsset (
        const WallpaperEngine::Data::Model::Project&,
        const std::string&
    );

    ImmutableJSONBlueprintCache* m_cache;
    const void* m_owner;
    const WallpaperEngine::Data::Model::Project* m_project;
    ParticleBlueprintResolutionScope* m_previous = nullptr;
};

[[nodiscard]] ImmutableJSONBlueprintCache::JSON instantiateParticleChildObject (
    const ImmutableJSONBlueprintCache::JSON& blueprint,
    int objectID,
    const std::string& origin,
    const std::string& scale,
    const std::string& angles
);

[[nodiscard]] std::shared_ptr<const ImmutableJSONBlueprintCache::JSON>
loadParticleBlueprintAsset (
    const WallpaperEngine::Data::Model::Project& project,
    const std::string& assetIdentity
);

}
