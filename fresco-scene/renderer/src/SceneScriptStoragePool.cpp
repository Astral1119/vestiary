#include "FrescoScene/SceneScriptStoragePool.h"

#include <map>
#include <stdexcept>
#include <utility>

namespace FrescoScene {

struct SceneScriptStoragePool::State {
    struct Entry {
        SceneScriptStorage storage;
        std::size_t leaseCount = 0;
        std::size_t lastUsed = 0;
    };

    std::map<std::string, Entry, std::less<>> entries;
    std::size_t clock = 0;

    [[nodiscard]] std::size_t totalByteSize () const {
        std::size_t total = 0;
        for (const auto &[identity, entry] : entries) {
            static_cast<void> (identity);
            total += entry.storage.byteSize ();
        }
        return total;
    }
};

SceneScriptStoragePool::Lease::Lease (
    std::shared_ptr<State> state,
    std::string identity
) : state_ (std::move (state)), identity_ (std::move (identity)) {}

SceneScriptStoragePool::Lease::Lease (Lease &&other) noexcept
    : state_ (std::move (other.state_)),
      identity_ (std::move (other.identity_)) {}

SceneScriptStoragePool::Lease &SceneScriptStoragePool::Lease::operator= (
    Lease &&other
) noexcept {
    if (this != &other) {
        release ();
        state_ = std::move (other.state_);
        identity_ = std::move (other.identity_);
    }
    return *this;
}

SceneScriptStoragePool::Lease::~Lease () {
    release ();
}

SceneScriptStorage &SceneScriptStoragePool::Lease::storage () const {
    if (!state_) {
        throw std::logic_error ("access through released storage lease");
    }
    return state_->entries.at (identity_).storage;
}

SceneScriptStorage *SceneScriptStoragePool::Lease::operator-> () const {
    return &storage ();
}

const std::string &SceneScriptStoragePool::Lease::canonicalIdentity () const {
    return identity_;
}

void SceneScriptStoragePool::Lease::release () {
    if (!state_) {
        return;
    }
    const auto found = state_->entries.find (identity_);
    if (found != state_->entries.end () && found->second.leaseCount > 0) {
        --found->second.leaseCount;
    }
    state_.reset ();
    identity_.clear ();
}

SceneScriptStoragePool::SceneScriptStoragePool ()
    : state_ (std::make_shared<State> ()) {}

std::optional<SceneScriptStoragePool::Lease>
SceneScriptStoragePool::leaseCanonical (std::string canonicalIdentity) {
    if (canonicalIdentity.empty ()
        || canonicalIdentity.find ('\0') != std::string::npos) {
        return std::nullopt;
    }

    if (auto found = state_->entries.find (canonicalIdentity);
        found != state_->entries.end ()) {
        ++found->second.leaseCount;
        found->second.lastUsed = ++state_->clock;
        return Lease (state_, std::move (canonicalIdentity));
    }

    while (state_->entries.size () >= maxIdentities
        || state_->totalByteSize () > maxPoolBytes) {
        auto victim = state_->entries.end ();
        for (auto candidate = state_->entries.begin ();
            candidate != state_->entries.end ();
            ++candidate) {
            if (candidate->second.leaseCount == 0
                && (victim == state_->entries.end ()
                    || candidate->second.lastUsed
                        < victim->second.lastUsed)) {
                victim = candidate;
            }
        }
        if (victim == state_->entries.end ()) {
            return std::nullopt;
        }
        state_->entries.erase (victim);
    }

    State::Entry entry;
    entry.leaseCount = 1;
    entry.lastUsed = ++state_->clock;
    state_->entries.emplace (canonicalIdentity, std::move (entry));
    return Lease (state_, std::move (canonicalIdentity));
}

std::size_t SceneScriptStoragePool::identityCount () const {
    return state_->entries.size ();
}

std::size_t SceneScriptStoragePool::totalByteSize () const {
    return state_->totalByteSize ();
}

}
