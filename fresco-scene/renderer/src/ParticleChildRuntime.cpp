#include "FrescoScene/ParticleChildRuntime.h"

#include "FrescoScene/ParticleBlueprintCache.h"
#include "FrescoScene/ParticleCompatibility.h"
#include "WallpaperEngine/Data/JSON.h"
#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Data/Parsers/ObjectParser.h"
#include "WallpaperEngine/Logging/Log.h"
#include "WallpaperEngine/Render/Objects/CParticle.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>

using WallpaperEngine::Data::JSON::JSON;
using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Data::Model::ObjectUniquePtr;
using WallpaperEngine::Data::Model::Particle;
using WallpaperEngine::Data::Model::ParticleChild;
using WallpaperEngine::Data::Parsers::ObjectParser;
using WallpaperEngine::Render::Objects::CParticle;
using WallpaperEngine::Render::Objects::ParticleInstance;

namespace FrescoScene {
namespace {

struct ChildInstance {
    ObjectUniquePtr model;
    std::unique_ptr<CParticle> renderer;
    std::uint64_t parentSerial = 0;
    std::uint32_t renderedFrames = 0;
    bool disabled = false;
    bool followObserved = false;
};

struct ChildDeclarationState {
    ParticleChildContract contract;
    const ParticleChild* definition = nullptr;
    std::uint32_t ordinal = 0;
    std::shared_ptr<const JSON> objectBlueprint;
    std::shared_ptr<ImmutableJSONBlueprintCache> assetBlueprints;
    const void* blueprintOwner = nullptr;
    std::map<std::uint64_t, ChildInstance> instances;
    std::set<std::uint64_t> previousLiveParticles;
};

struct ParentState {
    std::shared_ptr<ImmutableJSONBlueprintCache> assetBlueprints;
    std::vector<ChildDeclarationState> declarations;
};

std::map<CParticle*, ParentState> states;
int nextChildObjectID = -1000000;

bool traceEnabled () {
    static const bool enabled = std::getenv ("FRESCO_PARTICLE_CHILD_TRACE") != nullptr;
    return enabled;
}

const char* typeName (ParticleChildType type) {
    switch (type) {
    case ParticleChildType::staticSystem: return "static";
    case ParticleChildType::eventFollow: return "eventfollow";
    case ParticleChildType::eventSpawn: return "eventspawn";
    case ParticleChildType::unsupported: return "unsupported";
    }
    return "unsupported";
}

void trace (
    const char* event,
    const ChildDeclarationState& declaration,
    std::uint64_t serial = 0,
    std::size_t active = 0,
    std::size_t maximum = 0
) {
    if (!traceEnabled ()) {
        return;
    }
    std::cerr << "particle-child|" << event
              << "|" << typeName (declaration.contract.type)
              << "|" << declaration.ordinal
              << "|" << declaration.contract.path
              << "|" << serial
              << "|" << active
              << "|" << (maximum == 0 ? declaration.definition->maxCount : maximum)
              << '\n';
}

float probabilitySample (std::uint64_t serial, int childID, std::uint32_t ordinal) {
    std::uint64_t value = serial ^ (static_cast<std::uint64_t> (
        static_cast<std::uint32_t> (childID)
    ) << 32U) ^ ordinal;
    value += 0x9e3779b97f4a7c15ULL;
    value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
    value ^= value >> 31U;
    return static_cast<float> (value >> 40U) / static_cast<float> (1U << 24U);
}

int childKey (const ParticleChild& child) {
    std::uint32_t value = 2166136261U;
    for (const unsigned char character : child.particleFile) {
        value = (value ^ character) * 16777619U;
    }
    return static_cast<int> (value);
}

glm::vec3 childOrigin (
    const CParticle& parent,
    const ParticleChild& child,
    const ParticleInstance* particle
) {
    glm::vec3 result = parent.getParticle ().origin->value->getVec3 () + child.origin;
    if (particle != nullptr) {
        result += glm::vec3 (
            particle->position.x,
            -particle->position.y,
            particle->position.z
        );
    }
    return result;
}

std::string vectorString (const glm::vec3& value) {
    return std::to_string (value.x) + " "
        + std::to_string (value.y) + " "
        + std::to_string (value.z);
}

ChildInstance makeInstance (
    CParticle& parent,
    const ChildDeclarationState& declaration,
    const ParticleInstance* particle,
    std::uint64_t serial
) {
    const ParticleChild& child = *declaration.definition;
    if (const char* failurePath = std::getenv ("FRESCO_PARTICLE_CHILD_FAIL_PATH");
        failurePath != nullptr && child.particleFile == failurePath) {
        throw std::runtime_error ("injected particle child setup failure");
    }
    const glm::vec3 origin = childOrigin (parent, child, particle);
    const glm::vec3 scale
        = parent.getParticle ().scale->value->getVec3 () * child.scale;
    const glm::vec3 angles
        = parent.getParticle ().angles->value->getVec3 () + child.angles;
    JSON layer = instantiateParticleChildObject (
        *declaration.objectBlueprint,
        nextChildObjectID--,
        vectorString (origin),
        vectorString (scale),
        vectorString (angles)
    );
    auto& project = parent.getScene ().getScene ().project;
    ParticleBlueprintResolutionScope blueprintScope (
        *declaration.assetBlueprints,
        declaration.blueprintOwner,
        project
    );
    ObjectUniquePtr model = ObjectParser::parse (layer, project);
    auto* particleModel = model->as<Particle> ();
    if (particleModel == nullptr) {
        throw std::runtime_error ("particle child definition did not parse as a particle");
    }
    trace (
        "capacity", declaration, serial, particleModel->maxCount, child.maxCount
    );
    auto renderer = std::make_unique<CParticle> (parent.getScene (), *particleModel);
    renderer->setup ();
    return {
        .model = std::move (model),
        .renderer = std::move (renderer),
        .parentSerial = serial,
    };
}

void moveInstance (
    CParticle& parent,
    const ParticleChild& child,
    ChildInstance& instance,
    const ParticleInstance& particle
) {
    auto* model = instance.model->as<Particle> ();
    model->origin->value->update (
        childOrigin (parent, child, &particle),
        DynamicValue::UpdateSource::Script
    );
}

bool accepts (
    const ParticleChild& child,
    std::uint64_t serial,
    std::uint32_t ordinal
) {
    const float probability = std::clamp (child.probability, 0.0F, 1.0F);
    return probability >= 1.0F
        || (probability > 0.0F
            && probabilitySample (serial, childKey (child), ordinal) < probability);
}

}

void setupParticleChildren (CParticle& parent) {
    if (std::getenv ("FRESCO_PARTICLE_CHILD_DISABLED") != nullptr) {
        return;
    }
    ParentState state {
        .assetBlueprints = std::make_shared<ImmutableJSONBlueprintCache> (),
    };
    std::uint32_t ordinal = 0;
    for (const auto& child : parent.getParticle ().children) {
        ChildDeclarationState declaration {
            .contract = particleChildContract (
                child.type,
                child.particleFile,
                child.maxCount
            ),
            .definition = &child,
            .ordinal = ordinal++,
            .objectBlueprint = std::make_shared<const JSON> (JSON {
                {"id", 0},
                {"name", "particle-child-" + std::to_string (childKey (child))},
                {"particle", child.particleFile},
                {"visible", true},
            }),
            .assetBlueprints = state.assetBlueprints,
            .blueprintOwner = &parent,
        };
        trace ("declaration", declaration);
        if (declaration.contract.type == ParticleChildType::staticSystem
            && declaration.contract.renderable) {
            try {
                declaration.instances.emplace (
                    0,
                    makeInstance (parent, declaration, nullptr, 0)
                );
                trace ("birth", declaration, 0, declaration.instances.size ());
            } catch (const std::exception& error) {
                trace ("failure", declaration);
                sLog.error (
                    "particle child setup disabled for ",
                    declaration.contract.path,
                    ": ",
                    error.what ()
                );
            }
        }
        state.declarations.push_back (std::move (declaration));
    }
    if (!state.declarations.empty ()) {
        states.insert_or_assign (&parent, std::move (state));
    }
}

void updateParticleChildren (
    CParticle& parent,
    const std::vector<ParticleInstance>& particles,
    std::uint32_t count
) {
    const auto found = states.find (&parent);
    if (found == states.end ()) {
        return;
    }

    std::map<std::uint64_t, const ParticleInstance*> live;
    for (std::uint32_t index = 0; index < count; ++index) {
        live.insert_or_assign (particles[index].serial, &particles[index]);
    }

    for (auto& declaration : found->second.declarations) {
        const ParticleChild& child = *declaration.definition;
        if (declaration.contract.type == ParticleChildType::eventFollow) {
            for (auto iterator = declaration.instances.begin ();
                 iterator != declaration.instances.end (); ) {
                const auto particle = live.find (iterator->first);
                if (particle == live.end ()) {
                    trace (
                        "death", declaration, iterator->first,
                        declaration.instances.size () - 1
                    );
                    iterator = declaration.instances.erase (iterator);
                } else {
                    moveInstance (parent, child, iterator->second, *particle->second);
                    if (!iterator->second.followObserved) {
                        iterator->second.followObserved = true;
                        trace (
                            "follow", declaration, iterator->first,
                            declaration.instances.size ()
                        );
                    }
                    ++iterator;
                }
            }
        } else if (declaration.contract.type == ParticleChildType::eventSpawn) {
            for (auto iterator = declaration.instances.begin ();
                 iterator != declaration.instances.end (); ) {
                if (iterator->second.renderedFrames > 2
                    && (iterator->second.disabled
                        || !iterator->second.renderer->hasLiveParticles ())) {
                    trace (
                        "death", declaration, iterator->first,
                        declaration.instances.size () - 1
                    );
                    iterator = declaration.instances.erase (iterator);
                } else {
                    ++iterator;
                }
            }
        } else {
            continue;
        }

        for (const auto& [serial, particle] : live) {
            if (declaration.previousLiveParticles.contains (serial)) {
                continue;
            }
            if (declaration.instances.size ()
                    >= static_cast<std::size_t> (child.maxCount)
                || !accepts (child, serial, declaration.ordinal)) {
                trace ("rejected", declaration, serial, declaration.instances.size ());
                continue;
            }
            try {
                declaration.instances.emplace (
                    serial,
                    makeInstance (parent, declaration, particle, serial)
                );
                trace (
                    "birth", declaration, serial, declaration.instances.size ()
                );
            } catch (const std::exception& error) {
                trace ("failure", declaration, serial, declaration.instances.size ());
                sLog.error (
                    "particle child setup disabled for ",
                    declaration.contract.path,
                    ": ",
                    error.what ()
                );
            }
        }
        const bool liveSetChanged
            = declaration.previousLiveParticles.size () != live.size ()
            || std::ranges::any_of (live, [&declaration] (const auto& entry) {
                return !declaration.previousLiveParticles.contains (entry.first);
            });
        if (liveSetChanged) {
            trace (
                "bookkeeping", declaration, 0, live.size (),
                parent.getParticle ().maxCount
            );
        }
        declaration.previousLiveParticles.clear ();
        for (const auto& [serial, particle] : live) {
            static_cast<void> (particle);
            declaration.previousLiveParticles.insert (serial);
        }
    }
}

void renderParticleChildren (CParticle& parent) {
    const auto found = states.find (&parent);
    if (found == states.end ()) {
        return;
    }
    for (auto& declaration : found->second.declarations) {
        for (auto& [serial, instance] : declaration.instances) {
            static_cast<void> (serial);
            if (instance.disabled) {
                continue;
            }
            try {
                instance.renderer->render ();
            } catch (const std::exception& error) {
                instance.disabled = true;
                sLog.error (
                    "particle child render disabled for ",
                    declaration.contract.path,
                    ": ",
                    error.what ()
                );
            }
            ++instance.renderedFrames;
        }
    }
}

void destroyParticleChildren (CParticle& parent) {
    const auto found = states.find (&parent);
    if (found != states.end ()) {
        for (const auto& declaration : found->second.declarations) {
            trace ("teardown", declaration, 0, declaration.instances.size ());
        }
    }
    states.erase (&parent);
}

}
