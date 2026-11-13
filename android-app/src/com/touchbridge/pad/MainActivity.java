package com.touchbridge.pad;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Bundle;
import android.util.Log;
import android.util.SparseArray;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 平板侧触控转发应用。
 *
 * 通过 adb reverse tcp:7000 tcp:7000 把平板 localhost:7000 转发到 Mac 上的 bridge/touchd.py，
 * 用最朴素的文本行协议发送多点触控：
 *   d <id> <x> <y>   按下
 *   m <id> <x> <y>   移动
 *   u <id> <x> <y>   抬起
 *   c                取消全部
 * 坐标归一化到 0..1，原点在左下角（与 Moonlight/Sunshine 的触控语义一致）。
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

    /** 触控面板：绘制触点反馈 + 上报事件。 */
    static class TouchSurface extends View {
        private final Link link;
        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint bg = new Paint();
        private final SparseArray<float[]> active = new SparseArray<>();

        TouchSurface(Context c, Link link) {
            super(c);
            this.link = link;
            dot.setColor(Color.parseColor("#4DA3FF"));
            ring.setColor(Color.parseColor("#80FFFFFF"));
            ring.setStyle(Paint.Style.STROKE);
            ring.setStrokeWidth(3f);
            text.setColor(Color.parseColor("#99FFFFFF"));
            text.setTextSize(36f);
            bg.setColor(Color.BLACK);
            setKeepScreenOn(true);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            canvas.drawRect(0, 0, w, h, bg);
            for (int i = 0; i < active.size(); i++) {
                float[] p = active.valueAt(i);
                float cx = p[0] * w, cy = (1f - p[1]) * h;
                canvas.drawCircle(cx, cy, 70f, ring);
                canvas.drawCircle(cx, cy, 26f, dot);
            }
            canvas.drawText(link.statusText(), 40f, 60f, text);
            canvas.drawText(String.format(Locale.US, "touching: %d", active.size()),
                    40f, 110f, text);
            if (active.size() > 0) postInvalidateOnAnimation();
        }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            final int action = e.getActionMasked();
            switch (action) {
                case MotionEvent.ACTION_DOWN:
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
            int w = Math.max(1, getWidth()), h = Math.max(1, getHeight());
            float nx = clamp(px / w);
            float ny = 1f - clamp(py / h);
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
