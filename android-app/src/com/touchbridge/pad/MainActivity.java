package com.touchbridge.pad;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Bundle;
import android.util.Log;
import android.util.SparseArray;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

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
 * 平板侧触控转发应用。
 *
 * 通过 adb reverse tcp:47777 tcp:47777 把平板 localhost:47777 转发到 Mac 上的 bridge/touchd.py，
 * 用最朴素的文本行协议发送多点触控：
 *   d <id> <x> <y>   按下
 *   m <id> <x> <y>   移动
 *   u <id> <x> <y>   抬起
 *   c                取消全部
 * 坐标归一化到 0..1，原点在左上角（Sunshine 直接把它写成 HID digitizer 坐标）。
 *
 * 屏幕中间会画一个和 Mac 显示器同宽高比的活动框（由 touchd 通过 "#aspect <ratio>" 下发），
 * 框外的触摸不转发，框内坐标线性映射到 Mac 全屏，这样手感和真实触摸屏一致。
 */
public class MainActivity extends Activity {
    static final String TAG = "TouchBridge";
    static final String HOST = "127.0.0.1";
    static final int PORT = 47777;

    private TouchSurface surface;
    private Link link;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        link = new Link();
        surface = new TouchSurface(this, link);
        link.surface = surface;
        setContentView(surface);
        link.start();

        hideSystemBars();
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
        super.onDestroy();
    }

    /** 触控面板：绘制活动框与触点反馈，并按活动框映射坐标。 */
    static class TouchSurface extends View {
        private Link link;
        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint hint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint bg = new Paint();
        private final Paint outside = new Paint();
        private final Paint frame = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final SparseArray<float[]> active = new SparseArray<>();
        private final Set<Integer> ignored = new HashSet<>();

        private final RectF area = new RectF();
        private float targetAspect = 16f / 9f;
        private boolean aspectFromHost = false;

        TouchSurface(Context c, Link link) {
            super(c);
            this.link = link;
            dot.setColor(Color.parseColor("#4DA3FF"));
            ring.setColor(Color.parseColor("#80FFFFFF"));
            ring.setStyle(Paint.Style.STROKE);
            ring.setStrokeWidth(3f);
            text.setColor(Color.parseColor("#CCFFFFFF"));
            text.setTextSize(34f);
            hint.setColor(Color.parseColor("#66FFFFFF"));
            hint.setTextSize(28f);
            bg.setColor(Color.BLACK);
            outside.setColor(Color.parseColor("#121212"));
            frame.setStyle(Paint.Style.STROKE);
            frame.setStrokeWidth(3f);
            frame.setColor(Color.parseColor("#55FFFFFF"));
            setKeepScreenOn(true);
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
                return;
            }
            float fw = w, fh = fw / targetAspect;
            if (fh > h) {
                fh = h;
                fw = fh * targetAspect;
            }
            float left = (w - fw) / 2f, top = (h - fh) / 2f;
            area.set(left, top, left + fw, top + fh);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            canvas.drawRect(0, 0, w, h, bg);
            if (area.left > 0.5f || area.top > 0.5f
                    || area.right < w - 0.5f || area.bottom < h - 0.5f) {
                canvas.drawRect(0, 0, w, area.top, outside);
                canvas.drawRect(0, area.bottom, w, h, outside);
                canvas.drawRect(0, area.top, area.left, area.bottom, outside);
                canvas.drawRect(area.right, area.top, w, area.bottom, outside);
            }
            canvas.drawRect(area, frame);

            for (int i = 0; i < active.size(); i++) {
                float[] p = active.valueAt(i);
                float cx = area.left + p[0] * area.width();
                float cy = area.top + p[1] * area.height();
                canvas.drawCircle(cx, cy, 60f, ring);
                canvas.drawCircle(cx, cy, 24f, dot);
            }

            float tx = area.left + 36f, ty = area.top + 56f;
            canvas.drawText(link.statusText(), tx, ty, text);
            canvas.drawText(String.format(Locale.US, "touching: %d   frame: %s",
                    active.size(), aspectLabel()), tx, ty + 44f, text);
            canvas.drawText("只有框内区域会转发触摸", tx, ty + 88f, hint);
            if (active.size() > 0) postInvalidateOnAnimation();
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

        /** 读 touchd 下发的握手行，例如 "#aspect 1.777778"。 */
        private void startReader(Socket s) {
            Thread t = new Thread(() -> {
                try (BufferedReader br = new BufferedReader(
                        new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII))) {
                    String line;
                    while (running && (line = br.readLine()) != null) {
                        line = line.trim();
                        if (line.startsWith("#aspect ")) {
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
