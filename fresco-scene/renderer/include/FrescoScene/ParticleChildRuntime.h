#pragma once

#include <cstdint>
#include <vector>

namespace WallpaperEngine::Render::Objects {
class CParticle;
struct ParticleInstance;
}

namespace FrescoScene {

void setupParticleChildren (
    WallpaperEngine::Render::Objects::CParticle& parent
);
void updateParticleChildren (
    WallpaperEngine::Render::Objects::CParticle& parent,
    const std::vector<WallpaperEngine::Render::Objects::ParticleInstance>& particles,
    std::uint32_t count
);
void renderParticleChildren (
    WallpaperEngine::Render::Objects::CParticle& parent
);
void destroyParticleChildren (
    WallpaperEngine::Render::Objects::CParticle& parent
);

}
