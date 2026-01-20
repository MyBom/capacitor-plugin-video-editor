//
//  SimpleSessionExporter.swift
//  CapacitorPluginVideoEditor
//
//  Modified to use AVAssetWriter for H.264 codec support
//

import Foundation
import AVFoundation
import UIKit

// MARK: - SimpleSessionExporter

open class SimpleSessionExporter: NSObject {
    
    public var asset: AVAsset?
    public var outputURL: URL?
    public var outputFileType: AVFileType? = AVFileType.mp4
    public var timeRange: CMTimeRange
    public var optimizeForNetworkUse: Bool = false
    public var videoOutputConfiguration: [String : Any]?
    public var fps: Int = 30
    
    private var assetWriter: AVAssetWriter?
    private var assetReader: AVAssetReader?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoOutput: AVAssetReaderVideoCompositionOutput?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    
    private var _progress: Float = 0.0
    private var totalDuration: CMTime = .zero
    
    public convenience init(withAsset asset: AVAsset) {
        self.init()
        self.asset = asset
    }
    
    public override init() {
        self.timeRange = CMTimeRange(start: CMTime.zero, end: CMTime.positiveInfinity)
        super.init()
    }
    
    deinit {
        self.asset = nil
        self.assetWriter = nil
        self.assetReader = nil
    }
}

// MARK: - export

extension SimpleSessionExporter {
    
    public typealias CompletionHandler = (_ status: AVAssetExportSession.Status) -> Void
    
    var progress: Float {
        get {
            return _progress
        }
    }
    
    public func export(completionHandler: @escaping CompletionHandler) {
        guard let asset = self.asset,
              let outputURL = self.outputURL,
              let _ = self.outputFileType else {
            print("SimpleSessionExporter, an asset and output URL are required for encoding")
            completionHandler(.failed)
            return
        }
        
        // 기존 파일 삭제
        try? FileManager.default.removeItem(at: outputURL)
        
        // AssetWriter 설정
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            print("Failed to create AVAssetWriter: \(error)")
            completionHandler(.failed)
            return
        }
        
        guard let assetWriter = assetWriter else {
            completionHandler(.failed)
            return
        }
        
        // Video 트랙 가져오기
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("No video track found")
            completionHandler(.failed)
            return
        }
        
        // 비디오 크기 계산
        let transformedVideoSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let mediaSize = CGSize(width: abs(transformedVideoSize.width), height: abs(transformedVideoSize.height))
        
        let videoWidth = self.videoOutputConfiguration?[AVVideoWidthKey] as? NSNumber
        let videoHeight = self.videoOutputConfiguration?[AVVideoHeightKey] as? NSNumber
        
        let width = videoWidth?.intValue ?? Int(mediaSize.width)
        let height = videoHeight?.intValue ?? Int(mediaSize.height)
        let videoSize = CGSize(width: width, height: height)
        
        // H.264 코덱으로 비디오 설정
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 3,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = false
        
        // 비디오 변환 설정
        let scale = videoSize.width / mediaSize.width
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        videoComposition.instructions = [instruction]
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(asset.scaleTransform(scaleFactor: scale), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        
        // AssetReader 설정
        do {
            assetReader = try AVAssetReader(asset: asset)
        } catch {
            print("Failed to create AVAssetReader: \(error)")
            completionHandler(.failed)
            return
        }
        
        guard let assetReader = assetReader else {
            completionHandler(.failed)
            return
        }
        
        // Video Output 설정
        videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput?.videoComposition = videoComposition
        videoOutput?.alwaysCopiesSampleData = false
        
        if let videoOutput = videoOutput {
            assetReader.add(videoOutput)
        }
        
        if let videoInput = videoInput {
            assetWriter.add(videoInput)
        }
        
        // Audio 트랙 설정
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = false
            
            audioOutput = AVAssetReaderAudioMixOutput(
                audioTracks: [audioTrack],
                audioSettings: nil
            )
            audioOutput?.alwaysCopiesSampleData = false
            
            if let audioOutput = audioOutput {
                assetReader.add(audioOutput)
            }
            
            // 오디오를 먼저 추가
            if let audioInput = audioInput {
                assetWriter.add(audioInput)
            }
        }
        
        // timeRange 설정
        assetReader.timeRange = timeRange
        totalDuration = timeRange.duration
        
        // 인코딩 시작
        guard assetWriter.startWriting() else {
            print("Failed to start writing: \(String(describing: assetWriter.error))")
            completionHandler(.failed)
            return
        }
        
        guard assetReader.startReading() else {
            print("Failed to start reading: \(String(describing: assetReader.error))")
            completionHandler(.failed)
            return
        }
        
        assetWriter.startSession(atSourceTime: timeRange.start)
        
        let dispatchGroup = DispatchGroup()
        
        // 오디오 인코딩 (먼저 시작하여 Stream Order 유지)
        if let audioInput = audioInput, let audioOutput = audioOutput {
            dispatchGroup.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioQueue")) {
                self.encodeAudioSamples(input: audioInput, output: audioOutput) {
                    dispatchGroup.leave()
                }
            }
        }
        
        // 비디오 인코딩
        if let videoInput = videoInput, let videoOutput = videoOutput {
            dispatchGroup.enter()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoQueue")) { [weak self] in
                self?.encodeVideoSamples(input: videoInput, output: videoOutput) {
                    dispatchGroup.leave()
                }
            }
        }
        
        // 완료 처리
        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            self.assetReader?.cancelReading()
            self.assetWriter?.finishWriting {
                DispatchQueue.main.async {
                    switch self.assetWriter?.status {
                    case .completed:
                        self._progress = 1.0
                        completionHandler(.completed)
                    case .failed:
                        print("Export failed: \(String(describing: self.assetWriter?.error))")
                        completionHandler(.failed)
                    case .cancelled:
                        completionHandler(.cancelled)
                    default:
                        completionHandler(.failed)
                    }
                    
                    self.assetWriter = nil
                    self.assetReader = nil
                }
            }
        }
    }
    
    private func encodeVideoSamples(input: AVAssetWriterInput, output: AVAssetReaderOutput, completion: @escaping () -> Void) {
        while input.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                completion()
                return
            }
            
            // 진행률 업데이트
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let elapsed = CMTimeSubtract(timestamp, timeRange.start)
            if totalDuration.seconds > 0 {
                _progress = Float(elapsed.seconds / totalDuration.seconds) * 0.9 // 90%까지만 표시
            }
            
            if !input.append(sampleBuffer) {
                print("Failed to append video sample")
                input.markAsFinished()
                completion()
                return
            }
        }
    }
    
    private func encodeAudioSamples(input: AVAssetWriterInput, output: AVAssetReaderOutput, completion: @escaping () -> Void) {
        while input.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                completion()
                return
            }
            
            if !input.append(sampleBuffer) {
                print("Failed to append audio sample")
                input.markAsFinished()
                completion()
                return
            }
        }
    }
}

// MARK: - AVAsset extension

extension AVAsset {
    
    public func simple_export(outputFileType: AVFileType? = AVFileType.mp4,
                              outputURL: URL,
                              videoOutputConfiguration: [String : Any],
                              completionHandler: @escaping SimpleSessionExporter.CompletionHandler) {
        let exporter = SimpleSessionExporter(withAsset: self)
        exporter.outputFileType = outputFileType
        exporter.outputURL = outputURL
        exporter.videoOutputConfiguration = videoOutputConfiguration
        exporter.export(completionHandler: completionHandler)
    }
    
    private var g_naturalSize: CGSize {
        return tracks(withMediaType: AVMediaType.video).first?.naturalSize ?? .zero
    }
    
    var g_correctSize: CGSize {
        return g_isPortrait ? CGSize(width: g_naturalSize.height, height: g_naturalSize.width) : g_naturalSize
    }
    
    var g_isPortrait: Bool {
        let portraits: [UIInterfaceOrientation] = [.portrait, .portraitUpsideDown]
        return portraits.contains(g_orientation)
    }
    
    var g_orientation: UIInterfaceOrientation {
        guard let transform = tracks(withMediaType: AVMediaType.video).first?.preferredTransform else {
            return .portrait
        }
        
        switch (transform.tx, transform.ty) {
        case (0, 0):
            return .landscapeRight
        case (g_naturalSize.width, g_naturalSize.height):
            return .landscapeLeft
        case (0, g_naturalSize.width):
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
    
    public func scaleTransform(scaleFactor: CGFloat) -> CGAffineTransform {
        let offset: CGPoint
        let angle: Double

        switch g_orientation {
        case .landscapeLeft:
            offset = CGPoint(x: g_correctSize.width, y: g_correctSize.height)
            angle = Double.pi / 2
        case .landscapeRight:
            offset = CGPoint.zero
            angle = 0
        case .portraitUpsideDown:
            offset = CGPoint(x: 0, y: g_correctSize.height)
            angle = -Double.pi / 2
        default:
            offset = CGPoint(x: g_correctSize.width, y: 0)
            angle = Double.pi / 2
        }

        let scale = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        let translation = scale.translatedBy(x: offset.x, y: offset.y)
        let rotation = translation.rotated(by: CGFloat(angle))

        return rotation
    }
}