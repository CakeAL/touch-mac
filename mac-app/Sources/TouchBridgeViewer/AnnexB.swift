import Foundation

enum CodecKind: UInt8 {
    case h264 = 0
    case hevc = 1
}

/// Annex-B 码流工具：拆 NAL、转 AVCC（长度前缀）供 VideoToolbox 使用。
enum AnnexB {
    /// 把 Annex-B 字节流拆成裸 NAL 单元（去掉 3/4 字节起始码）。
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var starts: [(index: Int, headerLen: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !starts.isEmpty else {
            return bytes.isEmpty ? [] : [data]
        }

        var nals: [Data] = []
        nals.reserveCapacity(starts.count)
        for (idx, start) in starts.enumerated() {
            let begin = start.index + start.headerLen
            let end = idx + 1 < starts.count ? starts[idx + 1].index : bytes.count
            if end > begin {
                nals.append(Data(bytes[begin..<end]))
            }
        }
        return nals
    }

    /// NAL 单元类型（不含起始码）。
    static func nalType(_ nal: Data, codec: CodecKind) -> Int {
        guard let first = nal.first else { return -1 }
        switch codec {
        case .h264:
            return Int(first & 0x1F)
        case .hevc:
            return Int((first >> 1) & 0x3F)
        }
    }

    static func isParameterSet(_ nal: Data, codec: CodecKind) -> Bool {
        let type = nalType(nal, codec: codec)
        switch codec {
        case .h264:
            return type == 7 || type == 8
        case .hevc:
            return type == 32 || type == 33 || type == 34
        }
    }

    /// 给每个 NAL 前置 4 字节大端长度（AVCC/HVCC），VideoToolbox 需要这种封装。
    static func toAVCC(_ nals: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let len = UInt32(nal.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(nal)
        }
        return out
    }
}
