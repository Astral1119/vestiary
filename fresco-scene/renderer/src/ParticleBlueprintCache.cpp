#include "FrescoScene/ParticleBlueprintCache.h"

#include <algorithm>
#include <stdexcept>
#include <utility>

namespace FrescoScene {

ImmutableJSONBlueprintCache::ImmutableJSONBlueprintCache (
    std::size_t maximumEntries
) : m_maximumEntries (maximumEntries) {
    if (maximumEntries == 0) {
        throw std::invalid_argument ("blueprint cache capacity must be positive");
    }
}

std::shared_ptr<const ImmutableJSONBlueprintCache::JSON>
ImmutableJSONBlueprintCache::load (
    const void* owner,
    const void* assetSource,
    const std::string& assetIdentity,
    const Loader& loader
) {
    if (owner == nullptr || assetSource == nullptr || assetIdentity.empty ()) {
        throw std::invalid_argument ("blueprint cache identity must be complete");
    }

    const Key key { owner, assetSource, assetIdentity };
    {
        std::scoped_lock lock (m_mutex);
        if (const auto found = m_entries.find (key); found != m_entries.end ()) {
            found->second.access = ++m_access;
            return found->second.blueprint;
        }
    }

    auto parsed = std::make_shared<const JSON> (JSON::parse (loader (assetIdentity)));

    std::scoped_lock lock (m_mutex);
    if (const auto found = m_entries.find (key); found != m_entries.end ()) {
        found->second.access = ++m_access;
        return found->second.blueprint;
    }
    m_entries.emplace (key, Entry { .blueprint = parsed, .access = ++m_access });
    trimLocked ();
    return parsed;
}

std::size_t ImmutableJSONBlueprintCache::size () const {
    std::scoped_lock lock (m_mutex);
    return m_entries.size ();
}

void ImmutableJSONBlueprintCache::trimLocked () {
    while (m_entries.size () > m_maximumEntries) {
        const auto oldest = std::ranges::min_element (
            m_entries,
            {},
            [] (const auto& entry) { return entry.second.access; }
        );
        m_entries.erase (oldest);
    }
}

ImmutableJSONBlueprintCache::JSON instantiateParticleChildObject (
    const ImmutableJSONBlueprintCache::JSON& blueprint,
    int objectID,
    const std::string& origin,
    const std::string& scale,
    const std::string& angles
) {
    auto instance = blueprint;
    instance["id"] = objectID;
    instance["origin"] = origin;
    instance["scale"] = scale;
    instance["angles"] = angles;
    return instance;
}

}
