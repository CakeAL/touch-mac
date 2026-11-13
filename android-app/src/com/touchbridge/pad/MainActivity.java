package com.touchbridge.pad;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * 平板侧触控 + 视频显示应用。
 *
 * 触控：通过 adb reverse tcp:47777 tcp:47777 把平板 localhost:47777 转发到 Mac 上的
 * bridge/touchd.py，用最朴素的文本行协议发送多点触控：
 *   d <id> <x> <y>   按下
 *   m <id> <x> <y>   移动
 *   u <id> <x> <y>   抬起
 *   c                取消全部
 * 坐标归一化到 0..1，原点在左上角（Sunshine 直接把它写成 HID digitizer 坐标）。
 *
 * 视频：Mac 侧把 H.264 推到 localhost:47779（同样由 adb reverse 建立），
 * {@link VideoClient} 收流后用 MediaCodec 硬解，直接渲染到 SurfaceView。
 *
 * 视图结构（FrameLayout）：
 *   [0] SurfaceView   —— 视频画面，尺寸/位置精确对齐 16:9 活动框
 *   [1] TouchSurface  —— 透明背景，只画活动框描边、触点圆环、状态文字
 * 这样视频在下、触控反馈在上，触控逻辑与坐标映射完全不变。
 */
public class MainActivity extends Activity {
    static final String TAG = "TouchBridge";
    static final String HOST = "127.0.0.1";
    static final int PORT = 47777;

    private TouchSurface touch;
    private SurfaceView videoView;
    private FrameLayout root;
    private Link link;
    private VideoClient video;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        link = new Link();
        video = new VideoClient();
        video.setStateListener(s -> {
            TouchSurface t = touch;
            if (t != null) t.postInvalidateOnAnimation();
        });

        touch = new TouchSurface(this, link, video);
        link.surface = touch;

        videoView = new SurfaceView(this);
        videoView.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override
            public void surfaceCreated(SurfaceHolder holder) {
                Rect frame = holder.getSurfaceFrame();
                Log.i(TAG, "video surface created " + frame.width() + "x" + frame.height());
                video.setSurface(holder.getSurface(), frame.width(), frame.height());
            }

            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int w, int h) {
                video.onSurfaceSize(w, h);
            }

            @Override
            public void surfaceDestroyed(SurfaceHolder holder) {
                // 必须在 surface 真正失效前把 codec 放掉
                video.clearSurface();
            }
        });

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        FrameLayout.LayoutParams vp = new FrameLayout.LayoutParams(0, 0);
        vp.gravity = Gravity.TOP | Gravity.LEFT;
        root.addView(videoView, vp);
        root.addView(touch, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // 活动框变化（尺寸或 host 下发的比例）时，把视频 surface 摆到同一个矩形
        touch.setAreaListener(area -> {
            RectF r = new RectF(area);
            touch.post(() -> applyVideoRect(r));
        });

        setContentView(root);
        link.start();
        video.setRenderListener(sendUs -> {
            long nowUs = link.bridgeNowUs();
            if (nowUs == Long.MIN_VALUE || sendUs <= 0) return;
            long ms = (nowUs - sendUs) / 1000L;
            if (ms < -50 || ms > 5000) return;         // 时钟还没收敛时忽略
            TouchSurface t = touch;
            if (t != null) t.setLatency(ms);
        });
        video.start();
        hideSystemBars();
    }

    /** 让 SurfaceView 与 TouchSurface 算出的活动框精确重合。 */
    private void applyVideoRect(RectF r) {
        int left = Math.round(r.left);
        int top = Math.round(r.top);
        int w = Math.max(1, Math.round(r.right) - left);
        int h = Math.max(1, Math.round(r.bottom) - top);
        FrameLayout.LayoutParams cur = (FrameLayout.LayoutParams) videoView.getLayoutParams();
        if (cur != null && cur.width == w && cur.height == h
                && cur.leftMargin == left && cur.topMargin == top) {
            return;
        }
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w, h);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.leftMargin = left;
        lp.topMargin = top;
        videoView.setLayoutParams(lp);
        Log.i(TAG, "video rect " + left + "," + top + " " + w + "x" + h);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    private void hideSystemBars() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    @Override
    protected void onDestroy() {
        if (link != null) link.shutdown();
        if (video != null) video.shutdown();
        super.onDestroy();
    }

    /** 触控面板：透明背景，只画活动框描边、触点反馈与状态文字，并按活动框映射坐标。 */
    static class TouchSurface extends View {
        interface AreaListener {
            void onAreaChanged(RectF area);
        }

        private Link link;
        private VideoClient video;
        private AreaListener areaListener;
        /** 最近一帧的端到端延时（bridge 发出 → 平板渲染），毫秒；-1 表示还没测出来。 */
        private volatile long latencyMs = -1;

        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint statusBack = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint hint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint waiting = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint outside = new Paint();
        private final Paint frame = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final SparseArray<float[]> active = new SparseArray<>();
        private final Set<Integer> ignored = new HashSet<>();

        private final RectF area = new RectF();
        private float targetAspect = 16f / 9f;
        private boolean aspectFromHost = false;

        TouchSurface(Context c, Link link, VideoClient video) {
            super(c);
            this.link = link;
            this.video = video;
            dot.setColor(Color.parseColor("#4DA3FF"));
            ring.setColor(Color.parseColor("#80FFFFFF"));
            ring.setStyle(Paint.Style.STROKE);
            ring.setStrokeWidth(3f);
            text.setColor(Color.parseColor("#CCFFFFFF"));
            text.setTextSize(34f);
            text.setShadowLayer(4f, 0f, 1f, 0xCC000000);
            statusBack.setColor(Color.parseColor("#66000000"));
            hint.setColor(Color.parseColor("#66FFFFFF"));
            hint.setTextSize(28f);
            hint.setShadowLayer(4f, 0f, 1f, 0xCC000000);
            waiting.setColor(Color.parseColor("#99FFFFFF"));
            waiting.setTextSize(44f);
            waiting.setShadowLayer(6f, 0f, 2f, 0xCC000000);
            outside.setColor(Color.parseColor("#121212"));
            frame.setStyle(Paint.Style.STROKE);
            frame.setStrokeWidth(3f);
            frame.setColor(Color.parseColor("#55FFFFFF"));
            setKeepScreenOn(true);
            // 背景保持透明：视频画面由下层 SurfaceView 负责
            setBackgroundColor(Color.TRANSPARENT);
        }

        void setAreaListener(AreaListener l) {
            areaListener = l;
            if (area.width() > 0f && area.height() > 0f) {
                l.onAreaChanged(new RectF(area));
            }
        }

        /** touchd 下发的目标宽高比（Mac 显示器）。 */
        void setAspect(float a) {
            if (a < 0.2f || a > 6f) return;
            targetAspect = a;
            aspectFromHost = true;
            recomputeArea();
            postInvalidateOnAnimation();
            Log.i(TAG, "aspect from host: " + a);
        }

        @Override
        protected void onSizeChanged(int w, int h, int ow, int oh) {
            super.onSizeChanged(w, h, ow, oh);
            recomputeArea();
        }

        private void recomputeArea() {
            int w = Math.max(1, getWidth()), h = Math.max(1, getHeight());
            if (targetAspect <= 0f) {
                area.set(0, 0, w, h);
            } else {
                float fw = w, fh = fw / targetAspect;
                if (fh > h) {
                    fh = h;
                    fw = fh * targetAspect;
                }
                float left = (w - fw) / 2f, top = (h - fh) / 2f;
                area.set(left, top, left + fw, top + fh);
            }
            AreaListener l = areaListener;
            if (l != null) l.onAreaChanged(new RectF(area));
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (area.left > 0.5f || area.top > 0.5f
                    || area.right < w - 0.5f || area.bottom < h - 0.5f) {
                canvas.drawRect(0, 0, w, area.top, outside);
                canvas.drawRect(0, area.bottom, w, h, outside);
                canvas.drawRect(0, area.top, area.left, area.bottom, outside);
                canvas.drawRect(area.right, area.top, w, area.bottom, outside);
            }
            canvas.drawRect(area, frame);

            boolean playing = video != null && video.isPlaying();
            if (!playing) {
                // 视频还没来时在框内居中提示
                String msg = "等待画面…";
                float tw = waiting.measureText(msg);
                float cx = area.centerX();
                float cy = area.centerY();
                canvas.drawText(msg, cx - tw / 2f, cy, waiting);
            }

            for (int i = 0; i < active.size(); i++) {
                float[] p = active.valueAt(i);
                float cx = area.left + p[0] * area.width();
                float cy = area.top + p[1] * area.height();
                canvas.drawCircle(cx, cy, 60f, ring);
                canvas.drawCircle(cx, cy, 24f, dot);
            }

            float tx = area.left + 36f, ty = area.top + 56f;
            // 状态区压在视频上会看不清，垫一层半透明底。
            float boxRight = tx + Math.max(text.measureText(link.statusText()),
                    Math.max(text.measureText(video == null ? "video: off" : video.statusText()),
                            Math.max(text.measureText(String.format(Locale.US, "touching: %d   frame: %s",
                                    active.size(), aspectLabel())), hint.measureText("只有框内区域会转发触摸")))) + 24f;
            canvas.drawRoundRect(tx - 18f, ty - 34f, boxRight, ty + 152f, 18f, 18f, statusBack);
            canvas.drawText(link.statusText(), tx, ty, text);
            canvas.drawText(video == null ? "video: off" : video.statusText(), tx, ty + 44f, text);
            canvas.drawText(String.format(Locale.US, "touching: %d   frame: %s   %s",
                    active.size(), aspectLabel(), latencyLabel()), tx, ty + 88f, text);
            canvas.drawText("只有框内区域会转发触摸", tx, ty + 132f, hint);

            if (active.size() > 0 || !playing) postInvalidateOnAnimation();
        }

        void setLatency(long ms) {
            latencyMs = ms;
            postInvalidateOnAnimation();
        }

        private String latencyLabel() {
            long ms = latencyMs;
            if (ms < 0 || link.bridgeNowUs() == Long.MIN_VALUE) return "delay --";
            return String.format(Locale.US, "delay %d ms", ms);
        }

        private String aspectLabel() {
            if (aspectFromHost) return String.format(Locale.US, "%.3f (host)", targetAspect);
            return String.format(Locale.US, "%.3f", targetAspect);
        }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            final int action = e.getActionMasked();
            switch (action) {
                case MotionEvent.ACTION_DOWN: {
                    emit('d', e.getPointerId(0), e.getX(), e.getY());
                    break;
                }
                case MotionEvent.ACTION_POINTER_DOWN: {
                    int i = e.getActionIndex();
                    emit('d', e.getPointerId(i), e.getX(i), e.getY(i));
                    break;
                }
                case MotionEvent.ACTION_MOVE: {
                    for (int i = 0; i < e.getPointerCount(); i++) {
                        emit('m', e.getPointerId(i), e.getX(i), e.getY(i));
                    }
                    break;
                }
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_POINTER_UP: {
                    int i = e.getActionIndex();
                    emit('u', e.getPointerId(i), e.getX(i), e.getY(i));
                    break;
                }
                case MotionEvent.ACTION_CANCEL: {
                    for (int i = 0; i < e.getPointerCount(); i++) {
                        emit('u', e.getPointerId(i), e.getX(i), e.getY(i));
                    }
                    break;
                }
                default:
                    break;
            }
            invalidate();
            return true;
        }


        private void emit(char kind, int id, float px, float py) {
            if (area.width() <= 0f || area.height() <= 0f) return;

            if (kind == 'd') {
                if (!area.contains(px, py)) {
                    ignored.add(id);
                    Log.i(TAG, "ignore down outside frame id=" + id);
                    return;
                }
            } else if (ignored.contains(id)) {
                if (kind == 'u') ignored.remove(id);
                return;
            }

            float nx = clamp((px - area.left) / area.width());
            float ny = clamp((py - area.top) / area.height());
            if (kind == 'u') active.remove(id);
            else active.put(id, new float[]{nx, ny});

            if (kind != 'm') Log.i(TAG, "emit " + kind + " id=" + id + " " + nx + "," + ny);
            link.send(kind, id, nx, ny);
            if (kind == 'u' && active.size() == 0) link.send('c', 0, 0f, 0f);
            postInvalidateOnAnimation();
        }

        private static float clamp(float v) {
            return v < 0f ? 0f : (v > 1f ? 1f : v);
        }
    }

    /** 到 Mac 的 TCP 连接：写队列 + 独立线程发送（触控回调在主线程，不能直接写 socket）。 */
    static class Link extends Thread {
        private final java.util.concurrent.ArrayBlockingQueue<String> queue =
                new java.util.concurrent.ArrayBlockingQueue<>(8192);
        private volatile Socket socket;
        private volatile OutputStream out;
        private volatile boolean running = true;
        private volatile String state = "connecting...";
        volatile TouchSurface surface;
        /** bridge 单调时钟（微秒）与本地 SystemClock.elapsedRealtime 的差；用于算端到端延时。 */
        private volatile long offsetUs = Long.MIN_VALUE;
        private volatile long clockRttUs;

        long bridgeNowUs() {
            long off = offsetUs;
            if (off == Long.MIN_VALUE) return Long.MIN_VALUE;
            return SystemClock.elapsedRealtime() * 1000L + off;
        }

        long rttUs() {
            return clockRttUs;
        }

        String statusText() {
            return "adb reverse tcp:" + PORT + " · " + state;
        }

        @Override
        public void run() {
            while (running) {
                try {
                    Socket s = new Socket();
                    s.setTcpNoDelay(true);
                    s.setKeepAlive(true);
                    s.connect(new InetSocketAddress(HOST, PORT), 1500);
                    socket = s;
                    out = s.getOutputStream();
                    state = "connected";
                    Log.i(TAG, "link connected to " + HOST + ":" + PORT);
                    queue.clear();
                    startReader(s);
                    startClockProbe();

                    while (running && out != null) {
                        String line = queue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS);
                        if (line == null) continue;
                        try {
                            out.write(line.getBytes(StandardCharsets.US_ASCII));
                            out.flush();
                        } catch (Exception ex) {
                            state = "write failed";
                            Log.w(TAG, "send failed: " + ex + " line=" + line.trim());
                            break;
                        }
                    }
                } catch (InterruptedException ie) {
                    break;
                } catch (Exception ex) {
                    state = "no link";
                    Log.w(TAG, "link failure: " + ex);
                }
                closeQuietly();
                if (running) {
                    try {
                        sleep(400);
                    } catch (InterruptedException ignore) {
                        break;
                    }
                }
            }
            state = "stopped";
        }

        private volatile long clockSendMs;
        private volatile long clockRecvMs;
        private volatile long clockSendUs;

        /**
         * 用 #t0 / #pong 估 bridge 时钟：bridge 的 now_us(启动起算) 与本地 elapsedRealtime 同速，
         * 只差一个固定偏移。收到 #pong 时用往返中点修正，误差约为单程抖动的一半。
         */
        private void noteServerClock(String usText, long sendMs, long recvMs, long sendUs) {
            long serverUs;
            try {
                serverUs = Long.parseLong(usText);
            } catch (NumberFormatException e) {
                return;
            }
            long localUs = SystemClock.elapsedRealtime() * 1000L;
            if (sendMs < 0) {
                // 首帧 #t0：直接取一次粗偏移，后续 #pong 会收敛
                offsetUs = serverUs - localUs;
                return;
            }
            long rtt = (recvMs - sendMs) * 1000L;
            if (rtt < 0 || rtt > 1_000_000L) return;   // 异常值丢弃
            clockRttUs = rtt;
            long midLocalUs = (sendMs + recvMs) * 500L;
            offsetUs = serverUs - midLocalUs;
        }

        private void startClockProbe() {
            Thread t = new Thread(() -> {
                while (running) {
                    try {
                        sleep(1500);
                    } catch (InterruptedException e) {
                        break;
                    }
                    if (out == null) continue;
                    clockSendMs = SystemClock.elapsedRealtime();
                    clockSendUs = clockSendMs * 1000L;
                    try {
                        out.write("p\n".getBytes(StandardCharsets.US_ASCII));
                        out.flush();
                        clockRecvMs = SystemClock.elapsedRealtime();
                    } catch (Exception ignore) {
                    }
                }
            }, "clock-probe");
            t.setDaemon(true);
            t.start();
        }

        /** 读 touchd 下发的握手行，例如 "#aspect 1.777778"。 */
        private void startReader(Socket s) {
            Thread t = new Thread(() -> {
                try (BufferedReader br = new BufferedReader(
                        new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII))) {
                    String line;
                    while (running && (line = br.readLine()) != null) {
                        line = line.trim();
                        if (line.startsWith("#t0 ")) {
                            noteServerClock(line.substring(4).trim(), -1, -1, -1);
                        } else if (line.startsWith("#pong ")) {
                            noteServerClock(line.substring(6).trim(), clockSendMs, clockRecvMs, clockSendUs);
                        } else if (line.startsWith("#aspect ")) {
                            try {
                                float a = Float.parseFloat(line.substring(8).trim());
                                TouchSurface sf = surface;
                                if (sf != null) sf.post(() -> sf.setAspect(a));
                            } catch (NumberFormatException ignore) {
                                Log.w(TAG, "bad aspect line: " + line);
                            }
                        }
                    }
                } catch (Exception ignore) {
                }
            }, "touch-reader");
            t.setDaemon(true);
            t.start();
        }

        void send(char kind, int id, float x, float y) {
            String line = kind == 'c'
                    ? "c\n"
                    : String.format(Locale.US, "%c %d %.5f %.5f\n", kind, id, x, y);
            if (!queue.offer(line)) {
                state = "queue overflow";
            }
        }

        void shutdown() {
            running = false;
            interrupt();
            closeQuietly();
        }

        private void closeQuietly() {
            out = null;
            try {
                if (socket != null) socket.close();
            } catch (Exception ignore) {
            }
            socket = null;
        }
    }
}
