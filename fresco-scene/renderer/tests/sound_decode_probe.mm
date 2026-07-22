#include "WallpaperEngine/Audio/AudioContext.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

int main (int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) {
            std::cerr << "usage: sound-decode-probe FILE...\n";
            return 2;
        }
        auto backend = WallpaperEngine::Audio::makeAVAudioPlayerBackend ();
        try {
            for (int index = 1; index < argc; ++index) {
                std::ifstream input (argv[index], std::ios::binary);
                if (!input) {
                    throw std::runtime_error ("cannot open " + std::string (argv[index]));
                }
                const std::vector<std::uint8_t> data {
                    std::istreambuf_iterator<char> (input),
                    std::istreambuf_iterator<char> ()
                };
                auto player = backend->createPlayer (data);
                player->setLooping (false);
                player->setVolume (0.5F);
            }
        } catch (const std::exception& error) {
            std::cerr << error.what () << '\n';
            return 1;
        }
        std::cout << "decoded " << (argc - 1) << " authored sound assets\n";
        return 0;
    }
}
