#include "video_compressor.h"

#define NOMINMAX
#include <windows.h>
#include <shlwapi.h>

// C++/WinRT — ships with the Windows SDK, no third-party dependencies.
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.FileProperties.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Media.Transcoding.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <mutex>
#include <string>

#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "shlwapi.lib")

namespace easy_compressor {

namespace fs = std::filesystem;

// Guards the in-flight transcode operation so Cancel() can abort it cleanly.
static std::mutex g_op_mutex;
static winrt::Windows::Foundation::IAsyncActionWithProgress<double> g_op{ nullptr };

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

static std::wstring Utf8ToWide(const std::string& str) {
    if (str.empty()) return L"";
    int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
    std::wstring result(size - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &result[0], size);
    return result;
}

static std::string WideToUtf8(const std::wstring& wstr) {
    if (wstr.empty()) return "";
    int size = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string result(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, &result[0], size, nullptr, nullptr);
    return result;
}

static int64_t GetFileSize64(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA fi{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fi)) return 0;
    return (int64_t(fi.nFileSizeHigh) << 32) | fi.nFileSizeLow;
}

static flutter::EncodableValue MakeResult(
    const std::string& status,
    const std::string& outPath,
    int64_t originalSize,
    int64_t compressedSize,
    int durationMs,
    int compressionMs,
    int width,
    int height) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("status")]           = flutter::EncodableValue(status);
    m[flutter::EncodableValue("outputPath")]       = flutter::EncodableValue(outPath);
    m[flutter::EncodableValue("originalSize")]     = flutter::EncodableValue(static_cast<int>(originalSize));
    m[flutter::EncodableValue("compressedSize")]   = flutter::EncodableValue(static_cast<int>(compressedSize));
    m[flutter::EncodableValue("duration")]         = flutter::EncodableValue(durationMs);
    m[flutter::EncodableValue("compressionTime")]  = flutter::EncodableValue(compressionMs);
    m[flutter::EncodableValue("width")]            = flutter::EncodableValue(width);
    m[flutter::EncodableValue("height")]           = flutter::EncodableValue(height);
    return flutter::EncodableValue(m);
}

// ---------------------------------------------------------------------------
// VideoCompressor
// ---------------------------------------------------------------------------

VideoCompressor::VideoCompressor() {}
VideoCompressor::~VideoCompressor() {}

int VideoCompressor::GetResolutionCap(int height) {
    if (height <= 480)  return 2500000;
    if (height <= 720)  return 5000000;
    if (height <= 1080) return 8000000;
    if (height <= 1440) return 14000000;
    return 20000000;
}

int VideoCompressor::CalculateTargetBitrate(int originalBitrate, int quality, int outputHeight) {
    int q = std::clamp(quality, 0, 100);
    double factor = 0.05 + 0.95 * (q / 100.0);
    int qualityBitrate = static_cast<int>(originalBitrate * factor);
    int capBitrate = GetResolutionCap(outputHeight);
    return std::min(qualityBitrate, capBitrate);
}

std::string VideoCompressor::GetCacheDir() {
    wchar_t tempPath[MAX_PATH];
    GetTempPathW(MAX_PATH, tempPath);
    fs::path cacheDir = fs::path(tempPath) / "easy_compressor_cache";
    fs::create_directories(cacheDir);
    return WideToUtf8(cacheDir.wstring());
}

void VideoCompressor::ClearCache() {
    wchar_t tempPath[MAX_PATH];
    GetTempPathW(MAX_PATH, tempPath);
    fs::path cacheDir = fs::path(tempPath) / "easy_compressor_cache";
    if (fs::exists(cacheDir)) {
        fs::remove_all(cacheDir);
    }
}

void VideoCompressor::Cancel() {
    is_cancelled_ = true;
    std::lock_guard<std::mutex> lock(g_op_mutex);
    if (g_op) {
        try { g_op.Cancel(); } catch (...) {}
    }
}

flutter::EncodableValue VideoCompressor::Compress(
    const std::string& inputPath,
    int quality,
    int maxHeight,
    int maxWidth,
    int frameRate,
    bool includeAudio,
    int audioBitrate,
    const std::string& /*videoCodec*/,
    const std::string& outputPath,
    std::function<void(double)> onProgress) {

    using namespace winrt;
    using namespace winrt::Windows::Foundation;
    using namespace winrt::Windows::Storage;
    using namespace winrt::Windows::Storage::FileProperties;
    using namespace winrt::Windows::Media::MediaProperties;
    using namespace winrt::Windows::Media::Transcoding;

    is_cancelled_ = false;
    const auto startTime = std::chrono::steady_clock::now();

    // These are pure Win32 — safe before WinRT apartment init.
    const std::wstring wInputPath = Utf8ToWide(inputPath);
    const int64_t originalSize = GetFileSize64(wInputPath);

    std::wstring wOutputPath;
    if (!outputPath.empty()) {
        wOutputPath = Utf8ToWide(outputPath);
    } else {
        const auto ts = std::chrono::system_clock::now().time_since_epoch().count();
        wOutputPath = Utf8ToWide(GetCacheDir() + "\\compressed_" + std::to_string(ts) + ".mp4");
    }
    const std::string outPathUtf8 = WideToUtf8(wOutputPath);

    // Initialize WinRT for this worker thread (balancing uninit_apartment in each exit path).
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
        return MakeResult("failed", outPathUtf8, originalSize, 0, 0, 0, 0, 0);
    }

    // Accumulated during probing; used by the catch-all error return.
    int durationMs   = 0;
    int reportWidth  = 0;
    int reportHeight = 0;

    try {
        // 1. Probe source properties -----------------------------------------
        auto inputFile = StorageFile::GetFileFromPathAsync(hstring{ wInputPath }).get();
        auto vp        = inputFile.Properties().GetVideoPropertiesAsync().get();

        const uint32_t origWidth  = vp.Width();
        const uint32_t origHeight = vp.Height();
        uint32_t       origBitrate = vp.Bitrate();
        durationMs = static_cast<int>(vp.Duration().count() / 10000);
        const auto orientation = vp.Orientation();

        if (origBitrate == 0 && durationMs > 0) {
            origBitrate = static_cast<uint32_t>((originalSize * 8LL * 1000) / durationMs);
        }
        if (origBitrate == 0) origBitrate = 10000000;

        // 2. Target dimensions -----------------------------------------------
        int targetWidth  = static_cast<int>(origWidth  > 0 ? origWidth  : 1920);
        int targetHeight = static_cast<int>(origHeight > 0 ? origHeight : 1080);

        if (maxHeight > 0 && targetHeight > maxHeight) {
            double scale = static_cast<double>(maxHeight) / targetHeight;
            targetHeight = maxHeight;
            targetWidth  = static_cast<int>(targetWidth * scale);
        }
        if (maxWidth > 0 && targetWidth > maxWidth) {
            double scale = static_cast<double>(maxWidth) / targetWidth;
            targetWidth  = maxWidth;
            targetHeight = static_cast<int>(targetHeight * scale);
        }
        targetWidth  = (targetWidth  / 2) * 2; if (targetWidth  < 2) targetWidth  = 2;
        targetHeight = (targetHeight / 2) * 2; if (targetHeight < 2) targetHeight = 2;

        const int targetBitrate = CalculateTargetBitrate(
            static_cast<int>(origBitrate), quality, targetHeight);

        // VideoProperties returns stored (encoded) dimensions; swap for display reporting
        // if the video carries rotation metadata.
        const bool isRotated = (orientation == VideoOrientation::Rotate90 ||
                                orientation == VideoOrientation::Rotate270);
        reportWidth  = isRotated ? targetHeight : targetWidth;
        reportHeight = isRotated ? targetWidth  : targetHeight;

        // 3. Encoding profile (MP4 / H.264 / AAC) ---------------------------
        auto profile = MediaEncodingProfile::CreateMp4(VideoEncodingQuality::Auto);
        profile.Video().Width( static_cast<uint32_t>(targetWidth));
        profile.Video().Height(static_cast<uint32_t>(targetHeight));
        profile.Video().Bitrate(static_cast<uint32_t>(targetBitrate));
        if (frameRate > 0) {
            profile.Video().FrameRate().Numerator(static_cast<uint32_t>(frameRate));
            profile.Video().FrameRate().Denominator(1u);
        }
        if (!includeAudio) {
            profile.Audio(nullptr);
        } else if (audioBitrate > 0) {
            profile.Audio().Bitrate(static_cast<uint32_t>(audioBitrate));
        }

        // 4. Resolve output StorageFile -------------------------------------
        const fs::path outP(wOutputPath);
        auto parent = StorageFolder::GetFolderFromPathAsync(
            hstring{ outP.parent_path().wstring() }).get();
        auto outputFile = parent.CreateFileAsync(
            hstring{ outP.filename().wstring() },
            CreationCollisionOption::ReplaceExisting).get();

        // 5. Transcode with hardware acceleration ---------------------------
        MediaTranscoder transcoder;
        transcoder.HardwareAccelerationEnabled(true);

        // Re-open input; the earlier StorageFile object is still valid but
        // using a fresh one avoids any shared-state surprises across async calls.
        auto inputFile2 = StorageFile::GetFileFromPathAsync(hstring{ wInputPath }).get();
        auto prep = transcoder.PrepareFileTranscodeAsync(inputFile2, outputFile, profile).get();

        if (!prep.CanTranscode()) {
            winrt::uninit_apartment();
            return MakeResult("failed", outPathUtf8, originalSize, 0,
                              durationMs, 0, reportWidth, reportHeight);
        }

        auto op = prep.TranscodeAsync();
        op.Progress([onProgress](IAsyncActionWithProgress<double> const&, double pct) {
            if (onProgress) onProgress(std::clamp(pct / 100.0, 0.0, 1.0));
        });
        {
            std::lock_guard<std::mutex> lock(g_op_mutex);
            g_op = op;
        }

        bool cancelled = false;
        try {
            op.get();
        } catch (hresult_canceled const&) {
            cancelled = true;
        } catch (hresult_error const&) {
            std::lock_guard<std::mutex> lock(g_op_mutex);
            g_op = nullptr;
            winrt::uninit_apartment();
            return MakeResult("failed", outPathUtf8, originalSize, 0,
                              durationMs, 0, reportWidth, reportHeight);
        }
        {
            std::lock_guard<std::mutex> lock(g_op_mutex);
            g_op = nullptr;
        }

        if (onProgress) onProgress(1.0);

        const auto endTime = std::chrono::steady_clock::now();
        const int compressionMs = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime).count());
        const int64_t compressedSize = cancelled ? 0 : GetFileSize64(wOutputPath);

        winrt::uninit_apartment();
        return MakeResult(cancelled ? "cancelled" : "success",
                          outPathUtf8, originalSize, compressedSize,
                          durationMs, compressionMs, reportWidth, reportHeight);

    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(g_op_mutex);
            g_op = nullptr;
        }
        try { winrt::uninit_apartment(); } catch (...) {}
        return MakeResult("failed", outPathUtf8, originalSize, 0,
                          durationMs, 0, reportWidth, reportHeight);
    }
}

}  // namespace easy_compressor
