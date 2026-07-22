#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace WallpaperEngine::VideoPlayback::MPV {
class MemoryStreamProtocol {
public:
    MemoryStreamProtocol (const char* bytes, std::size_t size) :
        m_bytes (
            reinterpret_cast<const std::uint8_t*> (bytes),
            reinterpret_cast<const std::uint8_t*> (bytes) + size
        ) { }

    [[nodiscard]] const std::uint8_t* data () const { return m_bytes.data (); }
    [[nodiscard]] std::size_t size () const { return m_bytes.size (); }

private:
    std::vector<std::uint8_t> m_bytes;
};

using MemoryStreamProtocolUniquePtr = std::unique_ptr<MemoryStreamProtocol>;
}
