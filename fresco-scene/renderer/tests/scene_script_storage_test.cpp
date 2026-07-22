#include "FrescoScene/SceneScriptStorage.h"
#include "FrescoScene/SceneScriptStoragePool.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>
#include <cstddef>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using FrescoScene::SceneScriptStorage;
using FrescoScene::SceneScriptStoragePool;
using FrescoScene::SceneScriptStorageSetResult;
using FrescoScene::SceneScriptStorageValue;
using FrescoScene::SceneScriptStorageVec3;

namespace {

void expectStored (
    SceneScriptStorage &storage,
    std::string key,
    SceneScriptStorageValue value
) {
    assert (storage.set (std::move (key), std::move (value))
        == SceneScriptStorageSetResult::stored);
}

void fillProjectQuota (SceneScriptStorage &storage) {
    for (std::size_t index = 0; index < 15; ++index) {
        const auto key = std::string ("k")
            + static_cast<char> ('a' + index)
            + "0";
        expectStored (storage, key, std::string (4096, 'x'));
    }
    expectStored (storage, "kp0", std::string (4048, 'y'));
    assert (storage.byteSize () == SceneScriptStorage::maxProjectBytes);
}

void testValueAndEntryQuotas () {
    SceneScriptStorage storage;
    assert (storage.set ("", true)
        == SceneScriptStorageSetResult::emptyKey);
    expectStored (storage, "empty", std::string ());
    assert (storage.byteSize () == 5);

    SceneScriptStorage keyStorage;
    expectStored (keyStorage, std::string (128, 'k'), true);
    assert (keyStorage.set (std::string (129, 'k'), true)
        == SceneScriptStorageSetResult::keyTooLong);

    SceneScriptStorage stringStorage;
    expectStored (stringStorage, "text", std::string (4096, 'x'));
    assert (stringStorage.set ("too-long", std::string (4097, 'x'))
        == SceneScriptStorageSetResult::stringTooLong);

    SceneScriptStorage countStorage;
    for (std::size_t index = 0; index < 64; ++index) {
        expectStored (countStorage, "key-" + std::to_string (index), true);
    }
    assert (countStorage.keyCount () == 64);
    assert (countStorage.set ("key-64", true)
        == SceneScriptStorageSetResult::keyLimit);
    expectStored (countStorage, "key-0", false);

    SceneScriptStorage projectStorage;
    fillProjectQuota (projectStorage);
    assert (projectStorage.set ("kp0", std::string (4049, 'y'))
        == SceneScriptStorageSetResult::projectLimit);
    assert (projectStorage.byteSize () == SceneScriptStorage::maxProjectBytes);
    assert (std::get<std::string> (*projectStorage.get ("kp0")).size ()
        == 4048);
}

void testFiniteTypedValues () {
    SceneScriptStorage storage;
    expectStored (storage, "bool", true);
    expectStored (storage, "double", 3.5);
    expectStored (storage, "string", std::string ("value"));
    expectStored (storage, "vec3", SceneScriptStorageVec3 {1.0, 2.0, 3.0});

    assert (std::get<bool> (*storage.get ("bool")));
    assert (std::get<double> (*storage.get ("double")) == 3.5);
    assert (std::get<std::string> (*storage.get ("string")) == "value");
    assert (std::get<SceneScriptStorageVec3> (*storage.get ("vec3"))
        == (SceneScriptStorageVec3 {1.0, 2.0, 3.0}));

    const auto nan = std::numeric_limits<double>::quiet_NaN ();
    const auto infinity = std::numeric_limits<double>::infinity ();
    assert (storage.set ("double", nan)
        == SceneScriptStorageSetResult::nonFinite);
    assert (storage.set ("bad-vec", SceneScriptStorageVec3 {1.0, infinity, 3.0})
        == SceneScriptStorageSetResult::nonFinite);
    assert (std::get<double> (*storage.get ("double")) == 3.5);

    assert (storage.contains ("string"));
    assert (storage.erase ("string"));
    assert (!storage.contains ("string"));
    assert (!storage.erase ("missing"));
    storage.clear ();
    assert (storage.keyCount () == 0);
    assert (storage.byteSize () == 0);
}

void testIdentityRetentionAndIsolation () {
    SceneScriptStoragePool pool;
    assert (!pool.leaseCanonical (""));
    assert (!pool.leaseCanonical (std::string ("bad\0identity", 12)));

    {
        auto first = pool.leaseCanonical ("project-a");
        auto same = pool.leaseCanonical ("project-a");
        auto other = pool.leaseCanonical ("project-b");
        assert (first && same && other);
        expectStored (first->storage (), "answer", 42.0);
        assert (std::get<double> (*same->storage ().get ("answer")) == 42.0);
        assert (!other->storage ().contains ("answer"));
        assert (first->canonicalIdentity () == "project-a");
    }

    auto retained = pool.leaseCanonical ("project-a");
    assert (retained);
    assert (std::get<double> (*retained->storage ().get ("answer")) == 42.0);
}

void testPoolCapacityAndUnleasedEviction () {
    SceneScriptStoragePool pool;
    std::vector<std::optional<SceneScriptStoragePool::Lease>> leases;
    leases.reserve (SceneScriptStoragePool::maxIdentities);
    for (std::size_t index = 0;
        index < SceneScriptStoragePool::maxIdentities;
        ++index) {
        auto lease = pool.leaseCanonical ("full-" + std::to_string (index));
        assert (lease);
        fillProjectQuota (lease->storage ());
        leases.emplace_back (std::move (*lease));
    }
    assert (pool.identityCount () == SceneScriptStoragePool::maxIdentities);
    assert (pool.totalByteSize () == SceneScriptStoragePool::maxPoolBytes);
    assert (!pool.leaseCanonical ("full-overflow"));

    leases[0].reset ();
    auto replacement = pool.leaseCanonical ("full-replacement");
    assert (replacement);
    assert (pool.identityCount () == SceneScriptStoragePool::maxIdentities);
    assert (pool.totalByteSize ()
        == SceneScriptStoragePool::maxPoolBytes
            - SceneScriptStorage::maxProjectBytes);

    leases[1].reset ();
    replacement.reset ();
    auto evicted = pool.leaseCanonical ("full-0");
    assert (evicted);
    assert (evicted->storage ().keyCount () == 0);
}

void testLeastRecentlyUsedChoice () {
    SceneScriptStoragePool pool;
    std::vector<std::optional<SceneScriptStoragePool::Lease>> leases;
    leases.reserve (SceneScriptStoragePool::maxIdentities);
    for (std::size_t index = 0;
        index < SceneScriptStoragePool::maxIdentities;
        ++index) {
        auto lease = pool.leaseCanonical ("lru-" + std::to_string (index));
        assert (lease);
        expectStored (lease->storage (), "marker", static_cast<double> (index));
        leases.emplace_back (std::move (*lease));
    }

    leases[0].reset ();
    leases[1].reset ();
    auto touched = pool.leaseCanonical ("lru-0");
    assert (touched);
    touched.reset ();

    auto newcomer = pool.leaseCanonical ("lru-new");
    assert (newcomer);
    auto retained = pool.leaseCanonical ("lru-0");
    assert (retained);
    assert (std::get<double> (*retained->storage ().get ("marker")) == 0.0);

    leases[2].reset ();
    auto evicted = pool.leaseCanonical ("lru-1");
    assert (evicted);
    assert (!evicted->storage ().contains ("marker"));
}

}

int main () {
    testValueAndEntryQuotas ();
    testFiniteTypedValues ();
    testIdentityRetentionAndIsolation ();
    testPoolCapacityAndUnleasedEviction ();
    testLeastRecentlyUsedChoice ();
}
