package dev.local.touchpad;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.os.Bundle;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

/**
 * 平板上铺一层全屏触摸面，把 MotionEvent 的每根手指映射成
 * 一个 16 指 HID 触屏报告，写进 /dev/hidg0（需要先跑 hid_gadget.sh setup-mt）。
 *
 * 报告格式（97 字节，对应 gadget 的 16 个 Finger collection）：
 *   [0..95]  16 组 × 6 字节：flags, contactID, X(lo,hi), Y(lo,hi)
 *   [96]     contact count
 *   flags: 0x07 = 接触中（TipSwitch|InRange|Confidence），0x04 = 抬起（无 TipSwitch）
 */
public class MainActivity extends Activity {

    private static final int MAX_SLOTS = 16;
    private static final int REPORT_SIZE = MAX_SLOTS * 6 + 1;
    private static final int FLAG_TIP = 0x07;
    private static final int FLAG_LIFT = 0x04;

    private final byte[] report = new byte[REPORT_SIZE];
    private final Map<Integer, Integer> slotOfPointer = new HashMap<Integer, Integer>();
    private final boolean[] slotUsed = new boolean[MAX_SLOTS + 1];
    private final boolean[] slotDown = new boolean[MAX_SLOTS + 1];
    private final int[] slotX = new int[MAX_SLOTS + 1];
    private final int[] slotY = new int[MAX_SLOTS + 1];

    private volatile OutputStream hidgOut;
    private TextView status;
    private int lastShownCount = -1;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        TouchView pad = new TouchView(this);
        root.addView(pad, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.parseColor("#99FFFFFF"));
        status.setTextSize(14);
        status.setPadding(32, 32, 32, 32);
        status.setText("正在连接 /dev/hidg0…");
        root.addView(status, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT));

        setContentView(root);
        hideSystemUi();
        openHidgPipe();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemUi();
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    /**
     * 用 root 起一个 `cat > /dev/hidg0`，之后直接往它的 stdin 写报告。
     * 走 su 域是为了绕过 SELinux 对 untrusted_app 写 hidg 设备的限制。
     */
    private void openHidgPipe() {
        new Thread(new Runnable() {
            @Override
            public void run() {
                Process p;
                try {
                    p = new ProcessBuilder("su", "-c", "cat > /dev/hidg0")
                            .redirectErrorStream(true)
                            .start();
                } catch (IOException e) {
                    postStatus("无法启动 su：" + e.getMessage());
                    return;
                }
                // 把 su/cat 的输出读掉，避免管道写满卡住
                drainAsync(p.getInputStream());
                final OutputStream os = p.getOutputStream();
                try {
                    // 先送一帧空报告，确认管道是通的
                    os.write(new byte[REPORT_SIZE]);
                    os.flush();
                } catch (IOException e) {
                    postStatus("写入失败：" + e.getMessage() + "（需要 root，且先跑 setup-mt）");
                    return;
                }
                hidgOut = os;
                postStatus("已连接 /dev/hidg0 · 0 指");
            }
        }, "hidg-open").start();
    }

    private void drainAsync(final InputStream in) {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                byte[] buf = new byte[256];
                try {
                    while (in.read(buf) >= 0) {
                        // 丢弃
                    }
                } catch (IOException ignored) {
                }
            }
        }, "hidg-drain");
        t.setDaemon(true);
        t.start();
    }

    private void postStatus(final String text) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                status.setText(text);
            }
        });
    }

    private int acquireSlot() {
        for (int s = 1; s <= MAX_SLOTS; s++) {
            if (!slotUsed[s]) return s;
        }
        return 0;
    }

    private static int toHid(float v, int size) {
        if (size <= 1) return 0;
        int px = (int) v;
        if (px < 0) px = 0;
        if (px > size - 1) px = size - 1;
        return px * 65535 / (size - 1);
    }

    private void handleTouch(MotionEvent ev, int w, int h) {
        switch (ev.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN: {
                int i = ev.getActionIndex();
                addPointer(ev.getPointerId(i), ev.getX(i), ev.getY(i), w, h);
                break;
            }
            case MotionEvent.ACTION_MOVE: {
                for (int i = 0; i < ev.getPointerCount(); i++) {
                    int pid = ev.getPointerId(i);
                    Integer slot = slotOfPointer.get(pid);
                    if (slot == null || slot == 0) {
                        addPointer(pid, ev.getX(i), ev.getY(i), w, h);
                    } else {
                        slotX[slot] = toHid(ev.getX(i), w);
                        slotY[slot] = toHid(ev.getY(i), h);
                    }
                }
                break;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP: {
                int i = ev.getActionIndex();
                Integer slot = slotOfPointer.remove(ev.getPointerId(i));
                if (slot != null && slot != 0) slotDown[slot] = false;
                break;
            }
            case MotionEvent.ACTION_CANCEL: {
                for (int s = 1; s <= MAX_SLOTS; s++) slotDown[s] = false;
                break;
            }
            default:
                return;
        }
        sendFrame();
    }

    private void addPointer(int pid, float x, float y, int w, int h) {
        if (slotOfPointer.containsKey(pid)) return;
        int slot = acquireSlot();
        if (slot == 0) {
            slotOfPointer.put(pid, 0); // 超出 16 指，忽略
            return;
        }
        slotOfPointer.put(pid, slot);
        slotUsed[slot] = true;
        slotDown[slot] = true;
        slotX[slot] = toHid(x, w);
        slotY[slot] = toHid(y, h);
    }

    private void sendFrame() {
        OutputStream os = hidgOut;
        if (os == null) return;

        Arrays.fill(report, (byte) 0);
        int count = 0;
        for (int s = 1; s <= MAX_SLOTS; s++) {
            if (!slotUsed[s]) continue;
            int off = (s - 1) * 6;
            report[off] = (byte) (slotDown[s] ? FLAG_TIP : FLAG_LIFT);
            report[off + 1] = (byte) s;
            report[off + 2] = (byte) (slotX[s] & 0xFF);
            report[off + 3] = (byte) ((slotX[s] >> 8) & 0xFF);
            report[off + 4] = (byte) (slotY[s] & 0xFF);
            report[off + 5] = (byte) ((slotY[s] >> 8) & 0xFF);
            count++;
        }
        report[REPORT_SIZE - 1] = (byte) count;

        try {
            os.write(report);
            os.flush();
        } catch (IOException e) {
            hidgOut = null;
            postStatus("写入失败：" + e.getMessage());
            return;
        }

        for (int s = 1; s <= MAX_SLOTS; s++) {
            if (slotUsed[s] && !slotDown[s]) slotUsed[s] = false;
        }
        if (count != lastShownCount) {
            lastShownCount = count;
            postStatus("已连接 /dev/hidg0 · " + count + " 指");
        }
    }

    private final class TouchView extends View {
        TouchView(Context c) {
            super(c);
            setBackgroundColor(Color.BLACK);
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            handleTouch(ev, getWidth(), getHeight());
            return true;
        }
    }
}
