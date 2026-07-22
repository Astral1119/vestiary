#include "FrescoScene/ScopedStencilState.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using FrescoScene::ScopedStencilState;
using FrescoScene::StencilAttachment;
using FrescoScene::StencilAttachmentObjectType;
using FrescoScene::StencilFace;
using FrescoScene::StencilFaceState;
using FrescoScene::StencilStateAPI;
using FrescoScene::StencilStateSnapshot;

const StencilFaceState sentinelFront {
    11, -7, 0x12345678U, 21, 22, 23, 0x0F0F0F0FU
};

const StencilFaceState sentinelBack {
    31, 19, 0x87654321U, 41, 42, 43, 0xF0F0F0F0U
};

class RecordingAPI final : public StencilStateAPI {
public:
    StencilStateSnapshot state {
        true,
        sentinelFront,
        sentinelBack,
        73,
        { true, false, true, false },
        true,
        41,
        { StencilAttachmentObjectType::renderbuffer, 52 },
        63,
    };
    bool complete = true;
    mutable std::vector<std::string> calls;
    std::vector<std::array<std::int32_t, 3>> allocations;

    bool stencilEnabled () const noexcept override {
        calls.push_back ("query-enabled");
        return state.enabled;
    }

    StencilFaceState stencilFaceState (StencilFace face) const noexcept override {
        calls.push_back (face == StencilFace::front ? "query-front" : "query-back");
        return face == StencilFace::front ? state.front : state.back;
    }

    std::int32_t stencilClearValue () const noexcept override {
        calls.push_back ("query-clear-value");
        return state.clearValue;
    }

    std::array<bool, 4> colorWriteMask () const noexcept override {
        calls.push_back ("query-color-mask");
        return state.colorWriteMask;
    }

    bool scissorEnabled () const noexcept override {
        calls.push_back ("query-scissor");
        return state.scissorEnabled;
    }

    std::uint32_t drawFramebuffer () const noexcept override {
        calls.push_back ("query-framebuffer");
        return state.drawFramebuffer;
    }

    StencilAttachment drawFramebufferStencilAttachment () const noexcept override {
        calls.push_back ("query-attachment");
        return state.attachment;
    }

    std::uint32_t boundRenderbuffer () const noexcept override {
        calls.push_back ("query-renderbuffer");
        return state.boundRenderbuffer;
    }

    void setStencilEnabled (bool enabled) noexcept override {
        calls.push_back (enabled ? "enable" : "disable");
        state.enabled = enabled;
    }

    void setStencilFunction (
        StencilFace face, std::uint32_t function, std::int32_t reference,
        std::uint32_t valueMask
    ) noexcept override {
        calls.push_back (face == StencilFace::front ? "front-function" : "back-function");
        auto& value = faceState (face);
        value.function = function;
        value.reference = reference;
        value.valueMask = valueMask;
    }

    void setStencilOperation (
        StencilFace face, std::uint32_t stencilFail, std::uint32_t depthFail,
        std::uint32_t depthPass
    ) noexcept override {
        calls.push_back (face == StencilFace::front ? "front-operation" : "back-operation");
        auto& value = faceState (face);
        value.stencilFail = stencilFail;
        value.depthFail = depthFail;
        value.depthPass = depthPass;
    }

    void setStencilWriteMask (
        StencilFace face, std::uint32_t writeMask
    ) noexcept override {
        calls.push_back (face == StencilFace::front ? "front-mask" : "back-mask");
        faceState (face).writeMask = writeMask;
    }

    void setStencilClearValue (std::int32_t value) noexcept override {
        calls.push_back ("clear-value");
        state.clearValue = value;
    }

    void setColorWriteMask (std::array<bool, 4> mask) noexcept override {
        calls.push_back ("color-mask");
        state.colorWriteMask = mask;
    }

    void setScissorEnabled (bool enabled) noexcept override {
        calls.push_back (enabled ? "scissor-enable" : "scissor-disable");
        state.scissorEnabled = enabled;
    }

    void clearStencilBuffer () noexcept override {
        calls.push_back ("clear-stencil-buffer");
    }

    void bindDrawFramebuffer (std::uint32_t framebuffer) noexcept override {
        calls.push_back ("bind-framebuffer:" + std::to_string (framebuffer));
        state.drawFramebuffer = framebuffer;
    }

    void bindRenderbuffer (std::uint32_t renderbuffer) noexcept override {
        calls.push_back ("bind-renderbuffer:" + std::to_string (renderbuffer));
        state.boundRenderbuffer = renderbuffer;
    }

    void allocateStencil8Storage (
        std::int32_t width, std::int32_t height
    ) noexcept override {
        calls.push_back (
            "allocate:" + std::to_string (width) + "x" + std::to_string (height)
        );
        allocations.push_back ({
            static_cast<std::int32_t> (state.boundRenderbuffer), width, height
        });
    }

    void setDrawFramebufferStencilAttachment (
        StencilAttachment attachment
    ) noexcept override {
        calls.push_back (
            "attach:" + std::to_string (static_cast<int> (attachment.objectType))
            + ":" + std::to_string (attachment.objectName)
        );
        state.attachment = attachment;
    }

    bool drawFramebufferComplete () const noexcept override {
        calls.push_back ("check-complete");
        return complete;
    }

    void mutateInsideScope () {
        state.enabled = false;
        state.front = { 101, 102, 103, 104, 105, 106, 107 };
        state.back = { 201, 202, 203, 204, 205, 206, 207 };
        state.clearValue = 208;
        state.colorWriteMask = { false, false, false, false };
        state.scissorEnabled = false;
        state.drawFramebuffer = 209;
        state.boundRenderbuffer = 210;
    }

    bool sentinelDrawPasses (const StencilStateSnapshot& expected) const {
        return state == expected;
    }

private:
    StencilFaceState& faceState (StencilFace face) noexcept {
        return face == StencilFace::front ? state.front : state.back;
    }
};

void testSnapshotAttachmentCompletenessAndRestoreOrder () {
    RecordingAPI api;
    const StencilStateSnapshot sentinel = api.state;
    {
        ScopedStencilState scope (api, 77, 320, 180);
        assert (scope.snapshot () == sentinel);
        assert (api.state.attachment == sentinel.attachment);
        assert (api.state.boundRenderbuffer == sentinel.boundRenderbuffer);
        api.mutateInsideScope ();
    }

    assert (api.sentinelDrawPasses (sentinel));
    const std::vector<std::array<std::int32_t, 3>> expectedAllocations {
        { 77, 320, 180 }
    };
    assert (api.allocations == expectedAllocations);
    const std::vector<std::string> expected {
        "query-enabled",
        "query-front",
        "query-back",
        "query-clear-value",
        "query-color-mask",
        "query-scissor",
        "query-framebuffer",
        "query-attachment",
        "query-renderbuffer",
        "bind-renderbuffer:77",
        "allocate:320x180",
        "bind-renderbuffer:63",
        "attach:2:77",
        "check-complete",
        "attach:2:52",
        "bind-framebuffer:41",
        "attach:2:52",
        "front-function",
        "front-operation",
        "front-mask",
        "back-function",
        "back-operation",
        "back-mask",
        "clear-value",
        "color-mask",
        "scissor-enable",
        "enable",
        "bind-renderbuffer:63",
    };
    assert (api.calls == expected);
}

void testResizeAndRenderbufferSentinel () {
    RecordingAPI api;
    api.state.attachment = {
        StencilAttachmentObjectType::renderbuffer, 88
    };
    const StencilStateSnapshot sentinel = api.state;
    {
        ScopedStencilState first (api, 77, 320, 180);
    }
    api.calls.clear ();
    {
        ScopedStencilState resized (api, 77, 640, 360);
    }
    const std::vector<std::array<std::int32_t, 3>> expectedAllocations {
        { 77, 320, 180 }, { 77, 640, 360 }
    };
    assert (api.allocations == expectedAllocations);
    assert (api.sentinelDrawPasses (sentinel));
}

void testNoAttachmentAndDisabledState () {
    RecordingAPI api;
    api.state.enabled = false;
    api.state.attachment = {};
    const StencilStateSnapshot sentinel = api.state;
    {
        ScopedStencilState scope (api, 77, 1, 1);
        api.mutateInsideScope ();
    }
    assert (api.sentinelDrawPasses (sentinel));
    assert (api.calls[api.calls.size () - 2] == "disable");
}

void testIncompleteFramebufferRollsBack () {
    RecordingAPI api;
    api.complete = false;
    const StencilStateSnapshot sentinel = api.state;
    bool threw = false;
    try {
        ScopedStencilState scope (api, 77, 320, 180);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    assert (threw);
    assert (api.sentinelDrawPasses (sentinel));
}

void testMaskPhasesRestoreOuterStateBetweenPartsAndIgnoreScissorForClear () {
    RecordingAPI api;
    const StencilStateSnapshot sentinel = api.state;
    ScopedStencilState scope (api, 77, 320, 180);
    api.calls.clear ();

    scope.beginMaskWrite ();
    assert (!api.state.colorWriteMask[0]);
    const auto clear = std::find (
        api.calls.begin (), api.calls.end (), "clear-stencil-buffer"
    );
    assert (clear != api.calls.end ());
    assert (*(clear - 1) == "scissor-disable");
    assert (*(clear + 1) == "scissor-enable");

    scope.beginMaskedDraw ();
    assert (api.state.colorWriteMask == sentinel.colorWriteMask);
    assert (api.state.enabled);
    scope.restorePipelineState ();
    assert (api.state.enabled == sentinel.enabled);
    assert (api.state.front == sentinel.front);
    assert (api.state.back == sentinel.back);
    assert (api.state.colorWriteMask == sentinel.colorWriteMask);
    assert (api.state.scissorEnabled == sentinel.scissorEnabled);
    assert (api.state.attachment == sentinel.attachment);
}

void testNestedScopeRestoresRenderbufferOuterAttachment () {
    RecordingAPI api;
    api.state.attachment = { StencilAttachmentObjectType::renderbuffer, 88 };
    const StencilStateSnapshot outer = api.state;
    {
        ScopedStencilState first (api, 77, 320, 180);
        first.beginMaskWrite ();
        const StencilStateSnapshot innerOuter = api.state;
        {
            ScopedStencilState second (api, 99, 320, 180);
            second.beginMaskWrite ();
            second.beginMaskedDraw ();
        }
        assert (api.state == innerOuter);
    }
    assert (api.state == outer);
}

void testTextureAttachmentIsRejectedWithoutMutation () {
    RecordingAPI api;
    api.state.attachment = { StencilAttachmentObjectType::texture, 52 };
    const StencilStateSnapshot sentinel = api.state;
    bool threw = false;
    try {
        ScopedStencilState scope (api, 77, 320, 180);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    assert (threw);
    assert (api.state == sentinel);
    assert (api.allocations.empty ());
}

void testInvalidInputsDoNotMutateState () {
    for (const auto input : std::array<std::array<std::int32_t, 3>, 3> {{
             { 0, 320, 180 }, { 77, 0, 180 }, { 77, 320, -1 }
         }}) {
        RecordingAPI api;
        const StencilStateSnapshot sentinel = api.state;
        bool threw = false;
        try {
            ScopedStencilState scope (
                api, static_cast<std::uint32_t> (input[0]), input[1], input[2]
            );
        } catch (const std::invalid_argument&) {
            threw = true;
        }
        assert (threw);
        assert (api.calls.empty ());
        assert (api.sentinelDrawPasses (sentinel));
    }
}

} // namespace

int main () {
    testSnapshotAttachmentCompletenessAndRestoreOrder ();
    testResizeAndRenderbufferSentinel ();
    testNoAttachmentAndDisabledState ();
    testIncompleteFramebufferRollsBack ();
    testMaskPhasesRestoreOuterStateBetweenPartsAndIgnoreScissorForClear ();
    testNestedScopeRestoresRenderbufferOuterAttachment ();
    testTextureAttachmentIsRejectedWithoutMutation ();
    testInvalidInputsDoNotMutateState ();
}
