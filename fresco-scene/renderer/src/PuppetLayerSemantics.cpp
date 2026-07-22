#include "FrescoScene/PuppetLayerSemantics.h"

#include <mutex>
#include <unordered_map>

namespace FrescoScene {
namespace {

std::mutex semanticsMutex;
std::unordered_map<const WallpaperEngine::Data::Model::ImageAnimationLayer*, bool> semantics;
std::unordered_map<const WallpaperEngine::Data::Model::Object*, std::string> attachments;

}

void clearPuppetLayerSemantics () {
    const std::scoped_lock lock (semanticsMutex);
    semantics.clear ();
    attachments.clear ();
}

void registerPuppetLayerSemantics (
    const WallpaperEngine::Data::Model::ImageAnimationLayer* layer, bool additive
) {
    const std::scoped_lock lock (semanticsMutex);
    semantics[layer] = additive;
}

bool puppetLayerIsAdditive (
    const WallpaperEngine::Data::Model::ImageAnimationLayer* layer
) {
    const std::scoped_lock lock (semanticsMutex);
    const auto found = semantics.find (layer);
    return found != semantics.end () && found->second;
}

void registerPuppetAttachment (
    const WallpaperEngine::Data::Model::Object* object, std::string attachment
) {
    const std::scoped_lock lock (semanticsMutex);
    if (attachment.empty ()) {
        attachments.erase (object);
    } else {
        attachments[object] = std::move (attachment);
    }
}

std::string puppetAttachment (
    const WallpaperEngine::Data::Model::Object* object
) {
    const std::scoped_lock lock (semanticsMutex);
    const auto found = attachments.find (object);
    return found == attachments.end () ? std::string {} : found->second;
}

}
