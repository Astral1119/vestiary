#include "FrescoScene/TextWidthLimit.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

int main () {
    using FrescoScene::TextWidthLimitRequest;
    using FrescoScene::computeTextWidthLimit;

    const auto right = computeTextWidthLimit ({
        .limitWidth = true,
        .limitRows = true,
        .maxRows = 1,
        .fullWidthPixels = 300,
        .maxWidthPixels = 120,
        .alignment = "right",
    });
    assert (right.supported);
    assert (right.sourceOffsetPixels == 180);
    assert (right.widthPixels == 120);
    assert (right.quadLeft == -120.0f && right.quadRight == 0.0f);

    const auto left = computeTextWidthLimit ({
        .limitWidth = true,
        .limitRows = true,
        .maxRows = 1,
        .fullWidthPixels = 300,
        .maxWidthPixels = 120,
        .alignment = "left",
    });
    assert (left.supported);
    assert (left.sourceOffsetPixels == 0);
    assert (left.widthPixels == 120);
    assert (left.quadLeft == 0.0f && left.quadRight == 120.0f);

    const auto empty = computeTextWidthLimit ({
        .limitWidth = true,
        .limitRows = true,
        .maxRows = 1,
        .fullWidthPixels = 300,
        .maxWidthPixels = 0,
        .alignment = "right",
    });
    assert (empty.supported);
    assert (empty.sourceOffsetPixels == 300);
    assert (empty.widthPixels == 0);
    assert (empty.quadLeft == 0.0f && empty.quadRight == 0.0f);

    for (const auto request : {
             TextWidthLimitRequest {
                 .limitWidth = true, .limitRows = true, .useEllipsis = true,
                 .maxRows = 1, .fullWidthPixels = 300, .maxWidthPixels = 120,
                 .alignment = "right",
             },
             TextWidthLimitRequest {
                 .limitWidth = true, .limitRows = true, .maxRows = 2,
                 .fullWidthPixels = 300, .maxWidthPixels = 120,
                 .alignment = "right",
             },
             TextWidthLimitRequest {
                 .limitWidth = true, .limitRows = true, .maxRows = 1,
                 .fullWidthPixels = 300, .maxWidthPixels = 120,
                 .alignment = "center",
             },
             TextWidthLimitRequest {
                 .limitWidth = true, .limitRows = true, .maxRows = 1,
                 .fullWidthPixels = 300, .maxWidthPixels = -1,
                 .alignment = "right",
             },
         }) {
        const auto result = computeTextWidthLimit (request);
        assert (!result.supported);
        assert (!result.diagnostic.empty ());
    }

    assert (FrescoScene::singleTextRow ("title\r\nignored") == "title");
}
