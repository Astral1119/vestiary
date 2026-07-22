#include "FrescoScene/SceneScriptStorage.h"

#include <cmath>
#include <map>
#include <type_traits>
#include <utility>

namespace FrescoScene {

struct SceneScriptStorage::Impl {
    std::map<std::string, SceneScriptStorageValue, std::less<>> values;
    std::size_t bytes = 0;
};

namespace {

std::size_t valueByteSize (const SceneScriptStorageValue &value) {
    return std::visit ([] (const auto &item) -> std::size_t {
        using Item = std::decay_t<decltype (item)>;
        if constexpr (std::is_same_v<Item, bool>) {
            return 1;
        } else if constexpr (std::is_same_v<Item, double>) {
            return sizeof (double);
        } else if constexpr (std::is_same_v<Item, std::string>) {
            return item.size ();
        } else {
            return 3 * sizeof (double);
        }
    }, value);
}

bool isFinite (const SceneScriptStorageValue &value) {
    return std::visit ([] (const auto &item) {
        using Item = std::decay_t<decltype (item)>;
        if constexpr (std::is_same_v<Item, double>) {
            return std::isfinite (item);
        } else if constexpr (std::is_same_v<Item, SceneScriptStorageVec3>) {
            return std::isfinite (item.x)
                && std::isfinite (item.y)
                && std::isfinite (item.z);
        } else {
            return true;
        }
    }, value);
}

}

SceneScriptStorage::SceneScriptStorage ()
    : impl_ (std::make_unique<Impl> ()) {}

SceneScriptStorage::SceneScriptStorage (SceneScriptStorage &&) noexcept = default;

SceneScriptStorage &SceneScriptStorage::operator= (
    SceneScriptStorage &&
) noexcept = default;

SceneScriptStorage::~SceneScriptStorage () = default;

SceneScriptStorage::Impl &SceneScriptStorage::impl () {
    if (!impl_) {
        impl_ = std::make_unique<Impl> ();
    }
    return *impl_;
}

const SceneScriptStorage::Impl &SceneScriptStorage::impl () const {
    static const Impl empty;
    if (!impl_) {
        return empty;
    }
    return *impl_;
}

SceneScriptStorageSetResult SceneScriptStorage::set (
    std::string key,
    SceneScriptStorageValue value
) {
    if (key.empty ()) {
        return SceneScriptStorageSetResult::emptyKey;
    }
    if (key.size () > maxKeyBytes) {
        return SceneScriptStorageSetResult::keyTooLong;
    }
    if (const auto *text = std::get_if<std::string> (&value);
        text != nullptr && text->size () > maxStringBytes) {
        return SceneScriptStorageSetResult::stringTooLong;
    }
    if (!isFinite (value)) {
        return SceneScriptStorageSetResult::nonFinite;
    }

    auto &storage = impl ();
    const auto existing = storage.values.find (key);
    if (existing == storage.values.end () && storage.values.size () >= maxKeys) {
        return SceneScriptStorageSetResult::keyLimit;
    }

    const auto previousBytes = existing == storage.values.end ()
        ? 0
        : existing->first.size () + valueByteSize (existing->second);
    const auto newBytes = key.size () + valueByteSize (value);
    const auto projectedBytes = storage.bytes - previousBytes + newBytes;
    if (projectedBytes > maxProjectBytes) {
        return SceneScriptStorageSetResult::projectLimit;
    }

    storage.values.insert_or_assign (std::move (key), std::move (value));
    storage.bytes = projectedBytes;
    return SceneScriptStorageSetResult::stored;
}

std::optional<SceneScriptStorageValue> SceneScriptStorage::get (
    std::string_view key
) const {
    const auto &storage = impl ();
    const auto found = storage.values.find (key);
    if (found == storage.values.end ()) {
        return std::nullopt;
    }
    return found->second;
}

bool SceneScriptStorage::contains (std::string_view key) const {
    return impl ().values.contains (key);
}

std::vector<std::pair<std::string, SceneScriptStorageValue>>
SceneScriptStorage::snapshot () const {
    const auto &values = impl ().values;
    return {values.begin (), values.end ()};
}

bool SceneScriptStorage::erase (std::string_view key) {
    auto &storage = impl ();
    const auto found = storage.values.find (key);
    if (found == storage.values.end ()) {
        return false;
    }
    storage.bytes -= found->first.size () + valueByteSize (found->second);
    storage.values.erase (found);
    return true;
}

void SceneScriptStorage::clear () {
    auto &storage = impl ();
    storage.values.clear ();
    storage.bytes = 0;
}

std::size_t SceneScriptStorage::keyCount () const {
    return impl ().values.size ();
}

std::size_t SceneScriptStorage::byteSize () const {
    return impl ().bytes;
}

}
