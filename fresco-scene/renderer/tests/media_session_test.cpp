#include "FrescoScene/MediaSession.h"
#include "RuntimeMediaSource.h"

#include <cstdlib>
#include <string>
#include <vector>

using namespace FrescoScene;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    const std::string artwork =
        "data:image/png;base64,"
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY"
        "42YAAAAASUVORK5CYII=";
    RuntimeMediaSource source;
    std::vector<std::string> metadata;
    std::size_t thumbnails = 0;
    const auto removeMetadata = source.addMetadataListener (
        [&metadata] (const auto& info) {
            metadata.push_back (
                info.title + "|" + info.artist + "|" + info.album
            );
        }
    );
    const auto removeThumbnail = source.addAlbumArtListener (
        [&thumbnails] (const auto&) { ++thumbnails; }
    );

    require (contains (source.apply ({
        .kind = MediaSessionEventKind::status,
        .available = true,
    }), MediaSessionChange::status));
    require (contains (source.apply ({
        .kind = MediaSessionEventKind::properties,
        .title = "Full Moon Full Life",
        .artist = "Azumi Takahashi",
        .album = "Persona 3 Reload",
    }), MediaSessionChange::properties));
    require (contains (source.apply ({
        .kind = MediaSessionEventKind::playback,
        .playback = MediaPlaybackState::playing,
    }), MediaSessionChange::playback));
    require (contains (source.apply ({
        .kind = MediaSessionEventKind::timeline,
        .positionSeconds = 12.5,
        .durationSeconds = 240.0,
    }), MediaSessionChange::timeline));
    require (contains (source.apply ({
        .kind = MediaSessionEventKind::thumbnail,
        .thumbnail = MediaThumbnail {
            .uri = artwork,
            .primaryColor = "#112233",
            .secondaryColor = "#000000",
            .tertiaryColor = "#445566",
            .textColor = "#ffffff",
            .highContrastColor = "white",
        },
    }), MediaSessionChange::thumbnail));

    const auto& snapshot = source.snapshot ();
    require (snapshot.available);
    require (snapshot.playback == MediaPlaybackState::playing);
    require (snapshot.title == "Full Moon Full Life");
    require (snapshot.positionSeconds == 12.5);
    require (snapshot.durationSeconds == 240.0);
    require (snapshot.thumbnail->primaryColor == "#112233");
    require (source.artwork ().current != nullptr);
    require (source.artwork ().revision == 1);
    require (snapshot.revision == 5);
    require (metadata.size () == 4);
    require (thumbnails == 1);

    const auto acceptedArtwork = source.artwork ().current;
    require (contains (source.apply ({
        .kind = MediaSessionEventKind::thumbnail,
        .thumbnail = MediaThumbnail {
            .uri = "data:image/png;base64,rejected-artwork",
        },
    }), MediaSessionChange::thumbnail));
    require (source.artwork ().current == acceptedArtwork);
    require (source.artwork ().uri == artwork);
    require (source.artwork ().revision == 1);
    require (
        source.artwork ().lastError.code == MediaArtworkErrorCode::invalidBase64
    );
    require (source.evidence ().artworkErrors == 1);

    const auto unchanged = source.apply ({
        .kind = MediaSessionEventKind::properties,
        .title = "Full Moon Full Life",
        .artist = "Azumi Takahashi",
        .album = "Persona 3 Reload",
    });
    require (unchanged == MediaSessionChange::none);
    require (source.snapshot ().revision == 6);
    require (source.evidence ().events == 7);
    require (source.evidence ().eventsByKind[2] == 2);

    require (contains (source.apply ({
        .kind = MediaSessionEventKind::thumbnail,
        .thumbnail = std::nullopt,
    }), MediaSessionChange::thumbnail));
    require (source.artwork ().current == nullptr);
    require (source.artwork ().previous == nullptr);
    require (source.artwork ().revision == 2);
    require (source.evidence ().artworkUpdates == 1);
    require (source.evidence ().artworkClears == 1);

    const auto stopped = source.apply ({
        .kind = MediaSessionEventKind::status,
        .available = false,
    });
    require (contains (stopped, MediaSessionChange::status));
    require (contains (stopped, MediaSessionChange::playback));
    require (source.snapshot ().playback == MediaPlaybackState::stopped);

    removeThumbnail ();
    removeMetadata ();
}
