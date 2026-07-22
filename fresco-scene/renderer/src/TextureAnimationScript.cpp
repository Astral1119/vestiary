#include "FrescoScene/TextureAnimationScript.h"

#include <iterator>
#include <map>
#include <mutex>

namespace FrescoScene {
namespace {

std::mutex frameMutex;
std::map<std::pair<const void*, int>, uint32_t> frames;

}

bool setScriptedTextureAnimationFrame (
    const void* scene, int objectId, uint32_t frame
) {
    const std::lock_guard lock (frameMutex);
    const auto key = std::pair (scene, objectId);
    const auto current = frames.find (key);
    if (current != frames.end () && current->second == frame) {
        return false;
    }
    frames.insert_or_assign (key, frame);
    return true;
}

std::optional<uint32_t> scriptedTextureAnimationFrame (
    const void* scene, int objectId
) {
    const std::lock_guard lock (frameMutex);
    const auto frame = frames.find (std::pair (scene, objectId));
    return frame == frames.end () ? std::nullopt
                                 : std::optional<uint32_t> (frame->second);
}

void clearScriptedTextureAnimationFrame (const void* scene, int objectId) {
    const std::lock_guard lock (frameMutex);
    frames.erase (std::pair (scene, objectId));
}

void clearScriptedTextureAnimationFrames (const void* scene) {
    const std::lock_guard lock (frameMutex);
    for (auto frame = frames.begin (); frame != frames.end ();) {
        frame = frame->first.first == scene ? frames.erase (frame)
                                            : std::next (frame);
    }
}

}
