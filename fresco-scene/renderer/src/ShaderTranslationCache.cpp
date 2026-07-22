#include "FrescoScene/ShaderTranslationCache.h"

#include <stdexcept>

namespace FrescoScene {

ShaderTranslationCache::ShaderTranslationCache (
    std::size_t maximumEntries
) : m_maximumEntries (maximumEntries) {
    if (maximumEntries == 0) {
        throw std::invalid_argument (
            "shader translation cache capacity must be positive"
        );
    }
}

ShaderTranslationCache::Result ShaderTranslationCache::resolve (
    const std::string& backendTarget,
    const std::string& vertexStage,
    const std::string& vertexSource,
    const std::string& fragmentStage,
    const std::string& fragmentSource,
    const Translator& translator
) {
    if (!translator) {
        throw std::invalid_argument ("shader translator must be present");
    }

    const Key key {
        backendTarget,
        vertexStage,
        vertexSource,
        fragmentStage,
        fragmentSource
    };
    std::scoped_lock lock (m_mutex);
    const auto found = m_entries.find (key);
    if (found != m_entries.end ()) {
        found->second.access = ++m_access;
        return found->second.result;
    }

    Result result = translator ();
    m_entries.emplace (
        key,
        Entry { .result = result, .access = ++m_access }
    );
    trimLocked ();
    return result;
}

void ShaderTranslationCache::clear () {
    std::scoped_lock lock (m_mutex);
    m_entries.clear ();
}

std::size_t ShaderTranslationCache::size () const {
    std::scoped_lock lock (m_mutex);
    return m_entries.size ();
}

void ShaderTranslationCache::trimLocked () {
    while (m_entries.size () > m_maximumEntries) {
        auto oldest = m_entries.end ();
        for (auto iterator = m_entries.begin (); iterator != m_entries.end (); ++iterator) {
            if (oldest == m_entries.end ()
                || iterator->second.access < oldest->second.access) {
                oldest = iterator;
            }
        }
        m_entries.erase (oldest);
    }
}

ShaderTranslationCache& shaderTranslationCache () {
    // GLSLContext explicitly clears this registry during its own static
    // teardown. Keep the empty registry alive so destruction order cannot
    // make that teardown call target an already-destroyed function static.
    static auto* cache = new ShaderTranslationCache ();
    return *cache;
}

void clearShaderTranslationCache () {
    shaderTranslationCache ().clear ();
}

}
