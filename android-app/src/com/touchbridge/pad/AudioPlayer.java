package com.touchbridge.pad;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;

import java.util.concurrent.ArrayBlockingQueue;

/**
 * 音频播放：bridge 已经在 Mac 侧把 Opus 解成 PCM，这里只需要写 AudioTrack。
 *
 * 每包是 5 ms 的 48 kHz 立体声 16-bit（Sunshine 的 Opus 帧长就这么短），
 * 队列只留 40 包（约 200 ms）防止越堆越晚。
 */
final class AudioPlayer {
    private static final String TAG = "TouchBridge";
    private static final int SAMPLE_RATE = 48000;

    private final ArrayBlockingQueue<byte[]> queue = new ArrayBlockingQueue<>(40);
    private volatile boolean running = true;
    private volatile boolean enabled = true;
    private volatile String state = "audio idle";
    private final java.util.concurrent.atomic.AtomicBoolean started =
            new java.util.concurrent.atomic.AtomicBoolean(false);

    void start() {
        if (!started.compareAndSet(false, true)) return;
        Thread t = new Thread(this::loop, "audio-player");
        t.setDaemon(true);
        t.start();
    }

    void setEnabled(boolean on) {
        enabled = on;
        if (!on) queue.clear();
        state = on ? "audio on" : "audio off";
    }

    boolean enabled() {
        return enabled;
    }

    String state() {
        return state;
    }

    void feed(byte[] pcm) {
        if (!enabled) return;
        if (queue.remainingCapacity() == 0) queue.poll();
        queue.offer(pcm);
    }

    void stop() {
        running = false;
    }

    private void loop() {
        AudioTrack track = null;
        try {
            int minBuf = AudioTrack.getMinBufferSize(SAMPLE_RATE,
                    AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
            int bufSize = Math.max(minBuf, 960 * 2 * 8);
            AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build();
            AudioFormat af = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build();
            track = new AudioTrack.Builder()
                    .setAudioAttributes(attrs)
                    .setAudioFormat(af)
                    .setBufferSizeInBytes(bufSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            track.play();
            state = "audio playing";
            Log.i(TAG, "audio track " + SAMPLE_RATE + "Hz stereo, buf=" + bufSize);

            long written = 0;
            while (running) {
                byte[] pcm = queue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS);
                if (pcm == null) continue;
                int off = 0;
                while (running && off < pcm.length) {
                    int n = track.write(pcm, off, pcm.length - off);
                    if (n <= 0) break;
                    off += n;
                }
                written += pcm.length;
                if (written > 0 && written % (SAMPLE_RATE * 4 * 10) < pcm.length) {
                    Log.i(TAG, "audio written " + written / (SAMPLE_RATE * 4) + "s");
                }
            }
        } catch (Exception e) {
            state = "audio error " + e.getClass().getSimpleName();
            Log.w(TAG, "audio loop failed: " + e, e);
        } finally {
            try {
                if (track != null) {
                    track.stop();
                    track.release();
                }
            } catch (Exception ignore) {
            }
            state = "audio stopped";
        }
    }
}
