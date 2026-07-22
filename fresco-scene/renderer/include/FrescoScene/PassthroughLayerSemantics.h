#pragma once

namespace FrescoScene {

// copybackground controls whether passthrough layers seed their effect chain
// with the current scene. A false value starts the chain transparent instead.
[[nodiscard]] bool shouldCopyPassthroughBackground (
    bool passthrough,
    bool copyBackground
);

}
