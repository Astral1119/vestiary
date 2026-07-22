#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "FixtureData.h"

namespace {

using fresco::sdl3_spike::kIndices;
using fresco::sdl3_spike::kLandscapeT0;
using fresco::sdl3_spike::kLandscapeT1;
using fresco::sdl3_spike::kPortraitT1;
using fresco::sdl3_spike::kTexture;
using fresco::sdl3_spike::kVertices;

constexpr SDL_GPUTextureFormat kColorFormat =
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;

struct Counters {
    std::uint32_t commandBuffersAcquired = 0;
    std::uint32_t commandBuffersSubmitted = 0;
    std::uint32_t fencesCreated = 0;
    std::uint32_t fencesWaited = 0;
    std::uint32_t fencesReleased = 0;
    std::uint32_t buffersCreated = 0;
    std::uint32_t buffersReleased = 0;
    std::uint32_t texturesCreated = 0;
    std::uint32_t texturesReleased = 0;
    std::uint32_t transferBuffersCreated = 0;
    std::uint32_t transferBuffersReleased = 0;
    std::uint32_t shadersCreated = 0;
    std::uint32_t shadersReleased = 0;
    std::uint32_t pipelinesCreated = 0;
    std::uint32_t pipelinesReleased = 0;
    std::uint32_t samplersCreated = 0;
    std::uint32_t samplersReleased = 0;
    std::uint32_t resizeRetirementsAfterCompletion = 0;
    std::uint32_t pushedVertexUniforms = 0;
    std::uint32_t indexedDraws = 0;
};

[[noreturn]] void fail(std::string_view operation) {
    throw std::runtime_error(
        std::string(operation) + ": " + SDL_GetError());
}

std::string readFile(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot read shader: " + path.string());
    }
    return std::string(
        std::istreambuf_iterator<char>(stream),
        std::istreambuf_iterator<char>());
}

std::string jsonEscape(std::string_view input) {
    std::ostringstream result;
    for (const char value : input) {
        switch (value) {
        case '\\': result << "\\\\"; break;
        case '"': result << "\\\""; break;
        case '\n': result << "\\n"; break;
        case '\r': result << "\\r"; break;
        case '\t': result << "\\t"; break;
        default: result << value; break;
        }
    }
    return result.str();
}

const char* boolJson(const bool value) {
    return value ? "true" : "false";
}

struct Output {
    std::string identity;
    std::string transform;
    std::string cull;
    std::filesystem::path path;
    std::uint32_t width;
    std::uint32_t height;
    bool indexed;
};

class Spike {
public:
    explicit Spike(SDL_GPUTextureFormat depthFormat)
        : depthFormat_(depthFormat) {
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            fail("SDL_Init");
        }
        device_ = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, "metal");
        if (device_ == nullptr) {
            fail("SDL_CreateGPUDevice");
        }
    }

    Spike(const Spike&) = delete;
    Spike& operator=(const Spike&) = delete;

    ~Spike() {
        if (!shutdown_) {
            shutdownNoThrow();
        }
        SDL_Quit();
    }

    SDL_GPUDevice* device() const { return device_; }

    std::string driver() const {
        const char* value = SDL_GetGPUDeviceDriver(device_);
        return value == nullptr ? "unknown" : value;
    }

    void initializeGeometry() {
        vertexBuffer_ = createBuffer(
            SDL_GPU_BUFFERUSAGE_VERTEX,
            static_cast<std::uint32_t>(sizeof(kVertices)));
        indexBuffer_ = createBuffer(
            SDL_GPU_BUFFERUSAGE_INDEX,
            static_cast<std::uint32_t>(sizeof(kIndices)));
        sampledTexture_ = createTexture(
            SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            SDL_GPU_TEXTUREUSAGE_SAMPLER, 2, 2);

        const std::uint32_t vertexOffset = 0;
        const std::uint32_t indexOffset =
            static_cast<std::uint32_t>(sizeof(kVertices));
        const std::uint32_t unalignedTextureOffset = indexOffset +
            static_cast<std::uint32_t>(sizeof(kIndices));
        const std::uint32_t textureOffset =
            (unalignedTextureOffset + 3U) & ~3U;
        const std::uint32_t uploadSize = textureOffset +
            static_cast<std::uint32_t>(sizeof(kTexture));
        SDL_GPUTransferBuffer* transfer = createTransfer(
            SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, uploadSize);
        void* mapped = SDL_MapGPUTransferBuffer(device_, transfer, false);
        if (mapped == nullptr) {
            fail("SDL_MapGPUTransferBuffer(upload)");
        }
        auto* bytes = static_cast<std::uint8_t*>(mapped);
        std::memcpy(bytes + vertexOffset, kVertices.data(), sizeof(kVertices));
        std::memcpy(bytes + indexOffset, kIndices.data(), sizeof(kIndices));
        std::memcpy(bytes + textureOffset, kTexture.data(), sizeof(kTexture));
        SDL_UnmapGPUTransferBuffer(device_, transfer);

        SDL_GPUCommandBuffer* command = acquire();
        SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(command);
        if (copy == nullptr) {
            fail("SDL_BeginGPUCopyPass(upload)");
        }
        SDL_GPUTransferBufferLocation vertexSource{transfer, vertexOffset};
        SDL_GPUBufferRegion vertexDestination{
            vertexBuffer_, 0, static_cast<std::uint32_t>(sizeof(kVertices))};
        SDL_UploadToGPUBuffer(
            copy, &vertexSource, &vertexDestination, false);
        SDL_GPUTransferBufferLocation indexSource{transfer, indexOffset};
        SDL_GPUBufferRegion indexDestination{
            indexBuffer_, 0, static_cast<std::uint32_t>(sizeof(kIndices))};
        SDL_UploadToGPUBuffer(copy, &indexSource, &indexDestination, false);
        SDL_GPUTextureTransferInfo textureSource{
            transfer, textureOffset, 2, 2};
        SDL_GPUTextureRegion textureDestination{
            sampledTexture_, 0, 0, 0, 0, 0, 2, 2, 1};
        SDL_UploadToGPUTexture(
            copy, &textureSource, &textureDestination, false);
        SDL_EndGPUCopyPass(copy);
        submitAndWait(command);
        releaseTransfer(transfer);

        SDL_GPUSamplerCreateInfo samplerInfo{};
        samplerInfo.min_filter = SDL_GPU_FILTER_NEAREST;
        samplerInfo.mag_filter = SDL_GPU_FILTER_NEAREST;
        samplerInfo.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        samplerInfo.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        samplerInfo.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        samplerInfo.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_ = SDL_CreateGPUSampler(device_, &samplerInfo);
        if (sampler_ == nullptr) {
            fail("SDL_CreateGPUSampler");
        }
        ++counters_.samplersCreated;

        vertexShader_ = createShader("minimal.vert.metal", true);
        fragmentShader_ = createShader("minimal.frag.metal", false);
        pipelineNone_ = createPipeline(SDL_GPU_CULLMODE_NONE);
        pipelineBack_ = createPipeline(SDL_GPU_CULLMODE_BACK);
    }

    Output renderClear(
        const std::filesystem::path& outputDirectory,
        const std::uint32_t width,
        const std::uint32_t height) {
        replaceTargets(width, height, false);
        SDL_GPUCommandBuffer* command = acquire();
        SDL_GPUColorTargetInfo color{};
        color.texture = colorTarget_;
        color.clear_color = SDL_FColor{0.0F, 0.0F, 0.0F, 1.0F};
        color.load_op = SDL_GPU_LOADOP_CLEAR;
        color.store_op = SDL_GPU_STOREOP_STORE;
        SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(
            command, &color, 1, nullptr);
        if (pass == nullptr) {
            fail("SDL_BeginGPURenderPass(clear)");
        }
        SDL_EndGPURenderPass(pass);
        const auto path = outputDirectory / "static-render-foundation-clear.bgra";
        download(command, path, width, height);
        return {"static-render-foundation-clear", "none", "none", path, width, height, false};
    }

    Output renderIndexed(
        const std::filesystem::path& outputDirectory,
        const std::string& identity,
        const std::array<float, 16>& transform,
        const std::string& transformIdentity,
        const SDL_GPUCullMode cull,
        const std::uint32_t width,
        const std::uint32_t height) {
        replaceTargets(width, height, true);
        SDL_GPUCommandBuffer* command = acquire();
        SDL_PushGPUVertexUniformData(
            command, 0, transform.data(),
            static_cast<std::uint32_t>(sizeof(transform)));
        ++counters_.pushedVertexUniforms;

        SDL_GPUColorTargetInfo color{};
        color.texture = colorTarget_;
        color.clear_color = SDL_FColor{0.0F, 0.0F, 0.0F, 1.0F};
        color.load_op = SDL_GPU_LOADOP_CLEAR;
        color.store_op = SDL_GPU_STOREOP_STORE;
        SDL_GPUDepthStencilTargetInfo depth{};
        depth.texture = depthTarget_;
        depth.clear_depth = 1.0F;
        depth.load_op = SDL_GPU_LOADOP_CLEAR;
        depth.store_op = SDL_GPU_STOREOP_DONT_CARE;
        depth.stencil_load_op = SDL_GPU_LOADOP_DONT_CARE;
        depth.stencil_store_op = SDL_GPU_STOREOP_DONT_CARE;
        SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(
            command, &color, 1, &depth);
        if (pass == nullptr) {
            fail("SDL_BeginGPURenderPass(indexed)");
        }
        SDL_BindGPUGraphicsPipeline(
            pass, cull == SDL_GPU_CULLMODE_NONE ? pipelineNone_ : pipelineBack_);
        const SDL_GPUBufferBinding vertexBinding{vertexBuffer_, 0};
        const SDL_GPUBufferBinding indexBinding{indexBuffer_, 0};
        const SDL_GPUTextureSamplerBinding textureBinding{
            sampledTexture_, sampler_};
        SDL_BindGPUVertexBuffers(pass, 0, &vertexBinding, 1);
        SDL_BindGPUIndexBuffer(
            pass, &indexBinding, SDL_GPU_INDEXELEMENTSIZE_16BIT);
        SDL_BindGPUFragmentSamplers(pass, 0, &textureBinding, 1);
        SDL_DrawGPUIndexedPrimitives(
            pass, static_cast<std::uint32_t>(kIndices.size()), 1, 0, 0, 0);
        ++counters_.indexedDraws;
        SDL_EndGPURenderPass(pass);
        const auto path = outputDirectory / (identity + ".bgra");
        download(command, path, width, height);
        return {
            identity, transformIdentity,
            cull == SDL_GPU_CULLMODE_NONE ? "none" : "back",
            path, width, height, true};
    }

    void shutdown() {
        if (!SDL_WaitForGPUIdle(device_)) {
            fail("SDL_WaitForGPUIdle");
        }
        releaseTargets(false);
        releasePipeline(pipelineBack_);
        releasePipeline(pipelineNone_);
        releaseShader(fragmentShader_);
        releaseShader(vertexShader_);
        if (sampler_ != nullptr) {
            SDL_ReleaseGPUSampler(device_, sampler_);
            sampler_ = nullptr;
            ++counters_.samplersReleased;
        }
        releaseTexture(sampledTexture_);
        releaseBuffer(indexBuffer_);
        releaseBuffer(vertexBuffer_);
        SDL_DestroyGPUDevice(device_);
        device_ = nullptr;
        shutdown_ = true;
    }

    const Counters& counters() const { return counters_; }

private:
    SDL_GPUBuffer* createBuffer(
        SDL_GPUBufferUsageFlags usage, std::uint32_t size) {
        const SDL_GPUBufferCreateInfo info{usage, size, 0};
        SDL_GPUBuffer* result = SDL_CreateGPUBuffer(device_, &info);
        if (result == nullptr) {
            fail("SDL_CreateGPUBuffer");
        }
        ++counters_.buffersCreated;
        return result;
    }

    SDL_GPUTexture* createTexture(
        SDL_GPUTextureFormat format,
        SDL_GPUTextureUsageFlags usage,
        std::uint32_t width,
        std::uint32_t height) {
        const SDL_GPUTextureCreateInfo info{
            SDL_GPU_TEXTURETYPE_2D, format, usage, width, height, 1, 1,
            SDL_GPU_SAMPLECOUNT_1, 0};
        SDL_GPUTexture* result = SDL_CreateGPUTexture(device_, &info);
        if (result == nullptr) {
            fail("SDL_CreateGPUTexture");
        }
        ++counters_.texturesCreated;
        return result;
    }

    SDL_GPUTransferBuffer* createTransfer(
        SDL_GPUTransferBufferUsage usage, std::uint32_t size) {
        const SDL_GPUTransferBufferCreateInfo info{usage, size, 0};
        SDL_GPUTransferBuffer* result =
            SDL_CreateGPUTransferBuffer(device_, &info);
        if (result == nullptr) {
            fail("SDL_CreateGPUTransferBuffer");
        }
        ++counters_.transferBuffersCreated;
        return result;
    }

    SDL_GPUCommandBuffer* acquire() {
        SDL_GPUCommandBuffer* result = SDL_AcquireGPUCommandBuffer(device_);
        if (result == nullptr) {
            fail("SDL_AcquireGPUCommandBuffer");
        }
        ++counters_.commandBuffersAcquired;
        return result;
    }

    void submitAndWait(SDL_GPUCommandBuffer* command) {
        SDL_GPUFence* fence =
            SDL_SubmitGPUCommandBufferAndAcquireFence(command);
        if (fence == nullptr) {
            fail("SDL_SubmitGPUCommandBufferAndAcquireFence");
        }
        ++counters_.commandBuffersSubmitted;
        ++counters_.fencesCreated;
        if (!SDL_WaitForGPUFences(device_, true, &fence, 1)) {
            fail("SDL_WaitForGPUFences");
        }
        ++counters_.fencesWaited;
        SDL_ReleaseGPUFence(device_, fence);
        ++counters_.fencesReleased;
        lastSubmissionCompleted_ = true;
    }

    SDL_GPUShader* createShader(const char* filename, bool vertex) {
        const std::string code = readFile(
            std::filesystem::path(FRESCO_SDL3_GPU_SHADER_ROOT) / filename);
        SDL_GPUShaderCreateInfo info{};
        info.code_size = code.size();
        info.code = reinterpret_cast<const std::uint8_t*>(code.data());
        info.entrypoint = "main0";
        info.format = SDL_GPU_SHADERFORMAT_MSL;
        info.stage = vertex
            ? SDL_GPU_SHADERSTAGE_VERTEX : SDL_GPU_SHADERSTAGE_FRAGMENT;
        info.num_samplers = vertex ? 0 : 1;
        info.num_uniform_buffers = vertex ? 1 : 0;
        SDL_GPUShader* result = SDL_CreateGPUShader(device_, &info);
        if (result == nullptr) {
            fail("SDL_CreateGPUShader");
        }
        ++counters_.shadersCreated;
        return result;
    }

    SDL_GPUGraphicsPipeline* createPipeline(SDL_GPUCullMode cull) {
        SDL_GPUVertexBufferDescription bufferDescription{};
        bufferDescription.slot = 0;
        bufferDescription.pitch = sizeof(fresco::sdl3_spike::Vertex);
        bufferDescription.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX;
        SDL_GPUVertexAttribute attributes[2]{};
        attributes[0] = {
            0, 0, SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, 0};
        attributes[1] = {
            1, 0, SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, 12};
        SDL_GPUColorTargetDescription colorDescription{};
        colorDescription.format = kColorFormat;
        SDL_GPUGraphicsPipelineCreateInfo info{};
        info.vertex_shader = vertexShader_;
        info.fragment_shader = fragmentShader_;
        info.vertex_input_state = {
            &bufferDescription, 1, attributes, 2};
        info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        info.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = cull;
        // SDL names winding in Y-up NDC. The contract names winding after
        // the viewport's Y inversion, so framebuffer CCW maps to SDL CW.
        info.rasterizer_state.front_face = SDL_GPU_FRONTFACE_CLOCKWISE;
        info.rasterizer_state.enable_depth_clip = true;
        info.multisample_state.sample_count = SDL_GPU_SAMPLECOUNT_1;
        info.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_LESS;
        info.depth_stencil_state.enable_depth_test = true;
        info.depth_stencil_state.enable_depth_write = true;
        info.target_info.color_target_descriptions = &colorDescription;
        info.target_info.num_color_targets = 1;
        info.target_info.depth_stencil_format = depthFormat_;
        info.target_info.has_depth_stencil_target = true;
        SDL_GPUGraphicsPipeline* result =
            SDL_CreateGPUGraphicsPipeline(device_, &info);
        if (result == nullptr) {
            fail("SDL_CreateGPUGraphicsPipeline");
        }
        ++counters_.pipelinesCreated;
        return result;
    }

    void replaceTargets(
        std::uint32_t width, std::uint32_t height, bool withDepth) {
        if (colorTarget_ != nullptr && width_ == width && height_ == height &&
            (depthTarget_ != nullptr) == withDepth) {
            return;
        }
        if (colorTarget_ != nullptr) {
            if (!lastSubmissionCompleted_) {
                throw std::runtime_error(
                    "attempted target retirement before completion");
            }
            releaseTargets(true);
        }
        colorTarget_ = createTexture(
            kColorFormat, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET, width, height);
        if (withDepth) {
            depthTarget_ = createTexture(
                depthFormat_, SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
                width, height);
        }
        width_ = width;
        height_ = height;
    }

    void releaseTargets(bool resize) {
        if (depthTarget_ != nullptr) {
            releaseTexture(depthTarget_);
        }
        if (colorTarget_ != nullptr) {
            releaseTexture(colorTarget_);
        }
        width_ = 0;
        height_ = 0;
        if (resize) {
            ++counters_.resizeRetirementsAfterCompletion;
        }
    }

    void download(
        SDL_GPUCommandBuffer* command,
        const std::filesystem::path& path,
        std::uint32_t width,
        std::uint32_t height) {
        const std::uint32_t size = width * height * 4;
        SDL_GPUTransferBuffer* transfer = createTransfer(
            SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, size);
        SDL_GPUCopyPass* copy = SDL_BeginGPUCopyPass(command);
        if (copy == nullptr) {
            fail("SDL_BeginGPUCopyPass(download)");
        }
        const SDL_GPUTextureRegion source{
            colorTarget_, 0, 0, 0, 0, 0, width, height, 1};
        const SDL_GPUTextureTransferInfo destination{
            transfer, 0, width, height};
        SDL_DownloadFromGPUTexture(copy, &source, &destination);
        SDL_EndGPUCopyPass(copy);
        lastSubmissionCompleted_ = false;
        submitAndWait(command);
        void* mapped = SDL_MapGPUTransferBuffer(device_, transfer, false);
        if (mapped == nullptr) {
            fail("SDL_MapGPUTransferBuffer(download)");
        }
        std::ofstream stream(path, std::ios::binary);
        if (!stream) {
            throw std::runtime_error("cannot create readback: " + path.string());
        }
        stream.write(static_cast<const char*>(mapped), size);
        if (!stream) {
            throw std::runtime_error("cannot write readback: " + path.string());
        }
        SDL_UnmapGPUTransferBuffer(device_, transfer);
        releaseTransfer(transfer);
    }

    void releaseBuffer(SDL_GPUBuffer*& value) {
        if (value != nullptr) {
            SDL_ReleaseGPUBuffer(device_, value);
            value = nullptr;
            ++counters_.buffersReleased;
        }
    }

    void releaseTexture(SDL_GPUTexture*& value) {
        if (value != nullptr) {
            SDL_ReleaseGPUTexture(device_, value);
            value = nullptr;
            ++counters_.texturesReleased;
        }
    }

    void releaseTransfer(SDL_GPUTransferBuffer*& value) {
        if (value != nullptr) {
            SDL_ReleaseGPUTransferBuffer(device_, value);
            value = nullptr;
            ++counters_.transferBuffersReleased;
        }
    }

    void releaseShader(SDL_GPUShader*& value) {
        if (value != nullptr) {
            SDL_ReleaseGPUShader(device_, value);
            value = nullptr;
            ++counters_.shadersReleased;
        }
    }

    void releasePipeline(SDL_GPUGraphicsPipeline*& value) {
        if (value != nullptr) {
            SDL_ReleaseGPUGraphicsPipeline(device_, value);
            value = nullptr;
            ++counters_.pipelinesReleased;
        }
    }

    void shutdownNoThrow() noexcept {
        if (device_ != nullptr) {
            SDL_WaitForGPUIdle(device_);
            releaseTargets(false);
            releasePipeline(pipelineBack_);
            releasePipeline(pipelineNone_);
            releaseShader(fragmentShader_);
            releaseShader(vertexShader_);
            if (sampler_ != nullptr) {
                SDL_ReleaseGPUSampler(device_, sampler_);
            }
            releaseTexture(sampledTexture_);
            releaseBuffer(indexBuffer_);
            releaseBuffer(vertexBuffer_);
            SDL_DestroyGPUDevice(device_);
            device_ = nullptr;
        }
        shutdown_ = true;
    }

    SDL_GPUDevice* device_ = nullptr;
    SDL_GPUBuffer* vertexBuffer_ = nullptr;
    SDL_GPUBuffer* indexBuffer_ = nullptr;
    SDL_GPUTexture* sampledTexture_ = nullptr;
    SDL_GPUSampler* sampler_ = nullptr;
    SDL_GPUShader* vertexShader_ = nullptr;
    SDL_GPUShader* fragmentShader_ = nullptr;
    SDL_GPUGraphicsPipeline* pipelineNone_ = nullptr;
    SDL_GPUGraphicsPipeline* pipelineBack_ = nullptr;
    SDL_GPUTexture* colorTarget_ = nullptr;
    SDL_GPUTexture* depthTarget_ = nullptr;
    SDL_GPUTextureFormat depthFormat_;
    std::uint32_t width_ = 0;
    std::uint32_t height_ = 0;
    bool lastSubmissionCompleted_ = true;
    bool shutdown_ = false;
    Counters counters_;
};

std::string countersJson(const Counters& value) {
    std::ostringstream output;
    output << "{\"commandBuffersAcquired\":" << value.commandBuffersAcquired
        << ",\"commandBuffersSubmitted\":" << value.commandBuffersSubmitted
        << ",\"fencesCreated\":" << value.fencesCreated
        << ",\"fencesWaited\":" << value.fencesWaited
        << ",\"fencesReleased\":" << value.fencesReleased
        << ",\"buffersCreated\":" << value.buffersCreated
        << ",\"buffersReleased\":" << value.buffersReleased
        << ",\"texturesCreated\":" << value.texturesCreated
        << ",\"texturesReleased\":" << value.texturesReleased
        << ",\"transferBuffersCreated\":" << value.transferBuffersCreated
        << ",\"transferBuffersReleased\":" << value.transferBuffersReleased
        << ",\"shadersCreated\":" << value.shadersCreated
        << ",\"shadersReleased\":" << value.shadersReleased
        << ",\"pipelinesCreated\":" << value.pipelinesCreated
        << ",\"pipelinesReleased\":" << value.pipelinesReleased
        << ",\"samplersCreated\":" << value.samplersCreated
        << ",\"samplersReleased\":" << value.samplersReleased
        << ",\"resizeRetirementsAfterCompletion\":"
        << value.resizeRetirementsAfterCompletion
        << ",\"pushedVertexUniforms\":" << value.pushedVertexUniforms
        << ",\"indexedDraws\":" << value.indexedDraws << "}";
    return output.str();
}

void printProbe() {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fail("SDL_Init");
    }
    SDL_GPUDevice* device = SDL_CreateGPUDevice(
        SDL_GPU_SHADERFORMAT_MSL, true, "metal");
    if (device == nullptr) {
        fail("SDL_CreateGPUDevice");
    }
    const bool d32 = SDL_GPUTextureSupportsFormat(
        device, SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        SDL_GPU_TEXTURETYPE_2D,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    const bool d24s8 = SDL_GPUTextureSupportsFormat(
        device, SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT,
        SDL_GPU_TEXTURETYPE_2D,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    const bool d16 = SDL_GPUTextureSupportsFormat(
        device, SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        SDL_GPU_TEXTURETYPE_2D,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    const char* driver = SDL_GetGPUDeviceDriver(device);
    std::cout << "{\"schemaVersion\":1,\"mode\":\"depth-probe\""
        << ",\"sdlVersion\":\"" << SDL_MAJOR_VERSION << "."
        << SDL_MINOR_VERSION << "." << SDL_MICRO_VERSION << "\""
        << ",\"driver\":\"" << jsonEscape(driver == nullptr ? "unknown" : driver)
        << "\",\"support\":{\"depth32float\":" << boolJson(d32)
        << ",\"depth24unorm-stencil8\":" << boolJson(d24s8)
        << ",\"depth16unorm\":" << boolJson(d16) << "}}\n";
    SDL_DestroyGPUDevice(device);
    SDL_Quit();
}

SDL_GPUTextureFormat parseDepth(std::string_view value) {
    if (value == "depth32float") {
        return SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    }
    if (value == "depth24unorm-stencil8") {
        return SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
    }
    throw std::runtime_error("unsupported --depth value");
}

int run(int argc, char** argv) {
    bool probe = false;
    std::string depthName;
    std::filesystem::path outputDirectory;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--probe-depth") {
            probe = true;
        } else if (argument == "--depth" && index + 1 < argc) {
            depthName = argv[++index];
        } else if (argument == "--output" && index + 1 < argc) {
            outputDirectory = argv[++index];
        } else {
            throw std::runtime_error("unknown or incomplete argument");
        }
    }
    if (probe) {
        if (!depthName.empty() || !outputDirectory.empty()) {
            throw std::runtime_error("depth probe accepts no render arguments");
        }
        printProbe();
        return 0;
    }
    if (depthName.empty() || outputDirectory.empty()) {
        throw std::runtime_error("render requires --depth and --output");
    }
    std::filesystem::create_directories(outputDirectory);
    const SDL_GPUTextureFormat depthFormat = parseDepth(depthName);
    Spike spike(depthFormat);
    if (!SDL_GPUTextureSupportsFormat(
            spike.device(), depthFormat, SDL_GPU_TEXTURETYPE_2D,
            SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)) {
        throw std::runtime_error("frozen depth format is unsupported");
    }
    const std::string driver = spike.driver();
    std::vector<Output> outputs;
    outputs.push_back(spike.renderClear(outputDirectory, 320, 180));
    spike.initializeGeometry();
    outputs.push_back(spike.renderIndexed(
        outputDirectory, "cull-none-landscape-t0", kLandscapeT0,
        "landscape-t0", SDL_GPU_CULLMODE_NONE, 640, 360));
    outputs.push_back(spike.renderIndexed(
        outputDirectory, "cull-back-landscape-t0", kLandscapeT0,
        "landscape-t0", SDL_GPU_CULLMODE_BACK, 640, 360));
    outputs.push_back(spike.renderIndexed(
        outputDirectory, "cull-back-landscape-t1", kLandscapeT1,
        "landscape-t1", SDL_GPU_CULLMODE_BACK, 640, 360));
    outputs.push_back(spike.renderIndexed(
        outputDirectory, "cull-back-portrait-t1", kPortraitT1,
        "portrait-t1", SDL_GPU_CULLMODE_BACK, 360, 640));
    spike.shutdown();

    std::cout << "{\"schemaVersion\":1,\"mode\":\"render\""
        << ",\"sdlVersion\":\"" << SDL_MAJOR_VERSION << "."
        << SDL_MINOR_VERSION << "." << SDL_MICRO_VERSION << "\""
        << ",\"driver\":\"" << jsonEscape(driver) << "\""
        << ",\"depthFormat\":\"" << depthName << "\""
        << ",\"colorFormat\":\"bgra8unorm-srgb\""
        << ",\"offscreen\":true,\"debugMode\":true,\"outputs\":[";
    for (std::size_t index = 0; index < outputs.size(); ++index) {
        if (index != 0) {
            std::cout << ",";
        }
        const Output& output = outputs[index];
        std::cout << "{\"identity\":\"" << output.identity
            << "\",\"transform\":\"" << output.transform
            << "\",\"cull\":\"" << output.cull
            << "\",\"path\":\"" << jsonEscape(output.path.string())
            << "\",\"width\":" << output.width
            << ",\"height\":" << output.height
            << ",\"indexed\":" << boolJson(output.indexed) << "}";
    }
    std::cout << "],\"lifecycle\":" << countersJson(spike.counters())
        << "}\n";
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        return run(argc, argv);
    } catch (const std::exception& error) {
        std::cerr << "fresco SDL3 GPU spike: " << error.what() << "\n";
        return 1;
    }
}
