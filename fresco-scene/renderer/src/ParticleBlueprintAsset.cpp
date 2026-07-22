#include "FrescoScene/ParticleBlueprintCache.h"

#include "WallpaperEngine/Data/Model/Project.h"

namespace FrescoScene {
namespace {

thread_local ParticleBlueprintResolutionScope* activeResolution = nullptr;

}

ParticleBlueprintResolutionScope::ParticleBlueprintResolutionScope (
    ImmutableJSONBlueprintCache& cache,
    const void* owner,
    const WallpaperEngine::Data::Model::Project& project
) :
    m_cache (&cache),
    m_owner (owner),
    m_project (&project),
    m_previous (activeResolution) {
    activeResolution = this;
}

ParticleBlueprintResolutionScope::~ParticleBlueprintResolutionScope () {
    activeResolution = m_previous;
}

std::shared_ptr<const ImmutableJSONBlueprintCache::JSON>
loadParticleBlueprintAsset (
    const WallpaperEngine::Data::Model::Project& project,
    const std::string& assetIdentity
) {
    const auto loader = [&project] (const std::string& path) {
        return project.assetLocator->readString (path);
    };
    if (activeResolution == nullptr || activeResolution->m_project != &project) {
        return std::make_shared<const ImmutableJSONBlueprintCache::JSON> (
            ImmutableJSONBlueprintCache::JSON::parse (loader (assetIdentity))
        );
    }
    return activeResolution->m_cache->load (
        activeResolution->m_owner,
        project.assetLocator.get (),
        assetIdentity,
        loader
    );
}

}
