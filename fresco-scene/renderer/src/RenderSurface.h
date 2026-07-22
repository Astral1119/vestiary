#pragma once

#include "FrescoScene/RenderBackend.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace FrescoScene {

struct SurfaceConfiguration {
    double x = 0.0;
    double y = 0.0;
    double width = 1280.0;
    double height = 720.0;
};

struct SurfaceDisplayEvidence {
    int logicalWidth = 0;
    int logicalHeight = 0;
    int pixelWidth = 0;
    int pixelHeight = 0;
    int scaleMilli = 0;
    int maximumRefreshMilliHertz = 0;
    std::string colorSpace;
};

class RenderSurface {
public:
    virtual ~RenderSurface () = default;

    [[nodiscard]] virtual const BackendIdentity& identity () const = 0;
    [[nodiscard]] virtual int width () const = 0;
    [[nodiscard]] virtual int height () const = 0;
    [[nodiscard]] virtual const SurfaceDisplayEvidence& displayEvidence () const = 0;
    [[nodiscard]] virtual bool ordered () const = 0;
    [[nodiscard]] virtual int windowLevel () const = 0;
    [[nodiscard]] virtual void* getProcAddress (const char* name) const = 0;
    virtual void makeCurrent () = 0;
    virtual void update () = 0;
    virtual void present () = 0;
    virtual void setVisible (bool visible) = 0;
    virtual void completeFrame (bool wait) = 0;
    [[nodiscard]] virtual std::vector<uint8_t> readFrontRGBA () = 0;
};

[[nodiscard]] std::unique_ptr<RenderSurface> createRenderSurface (
    RenderBackend backend,
    const SurfaceConfiguration& configuration
);

}
