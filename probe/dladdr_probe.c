// dladdr_probe.c — resolve unslid shared-cache stub addresses to symbol names.
// clang -O2 -o dladdr_probe dladdr_probe.c -framework CoreFoundation
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

static const uint64_t addrs[] = {
    0x18806c140, 0x18806c2f0, 0x18806c560, 0x18806c7b0,
    0x18806e300, 0x188072a40, 0x188073200, 0x188073780,
    0x188073e30, 0x188073e40, 0x188073f00, 0x188074360,
    0x188075f50, 0x188075f70, 0x188076400, 0x1880770b0,
    0x188077390, 0x18807e410, 0x18807f9d0, 0x18807fa20,
    0x18807fa90, 0x18807fcf0, 0x18807fd00, 0x18807fd10,
    0x18807fd20, 0x188080890, 0x1880808c0,
};

int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    intptr_t slide = 0;
    const char *image = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "SkyLight.framework")) {
            image = n;
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    printf("image: %s\nslide: 0x%" PRIxPTR "\n", image ? image : "(not found)", (uintptr_t)slide);
    fflush(stdout);
    if (getenv("STOP")) raise(SIGSTOP);

    for (size_t i = 0; i < sizeof(addrs) / sizeof(addrs[0]); i++) {
        Dl_info info = {0};
        uint64_t live = addrs[i] + (uint64_t)slide;
        if (dladdr((void *)(uintptr_t)live, &info)) {
            printf("0x%" PRIx64 " -> %-40s  image=%s  saddr=%p fbase=%p\n",
                   addrs[i],
                   info.dli_sname ? info.dli_sname : "(null)",
                   info.dli_fname ? info.dli_fname : "(null)",
                   info.dli_saddr, info.dli_fbase);
        } else {
            printf("0x%" PRIx64 " -> dladdr failed (live=%p)\n", addrs[i], (void *)(uintptr_t)live);
        }
    }
    return 0;
}
