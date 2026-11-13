import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 一次 CONFIG 解析出来的解码参数：编解码器、参数集、CMFormatDescription。
final class VideoFormat {
    let codec: CodecKind
    let parameterSets: [Data]
    let formatDescription: CMFormatDescription
    let dimensions: CMVideoDimensions

    private init(codec: CodecKind, parameterSets: [Data], formatDescription: CMFormatDescription) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.formatDescription = formatDescription
        self.dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
    }

    /// payload: `u8 codec` + Annex-B 的 SPS/PPS（H.264）或 VPS/SPS/PPS（HEVC）。
    static func make(from payload: Data) -> VideoFormat? {
        guard let codecByte = payload.first, let codec = CodecKind(rawValue: codecByte) else {
            return nil
        }
        let stream = payload.dropFirst()
        guard !stream.isEmpty else { return nil }

        let allNALs = AnnexB.split(Data(stream))
        let params = allNALs.filter { AnnexB.isParameterSet($0, codec: codec) }
        guard !params.isEmpty else { return nil }

        var formatDescription: CMFormatDescription?
        if codec == .h264 {
            let status = params.withUnsafeBufferPointers { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
            guard status == noErr, let formatDescription else { return nil }
            return VideoFormat(codec: codec, parameterSets: params, formatDescription: formatDescription)
        } else {
            let status = params.withUnsafeBufferPointers { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }
            guard status == noErr, let formatDescription else { return nil }
            return VideoFormat(codec: codec, parameterSets: params, formatDescription: formatDescription)
        }
    }

    /// 把一帧 Annex-B 访问单元封装成 CMSampleBuffer（AVCC 布局）。
    /// - Parameter key: 关键帧标记。非关键帧必须带 NotSync 附件，
    ///   否则 VideoToolbox 会把它当同步帧处理、每帧重置参考帧队列，P 帧随即报 bad data。
    func makeSampleBuffer(accessUnit: Data, pts: CMTime, key: Bool) -> CMSampleBuffer? {
        let nals = AnnexB.split(accessUnit).filter {
            !$0.isEmpty && !AnnexB.isParameterSet($0, codec: codec)
        }
        guard !nals.isEmpty else { return nil }

        let avcc = AnnexB.toAVCC(nals)

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus: OSStatus = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        if !key {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return sampleBuffer
    }
}

private extension Array where Element == Data {
    /// 把若干 Data 的指针和长度数组一起交给 C API，回调期间指针有效。
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let sizes = map { $0.count }

        // 嵌套闭包保证所有 Data 在 body 执行期间保持存活且指针有效。
        func recurse(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> R {
            if index == count {
                return body(pointers, sizes)
            }
            return self[index].withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return recurse(index + 1, pointers + [pointer])
            }
        }
        return recurse(0, [])
    }
}
