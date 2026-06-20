import AVFoundation
import CoreMedia

class VideoCompressor {
    private var assetReader: AVAssetReader?
    private var assetWriter: AVAssetWriter?
    private var isCancelled = false

    private static let cacheDirName = "easy_compressor_cache"

    static func clearCache() {
        let tempDir = NSTemporaryDirectory()
        let cacheDir = (tempDir as NSString).appendingPathComponent(cacheDirName)
        try? FileManager.default.removeItem(atPath: cacheDir)
    }

    private static func getResolutionCap(_ height: Int) -> Int {
        switch height {
        case ...480: return 2_500_000
        case ...720: return 5_000_000
        case ...1080: return 8_000_000
        case ...1440: return 14_000_000
        default: return 20_000_000
        }
    }

    private static func calculateTargetBitrate(originalBitrate: Int, quality: Int, outputHeight: Int) -> Int {
        let q = max(0, min(100, quality))
        let factor = 0.05 + 0.95 * (Double(q) / 100.0)
        let qualityBitrate = Int(Double(originalBitrate) * factor)
        let capBitrate = getResolutionCap(outputHeight)
        return min(qualityBitrate, capBitrate)
    }

    func compress(
        inputPath: String,
        quality: Int,
        maxHeight: Int?,
        maxWidth: Int?,
        frameRate: Int?,
        includeAudio: Bool,
        audioBitrate: Int,
        videoCodec: String,
        outputPath: String?,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        isCancelled = false
        let startTime = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let result = try self.performCompression(
                    inputPath: inputPath,
                    quality: quality,
                    maxHeight: maxHeight,
                    maxWidth: maxWidth,
                    frameRate: frameRate,
                    includeAudio: includeAudio,
                    audioBitrate: audioBitrate,
                    videoCodec: videoCodec,
                    outputPath: outputPath,
                    startTime: startTime,
                    onProgress: onProgress
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func performCompression(
        inputPath: String,
        quality: Int,
        maxHeight: Int?,
        maxWidth: Int?,
        frameRate: Int?,
        includeAudio: Bool,
        audioBitrate: Int,
        videoCodec: String,
        outputPath: String?,
        startTime: Date,
        onProgress: @escaping (Double) -> Void
    ) throws -> [String: Any] {
        let inputURL = URL(fileURLWithPath: inputPath)
        let asset = AVAsset(url: inputURL)

        let originalSize = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int) ?? 0

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "EasyCompressor", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No video track found"
            ])
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000)

        // The frame buffer is encoded in `naturalSize`; the rotation transform tells the
        // player how to display it. We keep the encoded orientation and preserve the
        // transform so the output is upright with the correct aspect ratio (no squash).
        let isRotated = transform.a == 0

        // Display dimensions drive the max-height/width constraints and reporting.
        let displayWidth = isRotated ? naturalSize.height : naturalSize.width
        let displayHeight = isRotated ? naturalSize.width : naturalSize.height

        let originalBitrate = Int(videoTrack.estimatedDataRate)

        // Compute a single uniform downscale factor from the display constraints (never upscale).
        var scale = 1.0
        if let mh = maxHeight, Int(displayHeight) > mh {
            scale = min(scale, Double(mh) / Double(displayHeight))
        }
        if let mw = maxWidth, Int(displayWidth) > mw {
            scale = min(scale, Double(mw) / Double(displayWidth))
        }

        // Apply the uniform scale to the ENCODED dimensions so the writer receives frames
        // with their original aspect ratio preserved.
        var targetWidth = Int((Double(naturalSize.width) * scale).rounded())
        var targetHeight = Int((Double(naturalSize.height) * scale).rounded())

        targetWidth = (targetWidth / 2) * 2
        targetHeight = (targetHeight / 2) * 2
        if targetWidth < 2 { targetWidth = 2 }
        if targetHeight < 2 { targetHeight = 2 }

        // Reported/cap dimensions are in display orientation.
        let outputDisplayWidth = isRotated ? targetHeight : targetWidth
        let outputDisplayHeight = isRotated ? targetWidth : targetHeight

        let targetBitrate = VideoCompressor.calculateTargetBitrate(
            originalBitrate: originalBitrate,
            quality: quality,
            outputHeight: outputDisplayHeight
        )

        let outURL: URL
        if let op = outputPath {
            outURL = URL(fileURLWithPath: op)
        } else {
            let tempDir = NSTemporaryDirectory()
            let cacheDir = (tempDir as NSString).appendingPathComponent(VideoCompressor.cacheDirName)
            try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            let filename = "compressed_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"
            outURL = URL(fileURLWithPath: (cacheDir as NSString).appendingPathComponent(filename))
        }

        try? FileManager.default.removeItem(at: outURL)

        let reader = try AVAssetReader(asset: asset)
        self.assetReader = reader

        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        videoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(videoOutput) { reader.add(videoOutput) }

        var audioOutput: AVAssetReaderTrackOutput?
        let audioTrack = asset.tracks(withMediaType: .audio).first
        if includeAudio, let at = audioTrack {
            let audioReaderSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
            let aOutput = AVAssetReaderTrackOutput(track: at, outputSettings: audioReaderSettings)
            aOutput.alwaysCopiesSampleData = false
            if reader.canAdd(aOutput) {
                reader.add(aOutput)
                audioOutput = aOutput
            }
        }

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        self.assetWriter = writer

        let codecType: AVVideoCodecType = videoCodec == "h265" ? .hevc : .h264

        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Preserve the source rotation as metadata so players display the clip upright.
        videoInput.transform = transform
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        var audioInput: AVAssetWriterInput?
        if includeAudio && audioOutput != nil {
            let audioWriterSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: audioBitrate
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriterSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalDuration = CMTimeGetSeconds(asset.duration)
        let videoFinished = DispatchSemaphore(value: 0)
        let audioFinished = DispatchSemaphore(value: 0)

        let videoQueue = DispatchQueue(label: "com.easycompressor.macos.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            while videoInput.isReadyForMoreMediaData {
                if self?.isCancelled == true {
                    videoInput.markAsFinished()
                    videoFinished.signal()
                    return
                }
                if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentTime = CMTimeGetSeconds(timestamp)
                    if totalDuration > 0 {
                        onProgress(min(currentTime / totalDuration, 1.0))
                    }
                    videoInput.append(sampleBuffer)
                } else {
                    videoInput.markAsFinished()
                    videoFinished.signal()
                    return
                }
            }
        }

        if let aOutput = audioOutput, let aInput = audioInput {
            let audioQueue = DispatchQueue(label: "com.easycompressor.macos.audio")
            aInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                while aInput.isReadyForMoreMediaData {
                    if self?.isCancelled == true {
                        aInput.markAsFinished()
                        audioFinished.signal()
                        return
                    }
                    if let sampleBuffer = aOutput.copyNextSampleBuffer() {
                        aInput.append(sampleBuffer)
                    } else {
                        aInput.markAsFinished()
                        audioFinished.signal()
                        return
                    }
                }
            }
        } else {
            audioFinished.signal()
        }

        videoFinished.wait()
        audioFinished.wait()

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            return [
                "outputPath": outURL.path,
                "originalSize": originalSize,
                "compressedSize": 0,
                "duration": durationMs,
                "compressionTime": Int(Date().timeIntervalSince(startTime) * 1000),
                "width": outputDisplayWidth,
                "height": outputDisplayHeight,
                "status": "cancelled"
            ]
        }

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSemaphore.signal() }
        finishSemaphore.wait()

        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        let compressionTime = Int(Date().timeIntervalSince(startTime) * 1000)

        onProgress(1.0)

        return [
            "outputPath": outURL.path,
            "originalSize": originalSize,
            "compressedSize": compressedSize,
            "duration": durationMs,
            "compressionTime": compressionTime,
            "width": outputDisplayWidth,
            "height": outputDisplayHeight,
            "status": "success"
        ]
    }

    func cancel() {
        isCancelled = true
        assetReader?.cancelReading()
    }
}
