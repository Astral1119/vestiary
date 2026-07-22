#pragma once

#include <cstddef>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <tuple>
#include <utility>

namespace FrescoScene {

class ShaderTranslationCache {
public:
    using Result = std::pair<std::string, std::string>;
    using Translator = std::function<Result ()>;

    explicit ShaderTranslationCache (std::size_t maximumEntries = 128);

    [[nodiscard]] Result resolve (
        const std::string& backendTarget,
        const std::string& vertexStage,
        const std::string& vertexSource,
        const std::string& fragmentStage,
        const std::string& fragmentSource,
        const Translator& translator
    );
    void clear ();

    [[nodiscard]] std::size_t size () const;

private:
    using Key = std::tuple<
        std::string,
        std::string,
        std::string,
        std::string,
        std::string
    >;

    struct Entry {
        Result result;
        std::size_t access = 0;
    };

    void trimLocked ();

    std::size_t m_maximumEntries;
    mutable std::mutex m_mutex;
    std::map<Key, Entry> m_entries;
    std::size_t m_access = 0;
};

[[nodiscard]] ShaderTranslationCache& shaderTranslationCache ();
void clearShaderTranslationCache ();

}
