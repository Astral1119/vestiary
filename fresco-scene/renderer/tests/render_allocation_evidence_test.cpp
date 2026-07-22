#include "FrescoScene/RenderAllocationEvidence.h"

#include <stdexcept>
#include <vector>

namespace {

void expect (bool condition) {
    if (!condition) {
        throw std::runtime_error ("render allocation ownership assertion failed");
    }
}

struct Value {
    explicit Value (int value) : value (value) { }
    int value;
};

struct ThrowingOwner {
    ThrowingOwner ()
        : value (FrescoScene::makeTrackedRenderUnique<Value> (
              FrescoScene::RenderAllocationKind::shader, 7
          )) {
        throw std::runtime_error ("injected construction failure");
    }

    FrescoScene::TrackedRenderUniquePtr<Value> value;
};

}

int main () {
    const auto before = FrescoScene::renderAllocationEvidence ();

    for (int cycle = 0; cycle < 1'000; ++cycle) {
        auto shader = FrescoScene::makeTrackedRenderUnique<Value> (
            FrescoScene::RenderAllocationKind::shader, cycle
        );
        auto uniform = FrescoScene::makeTrackedRenderShared<Value> (
            FrescoScene::RenderAllocationKind::copiedUniformValue, cycle
        );
        auto copy = uniform;
        expect (shader->value == cycle && copy->value == cycle);
    }

    try {
        ThrowingOwner owner;
        static_cast<void> (owner);
    } catch (const std::runtime_error&) { }

    const auto after = FrescoScene::renderAllocationEvidence ();
    expect (after.shaders.live == before.shaders.live);
    expect (after.copiedUniformValues.live == before.copiedUniformValues.live);
    expect (after.shaders.allocations - before.shaders.allocations == 1'001);
    expect (after.shaders.deallocations - before.shaders.deallocations == 1'001);
    expect (
        after.copiedUniformValues.allocations
            - before.copiedUniformValues.allocations
        == 1'000
    );
    expect (
        after.copiedUniformValues.deallocations
            - before.copiedUniformValues.deallocations
        == 1'000
    );
}
