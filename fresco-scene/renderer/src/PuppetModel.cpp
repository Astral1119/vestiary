#include "FrescoScene/PuppetModel.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <string_view>

namespace FrescoScene {
namespace {

constexpr uint32_t normalFlag = 0x00000002;
constexpr uint32_t tangentFlag = 0x00000004;
constexpr uint32_t uvFlag = 0x00000008;
constexpr uint32_t uv2Flag = 0x00000020;
constexpr uint32_t extra4Flag = 0x00010000;
constexpr uint32_t skinIndicesFlag = 0x00800000;
constexpr uint32_t skinWeightsFlag = 0x01000000;

class Reader {
public:
    explicit Reader (std::span<const std::byte> data) : m_data (data) { }

    [[nodiscard]] size_t size () const { return m_data.size (); }
    [[nodiscard]] size_t tell () const { return m_offset; }

    void seek (size_t offset) {
        if (offset > size ()) {
            throw PuppetParseError ("puppet offset lies outside model");
        }
        m_offset = offset;
    }

    uint8_t u8 () { return scalar<uint8_t> (); }
    uint16_t u16 () { return scalar<uint16_t> (); }
    uint32_t u32 () { return scalar<uint32_t> (); }
    int32_t i32 () { return scalar<int32_t> (); }
    float f32 () { return scalar<float> (); }

    std::string cString () {
        const size_t start = m_offset;
        while (m_offset < size () && m_data[m_offset] != std::byte { 0 }) {
            ++m_offset;
        }
        if (m_offset == size ()) {
            throw PuppetParseError ("unterminated puppet string");
        }
        const auto* bytes = reinterpret_cast<const char*> (m_data.data () + start);
        std::string result (bytes, m_offset - start);
        ++m_offset;
        return result;
    }

    std::string fixedString (size_t count) {
        require (count);
        const auto* bytes = reinterpret_cast<const char*> (m_data.data () + m_offset);
        std::string result (bytes, count);
        m_offset += count;
        return result;
    }

    [[nodiscard]] bool hasPrefix (size_t offset, std::string_view prefix) const {
        return offset <= size () && prefix.size () <= size () - offset
            && std::memcmp (m_data.data () + offset, prefix.data (), prefix.size ()) == 0;
    }

    [[nodiscard]] uint8_t peekU8 (size_t offset) const {
        return peekScalar<uint8_t> (offset);
    }

    [[nodiscard]] uint32_t peekU32 (size_t offset) const {
        return peekScalar<uint32_t> (offset);
    }

    [[nodiscard]] std::optional<size_t> uniqueMarker (std::string_view marker, size_t start) const {
        std::optional<size_t> found;
        for (size_t offset = start; offset + marker.size () <= size (); ++offset) {
            if (std::memcmp (m_data.data () + offset, marker.data (), marker.size ()) != 0) {
                continue;
            }
            if (found.has_value ()) {
                throw PuppetParseError ("ambiguous puppet section marker");
            }
            found = offset;
        }
        return found;
    }

private:
    template<typename Value>
    Value scalar () {
        require (sizeof (Value));
        Value value;
        std::memcpy (&value, m_data.data () + m_offset, sizeof (Value));
        m_offset += sizeof (Value);
        return value;
    }

    template<typename Value>
    [[nodiscard]] Value peekScalar (size_t offset) const {
        if (offset > size () || sizeof (Value) > size () - offset) {
            throw PuppetParseError ("truncated puppet model");
        }
        Value value;
        std::memcpy (&value, m_data.data () + offset, sizeof (Value));
        return value;
    }

    void require (size_t count) const {
        if (m_offset > size () || count > size () - m_offset) {
            throw PuppetParseError ("truncated puppet model");
        }
    }

    std::span<const std::byte> m_data;
    size_t m_offset = 0;
};

std::optional<std::string_view> metadataValue (
    std::string_view metadata, std::string_view key
) {
    const std::string marker = "\"" + std::string (key) + "\"";
    const size_t field = metadata.find (marker);
    if (field == std::string_view::npos) return std::nullopt;
    if (metadata.find (marker, field + marker.size ()) != std::string_view::npos) {
        throw PuppetParseError ("duplicate puppet constraint field");
    }
    size_t cursor = field + marker.size ();
    while (cursor < metadata.size ()
        && std::isspace (static_cast<unsigned char> (metadata[cursor]))) ++cursor;
    if (cursor == metadata.size () || metadata[cursor] != ':') {
        throw PuppetParseError ("malformed puppet constraint field");
    }
    ++cursor;
    while (cursor < metadata.size ()
        && std::isspace (static_cast<unsigned char> (metadata[cursor]))) ++cursor;
    if (cursor == metadata.size ()) {
        throw PuppetParseError ("missing puppet constraint value");
    }
    if (metadata[cursor] == '"') {
        const size_t end = metadata.find ('"', cursor + 1);
        if (end == std::string_view::npos) {
            throw PuppetParseError ("unterminated puppet constraint string");
        }
        return metadata.substr (cursor + 1, end - cursor - 1);
    }
    size_t end = cursor;
    while (end < metadata.size () && metadata[end] != ',' && metadata[end] != '}') ++end;
    while (end > cursor
        && std::isspace (static_cast<unsigned char> (metadata[end - 1]))) --end;
    return metadata.substr (cursor, end - cursor);
}

std::optional<bool> metadataBool (std::string_view metadata, std::string_view key) {
    const auto value = metadataValue (metadata, key);
    if (!value.has_value () || *value == "null") return std::nullopt;
    if (*value == "true") return true;
    if (*value == "false") return false;
    throw PuppetParseError ("puppet constraint boolean has invalid value");
}

bool requiredMetadataBool (std::string_view metadata, std::string_view key) {
    const auto value = metadataBool (metadata, key);
    if (!value.has_value ()) {
        throw PuppetParseError ("simulation constraint is missing a boolean field");
    }
    return *value;
}

float requiredMetadataFloat (std::string_view metadata, std::string_view key) {
    const auto value = metadataValue (metadata, key);
    if (!value.has_value () || *value == "null") {
        throw PuppetParseError ("simulation constraint is missing a numeric field");
    }
    size_t consumed = 0;
    float result = 0.0f;
    try {
        result = std::stof (std::string (*value), &consumed);
    } catch (const std::exception&) {
        throw PuppetParseError ("simulation constraint has an invalid number");
    }
    if (consumed != value->size () || !std::isfinite (result)) {
        throw PuppetParseError ("simulation constraint has an invalid number");
    }
    return result;
}

int requiredMetadataInt (std::string_view metadata, std::string_view key) {
    const float value = requiredMetadataFloat (metadata, key);
    if (value < static_cast<float> (std::numeric_limits<int>::min ())
        || value > static_cast<float> (std::numeric_limits<int>::max ())
        || std::floor (value) != value) {
        throw PuppetParseError ("simulation constraint has a non-integer mode");
    }
    return static_cast<int> (value);
}

PuppetVec3 requiredMetadataVec3 (std::string_view metadata, std::string_view key) {
    const auto value = metadataValue (metadata, key);
    if (!value.has_value () || *value == "null") {
        throw PuppetParseError ("simulation constraint is missing a vector field");
    }
    std::string text (*value);
    size_t cursor = 0;
    PuppetVec3 result;
    float* components[] = { &result.x, &result.y, &result.z };
    for (float* component : components) {
        while (cursor < text.size ()
            && std::isspace (static_cast<unsigned char> (text[cursor]))) ++cursor;
        if (cursor == text.size ()) {
            throw PuppetParseError ("simulation constraint has a short vector");
        }
        size_t consumed = 0;
        try {
            *component = std::stof (text.substr (cursor), &consumed);
        } catch (const std::exception&) {
            throw PuppetParseError ("simulation constraint has an invalid vector");
        }
        if (consumed == 0 || !std::isfinite (*component)) {
            throw PuppetParseError ("simulation constraint has an invalid vector");
        }
        cursor += consumed;
    }
    while (cursor < text.size ()
        && std::isspace (static_cast<unsigned char> (text[cursor]))) ++cursor;
    if (cursor != text.size ()) {
        throw PuppetParseError ("simulation constraint has a long vector");
    }
    return result;
}

std::optional<PuppetSimulationConstraint> parseSimulationConstraint (
    std::string_view metadata
) {
    if (metadataBool (metadata, "se") != std::optional<bool> (true)) {
        return std::nullopt;
    }
    PuppetSimulationConstraint result {
        .mode = requiredMetadataInt (metadata, "s"),
        .rotationEnabled = requiredMetadataBool (metadata, "r"),
        .translationEnabled = requiredMetadataBool (metadata, "t"),
        .gravityEnabled = requiredMetadataBool (metadata, "ge"),
        .inverseKinematicsEnabled = requiredMetadataBool (metadata, "ik"),
        .rotationAxes = {
            requiredMetadataBool (metadata, "rax"),
            requiredMetadataBool (metadata, "ray"),
            requiredMetadataBool (metadata, "raz"),
        },
        .rotationLimited = requiredMetadataBool (metadata, "la"),
        .rotationMinimum = requiredMetadataVec3 (metadata, "lamin"),
        .rotationMaximum = requiredMetadataVec3 (metadata, "lamax"),
        .rotationFriction = requiredMetadataFloat (metadata, "rf"),
        .rotationInertia = requiredMetadataFloat (metadata, "ri"),
        .rotationStiffness = requiredMetadataFloat (metadata, "rs"),
        .tipMass = requiredMetadataFloat (metadata, "m"),
        .tipPosition = requiredMetadataVec3 (metadata, "tp"),
    };
    if (result.rotationFriction < 0.0f || result.rotationInertia < 0.0f
        || result.rotationStiffness < 0.0f || result.tipMass < 0.0f) {
        throw PuppetParseError ("simulation constraint has a negative parameter");
    }
    return result;
}

int parseVersion (const std::string& tag, std::string_view prefix) {
    if (tag.size () != 9 || tag.back () != '\0'
        || !std::string_view (tag).starts_with (prefix)) {
        throw PuppetParseError ("unsupported puppet section tag");
    }
    int result = 0;
    for (size_t index = 4; index < 8; ++index) {
        if (tag[index] < '0' || tag[index] > '9') {
            throw PuppetParseError ("invalid puppet version tag");
        }
        result = result * 10 + tag[index] - '0';
    }
    return result;
}

PuppetVec3 readVec3 (Reader& reader) {
    return { reader.f32 (), reader.f32 (), reader.f32 () };
}

PuppetMat4 readMat4 (Reader& reader) {
    PuppetMat4 result;
    for (float& value : result.values) {
        value = reader.f32 ();
    }
    return result;
}

PuppetMat4 multiply (const PuppetMat4& left, const PuppetMat4& right) {
    PuppetMat4 result;
    for (size_t column = 0; column < 4; ++column) {
        for (size_t row = 0; row < 4; ++row) {
            float value = 0.0f;
            for (size_t inner = 0; inner < 4; ++inner) {
                value += left.values[inner * 4 + row] * right.values[column * 4 + inner];
            }
            result.values[column * 4 + row] = value;
        }
    }
    return result;
}

PuppetVec3 transformPoint (const PuppetMat4& matrix, PuppetVec3 point) {
    return {
        matrix.values[0] * point.x + matrix.values[4] * point.y
            + matrix.values[8] * point.z + matrix.values[12],
        matrix.values[1] * point.x + matrix.values[5] * point.y
            + matrix.values[9] * point.z + matrix.values[13],
        matrix.values[2] * point.x + matrix.values[6] * point.y
            + matrix.values[10] * point.z + matrix.values[14],
    };
}

PuppetMat4 inverseAffine (const PuppetMat4& matrix) {
    const float a = matrix.values[0], b = matrix.values[4], c = matrix.values[8];
    const float d = matrix.values[1], e = matrix.values[5], f = matrix.values[9];
    const float g = matrix.values[2], h = matrix.values[6], i = matrix.values[10];
    const float determinant = a * (e * i - f * h) - b * (d * i - f * g)
        + c * (d * h - e * g);
    if (!std::isfinite (determinant) || std::abs (determinant) < 1.0e-8f) {
        throw PuppetParseError ("singular puppet bind transform");
    }
    const float inverseDeterminant = 1.0f / determinant;
    PuppetMat4 result = PuppetMat4::identity ();
    result.values[0] = (e * i - f * h) * inverseDeterminant;
    result.values[4] = (c * h - b * i) * inverseDeterminant;
    result.values[8] = (b * f - c * e) * inverseDeterminant;
    result.values[1] = (f * g - d * i) * inverseDeterminant;
    result.values[5] = (a * i - c * g) * inverseDeterminant;
    result.values[9] = (c * d - a * f) * inverseDeterminant;
    result.values[2] = (d * h - e * g) * inverseDeterminant;
    result.values[6] = (b * g - a * h) * inverseDeterminant;
    result.values[10] = (a * e - b * d) * inverseDeterminant;
    const PuppetVec3 translation {
        matrix.values[12], matrix.values[13], matrix.values[14]
    };
    const PuppetVec3 inverseTranslation = transformPoint (result, {
        -translation.x, -translation.y, -translation.z
    });
    result.values[12] = inverseTranslation.x;
    result.values[13] = inverseTranslation.y;
    result.values[14] = inverseTranslation.z;
    return result;
}

struct Quaternion {
    double w = 1.0;
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

Quaternion multiply (Quaternion left, Quaternion right) {
    return {
        left.w * right.w - left.x * right.x - left.y * right.y - left.z * right.z,
        left.w * right.x + left.x * right.w + left.y * right.z - left.z * right.y,
        left.w * right.y - left.x * right.z + left.y * right.w + left.z * right.x,
        left.w * right.z + left.x * right.y - left.y * right.x + left.z * right.w,
    };
}

Quaternion quaternionForAngles (PuppetVec3 angles) {
    const auto axis = [] (double angle, size_t component) {
        Quaternion result { std::cos (angle / 2.0), 0.0, 0.0, 0.0 };
        const double value = std::sin (angle / 2.0);
        if (component == 0) result.x = value;
        if (component == 1) result.y = value;
        if (component == 2) result.z = value;
        return result;
    };
    return multiply (multiply (axis (angles.z, 2), axis (angles.y, 1)), axis (angles.x, 0));
}

double rotationZ (Quaternion rotation) {
    return std::atan2 (
        2.0 * (rotation.w * rotation.z + rotation.x * rotation.y),
        1.0 - 2.0 * (rotation.y * rotation.y + rotation.z * rotation.z)
    );
}

Quaternion slerp (Quaternion left, Quaternion right, double amount) {
    double dot = left.w * right.w + left.x * right.x + left.y * right.y + left.z * right.z;
    if (dot < 0.0) {
        dot = -dot;
        right = { -right.w, -right.x, -right.y, -right.z };
    }
    if (dot > 0.9995) {
        Quaternion result {
            left.w + amount * (right.w - left.w),
            left.x + amount * (right.x - left.x),
            left.y + amount * (right.y - left.y),
            left.z + amount * (right.z - left.z),
        };
        const double length = std::sqrt (result.w * result.w + result.x * result.x
            + result.y * result.y + result.z * result.z);
        return { result.w / length, result.x / length, result.y / length, result.z / length };
    }
    const double angle = std::acos (std::clamp (dot, -1.0, 1.0));
    const double denominator = std::sin (angle);
    const double leftWeight = std::sin ((1.0 - amount) * angle) / denominator;
    const double rightWeight = std::sin (amount * angle) / denominator;
    return {
        left.w * leftWeight + right.w * rightWeight,
        left.x * leftWeight + right.x * rightWeight,
        left.y * leftWeight + right.y * rightWeight,
        left.z * leftWeight + right.z * rightWeight,
    };
}

PuppetMat4 trs (PuppetVec3 translation, Quaternion rotation, PuppetVec3 scale) {
    const double xx = rotation.x * rotation.x, yy = rotation.y * rotation.y;
    const double zz = rotation.z * rotation.z, xy = rotation.x * rotation.y;
    const double xz = rotation.x * rotation.z, yz = rotation.y * rotation.z;
    const double wx = rotation.w * rotation.x, wy = rotation.w * rotation.y;
    const double wz = rotation.w * rotation.z;
    PuppetMat4 result = PuppetMat4::identity ();
    result.values[0] = static_cast<float> ((1.0 - 2.0 * (yy + zz)) * scale.x);
    result.values[1] = static_cast<float> ((2.0 * (xy + wz)) * scale.x);
    result.values[2] = static_cast<float> ((2.0 * (xz - wy)) * scale.x);
    result.values[4] = static_cast<float> ((2.0 * (xy - wz)) * scale.y);
    result.values[5] = static_cast<float> ((1.0 - 2.0 * (xx + zz)) * scale.y);
    result.values[6] = static_cast<float> ((2.0 * (yz + wx)) * scale.y);
    result.values[8] = static_cast<float> ((2.0 * (xz + wy)) * scale.z);
    result.values[9] = static_cast<float> ((2.0 * (yz - wx)) * scale.z);
    result.values[10] = static_cast<float> ((1.0 - 2.0 * (xx + yy)) * scale.z);
    result.values[12] = translation.x;
    result.values[13] = translation.y;
    result.values[14] = translation.z;
    return result;
}

PuppetPlayMode parseMode (const std::string& mode) {
    if (mode.empty () || mode == "loop") return PuppetPlayMode::loop;
    if (mode == "mirror") return PuppetPlayMode::mirror;
    if (mode == "single") return PuppetPlayMode::single;
    throw PuppetParseError ("unsupported puppet play mode");
}

bool validMainTrackSize (uint32_t byteSize, int32_t length) {
    if (length < 0 || byteSize == 0 || byteSize % 4 != 0) return false;
    const uint64_t samples = static_cast<uint64_t> (length) + 1;
    return byteSize == samples * 36 || byteSize == samples * 4;
}

void skipFloats (Reader& reader, uint32_t byteSize) {
    if (byteSize % 4 != 0) throw PuppetParseError ("unaligned puppet float block");
    reader.seek (reader.tell () + byteSize);
}

bool nextIsCurves (const Reader& reader) {
    const size_t offset = reader.tell ();
    if (offset >= reader.size ()) return false;
    const uint8_t present = reader.peekU8 (offset);
    if (present == 0) return true;
    return present == 1 && offset + 9 <= reader.size ()
        && reader.peekU32 (offset + 1) == 0
        && reader.peekU32 (offset + 5) % 4 == 0;
}

bool skipCurves (Reader& reader, uint32_t boneCount) {
    if (reader.u8 () == 0) return false;
    for (uint32_t index = 0; index < boneCount; ++index) {
        if (reader.u32 () != 0) throw PuppetParseError ("invalid puppet curve header");
        skipFloats (reader, reader.u32 ());
    }
    return true;
}

PuppetAnimation parseAnimation (
    Reader& reader, int version, size_t sectionEnd, bool& hasCurves
) {
    PuppetAnimation animation;
    animation.id = reader.i32 ();
    (void)reader.u32 ();
    animation.name = reader.cString ();
    if (animation.name.empty ()) animation.name = reader.cString ();
    animation.mode = parseMode (reader.cString ());
    animation.framesPerSecond = reader.f32 ();
    animation.length = reader.i32 ();
    (void)reader.i32 ();
    if (!std::isfinite (animation.framesPerSecond) || animation.framesPerSecond <= 0.0f
        || animation.length < 0) {
        throw PuppetParseError ("invalid puppet animation clock");
    }
    const uint32_t boneCount = reader.u32 ();
    animation.boneTracks.resize (boneCount);
    for (PuppetBoneTrack& track : animation.boneTracks) {
        (void)reader.i32 ();
        const uint32_t byteSize = reader.u32 ();
        if (byteSize % 36 != 0) throw PuppetParseError ("invalid puppet bone track");
        track.frames.resize (byteSize / 36);
        for (PuppetBoneFrame& frame : track.frames) {
            frame.position = readVec3 (reader);
            frame.angles = readVec3 (reader);
            frame.scale = readVec3 (reader);
        }
        if (track.frames.size () != static_cast<size_t> (animation.length) + 1) {
            throw PuppetParseError ("puppet track length does not match animation");
        }
    }
    if (version >= 3) {
        const uint32_t transFlag = reader.u32 ();
        if (transFlag == 1) {
            const uint32_t extraSize = reader.u32 ();
            skipFloats (reader, extraSize);
            if (extraSize > 0 && reader.u32 () != 0) {
                throw PuppetParseError ("invalid puppet translation separator");
            }
            skipFloats (reader, reader.u32 ());
            if (extraSize > 0 && reader.u32 () != 0) {
                throw PuppetParseError ("invalid puppet translation trailer");
            }
        } else if (transFlag == 0) {
            if (validMainTrackSize (reader.peekU32 (reader.tell ()), animation.length)) {
                skipFloats (reader, reader.u32 ());
                while (reader.tell () + 8 <= sectionEnd
                       && reader.peekU32 (reader.tell ()) == 0
                       && validMainTrackSize (reader.peekU32 (reader.tell () + 4), animation.length)) {
                    (void)reader.u32 ();
                    skipFloats (reader, reader.u32 ());
                }
            }
        } else {
            throw PuppetParseError ("unsupported puppet translation block");
        }
        hasCurves = skipCurves (reader, boneCount) || hasCurves;
    }
    if (version >= 4) {
        const uint8_t present = reader.u8 ();
        if (present > 1) throw PuppetParseError ("invalid puppet event block");
        if (present == 1) {
            const uint32_t count = reader.u32 ();
            for (uint32_t index = 0; index < count; ++index) {
                (void)reader.f32 ();
                (void)reader.u32 ();
                skipFloats (reader, reader.u32 ());
            }
        }
    }
    if (version >= 5) {
        for (size_t index = 0; index < 6; ++index) (void)reader.f32 ();
    }
    if (version == 6 && nextIsCurves (reader)) {
        hasCurves = skipCurves (reader, boneCount) || hasCurves;
    }
    const uint32_t eventCount = reader.u32 ();
    for (uint32_t index = 0; index < eventCount; ++index) {
        (void)reader.u32 ();
        (void)reader.cString ();
    }
    return animation;
}

std::pair<size_t, size_t> sampleFrames (const PuppetAnimation& animation, double seconds, double& amount) {
    const size_t length = static_cast<size_t> (animation.length);
    if (length == 0) {
        amount = 0.0;
        return { 0, 0 };
    }
    const double framePosition = std::max (0.0, seconds) * animation.framesPerSecond;
    if (animation.mode == PuppetPlayMode::single) {
        const double clamped = std::min (framePosition, static_cast<double> (length));
        const size_t first = std::min (static_cast<size_t> (clamped), length - 1);
        amount = clamped >= length ? 1.0 : clamped - first;
        return { first, first + 1 };
    }
    const size_t cycleLength = animation.mode == PuppetPlayMode::mirror ? length * 2 : length;
    const double wrapped = std::fmod (framePosition, static_cast<double> (cycleLength));
    const size_t cycleFirst = static_cast<size_t> (wrapped);
    const size_t cycleSecond = cycleFirst + 1;
    const auto mirror = [length] (size_t frame) {
        return frame <= length ? frame : length * 2 - frame;
    };
    amount = wrapped - cycleFirst;
    if (animation.mode == PuppetPlayMode::mirror) {
        return { mirror (cycleFirst), mirror (cycleSecond) };
    }
    return { cycleFirst % length, cycleSecond % (length + 1) };
}

PuppetVec3 interpolate (PuppetVec3 left, PuppetVec3 right, double amount) {
    return {
        static_cast<float> (left.x + (right.x - left.x) * amount),
        static_cast<float> (left.y + (right.y - left.y) * amount),
        static_cast<float> (left.z + (right.z - left.z) * amount),
    };
}

bool hasAuthoredTrack (const PuppetBoneTrack& track) {
    constexpr float epsilon = 1.0e-6f;
    for (const PuppetBoneFrame& frame : track.frames) {
        const bool moved = std::abs (frame.position.x) > epsilon
            || std::abs (frame.position.y) > epsilon || std::abs (frame.position.z) > epsilon
            || std::abs (frame.angles.x) > epsilon || std::abs (frame.angles.y) > epsilon
            || std::abs (frame.angles.z) > epsilon;
        const bool zeroScale = std::abs (frame.scale.x) <= epsilon
            && std::abs (frame.scale.y) <= epsilon && std::abs (frame.scale.z) <= epsilon;
        const bool unitScale = std::abs (frame.scale.x - 1.0f) <= epsilon
            && std::abs (frame.scale.y - 1.0f) <= epsilon
            && std::abs (frame.scale.z - 1.0f) <= epsilon;
        if (moved || (!zeroScale && !unitScale)) return true;
    }
    return false;
}

}

PuppetMat4 PuppetMat4::identity () {
    PuppetMat4 result;
    result.values[0] = result.values[5] = result.values[10] = result.values[15] = 1.0f;
    return result;
}

PuppetModel PuppetModel::parse (std::span<const std::byte> data) {
    Reader reader (data);
    PuppetModel result;
    result.m_modelVersion = parseVersion (reader.fixedString (9), "MDLV");
    if (result.m_modelVersion != 23) {
        throw PuppetParseError ("bounded puppet parser accepts MDLV0023 only");
    }
    (void)reader.u32 ();
    if (reader.u32 () != 1 || reader.u32 () != 1) {
        throw PuppetParseError ("bounded puppet parser accepts one mesh only");
    }
    (void)reader.cString ();
    const uint32_t flagA = reader.u32 ();
    if (flagA == 2) (void)reader.u32 ();
    for (size_t index = 0; index < 6; ++index) (void)reader.f32 ();
    const uint32_t flags = reader.u32 ();
    const uint32_t vertexBytes = reader.u32 ();
    uint32_t stride = 12;
    if (flags & normalFlag) stride += 12;
    if (flags & tangentFlag) stride += 16;
    if (flags & extra4Flag) stride += 4;
    if (flags & skinIndicesFlag) stride += 16;
    if (flags & skinWeightsFlag) stride += 16;
    if (flags & (uvFlag | uv2Flag)) stride += 8;
    if (flags & uv2Flag) stride += 8;
    if (!(flags & skinIndicesFlag) || vertexBytes == 0 || vertexBytes % stride != 0) {
        throw PuppetParseError ("puppet mesh lacks bounded skinning layout");
    }
    const uint32_t vertexCount = vertexBytes / stride;
    result.m_vertices.resize (vertexCount);
    for (PuppetVertex& vertex : result.m_vertices) {
        vertex.position = readVec3 (reader);
        if (flags & normalFlag) reader.seek (reader.tell () + 12);
        if (flags & tangentFlag) reader.seek (reader.tell () + 16);
        if (flags & extra4Flag) reader.seek (reader.tell () + 4);
        for (uint32_t& value : vertex.boneIndices) value = reader.u32 ();
        if (flags & skinWeightsFlag) {
            for (float& value : vertex.boneWeights) value = reader.f32 ();
        } else {
            vertex.boneWeights[0] = 1.0f;
        }
        if (flags & (uvFlag | uv2Flag)) {
            vertex.textureCoordinate[0] = reader.f32 ();
            vertex.textureCoordinate[1] = reader.f32 ();
        }
        if (flags & uv2Flag) reader.seek (reader.tell () + 8);
    }
    const uint32_t indexBytes = reader.u32 ();
    if (indexBytes == 0 || indexBytes % 6 != 0) {
        throw PuppetParseError ("invalid puppet triangle buffer");
    }
    result.m_triangles.resize (indexBytes / 6);
    for (auto& triangle : result.m_triangles) {
        for (uint32_t& value : triangle) {
            value = reader.u16 ();
            if (value >= vertexCount) throw PuppetParseError ("puppet index exceeds mesh");
        }
    }
    const uint8_t partExtras = reader.u8 ();
    if (partExtras == 1) {
        if (reader.u8 () != 0) {
            if (reader.u16 () != 0) throw PuppetParseError ("invalid puppet part header");
            (void)reader.u8 ();
            const uint32_t payloadBytes = reader.u32 ();
            if (payloadBytes != vertexCount * 12) {
                throw PuppetParseError ("invalid puppet part vertex payload");
            }
            reader.seek (reader.tell () + payloadBytes);
        }
    } else if (partExtras != 0) {
        throw PuppetParseError ("unsupported puppet part block");
    }
    if (reader.u8 () != 0) {
        const uint32_t partBytes = reader.u32 ();
        if (partBytes % 16 != 0) throw PuppetParseError ("invalid puppet part table");
        result.m_partCount = partBytes / 16;
        result.m_parts.resize (result.m_partCount);
        for (PuppetPart& part : result.m_parts) {
            part.id = reader.u32 ();
            if (reader.u32 () != 0) throw PuppetParseError ("invalid puppet part entry");
            part.firstIndex = reader.u32 ();
            part.indexCount = reader.u32 ();
            if (part.firstIndex > result.m_triangles.size () * 3
                || part.indexCount > result.m_triangles.size () * 3 - part.firstIndex) {
                throw PuppetParseError ("puppet part lies outside triangle buffer");
            }
        }
    }
    result.m_maskCount = reader.u32 ();
    result.m_masks.resize (result.m_maskCount);
    for (PuppetMask& mask : result.m_masks) {
        const uint64_t sourceLow = reader.u32 ();
        const uint64_t sourceHigh = reader.u32 ();
        mask.source = sourceLow | (sourceHigh << 32U);
        mask.texture = reader.cString ();
        mask.flags = reader.u32 ();
        const auto readOrdinals = [&reader, &result] (std::vector<uint32_t>& ordinals) {
            const uint32_t count = reader.u32 ();
            ordinals.resize (count);
            for (uint32_t& ordinal : ordinals) {
                ordinal = reader.u32 ();
                if (ordinal >= result.m_parts.size ()) {
                    throw PuppetParseError ("puppet mask references missing part");
                }
            }
        };
        readOrdinals (mask.targetPartOrdinals);
        readOrdinals (mask.maskPartOrdinals);
    }
    const auto skeletonOffset = reader.uniqueMarker ("MDLS", reader.tell ());
    if (!skeletonOffset.has_value ()) throw PuppetParseError ("puppet has no skeleton section");
    reader.seek (*skeletonOffset);
    result.m_skeletonVersion = parseVersion (reader.fixedString (9), "MDLS");
    if (result.m_skeletonVersion != 4) {
        throw PuppetParseError ("bounded puppet parser accepts MDLS0004 only");
    }
    const uint32_t skeletonEnd = reader.u32 ();
    const uint16_t boneCount = reader.u16 ();
    (void)reader.u16 ();
    result.m_bones.resize (boneCount);
    for (size_t index = 0; index < result.m_bones.size (); ++index) {
        PuppetBone& bone = result.m_bones[index];
        bone.name = reader.cString ();
        (void)reader.i32 ();
        bone.parent = reader.u32 ();
        if (bone.parent != PuppetBone::noParent && bone.parent >= index) {
            throw PuppetParseError ("puppet bone has forward parent");
        }
        if (reader.u32 () != 64) throw PuppetParseError ("invalid puppet bind transform");
        bone.localBind = readMat4 (reader);
        bone.constraintMetadata = reader.cString ();
        if (!bone.constraintMetadata.empty ()) {
            ++result.m_constraintMetadataBoneCount;
            bone.simulation = parseSimulationConstraint (bone.constraintMetadata);
            if (bone.simulation.has_value ()) {
                ++result.m_simulationEnabledBoneCount;
            }
            if (metadataBool (bone.constraintMetadata, "ik") == std::optional<bool> (true)) {
                ++result.m_activeIKBoneCount;
            }
        }
    }
    if (skeletonEnd <= reader.tell () || skeletonEnd > reader.size ()) {
        throw PuppetParseError ("invalid puppet skeleton extent");
    }
    reader.seek (skeletonEnd);
    if (reader.hasPrefix (reader.tell (), "MDAT")) {
        if (parseVersion (reader.fixedString (9), "MDAT") != 1) {
            throw PuppetParseError ("unsupported puppet attachment section");
        }
        const uint32_t attachmentEnd = reader.u32 ();
        result.m_attachmentCount = reader.u16 ();
        result.m_attachments.resize (result.m_attachmentCount);
        for (PuppetAttachment& attachment : result.m_attachments) {
            attachment.boneIndex = reader.u16 ();
            attachment.name = reader.cString ();
            attachment.localTransform = readMat4 (reader);
            if (attachment.boneIndex >= result.m_bones.size ()) {
                throw PuppetParseError ("puppet attachment references missing bone");
            }
        }
        if (attachmentEnd < reader.tell () || attachmentEnd > reader.size ()) {
            throw PuppetParseError ("invalid puppet attachment extent");
        }
        reader.seek (attachmentEnd);
    }
    const auto animationOffset = reader.uniqueMarker ("MDLA", skeletonEnd);
    if (animationOffset.has_value ()) {
        reader.seek (*animationOffset);
        result.m_animationVersion = parseVersion (reader.fixedString (9), "MDLA");
        if (result.m_animationVersion != 6) {
            throw PuppetParseError ("bounded puppet parser accepts MDLA0006 only");
        }
        const uint32_t animationEnd = reader.u32 ();
        if (animationEnd <= reader.tell () || animationEnd > reader.size ()) {
            throw PuppetParseError ("invalid puppet animation extent");
        }
        const uint32_t animationCount = reader.u32 ();
        result.m_animations.reserve (animationCount);
        for (uint32_t index = 0; index < animationCount; ++index) {
            result.m_animations.push_back (parseAnimation (
                reader, result.m_animationVersion, animationEnd, result.m_hasAnimationCurves
            ));
            if (index + 1 < animationCount && reader.tell () + 12 <= animationEnd
                && reader.peekU32 (reader.tell ()) == 0
                && reader.peekU32 (reader.tell () + 4) > 0
                && reader.peekU32 (reader.tell () + 8) == 0) {
                (void)reader.u32 ();
            }
        }
        for (const PuppetAnimation& animation : result.m_animations) {
            if (animation.boneTracks.size () != result.m_bones.size ()) {
                throw PuppetParseError ("animation and skeleton bone counts differ");
            }
        }
    }
    result.m_hasMorphSections = reader.uniqueMarker ("MDMP", skeletonEnd).has_value ();
    const auto extendedBindOffset = reader.uniqueMarker ("MDLE0002", skeletonEnd);
    result.m_hasExtendedBindMetadata = extendedBindOffset.has_value ();
    for (const PuppetVertex& vertex : result.m_vertices) {
        float total = 0.0f;
        for (size_t index = 0; index < 4; ++index) {
            if (vertex.boneWeights[index] < 0.0f || !std::isfinite (vertex.boneWeights[index])) {
                throw PuppetParseError ("invalid puppet bone weight");
            }
            if (vertex.boneWeights[index] > 0.0f
                && vertex.boneIndices[index] >= result.m_bones.size ()) {
                throw PuppetParseError ("puppet vertex references missing bone");
            }
            total += vertex.boneWeights[index];
        }
        if (std::abs (total - 1.0f) > 0.01f) {
            throw PuppetParseError ("puppet bone weights are not normalized");
        }
    }
    if (extendedBindOffset.has_value ()) {
        reader.seek (*extendedBindOffset);
        if (parseVersion (reader.fixedString (9), "MDLE") != 2) {
            throw PuppetParseError ("unsupported puppet extended-bind section");
        }
        const uint32_t extendedBindEnd = reader.u32 ();
        const uint32_t matrixBytes = reader.u32 ();
        if (matrixBytes != result.m_bones.size () * 64
            || reader.tell () + matrixBytes > extendedBindEnd
            || extendedBindEnd > reader.size ()) {
            throw PuppetParseError ("invalid puppet extended-bind matrices");
        }
        std::vector<PuppetMat4> bindWorld (result.m_bones.size ());
        for (size_t boneIndex = 0; boneIndex < result.m_bones.size (); ++boneIndex) {
            const PuppetBone& bone = result.m_bones[boneIndex];
            bindWorld[boneIndex] = bone.parent == PuppetBone::noParent
                ? bone.localBind : multiply (bindWorld[bone.parent], bone.localBind);
            const PuppetMat4 authoredInverse = readMat4 (reader);
            const PuppetMat4 computedInverse = inverseAffine (bindWorld[boneIndex]);
            for (size_t value = 0; value < authoredInverse.values.size (); ++value) {
                result.m_extendedBindMaxDifference = std::max (
                    result.m_extendedBindMaxDifference,
                    std::abs (authoredInverse.values[value] - computedInverse.values[value])
                );
            }
        }
    }
    return result;
}

std::vector<PuppetVec3> PuppetModel::deformSingleAnimation (
    int32_t animationID, double seconds
) const {
    const auto animation = std::find_if (m_animations.begin (), m_animations.end (),
        [animationID] (const auto& candidate) { return candidate.id == animationID; });
    if (animation == m_animations.end ()) throw PuppetParseError ("missing puppet animation");
    double amount = 0.0;
    const auto [first, second] = sampleFrames (*animation, seconds, amount);
    std::vector<PuppetMat4> bindWorld (m_bones.size ());
    std::vector<PuppetMat4> animatedWorld (m_bones.size ());
    std::vector<PuppetMat4> skin (m_bones.size ());
    for (size_t index = 0; index < m_bones.size (); ++index) {
        const PuppetBone& bone = m_bones[index];
        bindWorld[index] = bone.parent == PuppetBone::noParent
            ? bone.localBind : multiply (bindWorld[bone.parent], bone.localBind);
        const PuppetBoneTrack& track = animation->boneTracks[index];
        const PuppetBoneFrame& left = track.frames[first];
        const PuppetBoneFrame& right = track.frames[second];
        const PuppetMat4 local = trs (
            interpolate (left.position, right.position, amount),
            slerp (quaternionForAngles (left.angles), quaternionForAngles (right.angles), amount),
            interpolate (left.scale, right.scale, amount)
        );
        animatedWorld[index] = bone.parent == PuppetBone::noParent
            ? local : multiply (animatedWorld[bone.parent], local);
        skin[index] = multiply (animatedWorld[index], inverseAffine (bindWorld[index]));
    }
    std::vector<PuppetVec3> result;
    result.reserve (m_vertices.size ());
    for (const PuppetVertex& vertex : m_vertices) {
        PuppetVec3 deformed;
        for (size_t index = 0; index < 4; ++index) {
            const float weight = vertex.boneWeights[index];
            if (weight == 0.0f) continue;
            const PuppetVec3 point = transformPoint (skin[vertex.boneIndices[index]], vertex.position);
            deformed.x += point.x * weight;
            deformed.y += point.y * weight;
            deformed.z += point.z * weight;
        }
        result.push_back (deformed);
    }
    return result;
}

std::vector<PuppetMat4> PuppetModel::animatedBoneWorld (
    std::span<const AnimationLayer> layers,
    std::span<const float> localRotationOffsetsZ,
    std::vector<float>* localRotationZOutput
) const {
    if (!localRotationOffsetsZ.empty ()
        && localRotationOffsetsZ.size () != m_bones.size ()) {
        throw PuppetParseError ("puppet rotation-offset count differs from skeleton");
    }
    if (localRotationZOutput != nullptr) {
        localRotationZOutput->assign (m_bones.size (), 0.0f);
    }
    if (layers.empty ()) {
        std::vector<PuppetMat4> result (m_bones.size ());
        for (size_t index = 0; index < m_bones.size (); ++index) {
            const PuppetBone& bone = m_bones[index];
            if (localRotationZOutput != nullptr) {
                (*localRotationZOutput)[index] = std::atan2 (
                    bone.localBind.values[1], bone.localBind.values[0]
                );
            }
            PuppetMat4 local = bone.localBind;
            if (!localRotationOffsetsZ.empty ()
                && localRotationOffsetsZ[index] != 0.0f) {
                local = multiply (local, trs (
                    {}, quaternionForAngles ({ 0.0f, 0.0f, localRotationOffsetsZ[index] }),
                    { 1.0f, 1.0f, 1.0f }
                ));
            }
            result[index] = bone.parent == PuppetBone::noParent
                ? local : multiply (result[bone.parent], local);
        }
        return result;
    }

    struct SampledLayer {
        const AnimationLayer* input = nullptr;
        const PuppetAnimation* animation = nullptr;
        size_t first = 0;
        size_t second = 0;
        double amount = 0.0;
        bool replacement = false;
    };
    std::vector<SampledLayer> sampled;
    sampled.reserve (layers.size ());
    for (const AnimationLayer& layer : layers) {
        if (!layer.visible || layer.blend <= 0.0) continue;
        const auto animation = std::find_if (m_animations.begin (), m_animations.end (),
            [&layer] (const auto& candidate) { return candidate.id == layer.animationID; });
        if (animation == m_animations.end ()) continue;
        SampledLayer value { .input = &layer, .animation = &*animation };
        value.replacement = !layer.additive;
        const auto frames = sampleFrames (*animation, layer.timeSeconds, value.amount);
        value.first = frames.first;
        value.second = frames.second;
        sampled.push_back (value);
    }
    if (sampled.empty ()) {
        return animatedBoneWorld ({}, localRotationOffsetsZ, localRotationZOutput);
    }

    const bool hasReplacement = std::any_of (sampled.begin (), sampled.end (),
        [] (const auto& layer) { return layer.replacement; });
    if (!hasReplacement) sampled.front ().replacement = true;

    std::vector<PuppetMat4> animatedWorld (m_bones.size ());
    for (size_t boneIndex = 0; boneIndex < m_bones.size (); ++boneIndex) {
        const PuppetBone& bone = m_bones[boneIndex];

        const SampledLayer* baseLayer = nullptr;
        for (const SampledLayer& layer : sampled) {
            if (layer.replacement && boneIndex < layer.animation->boneTracks.size ()
                && hasAuthoredTrack (layer.animation->boneTracks[boneIndex])) {
                baseLayer = &layer;
                break;
            }
        }
        PuppetVec3 translation {
            bone.localBind.values[12], bone.localBind.values[13], bone.localBind.values[14]
        };
        PuppetVec3 scale {
            std::sqrt (bone.localBind.values[0] * bone.localBind.values[0]
                + bone.localBind.values[1] * bone.localBind.values[1]
                + bone.localBind.values[2] * bone.localBind.values[2]),
            std::sqrt (bone.localBind.values[4] * bone.localBind.values[4]
                + bone.localBind.values[5] * bone.localBind.values[5]
                + bone.localBind.values[6] * bone.localBind.values[6]),
            std::sqrt (bone.localBind.values[8] * bone.localBind.values[8]
                + bone.localBind.values[9] * bone.localBind.values[9]
                + bone.localBind.values[10] * bone.localBind.values[10]),
        };
        Quaternion rotation;
        if (baseLayer != nullptr) {
            const PuppetBoneFrame& frame = baseLayer->animation->boneTracks[boneIndex].frames.front ();
            translation = frame.position;
            scale = frame.scale;
            rotation = quaternionForAngles (frame.angles);
        }
        for (const SampledLayer& layer : sampled) {
            const PuppetBoneTrack& track = layer.animation->boneTracks[boneIndex];
            if (!hasAuthoredTrack (track)) continue;
            const PuppetBoneFrame& base = track.frames.front ();
            const PuppetBoneFrame current {
                interpolate (track.frames[layer.first].position, track.frames[layer.second].position,
                    layer.amount),
                {},
                interpolate (track.frames[layer.first].scale, track.frames[layer.second].scale,
                    layer.amount),
            };
            const Quaternion currentRotation = slerp (
                quaternionForAngles (track.frames[layer.first].angles),
                quaternionForAngles (track.frames[layer.second].angles), layer.amount
            );
            const Quaternion baseRotation = quaternionForAngles (base.angles);
            const Quaternion inverseBase {
                baseRotation.w, -baseRotation.x, -baseRotation.y, -baseRotation.z
            };
            const double blend = std::clamp (
                layer.input->blend, 0.0, 1.0
            );
            translation = {
                translation.x + static_cast<float> ((current.position.x - base.position.x) * blend),
                translation.y + static_cast<float> ((current.position.y - base.position.y) * blend),
                translation.z + static_cast<float> ((current.position.z - base.position.z) * blend),
            };
            scale = {
                scale.x + static_cast<float> ((current.scale.x - base.scale.x) * blend),
                scale.y + static_cast<float> ((current.scale.y - base.scale.y) * blend),
                scale.z + static_cast<float> ((current.scale.z - base.scale.z) * blend),
            };
            const Quaternion delta = multiply (currentRotation, inverseBase);
            rotation = multiply (rotation, slerp ({}, delta, blend));
        }
        if (localRotationZOutput != nullptr) {
            (*localRotationZOutput)[boneIndex] = static_cast<float> (rotationZ (rotation));
        }
        if (!localRotationOffsetsZ.empty ()) {
            rotation = multiply (rotation, quaternionForAngles ({
                0.0f, 0.0f, localRotationOffsetsZ[boneIndex]
            }));
        }
        const PuppetMat4 local = trs (translation, rotation, scale);
        animatedWorld[boneIndex] = bone.parent == PuppetBone::noParent
            ? local : multiply (animatedWorld[bone.parent], local);
    }

    return animatedWorld;
}

std::vector<PuppetVec3> PuppetModel::deformLayers (
    std::span<const AnimationLayer> layers,
    std::span<const float> localRotationOffsetsZ
) const {
    if (layers.empty () && localRotationOffsetsZ.empty ()) {
        std::vector<PuppetVec3> result;
        result.reserve (m_vertices.size ());
        for (const PuppetVertex& vertex : m_vertices) result.push_back (vertex.position);
        return result;
    }

    const auto animatedWorld = animatedBoneWorld (layers, localRotationOffsetsZ);
    std::vector<PuppetMat4> bindWorld (m_bones.size ());
    std::vector<PuppetMat4> skin (m_bones.size ());
    for (size_t boneIndex = 0; boneIndex < m_bones.size (); ++boneIndex) {
        const PuppetBone& bone = m_bones[boneIndex];
        bindWorld[boneIndex] = bone.parent == PuppetBone::noParent
            ? bone.localBind : multiply (bindWorld[bone.parent], bone.localBind);
        skin[boneIndex] = multiply (animatedWorld[boneIndex], inverseAffine (bindWorld[boneIndex]));
    }

    std::vector<PuppetVec3> result;
    result.reserve (m_vertices.size ());
    for (const PuppetVertex& vertex : m_vertices) {
        PuppetVec3 deformed;
        for (size_t index = 0; index < 4; ++index) {
            const float weight = vertex.boneWeights[index];
            if (weight == 0.0f) continue;
            const PuppetVec3 point = transformPoint (skin[vertex.boneIndices[index]], vertex.position);
            deformed.x += point.x * weight;
            deformed.y += point.y * weight;
            deformed.z += point.z * weight;
        }
        result.push_back (deformed);
    }
    return result;
}

std::vector<float> PuppetModel::localRotationZ (
    std::span<const AnimationLayer> layers
) const {
    std::vector<float> result;
    (void)animatedBoneWorld (layers, {}, &result);
    return result;
}

std::optional<PuppetVec3> PuppetModel::attachmentPosition (
    std::string_view name,
    std::span<const AnimationLayer> layers,
    std::span<const float> localRotationOffsetsZ
) const {
    const auto attachment = std::find_if (m_attachments.begin (), m_attachments.end (),
        [name] (const auto& candidate) { return candidate.name == name; });
    if (attachment == m_attachments.end ()) return std::nullopt;
    const auto animatedWorld = animatedBoneWorld (layers, localRotationOffsetsZ);
    const PuppetMat4 world = multiply (
        animatedWorld[attachment->boneIndex], attachment->localTransform
    );
    return transformPoint (world, {});
}

}
