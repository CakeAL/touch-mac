// 最小 Moonlight 客户端：连接本地 Sunshine，只发原生触控包，视频/音频丢弃。
//
// 用途：验证 SS_TOUCH 报文经 Sunshine 的 mac_native_touch 路径触发
// IOHIDUserDeviceHandleReportWithTimeStamp → VoidLink HID Touchscreen 原生 digitizer。
//
// 用法:
//   ./client <rtspUrl> <rikeyHex32> <rikeyId> [--hold-seconds N] [--two-finger]
// rikey/rikeyId 必须与 /launch 请求中发送的一致（见 launch.sh）。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <signal.h>
#include <time.h>

static double now_ts(void) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

#include "Limelight.h"

static volatile int g_stop = 0;
static int g_connected = 0;

static void on_stage_starting(int stage) {
    fprintf(stderr, "[stage] %s\n", LiGetStageName(stage));
}
static void on_stage_complete(int stage) {
    fprintf(stderr, "[stage] %s done\n", LiGetStageName(stage));
}
static void on_stage_failed(int stage, int error) {
    fprintf(stderr, "[stage] %s FAILED %d\n", LiGetStageName(stage), error);
}
static void on_connection_started(void) {
    g_connected = 1;
    fprintf(stderr, "[conn] started\n");
}
static void on_connection_terminated(int error) {
    g_connected = 0;
    fprintf(stderr, "[conn] terminated %d\n", error);
}
static void on_log(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("[lib] ", stderr);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}
static void on_status(int status) {
    fprintf(stderr, "[conn] status %d\n", status);
}

static void on_sigint(int sig) {
    (void) sig;
    g_stop = 1;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex_key(const char* hex, char out[16]) {
    if (strlen(hex) != 32) return -1;
    for (int i = 0; i < 16; i++) {
        int hi = hexval(hex[i * 2]);
        int lo = hexval(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (char) ((hi << 4) | lo);
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <rtspUrl> <rikeyHex32> <rikeyId> [--hold-seconds N] [--two-finger]\n", argv[0]);
        return 2;
    }

    const char* rtsp_url = argv[1];
    const char* rikey_hex = argv[2];
    unsigned int rikey_id = (unsigned int) strtoul(argv[3], NULL, 10);

    int hold_seconds = 4;
    int two_finger = 0;
    int stdin_touch = 0;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--hold-seconds") && i + 1 < argc) {
            hold_seconds = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--two-finger")) {
            two_finger = 1;
        } else if (!strcmp(argv[i], "--stdin")) {
            stdin_touch = 1;
        }
    }

    STREAM_CONFIGURATION sc;
    LiInitializeStreamConfiguration(&sc);
    sc.width = 1280;
    sc.height = 720;
    sc.fps = 60;
    sc.bitrate = 20000;
    sc.packetSize = 1024;
    sc.streamingRemotely = 0;
    sc.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    sc.supportedVideoFormats = VIDEO_FORMAT_H264;
    sc.clientRefreshRateX100 = 6000;
    sc.colorSpace = COLORSPACE_REC_709;
    sc.colorRange = COLOR_RANGE_LIMITED;
    sc.encryptionFlags = ENCFLG_ALL;

    if (parse_hex_key(rikey_hex, sc.remoteInputAesKey) != 0) {
        fprintf(stderr, "bad rikey hex (need 32 chars)\n");
        return 2;
    }
    // IV: 前 4 字节 = rikeyId 大端，其余 0（与 Moonlight 客户端一致）
    memset(sc.remoteInputAesIv, 0, sizeof(sc.remoteInputAesIv));
    sc.remoteInputAesIv[0] = (char) ((rikey_id >> 24) & 0xff);
    sc.remoteInputAesIv[1] = (char) ((rikey_id >> 16) & 0xff);
    sc.remoteInputAesIv[2] = (char) ((rikey_id >> 8) & 0xff);
    sc.remoteInputAesIv[3] = (char) (rikey_id & 0xff);

    SERVER_INFORMATION si;
    LiInitializeServerInformation(&si);
    si.address = "127.0.0.1";
    si.serverInfoAppVersion = "7.1.431.0";
    si.serverInfoGfeVersion = NULL;
    si.rtspSessionUrl = rtsp_url;
    si.serverCodecModeSupport = SCM_H264;

    CONNECTION_LISTENER_CALLBACKS cl;
    LiInitializeConnectionCallbacks(&cl);
    cl.stageStarting = on_stage_starting;
    cl.stageComplete = on_stage_complete;
    cl.stageFailed = on_stage_failed;
    cl.connectionStarted = on_connection_started;
    cl.connectionTerminated = on_connection_terminated;
    cl.logMessage = on_log;
    cl.connectionStatusUpdate = on_status;

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    fprintf(stderr, "[main] connecting rtsp=%s rikeyId=%u\n", rtsp_url, rikey_id);
    int err = LiStartConnection(&si, &sc, &cl, NULL, NULL, NULL, 0, NULL, 0);
    fprintf(stderr, "[main] LiStartConnection -> %d\n", err);
    if (err != 0) {
        return 1;
    }

    fprintf(stderr, "[main] host feature flags = 0x%x (LI_FF_PEN_TOUCH_EVENTS=0x1)\n",
            LiGetHostFeatureFlags());

    // 等连接就绪（control stream 建好后 connectionStarted 才回调）
    for (int i = 0; i < 100 && !g_connected && !g_stop; i++) {
        usleep(100 * 1000);
    }
    if (!g_connected) {
        fprintf(stderr, "[main] never connected\n");
    }

    if (stdin_touch) {
        // 交互模式：从 stdin 读指令，一行一条
        //   d <id> <x> <y>   down
        //   m <id> <x> <y>   move
        //   u <id> <x> <y>   up
        //   c                cancel all
        // 坐标为 0..1 归一化；EOF 或 "q" 结束会话
        char line[256];
        int n = 0;
        fprintf(stderr, "[main] stdin touch mode\n");
        while (!g_stop && fgets(line, sizeof(line), stdin)) {
            char cmd = line[0];
            unsigned int id = 0;
            float x = 0, y = 0;
            if (cmd == 'q') break;
            if (cmd == 'c') {
                LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL_ALL, 0, 0, 0, 0, 0, 0, 0);
                n++;
                continue;
            }
            if (sscanf(line + 1, "%u %f %f", &id, &x, &y) != 3) continue;
            uint8_t ev = (cmd == 'd') ? LI_TOUCH_EVENT_DOWN
                       : (cmd == 'm') ? LI_TOUCH_EVENT_MOVE
                       : (cmd == 'u') ? LI_TOUCH_EVENT_UP
                       : 0xFF;
            if (ev == 0xFF) continue;
            float p = (ev == LI_TOUCH_EVENT_UP) ? 0.0f : 1.0f;
            LiSendTouchEvent(ev, id, x, y, p, 0.05f, 0.05f, 0xFFFF);
            n++;
            if (getenv("TOUCH_TS")) fprintf(stderr, "[ts] %.6f %c %u\n", now_ts(), cmd, id);
            if (n % 50 == 0) fprintf(stderr, "[touch] %d events sent\n", n);
        }
        fprintf(stderr, "[main] stdin closed after %d events\n", n);
    } else {
    // 单指：Down → Move → Up
    fprintf(stderr, "[touch] DOWN id=1 (0.50,0.50)\n");
    fprintf(stderr, "[touch] down rc=%d\n",
            LiSendTouchEvent(LI_TOUCH_EVENT_DOWN, 1, 0.50f, 0.50f, 1.0f, 0.05f, 0.05f, 0xFFFF));
    usleep(400 * 1000);

    for (int i = 1; i <= 6 && !g_stop; i++) {
        float x = 0.50f + 0.03f * (float) i;
        fprintf(stderr, "[touch] MOVE id=1 (%.2f,0.50) rc=%d\n", x,
                LiSendTouchEvent(LI_TOUCH_EVENT_MOVE, 1, x, 0.50f, 1.0f, 0.05f, 0.05f, 0xFFFF));
        usleep(120 * 1000);
    }

    if (two_finger) {
        fprintf(stderr, "[touch] DOWN id=2 (0.40,0.60)\n");
        LiSendTouchEvent(LI_TOUCH_EVENT_DOWN, 2, 0.40f, 0.60f, 1.0f, 0.05f, 0.05f, 0xFFFF);
        usleep(200 * 1000);
        LiSendTouchEvent(LI_TOUCH_EVENT_MOVE, 2, 0.45f, 0.62f, 1.0f, 0.05f, 0.05f, 0xFFFF);
        usleep(200 * 1000);
        LiSendTouchEvent(LI_TOUCH_EVENT_UP, 2, 0.45f, 0.62f, 0.0f, 0.05f, 0.05f, 0xFFFF);
    }

    fprintf(stderr, "[touch] UP id=1 rc=%d\n",
            LiSendTouchEvent(LI_TOUCH_EVENT_UP, 1, 0.68f, 0.50f, 0.0f, 0.05f, 0.05f, 0xFFFF));

    }

    for (int i = 0; i < hold_seconds * 10 && !g_stop; i++) {
        usleep(100 * 1000);
    }

    LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL_ALL, 0, 0, 0, 0, 0, 0, 0);
    usleep(100 * 1000);

    fprintf(stderr, "[main] stopping\n");
    LiStopConnection();
    fprintf(stderr, "[main] done\n");
    return 0;
}
