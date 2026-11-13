package com.touchbridge.pad;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Mac → 平板 的 H.264 视频接收 + MediaCodec 硬解，直接渲染到 SurfaceView 的 Surface。
 *
 * 传输（TCP 127.0.0.1:47779，adb reverse 由 Mac 侧建立）：
 *   u8 type | u32 BE length | payload
 *   type=0x01 CONFIG：payload 是带 00 00 00 01 起始码的 Annex-B（SPS/PPS），整段作为 csd-0
 *   type=0x02 FRAME ：payload = u64 BE pts_us | u8 flags | Annex-B access unit
 *                     flags bit0=1 表示关键帧（IDR）
 *
 * 两条后台线程：
 *   video-net  连接 / 断线后 400ms 重连 / 拆包，并把 access unit 放进有界队列
 *              （队列满了丢弃积压并要求解码器在下一个 IDR 重新同步，避免延迟无限增长）
 *   video-dec  MediaCodec 的生命周期与送帧；Surface 失效时立刻 stop/release，
 *              CONFIG 变化时先 stop/release 再按新 csd 重建
 * 两条线程都不碰 UI；状态变化通过 StateListener 通知出去。
 */
public final class VideoClient {
    static final String TAG = "TouchBridge";
    static final String HOST = "127.0.0.1";
    static final int PORT = 47779;

    private static final int TYPE_AUDIO = 0x03;
    private static final int TYPE_CONFIG = 0x01;
    private static final int TYPE_FRAME = 0x02;

    /** 单条消息上限，防止坏长度把内存吃穿。 */
    private static final int MAX_MESSAGE = 16 * 1024 * 1024;
    /** 待解码帧数上限：一帧 100KB 级，12 帧 ≈ 1.2MB，够吸收抖动又不会积压成延迟。 */
    private static final int FRAME_QUEUE = 6;

    /** 低延迟解码（Qualcomm 上可能引起画面撕裂）。可通过设置面板关闭。 */
    private volatile boolean lowLatency = false;

    /** 给 Surface 的帧率提示，等于实际码流帧率（不是面板刷新率）。 */
    private volatile float frameRateHint = 60f;
    private float measuredFps = 0f;
    private long fpsWindowStart = 0;
    private int fpsWindowFrames = 0;
    /** 上行心跳间隔：adbd 会攒包，间隔越小单向延时越低（实测 5ms→3.5ms，2ms→1.5ms，1ms→0.8ms）。 */
    static volatile int KEEPALIVE_MS = readKeepalive();

    /** 允许用 /data/local/tmp/tb_ka 临时调心跳间隔（调试用，缺省 5 ms）。 */
    private static int readKeepalive() {
        try {
            java.io.File f = new java.io.File("/data/local/tmp/tb_ka");
            if (f.canRead()) {
                String v = new String(java.nio.file.Files.readAllBytes(f.toPath())).trim();
                int ms = Integer.parseInt(v);
                if (ms >= 1 && ms <= 100) return ms;
            }
        } catch (Exception ignore) {
        }
        return 2;
    }
    private static final int RECONNECT_MS = 400;
    private static final int TYPE_TICK = 0x04;

    interface StateListener {
        void onState(String text);
    }

    private final Object codecLock = new Object();
    private final ArrayBlockingQueue<Frame> frames = new ArrayBlockingQueue<>(FRAME_QUEUE);

    private volatile boolean running = true;
    /** 请求解码器丢弃到下一个 IDR 再继续送帧（配置变化 / 队列溢出）。 */
    private volatile boolean wantResync = true;

    // ---- 以下字段由 codecLock 保护 ----
    private Surface surface;
    private int surfaceW;
    private int surfaceH;
    private byte[] csd;
    private String codecMime = "video/avc";
    private String appliedMime = "video/avc";
    private volatile AudioPlayer audio;
    private final java.util.ArrayDeque<Long> inflightSendUs = new java.util.ArrayDeque<>();
    private final java.util.ArrayDeque<Long> inflightFeedUs = new java.util.ArrayDeque<>();
    /** 桥的单调时钟（微秒），用于算网络/解码/合成各段延时。 */
    private volatile java.util.function.LongSupplier bridgeClock;
    private volatile Runnable idrRequester;
    private long statRecvSum, statRecvN, statTotSum, statTotN, statDecSum, statDecN;
    private long audioNetSum, audioNetN;
    private int audioPeak, audioPkCount;
    private int tickN;

    void setIdrRequester(Runnable r) {
        idrRequester = r;
    }

    void setBridgeClock(java.util.function.LongSupplier c) {
        bridgeClock = c;
    }

    /** 每渲染一帧回调一次，参数是 bridge 侧发出该帧的单调微秒。 */
    interface RenderListener {
        void onRendered(long sendUs);
    }

    private volatile RenderListener renderListener;

    void setRenderListener(RenderListener l) {
        renderListener = l;
    }
    private volatile boolean audioWanted = true;
    private long csdGen;
    private MediaCodec codec;
    private byte[] appliedCsd;
    private long appliedGen = -1;
    private Surface appliedSurface;
    private boolean needKey = true;
    private boolean gotFrame;

    private volatile String netState = "connecting…";
    private volatile String decState = "idle";
    private volatile long lastFrameAt;
    private volatile int videoW;
    private volatile int videoH;
    private volatile StateListener listener;

    private volatile Socket socket;
    private Thread netThread;
    private Thread decThread;

    void setStateListener(StateListener l) {
        listener = l;
    }

    String statusText() {
        String d = decState;
        String n = netState;
        return "video: " + n + ("idle".equals(d) ? "" : " · " + d);
    }

    /** 最近 1.5s 内有帧被渲染出去。 */
    boolean isPlaying() {
        long t = lastFrameAt;
        return t != 0 && SystemClock.elapsedRealtime() - t < 1500;
    }

    // ---------------------------------------------------------------- 生命周期

    void start() {
        netThread = new Thread(this::netLoop, "video-net");
        netThread.setDaemon(true);
        netThread.start();
        decThread = new Thread(this::decLoop, "video-dec");
        decThread.setDaemon(true);
        decThread.start();
    }

    void shutdown() {
        running = false;
        closeQuietly();
        if (netThread != null) netThread.interrupt();
        if (decThread != null) decThread.interrupt();
        synchronized (codecLock) {
            releaseCodecLocked();
        }
        setNetState("stopped");
    }

    // ---------------------------------------------------------------- Surface

    /** SurfaceView 的 Surface 建好了（主线程回调）。 */
    /** 低延迟解码开关（改完需要重建解码器，由调用方负责）。 */
    void setLowLatency(boolean on) {
        lowLatency = on;
    }

    /** 按实测码流帧率给 Surface 帧率提示，避免 60fps 内容配 120Hz 提示造成节奏错乱。 */
    private void noteFrameForFps() {
        long now = SystemClock.elapsedRealtime();
        if (fpsWindowStart == 0) {
            fpsWindowStart = now;
            fpsWindowFrames = 0;
            return;
        }
        fpsWindowFrames++;
        long dt = now - fpsWindowStart;
        if (dt >= 1000) {
            float fps = fpsWindowFrames * 1000f / dt;
            fpsWindowStart = now;
            fpsWindowFrames = 0;
            if (fps > 5 && Math.abs(fps - measuredFps) > 3f) {
                measuredFps = fps;
                float hint = Math.round(fps / 10f) * 10f;
                if (Math.abs(hint - frameRateHint) >= 1f) {
                    frameRateHint = hint;
                    Surface s = surface;
                    if (s != null && Build.VERSION.SDK_INT >= 30) {
                        try {
                            s.setFrameRate(hint, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
                            Log.i(TAG, "video frame rate hint -> " + hint);
                        } catch (Exception ignore) {
                        }
                    }
                }
            }
        }
    }

    void setSurface(Surface s, int w, int h) {
        synchronized (codecLock) {
            surface = s;
            surfaceW = w;
            surfaceH = h;
        }
        // 显式告诉系统这块 surface 要按高帧率出图：不然 SurfaceFlinger 可能按 60 Hz 合成，
        // 白白多等一个 16.7 ms 的 vsync。
        try {
            if (Build.VERSION.SDK_INT >= 30 && s != null) {
                s.setFrameRate(frameRateHint, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
            }
        } catch (Exception e) {
            Log.w(TAG, "setFrameRate failed: " + e);
        }
        Log.i(TAG, "video surface ready " + w + "x" + h);
    }

    /** 活动框比例变化导致 SurfaceView 尺寸变化（surface 本身没销毁）。 */
    void onSurfaceSize(int w, int h) {
        synchronized (codecLock) {
            surfaceW = w;
            surfaceH = h;
        }
        Log.i(TAG, "video surface resized " + w + "x" + h);
    }

    /** Surface 即将销毁：必须在 surface 失效前把 codec 放掉。 */
    void clearSurface() {
        synchronized (codecLock) {
            surface = null;
            releaseCodecLocked();
        }
        Log.i(TAG, "video surface destroyed, codec released");
        setDecState("waiting for surface");
    }

    // ---------------------------------------------------------------- 网络线程

    private void netLoop() {
        while (running) {
            boolean connected = false;
            try {
                Socket s = new Socket();
                s.setTcpNoDelay(true);
                s.setKeepAlive(true);
                s.setReceiveBufferSize(1 << 20);
                s.connect(new InetSocketAddress(HOST, PORT), 1500);
                socket = s;
                connected = true;
                // 反向保活：adbd 对“只下行”的 socket 会攒包，周期性上行一个字节可以让它尽快 flush
                final java.io.OutputStream keep = s.getOutputStream();
                Thread kt = new Thread(() -> {
                    while (running && !s.isClosed()) {
                        try {
                            keep.write('k');
                            keep.flush();
                            Thread.sleep(KEEPALIVE_MS);
                        } catch (Exception e) {
                            return;
                        }
                    }
                }, "video-keepalive");
                kt.setDaemon(true);
                kt.start();
                Log.i(TAG, "video connected to " + HOST + ":" + PORT);
                setNetState("connected");
                DataInputStream in = new DataInputStream(
                        new BufferedInputStream(s.getInputStream(), 64 * 1024));
                readLoop(in);
            } catch (Exception e) {
                if (!running) break;
                // 已连上后断开由下面的 "stream closed" 分支统一报告，避免重复日志
                if (!connected) {
                    Log.w(TAG, "video link failure: " + e + " — retry in " + RECONNECT_MS + "ms");
                    setNetState("no stream, retry " + RECONNECT_MS + "ms");
                }
            } finally {
                closeQuietly();
            }
            if (!running) break;
            if (connected) {
                Log.w(TAG, "video stream closed — retry in " + RECONNECT_MS + "ms");
                setNetState("stream closed, retry " + RECONNECT_MS + "ms");
            }
            try {
                Thread.sleep(RECONNECT_MS);
            } catch (InterruptedException ie) {
                break;
            }
        }
        setNetState("stopped");
    }

    /** 按协议逐条读消息；大消息用 readFully 整块读。 */
    private void readLoop(DataInputStream in) throws IOException {
        // 收流线程提到高优先级：低优先级时读 socket 会被解码线程抢占，实测能多出十几毫秒
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
        } catch (Exception ignore) {
        }
        while (running) {
            int type = in.readUnsignedByte();
            long len = ((long) in.readUnsignedByte() << 24)
                    | ((long) in.readUnsignedByte() << 16)
                    | ((long) in.readUnsignedByte() << 8)
                    | in.readUnsignedByte();
            if (len < 0 || len > MAX_MESSAGE) {
                throw new IOException("bad message length " + len + " (type=" + type + ")");
            }
            byte[] payload = new byte[(int) len];
            in.readFully(payload);
            if (type == TYPE_CONFIG) {
                onConfig(payload);
            } else if (type == TYPE_FRAME) {
                onFramePayload(payload);
            } else if (type == TYPE_TICK) {
                if (payload.length >= 8) {
                    long send = 0;
                    for (int i = 0; i < 8; i++) send = (send << 8) | (payload[i] & 0xffL);
                    java.util.function.LongSupplier ck = bridgeClock;
                    long now = ck == null ? 0 : ck.getAsLong();
                    if (now > 0) {
                        long d = now - send;
                        if (d > -1_000_000L && d < 1_000_000L && (++tickN % 20) == 1) {
                            Log.i(TAG, String.format(java.util.Locale.US, "tick one-way %.2f ms", d / 1000.0));
                        }
                    }
                }
            } else if (type == TYPE_AUDIO) {
                onAudioPayload(payload);
            } else {
                Log.w(TAG, "video: unknown message type " + type + " len=" + len);
            }
        }
    }

    private void onAudioPayload(byte[] payload) {
        if (payload.length < 9) return;
        long pts = 0;
        for (int i = 0; i < 8; i++) {
            pts = (pts << 8) | (payload[i] & 0xffL);
        }
        java.util.function.LongSupplier ck = bridgeClock;
        long nowUs = ck == null ? 0 : ck.getAsLong();
        if (nowUs > 0) {
            long d = nowUs - pts;
            if (d > 0 && d < 5_000_000L) {
                audioNetSum += d;
                if (++audioNetN >= 360) {
                    Log.i(TAG, String.format(java.util.Locale.US,
                            "audio net %.1f ms (n=%d)", audioNetSum / 1000.0 / audioNetN, audioNetN));
                    audioNetSum = 0;
                    audioNetN = 0;
                }
            }
        }
        int pk = 0;
        for (int i = 8; i + 1 < payload.length; i += 2) {
            int v = (short) ((payload[i] & 0xff) | (payload[i + 1] << 8));
            pk = Math.max(pk, Math.abs(v));
        }
        audioPeak = Math.max(audioPeak, pk);
        if (++audioPkCount >= 200) {
            Log.i(TAG, "audio peak " + audioPeak + " / " + audioPkCount + " pkts");
            audioPeak = 0;
            audioPkCount = 0;
        }
        byte[] pcm = new byte[payload.length - 8];
        System.arraycopy(payload, 8, pcm, 0, pcm.length);
        AudioPlayer a = audio;
        if (a == null) {
            synchronized (codecLock) {
                if (audio == null) {
                    audio = new AudioPlayer();
                    audio.start();
                }
                a = audio;
            }
        }
        a.feed(pcm);
    }

    void setMuted(boolean muted) {
        setAudioEnabled(!muted);
    }

    void setAudioEnabled(boolean on) {
        AudioPlayer a = audio;
        if (a != null) a.setEnabled(on);
        audioWanted = on;
    }

    boolean audioEnabled() {
        AudioPlayer a = audio;
        return a != null && a.enabled();
    }

    private void onConfig(byte[] payload) {
        if (payload.length < 2) {
            Log.w(TAG, "video: short CONFIG " + payload.length);
            return;
        }
        int codecId = payload[0] & 0xff;
        byte[] annexb = new byte[payload.length - 1];
        System.arraycopy(payload, 1, annexb, 0, annexb.length);
        boolean hevc = codecId == 1;
        String mime = hevc ? "video/hevc" : "video/avc";
        int[] wh = hevc ? null : H264Sps.parse(annexb);
        synchronized (codecLock) {
            codecMime = mime;
            csd = annexb;
            csdGen++;
            if (wh != null) {
                videoW = wh[0];
                videoH = wh[1];
            }
        }
        frames.clear();
        wantResync = true;
        Log.i(TAG, "video CONFIG " + payload.length + " bytes"
                + (wh != null ? ", sps " + wh[0] + "x" + wh[1] : ", sps parse failed"));
        setDecState("config " + (wh != null ? wh[0] + "x" + wh[1] : payload.length + "B"));
    }

    private void onFramePayload(byte[] payload) {
        if (payload.length < 17) {
            Log.w(TAG, "video: short FRAME message " + payload.length);
            return;
        }
        long pts = 0;
        for (int i = 0; i < 8; i++) {
            pts = (pts << 8) | (payload[i] & 0xffL);
        }
        int flags = payload[8] & 0xff;
        boolean key = (flags & 0x01) != 0;
        long sendUs = 0;
        for (int i = 9; i < 17; i++) {
            sendUs = (sendUs << 8) | (payload[i] & 0xffL);
        }

        byte[] au = new byte[payload.length - 17];
        System.arraycopy(payload, 17, au, 0, au.length);

        java.util.function.LongSupplier ck = bridgeClock;
        long nowUs = ck == null ? 0 : ck.getAsLong();
        if (nowUs > 0 && sendUs > 0) {
            long d = nowUs - sendUs;
            if (d > 0 && d < 5_000_000L) {
                statRecvSum += d;
                statRecvN++;
            }
        }

        if (surface == null || csd == null) {
            // surface 还没就绪（例如退到后台）：直接丢帧，别把队列灌满
            return;
        }
        if (!frames.offer(new Frame(au, pts, key, sendUs))) {
            // 解码跟不上：丢掉积压，等下一个 IDR 重新同步
            frames.clear();
            wantResync = true;
            frames.offer(new Frame(au, pts, key, sendUs));
            Runnable r = idrRequester;
            if (r != null) r.run();
            Log.w(TAG, "video queue overflow, dropped backlog, requested IDR");
        }
    }

    // ---------------------------------------------------------------- 解码线程

    private void decLoop() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (running) {
            boolean ready;
            synchronized (codecLock) {
                ready = ensureCodecLocked();
            }
            if (!ready) {
                sleepQuietly(80);
                continue;
            }
            Frame f;
            try {
                f = frames.poll(8, TimeUnit.MILLISECONDS);
            } catch (InterruptedException ie) {
                break;
            }
            synchronized (codecLock) {
                MediaCodec c = codec;
                if (c == null) continue;
                if (wantResync) {
                    wantResync = false;
                    needKey = true;
                }
                if (f != null && (!needKey || f.key)) {
                    if (feedLocked(c, f)) {
                        needKey = false;
                    }
                }
                drainLocked(c, info);
            }
        }
        synchronized (codecLock) {
            releaseCodecLocked();
        }
        Log.i(TAG, "video decoder stopped");
    }

    /** 按当前 surface + csd 准备 codec；配置变了就先 stop/release 再重建。 */
    private boolean ensureCodecLocked() {
        Surface surf = surface;
        byte[] csdLocal = csd;
        long gen = csdGen;
        String mime = codecMime;
        if (codec != null && surf == appliedSurface && csdLocal == appliedCsd && gen == appliedGen
                && mime.equals(appliedMime)) {
            return true;
        }
        releaseCodecLocked();
        if (surf == null || csdLocal == null) {
            if (surf == null) setDecState("waiting for surface");
            else setDecState("waiting csd");
            return false;
        }

        int w = videoW;
        int h = videoH;
        if (w <= 0 || h <= 0) {
            w = surfaceW;
            h = surfaceH;
        }
        if (w <= 0 || h <= 0) {
            w = 1920;
            h = 1080;
        }

        MediaCodec c = null;
        try {
            c = MediaCodec.createDecoderByType(mime);
            MediaFormat fmt = MediaFormat.createVideoFormat(mime, w, h);
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(csdLocal));
            if (Build.VERSION.SDK_INT >= 30 && lowLatency) {
                try {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                } catch (Exception ignore) {
                    Log.i(TAG, "video: decoder refused low-latency flag");
                }
            }
            // 实时优先 + 声明操作帧率，避免解码器按省电策略攒帧
            try {
                fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);
            } catch (Exception ignore) {
            }
            try {
                fmt.setInteger(MediaFormat.KEY_OPERATING_RATE, 120);
            } catch (Exception ignore) {
            }
            c.configure(fmt, surf, null, 0);
            c.start();
        } catch (Exception e) {
            Log.w(TAG, "video codec start failed: " + e);
            if (c != null) {
                try {
                    c.release();
                } catch (Exception ignore) {
                }
            }
            setDecState("codec error");
            return false;
        }

        codec = c;
        appliedMime = mime;
        appliedCsd = csdLocal;
        appliedGen = gen;
        appliedSurface = surf;
        needKey = true;
        gotFrame = false;
        wantResync = false;
        frames.clear();          // 新 codec 只能从 IDR 开始喂
        inflightSendUs.clear();
        inflightFeedUs.clear();
        Log.i(TAG, "video codec started " + c.getName() + " " + w + "x" + h
                + " low-latency=" + (Build.VERSION.SDK_INT >= 30 ? 1 : 0));
        setDecState("decoding " + w + "x" + h);
        return true;
    }

    private void releaseCodecLocked() {
        MediaCodec c = codec;
        codec = null;
        appliedMime = "";
        appliedCsd = null;
        appliedGen = -1;
        appliedSurface = null;
        needKey = true;
        gotFrame = false;
        if (c != null) {
            try {
                c.stop();
            } catch (Exception ignore) {
            }
            try {
                c.release();
            } catch (Exception ignore) {
            }
            Log.i(TAG, "video codec released");
        }
    }

    /** 送一个 access unit。返回 true 表示成功进了解码器。 */
    private boolean feedLocked(MediaCodec c, Frame f) {
        long deadline = SystemClock.elapsedRealtime() + 60;
        while (true) {
            int in;
            try {
                in = c.dequeueInputBuffer(5000);
            } catch (IllegalStateException ise) {
                Log.w(TAG, "video dequeueInputBuffer failed: " + ise);
                return false;
            }
            if (in >= 0) {
                ByteBuffer buf = c.getInputBuffer(in);
                if (buf == null) {
                    needKey = true;
                    return false;
                }
                buf.clear();
                if (f.data.length > buf.capacity()) {
                    Log.w(TAG, "video AU too big: " + f.data.length + " > " + buf.capacity());
                    needKey = true;
                    return false;
                }
                buf.put(f.data);
                try {
                    c.queueInputBuffer(in, 0, f.data.length, f.ptsUs, 0);
                    inflightSendUs.addLast(f.sendUs);
                    inflightFeedUs.addLast(SystemClock.elapsedRealtime() * 1000L);
                    if (inflightSendUs.size() > 64) inflightSendUs.pollFirst();
                } catch (IllegalStateException ise) {
                    Log.w(TAG, "video queueInputBuffer failed: " + ise);
                    needKey = true;
                    return false;
                }
                return true;
            }
            if (SystemClock.elapsedRealtime() > deadline) {
                // 解码器一直不给输入 buffer：丢掉这帧，等下一个 IDR 重新同步
                needKey = true;
                Log.w(TAG, "video: no input buffer for 60ms, resync at next IDR");
                return false;
            }
        }
    }

    /** 取出所有已解码的输出并渲染到 surface。 */
    private void drainLocked(MediaCodec c, MediaCodec.BufferInfo info) {
        while (true) {
            int out;
            try {
                out = c.dequeueOutputBuffer(info, 0);
            } catch (IllegalStateException ise) {
                return;
            }
            if (out == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return;
            }
            if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat of = c.getOutputFormat();
                if (of.containsKey("width") && of.containsKey("height")) {
                    videoW = of.getInteger("width");
                    videoH = of.getInteger("height");
                    // crop-* 才是真正可见尺寸（1080 编出来是 1088，需要裁掉 8 行）
                    if (of.containsKey("crop-right") && of.containsKey("crop-left")
                            && of.containsKey("crop-bottom") && of.containsKey("crop-top")) {
                        int cw = of.getInteger("crop-right") - of.getInteger("crop-left") + 1;
                        int ch = of.getInteger("crop-bottom") - of.getInteger("crop-top") + 1;
                        if (cw > 0 && ch > 0) {
                            videoW = cw;
                            videoH = ch;
                        }
                    }
                }
                Log.i(TAG, "video output format: " + of);
                continue;
            }
            if (out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                continue;
            }
            if (out < 0) {
                return;
            }
            boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
            boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            boolean render = !config && !eos;
            try {
                noteFrameForFps();
                c.releaseOutputBuffer(out, render);
            } catch (Exception ignore) {
            }
            if (render) {
                Long sent = inflightSendUs.pollFirst();
                Long fed = inflightFeedUs.pollFirst();
                RenderListener l = renderListener;
                if (sent != null && l != null) l.onRendered(sent);
                java.util.function.LongSupplier ck2 = bridgeClock;
                long now2 = ck2 == null ? 0 : ck2.getAsLong();
                if (now2 > 0 && sent != null) {
                    long tot = now2 - sent;
                    if (tot > 0 && tot < 5_000_000L) {
                        statTotSum += tot;
                        statTotN++;
                    }
                    if (fed != null) {
                        long dec = SystemClock.elapsedRealtime() * 1000L - fed;
                        if (dec > 0 && dec < 5_000_000L) {
                            statDecSum += dec;
                            statDecN++;
                        }
                    }
                    if (statTotN >= 120) {
                        Log.i(TAG, String.format(java.util.Locale.US,
                                "lat: net %.1fms decode+compose %.1fms total %.1fms (n=%d)",
                                statRecvN == 0 ? 0.0 : statRecvSum / 1000.0 / statRecvN,
                                statDecN == 0 ? 0.0 : statDecSum / 1000.0 / statDecN,
                                statTotSum / 1000.0 / statTotN, statTotN));
                        statRecvSum = statRecvN = statTotSum = statTotN = statDecSum = statDecN = 0;
                    }
                }
                lastFrameAt = SystemClock.elapsedRealtime();
                if (!gotFrame) {
                    gotFrame = true;
                    Log.i(TAG, "video first frame rendered (" + videoW + "x" + videoH + ")");
                    setDecState("playing " + videoW + "x" + videoH);
                }
            }
        }
    }

    // ---------------------------------------------------------------- 工具

    /** 链路状态（网络线程维护），只在变化时打日志。 */
    private void setNetState(String s) {
        if (s.equals(netState)) {
            return;
        }
        netState = s;
        Log.i(TAG, "video net: " + s);
        notifyState();
    }

    /** 解码状态（解码线程维护），只在变化时打日志。 */
    private void setDecState(String s) {
        if (s.equals(decState)) {
            return;
        }
        decState = s;
        Log.i(TAG, "video dec: " + s);
        notifyState();
    }

    private void notifyState() {
        StateListener l = listener;
        if (l != null) {
            try {
                l.onState(statusText());
            } catch (Exception ignore) {
            }
        }
    }

    private void closeQuietly() {
        Socket s = socket;
        socket = null;
        if (s != null) {
            try {
                s.close();
            } catch (Exception ignore) {
            }
        }
    }

    private static void sleepQuietly(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignore) {
        }
    }

    private static final class Frame {
        final byte[] data;
        final long ptsUs;
        final boolean key;
        final long sendUs;

        Frame(byte[] data, long ptsUs, boolean key, long sendUs) {
            this.data = data;
            this.ptsUs = ptsUs;
            this.key = key;
            this.sendUs = sendUs;
        }
    }
}
