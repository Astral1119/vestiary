#include "FrescoScene/TextEffectRegistry.h"

#include "WallpaperEngine/Data/Model/Object.h"

#include <algorithm>
#include <map>
#include <utility>

namespace FrescoScene {
namespace {

using EffectMap = std::map<
    int, std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>
>;

std::map<std::uint64_t, EffectMap> registries;
std::map<const WallpaperEngine::Render::Wallpapers::CScene*, std::uint64_t>
    sceneOwners;
std::uint64_t activeOwner = 0;
std::uint64_t nextOwner = 1;
const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr> empty;

const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>& findEffects (
    std::uint64_t owner, int objectId
) {
    const auto registry = registries.find (owner);
    if (registry == registries.end ()) {
        return empty;
    }
    const auto result = registry->second.find (objectId);
    return result == registry->second.end () ? empty : result->second;
}

}

TextEffectRegistrySession::TextEffectRegistrySession () : m_id (nextOwner++) {
    registries.try_emplace (m_id);
}

TextEffectRegistrySession::~TextEffectRegistrySession () {
    registries.erase (m_id);
    std::erase_if (sceneOwners, [this] (const auto& entry) {
        return entry.second == m_id;
    });
    if (activeOwner == m_id) {
        activeOwner = 0;
    }
}

void TextEffectRegistrySession::activate () const { activeOwner = m_id; }

void TextEffectRegistrySession::bindScene (
    const WallpaperEngine::Render::Wallpapers::CScene* scene
) const {
    if (scene != nullptr) {
        sceneOwners.insert_or_assign (scene, m_id);
    }
}

void registerTextEffects (
    int objectId,
    std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr> effects
) {
    if (activeOwner != 0) {
        registries[activeOwner].insert_or_assign (objectId, std::move (effects));
    }
}

const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>&
textEffects (int objectId) {
    return findEffects (activeOwner, objectId);
}

const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>&
textEffects (
    const WallpaperEngine::Render::Wallpapers::CScene* scene,
    int objectId
) {
    const auto owner = sceneOwners.find (scene);
    return owner == sceneOwners.end () ? empty : findEffects (owner->second, objectId);
}

}
