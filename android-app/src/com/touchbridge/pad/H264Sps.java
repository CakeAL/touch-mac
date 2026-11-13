package com.touchbridge.pad;

import java.util.Arrays;

/**
 * 极简 H.264 SPS 解析：从 Annex-B 字节流里找到 NAL type 7，解析出显示宽高。
 * 只为给 MediaCodec 的 MediaFormat 填一份靠谱的 width/height；解析失败返回 null，
 * 由调用方退回 surface 尺寸。
 */
final class H264Sps {
    private H264Sps() {
    }

    /** @return {width, height}，失败返回 null。 */
    static int[] parse(byte[] buf) {
        int n = buf.length;
        int i = 0;
        while (i + 3 <= n) {
            int start;
            if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
                start = i + 3;
            } else if (i + 4 <= n && buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 0 && buf[i + 3] == 1) {
                start = i + 4;
            } else {
                i++;
                continue;
            }
            if (start >= n) {
                return null;
            }
            int type = buf[start] & 0x1f;
            int end = nalEnd(buf, start, n);
            if (type == 7) {
                int[] wh = parseSps(rbsp(buf, start + 1, end));
                if (wh != null) {
                    return wh;
                }
            }
            i = Math.max(end, start + 1);
        }
        return null;
    }

    /** 下一个起始码（含 3/4 字节两种）的位置；没有则返回流尾。 */
    private static int nalEnd(byte[] buf, int from, int n) {
        for (int j = from + 1; j + 2 < n; j++) {
            if (buf[j] == 0 && buf[j + 1] == 0 && buf[j + 2] == 1) {
                return j;
            }
            if (buf[j] == 0 && buf[j + 1] == 0 && buf[j + 2] == 0 && j + 3 < n && buf[j + 3] == 1) {
                return j;
            }
        }
        return n;
    }

    /** 去掉防竞争字节 00 00 03 → 00 00。 */
    private static byte[] rbsp(byte[] src, int from, int to) {
        byte[] out = new byte[Math.max(0, to - from)];
        int k = 0;
        int zeros = 0;
        for (int i = from; i < to; i++) {
            int b = src[i] & 0xff;
            if (zeros >= 2 && b == 3) {
                zeros = 0;
                continue;
            }
            out[k++] = (byte) b;
            if (b == 0) {
                zeros++;
            } else {
                zeros = 0;
            }
        }
        return Arrays.copyOf(out, k);
    }

    private static int[] parseSps(byte[] rbsp) {
        try {
            Bits b = new Bits(rbsp);
            int profile = b.u(8);
            b.u(8);            // constraint_set*_flag + reserved
            b.u(8);            // level_idc
            b.ue();            // seq_parameter_set_id

            int chromaFormat = 1;
            boolean separateColourPlane = false;
            if (profile == 100 || profile == 110 || profile == 122 || profile == 244
                    || profile == 44 || profile == 83 || profile == 86 || profile == 118
                    || profile == 128 || profile == 138 || profile == 139 || profile == 134
                    || profile == 135) {
                chromaFormat = b.ue();
                if (chromaFormat == 3) {
                    separateColourPlane = b.u(1) == 1;
                }
                b.ue();        // bit_depth_luma_minus8
                b.ue();        // bit_depth_chroma_minus8
                b.u(1);        // qpprime_y_zero_transform_bypass_flag
                if (b.u(1) == 1) {
                    int count = chromaFormat == 3 ? 12 : 8;
                    for (int i = 0; i < count; i++) {
                        if (b.u(1) == 1) {
                            skipScalingList(b, i < 6 ? 16 : 64);
                        }
                    }
                }
            }

            b.ue();            // log2_max_frame_num_minus4
            int pocType = b.ue();
            if (pocType == 0) {
                b.ue();        // log2_max_pic_order_cnt_lsb_minus4
            } else if (pocType == 1) {
                b.u(1);        // delta_pic_order_always_zero_flag
                b.se();        // offset_for_non_ref_pic
                b.se();        // offset_for_top_to_bottom_field
                int cycle = b.ue();
                for (int i = 0; i < cycle && i < 256; i++) {
                    b.se();
                }
            }
            b.ue();            // max_num_ref_frames
            b.u(1);            // gaps_in_frame_num_value_allowed_flag

            int wMbs = b.ue() + 1;
            int hMapUnits = b.ue() + 1;
            boolean frameMbsOnly = b.u(1) == 1;
            if (!frameMbsOnly) {
                b.u(1);        // mb_adaptive_frame_field_flag
            }
            b.u(1);            // direct_8x8_inference_flag

            int cropL = 0, cropR = 0, cropT = 0, cropB = 0;
            if (b.u(1) == 1) { // frame_cropping_flag
                cropL = b.ue();
                cropR = b.ue();
                cropT = b.ue();
                cropB = b.ue();
            }

            int width = wMbs * 16;
            int height = (frameMbsOnly ? 1 : 2) * hMapUnits * 16;

            int chromaArrayType = separateColourPlane ? 0 : chromaFormat;
            int subWidthC = (chromaFormat == 1 || chromaFormat == 2) ? 2 : 1;
            int subHeightC = chromaFormat == 1 ? 2 : 1;
            int cropUnitX = chromaArrayType == 0 ? 1 : subWidthC;
            int cropUnitY = chromaArrayType == 0
                    ? (frameMbsOnly ? 1 : 2)
                    : subHeightC * (frameMbsOnly ? 1 : 2);
            width -= cropUnitX * (cropL + cropR);
            height -= cropUnitY * (cropT + cropB);

            if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
                return null;
            }
            return new int[]{width, height};
        } catch (RuntimeException e) {
            return null;
        }
    }

    private static void skipScalingList(Bits b, int size) {
        int last = 8;
        int next = 8;
        for (int j = 0; j < size; j++) {
            if (next != 0) {
                int delta = b.se();
                next = (last + delta + 256) % 256;
            }
            last = next == 0 ? last : next;
        }
    }

    /** 按位读取 + 指数哥伦布。越界直接抛 RuntimeException，由 parseSps 兜住。 */
    private static final class Bits {
        private final byte[] d;
        private int pos;

        Bits(byte[] d) {
            this.d = d;
        }

        int u(int bits) {
            int v = 0;
            for (int i = 0; i < bits; i++) {
                int bit = (d[pos >> 3] >> (7 - (pos & 7))) & 1;
                pos++;
                v = (v << 1) | bit;
            }
            return v;
        }

        int ue() {
            int zeros = 0;
            while (u(1) == 0) {
                if (++zeros > 31) {
                    throw new IllegalStateException("bad ue");
                }
            }
            if (zeros == 0) {
                return 0;
            }
            return (1 << zeros) - 1 + u(zeros);
        }

        int se() {
            int k = ue();
            int v = (k + 1) / 2;
            return (k % 2 == 0) ? -v : v;
        }
    }
}
