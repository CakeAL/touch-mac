package com.touchbridge.pad;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.Locale;

/**
 * 平板设置面板（参考 Moonlight 的设置项）。
 *
 * 服务端参数（分辨率/帧率/码率/HEVC/音频）走 bridge 控制口 127.0.0.1:47781（adb reverse）：
 *   get            → #cfg width=1920 height=1080 fps=120 bitrate=40000 hevc=1 hdr=1 audio=1
 *   set key=value  → #ok
 *   apply          → bridge 用新参数重启，App 会自动重连
 * 纯客户端开关（是否显示延时、是否静音）存 SharedPreferences。
 */
final class SettingsPanel {
    private static final String TAG = "TouchBridge";
    private static final int CFG_PORT = 47781;

    /** 分辨率只选档位，具体宽高由桥按平板屏幕比例算。 */
    private static final String[] RESOLUTIONS = {"1080p", "2K", "4K"};
    private static final int[] RES_HEIGHTS = {1080, 1440, 2160};
    private static final String[] RATES = {"30", "60", "90", "120"};
    private static final String[] BITRATES = {"10", "20", "30", "40", "60", "80"};

    private final Activity act;
    private final FrameLayout root;
    private final VideoClient video;
    private final MainActivity.TouchSurface surface;
    private final SharedPreferences prefs;
    private final MainActivity host;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private LinearLayout panel;
    private Spinner resSpin, fpsSpin, brSpin;
    private CheckBox hevcBox, hdrBox, audioBox, delayBox, hudBox, fillBox, touchBox, lowLatBox;
    private TextView status;

    private int curRes = 1080, curFps = 60, curBr = 40000;
    private String sizeText = null;
    private int screenW, screenH;

    SettingsPanel(Activity act, FrameLayout root, VideoClient video, MainActivity.TouchSurface surface) {
        this.act = act;
        this.host = (MainActivity) act;
        int[] sc = host.screenSize();
        this.screenW = sc[0];
        this.screenH = sc[1];
        this.root = root;
        this.video = video;
        this.surface = surface;
        this.prefs = act.getSharedPreferences("touchbridge", Context.MODE_PRIVATE);
        build();
    }

    // ------------------------------------------------------------------ 构建 UI

    private void build() {
        panel = new LinearLayout(act);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(14), dp(18), dp(14));
        panel.setBackground(rounded(0xF0101216, dp(18)));

        TextView title = new TextView(act);
        title.setText("设置");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        title.setPadding(0, 0, 0, dp(8));
        panel.addView(title);

        status = new TextView(act);
        status.setTextColor(0xFF9AA4B2);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        status.setText("读取桥参数…");
        panel.addView(status);

        resSpin = addRow("分辨率", RESOLUTIONS);
        fpsSpin = addRow("帧率 (fps)", RATES);
        brSpin = addRow("码率 (Mbps)", BITRATES);

        hevcBox = addCheck("HEVC 编码", true);
        hdrBox = addCheck("HDR / 10-bit（偶发绿屏时关闭）", true);
        audioBox = addCheck("串流音频", true);
        hudBox = addCheck("显示左上角调试信息", prefs.getBoolean("showHud", true));
        delayBox = addCheck("  其中显示延时数字", prefs.getBoolean("showDelay", true));
        fillBox = addCheck("画面铺满平板（轻微拉伸）", prefs.getBoolean("fillScreen", true));
        touchBox = addCheck("显示触点圆圈", prefs.getBoolean("showTouches", false));
        lowLatBox = addCheck("低延迟解码（画面撕裂时关掉）", prefs.getBoolean("lowLatency", false));

        LinearLayout buttons = new LinearLayout(act);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setPadding(0, dp(12), 0, 0);

        Button apply = new Button(act);
        apply.setText("应用并重连");
        apply.setOnClickListener(v -> apply());
        buttons.addView(apply, new LinearLayout.LayoutParams(0, dp(40), 1f));

        Button close = new Button(act);
        close.setText("关闭");
        close.setOnClickListener(v -> hide());
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, dp(40), 1f);
        clp.leftMargin = dp(8);
        buttons.addView(close, clp);
        panel.addView(buttons);

        ScrollView sv = new ScrollView(act);
        sv.addView(panel);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(dp(520), dp(560));
        lp.gravity = Gravity.CENTER;
        root.addView(sv, lp);
        this.scroll = sv;
        sv.setVisibility(View.GONE);
    }

    private ScrollView scroll;

    private Spinner addRow(String label, String[] items) {
        LinearLayout row = new LinearLayout(act);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(3), 0, dp(3));

        TextView l = new TextView(act);
        l.setText(label);
        l.setTextColor(0xFFE6EAF0);
        l.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        row.addView(l, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        Spinner sp = new Spinner(act);
        ArrayAdapter<String> ad = new ArrayAdapter<>(act,
                android.R.layout.simple_spinner_dropdown_item, items);
        sp.setAdapter(ad);
        sp.setMinimumWidth(dp(200));
        row.addView(sp, new LinearLayout.LayoutParams(dp(200), dp(40)));
        panel.addView(row);
        return sp;
    }

    private CheckBox addCheck(String label, boolean on) {
        CheckBox cb = new CheckBox(act);
        cb.setText(label);
        cb.setTextColor(0xFFE6EAF0);
        cb.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        cb.setChecked(on);
        panel.addView(cb);
        return cb;
    }

    // ------------------------------------------------------------------ 交互

    void toggle() {
        if (scroll.getVisibility() == View.VISIBLE) {
            hide();
        } else {
            show();
        }
    }

    void show() {
        Log.i(TAG, "settings panel show, w=" + scroll.getWidth() + " h=" + scroll.getHeight()
                + " parent=" + scroll.getParent() + " vis=" + scroll.getVisibility());
        scroll.post(() -> {
            int[] loc = new int[2];
            scroll.getLocationOnScreen(loc);
            Log.i(TAG, "panel at " + loc[0] + "," + loc[1] + " size "
                    + scroll.getWidth() + "x" + scroll.getHeight()
                    + " alpha=" + scroll.getAlpha());
        });
        scroll.setVisibility(View.VISIBLE);
        scroll.bringToFront();
        hudBox.setChecked(prefs.getBoolean("showHud", true));
        delayBox.setChecked(prefs.getBoolean("showDelay", true));
        fillBox.setChecked(prefs.getBoolean("fillScreen", true));
        touchBox.setChecked(prefs.getBoolean("showTouches", false));
        lowLatBox.setChecked(prefs.getBoolean("lowLatency", false));
        audioBox.setChecked(!prefs.getBoolean("muteAudio", false));
        status.setText("读取桥参数…");
        new Thread(this::fetchCfg, "settings-fetch").start();
    }

    void hide() {
        scroll.setVisibility(View.GONE);
    }

    boolean visible() {
        return scroll.getVisibility() == View.VISIBLE;
    }

    private void fetchCfg() {
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress("127.0.0.1", CFG_PORT), 1200);
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "US-ASCII"));
            String line = br.readLine();
            if (line != null && line.startsWith("#cfg ")) {
                parseCfg(line.substring(5));
                ui.post(() -> status.setText(String.format(Locale.US,
                        "桥当前：%s @ %d fps，%d Mbps",
                        sizeText == null ? "自动" : sizeText, curFps, curBr / 1000)));
                return;
            }
        } catch (Exception e) {
            Log.w(TAG, "settings fetch failed: " + e);
        }
        ui.post(() -> status.setText("读不到桥参数（adb reverse tcp:47781 了吗？）"));
    }

    private void parseCfg(String kv) {
        for (String part : kv.trim().split("\\s+")) {
            int eq = part.indexOf('=');
            if (eq <= 0) continue;
            String k = part.substring(0, eq);
            String v = part.substring(eq + 1);
            ui.post(() -> {
                try {
                    switch (k) {
                        case "res": curRes = Integer.parseInt(v); break;
                        case "size": sizeText = v; break;
                        case "fps": curFps = Integer.parseInt(v); fpsSpin.setSelection(indexOf(RATES, v)); break;
                        case "bitrate": curBr = Integer.parseInt(v);
                            brSpin.setSelection(indexOf(BITRATES, String.valueOf(curBr / 1000))); break;
                        case "hevc": hevcBox.setChecked("1".equals(v)); break;
                        case "hdr": hdrBox.setChecked("1".equals(v)); break;
                        case "audio": audioBox.setChecked("1".equals(v)); break;
                        default: break;
                    }
                } catch (NumberFormatException ignore) {
                }
            });
        }
        ui.post(() -> {
            for (int i = 0; i < RES_HEIGHTS.length; i++) {
                if (RES_HEIGHTS[i] == curRes) resSpin.setSelection(i);
            }
            if (sizeText != null) {
                status.setText("桥当前: " + sizeText + " @ " + curFps + " fps, " + (curBr / 1000) + " Mbps");
            }
        });
    }

    private static int indexOf(String[] arr, String v) {
        for (int i = 0; i < arr.length; i++) if (arr[i].equals(v)) return i;
        return 0;
    }

    private void apply() {
        // 客户端开关先落地（不需要重启会话）
        boolean showHud = hudBox.isChecked();
        boolean showDelay = delayBox.isChecked();
        boolean fill = fillBox.isChecked();
        boolean showTouches = touchBox.isChecked();
        boolean lowLatency = lowLatBox.isChecked();
        boolean mute = !audioBox.isChecked();
        int resH = RES_HEIGHTS[Math.max(0, resSpin.getSelectedItemPosition())];
        prefs.edit().putBoolean("showHud", showHud).putBoolean("showDelay", showDelay)
                .putInt("res", resH)
                .putBoolean("fillScreen", fill).putBoolean("showTouches", showTouches)
                .putBoolean("muteAudio", mute).apply();
        surface.setShowHud(showHud);
        surface.setShowDelay(showDelay);
        surface.setFillScreen(fill);
        surface.setShowTouches(showTouches);
        video.setLowLatency(lowLatency);
        video.setMuted(mute);

        String fps = (String) fpsSpin.getSelectedItem();
        String mbps = (String) brSpin.getSelectedItem();
        int bitrate = Integer.parseInt(mbps) * 1000;
        boolean hevc = hevcBox.isChecked();
        boolean hdr = hdrBox.isChecked();
        boolean audio = audioBox.isChecked();

        status.setText("正在应用…");
        new Thread(() -> {
            boolean ok = push(resH, Integer.parseInt(fps), bitrate, hevc, hdr, audio, screenW, screenH);
            ui.post(() -> {
                if (ok) {
                    hide();
                    Toast.makeText(act, "已应用，桥正在用新参数重连", Toast.LENGTH_SHORT).show();
                } else {
                    status.setText("应用失败：连不上 bridge 设置口");
                }
            });
        }, "settings-apply").start();
    }

    private boolean push(int resH, int fps, int bitrate, boolean hevc, boolean hdr, boolean audio,
                         int screenW, int screenH) {
        try (Socket s = new Socket()) {
            s.setTcpNoDelay(true);
            s.connect(new InetSocketAddress("127.0.0.1", CFG_PORT), 1500);
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "US-ASCII"));
            OutputStreamWriter wr = new OutputStreamWriter(s.getOutputStream(), "US-ASCII");
            br.readLine(); // #cfg 欢迎行
            String[] lines = {
                    "set res=" + resH,
                    "set screen=" + screenW + "x" + screenH,
                    "set fps=" + fps,
                    "set bitrate=" + bitrate,
                    "set hevc=" + (hevc ? "1" : "0"),
                    "set hdr=" + (hdr ? "1" : "0"),
                    "set audio=" + (audio ? "1" : "0"),
            };
            for (String l : lines) {
                wr.write(l + "\n");
                wr.flush();
                br.readLine();
            }
            wr.write("apply\n");
            wr.flush();
            String ack = br.readLine();
            Log.i(TAG, "settings apply ack=" + ack);
            return ack != null && ack.startsWith("#applied");
        } catch (Exception e) {
            Log.w(TAG, "settings apply failed: " + e);
            return false;
        }
    }

    // ------------------------------------------------------------------ 小工具

    private int dp(int v) {
        return Math.round(v * act.getResources().getDisplayMetrics().density);
    }

    private GradientDrawable rounded(int color, int radius) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radius);
        return g;
    }
}
