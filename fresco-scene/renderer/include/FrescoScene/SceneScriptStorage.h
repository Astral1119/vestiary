#pragma once

#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace FrescoScene {

struct SceneScriptStorageVec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    bool operator== (const SceneScriptStorageVec3 &) const = default;
};

using SceneScriptStorageValue = std::variant<
    bool,
    double,
    std::string,
    SceneScriptStorageVec3
>;

enum class SceneScriptStorageSetResult {
    stored,
    emptyKey,
    keyTooLong,
    stringTooLong,
    nonFinite,
    keyLimit,
    projectLimit,
};

class SceneScriptStorage {
public:
    static constexpr std::size_t maxKeys = 64;
    static constexpr std::size_t maxKeyBytes = 128;
    static constexpr std::size_t maxStringBytes = 4 * 1024;
    static constexpr std::size_t maxProjectBytes = 64 * 1024;

    SceneScriptStorage ();
    SceneScriptStorage (SceneScriptStorage &&) noexcept;
    SceneScriptStorage &operator= (SceneScriptStorage &&) noexcept;
    SceneScriptStorage (const SceneScriptStorage &) = delete;
    SceneScriptStorage &operator= (const SceneScriptStorage &) = delete;
    ~SceneScriptStorage ();

    [[nodiscard]] SceneScriptStorageSetResult set (
        std::string key,
        SceneScriptStorageValue value
    );
    [[nodiscard]] std::optional<SceneScriptStorageValue> get (
        std::string_view key
    ) const;
    [[nodiscard]] bool contains (std::string_view key) const;
    [[nodiscard]] std::vector<
        std::pair<std::string, SceneScriptStorageValue>
    > snapshot () const;
    bool erase (std::string_view key);
    void clear ();

    [[nodiscard]] std::size_t keyCount () const;
    [[nodiscard]] std::size_t byteSize () const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    Impl &impl ();
    const Impl &impl () const;
};

}
