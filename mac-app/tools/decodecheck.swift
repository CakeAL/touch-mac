import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 离线解码自检：读取 bridge-rs 47779 的原始消息流，用与 App 相同的
/// AnnexB/VideoFormat 代码封装帧并送 VideoToolbox，逐帧打印状态。
@main
struct DecodeCheck {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            print("usage: decodecheck <stream.bin>")
            exit(2)
        }
        let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var offset = 0
        var format: VideoFormat?
        var frames: [(key: Bool, au: Data)] = []

        while offset + 5 <= data.count {
            let type = data[offset]
            let length = (Int(data[offset + 1]) << 24) | (Int(data[offset + 2]) << 16)
                | (Int(data[offset + 3]) << 8) | Int(data[offset + 4])
            offset += 5
            guard offset + length <= data.count else { break }
            let payload = data.subdata(in: offset..<(offset + length))
            offset += length
            switch type {
            case 0x01:
                format = VideoFormat.make(from: payload)
                print("CONFIG ok=\(format != nil) \(format?.dimensions.width ?? 0)x\(format?.dimensions.height ?? 0)")
            case 0x02:
                frames.append(((payload[8] & 1) != 0, payload.subdata(in: 17..<payload.count)))
            default:
                break
            }
        }

        guard let format else { print("no config"); exit(1) }
        var out: VTDecompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let cs = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format.formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &out
        )
        guard cs == noErr, let session = out else { print("session create \(cs)"); exit(1) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var decoded = 0
        var failed = 0
        var started = false
        for (index, frame) in frames.enumerated() {
            if !started {
                guard frame.key else { continue }
                started = true
            }
            let pts = CMTime(value: CMTimeValue(index + 1), timescale: 60)
            guard let sb = format.makeSampleBuffer(accessUnit: frame.au, pts: pts, key: frame.key) else {
                print("#\(index) key=\(frame.key) sampleBuffer=nil")
                continue
            }
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sb, flags: [], infoFlagsOut: nil
            ) { st, flags, image, _, _ in
                if st != noErr || image == nil {
                    print("#\(index) key=\(frame.key) handler status=\(st) flags=\(flags.rawValue) img=\(image != nil)")
                } else {
                    decoded += 1
                }
            }
            if status != noErr {
                failed += 1
                print("#\(index) key=\(frame.key) au=\(frame.au.count) sync status=\(status)")
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        print("frames=\(frames.count) decoded=\(decoded) failed=\(failed)")
    }
}
