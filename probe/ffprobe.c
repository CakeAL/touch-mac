// Query macOS feature flags (same shm state backboardd/WindowServer see).
#include <stdio.h>
#include <dlfcn.h>
#include <stdbool.h>

typedef bool (*ffn)(const char *, const char *);

int main(int argc, char **argv) {
    void *h = dlopen("/usr/lib/system/libsystem_featureflags.dylib", RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    ffn f = (ffn)dlsym(h, "_os_feature_enabled_impl");
    if (!f) { printf("dlsym failed\n"); return 1; }
    const char *pairs[][2] = {
        {"backboardd", "SupportExternalTouchscreen"},
        {"backboardd", "SupportExternalTouchscreenSimulator"},
        {"SkyLight", "SupportExternalTouchscreen"},
        {"BackBoard", "SupportExternalTouchscreen"},
    };
    if (argc == 3) { printf("%s/%s = %d\n", argv[1], argv[2], f(argv[1], argv[2])); return 0; }
    for (unsigned i = 0; i < sizeof(pairs)/sizeof(pairs[0]); i++)
        printf("%-12s %-34s = %d\n", pairs[i][0], pairs[i][1], f(pairs[i][0], pairs[i][1]));
    return 0;
}
