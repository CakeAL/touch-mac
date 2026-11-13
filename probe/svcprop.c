// svcprop — 用 BackBoard 实际调用的 API 读取服务属性
// 目的：区分“IORegistry 属性表”与“HID 事件系统服务端属性表”
//
// clang svcprop.c -framework IOKit -framework CoreFoundation -o svcprop
// ./svcprop 0x10004bf39
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern uint64_t IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern CFStringRef IOHIDServiceClientCopyDescription(IOHIDServiceClientRef);

static void dump(IOHIDServiceClientRef svc, const char *key)
{
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IOHIDServiceClientCopyProperty(svc, k);
    if (v) {
        CFStringRef d = CFCopyDescription(v);
        char buf[512] = {0};
        CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8);
        printf("  %-28s %s\n", key, buf);
        if (d) CFRelease(d);
        CFRelease(v);
    } else {
        printf("  %-28s <NULL>\n", key);
    }
    CFRelease(k);
}

int main(int argc, char **argv)
{
    const char *want = (argc > 1) ? argv[1] : NULL;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) { fprintf(stderr, "client create failed\n"); return 1; }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { fprintf(stderr, "no services\n"); return 1; }

    CFIndex n = CFArrayGetCount(services);
    printf("services: %ld\n", (long)n);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        uint64_t rid = IOHIDServiceClientGetRegistryID(svc);

        CFStringRef pk = CFSTR("Product");
        CFTypeRef pv = IOHIDServiceClientCopyProperty(svc, pk);
        char pbuf[256] = {0};
        if (pv) {
            if (CFGetTypeID(pv) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)pv, pbuf, sizeof(pbuf), kCFStringEncodingUTF8);
            CFRelease(pv);
        }
        if (want && !strstr(pbuf, want)) continue;

        CFStringRef d = IOHIDServiceClientCopyDescription(svc);
        char buf[512] = {0};
        if (d) { CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8); CFRelease(d); }

        printf("\n== serviceID 0x%llx  product=%s  %s\n",
               (unsigned long long)rid, pbuf, buf);
        dump(svc, "Product");
        dump(svc, "displayUUID");
        dump(svc, "DisplayIntegrated");
        dump(svc, "DigitizerCollectionDispatch");
        dump(svc, "Built-In");
        dump(svc, "Transport");
        dump(svc, "PrimaryUsagePage");
        dump(svc, "PrimaryUsage");
    }
    CFRelease(services);
    return 0;
}
