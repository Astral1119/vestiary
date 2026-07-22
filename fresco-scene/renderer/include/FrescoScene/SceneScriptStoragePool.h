#pragma once

#include "FrescoScene/SceneScriptStorage.h"

#include <cstddef>
#include <memory>
#include <optional>
#include <string>

namespace FrescoScene {

class SceneScriptStoragePool {
private:
    struct State;

public:
    static constexpr std::size_t maxIdentities = 32;
    static constexpr std::size_t maxPoolBytes = 2 * 1024 * 1024;

    class Lease {
    public:
        Lease (Lease &&other) noexcept;
        Lease &operator= (Lease &&other) noexcept;
        Lease (const Lease &) = delete;
        Lease &operator= (const Lease &) = delete;
        ~Lease ();

        SceneScriptStorage &storage () const;
        SceneScriptStorage *operator-> () const;
        [[nodiscard]] const std::string &canonicalIdentity () const;

    private:
        friend class SceneScriptStoragePool;

        Lease (std::shared_ptr<State> state, std::string identity);
        void release ();

        std::shared_ptr<State> state_;
        std::string identity_;
    };

    SceneScriptStoragePool ();

    // The caller owns filesystem or package canonicalization policy. Equal
    // canonical identity strings always address the same retained storage.
    [[nodiscard]] std::optional<Lease> leaseCanonical (
        std::string canonicalIdentity
    );

    [[nodiscard]] std::size_t identityCount () const;
    [[nodiscard]] std::size_t totalByteSize () const;

private:
    std::shared_ptr<State> state_;
};

}
