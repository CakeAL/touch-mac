// vnat.m — 按 CanvasHost 的方式创建 macOS 27 虚拟触屏并发送原生触摸
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

#define MAX_CONTACTS 16

static void appendFinger(NSMutableData *d) {
    const uint8_t finger[] = {
        0x05,0x0d, 0x09,0x22, 0xa1,0x02,
        0x09,0x42, 0x09,0x32, 0x09,0x47,
        0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x03, 0x81,0x02,
        0x75,0x05, 0x95,0x01, 0x81,0x03,
        0x09,0x51, 0x25,0x7f, 0x75,0x08, 0x95,0x01, 0x81,0x02,
        0x05,0x01, 0x09,0x30, 0x09,0x31, 0x27,0xff,0xff,0x00,0x00,
        0x75,0x10, 0x95,0x02, 0x81,0x02,
        0xc0
    };
    [d appendBytes:finger length:sizeof(finger)];
}

static NSData *makeDescriptor(void) {
    NSMutableData *d = [NSMutableData data];
    const uint8_t header[] = {0x05,0x0d, 0x09,0x04, 0xa1,0x01};
    [d appendBytes:header length:sizeof(header)];
    for (int i = 0; i < MAX_CONTACTS; i++) appendFinger(d);
    const uint8_t end[] = {0x05,0x0d, 0x09,0x54, 0x15,0x00, 0x25,MAX_CONTACTS, 0x75,0x08, 0x95,0x01, 0x81,0x02, 0xc0};
    [d appendBytes:end length:sizeof(end)];
    return d;
}

static BOOL serviceReady(io_service_t service) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return NO;
    BOOL found = NO;
    io_object_t e;
    while ((e = IOIteratorNext(it))) {
        if (IOObjectConformsTo(e, "AppleUserHIDEventService")) { found = YES; }
        IOObjectRelease(e);
        if (found) break;
    }
    IOObjectRelease(it);
    return found;
}

static void printTouchCaps(const char *when) {
    for (NSScreen *s in [NSScreen screens])
        printf("  [%s] %-10s touchCaps=%lu\n", when, [[s localizedName] UTF8String] ?: "?", (unsigned long)s.touchCapabilities);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL tap = (argc > 1 && strcmp(argv[1], "tap") == 0);
        double nx = argc > 2 ? atof(argv[2]) : 0.30;
        double ny = argc > 3 ? atof(argv[3]) : 0.70;
        double hold = argc > 4 ? atof(argv[4]) : 6.0;

        typedef CFTypeRef (*create_fn)(CFAllocatorRef, CFDictionaryRef, uint32_t);
        typedef io_service_t (*service_fn)(CFTypeRef);
        typedef IOReturn (*post_fn)(CFTypeRef, uint64_t, const uint8_t *, CFIndex);
        create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCreateWithProperties");
        service_fn copyService = (service_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCopyService");
        post_fn post = (post_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceHandleReportWithTimeStamp");
        printf("dlsym: create=%p service=%p post=%p\n", (void *)create, (void *)copyService, (void *)post);
        if (!create || !copyService || !post) return 2;

        CGDirectDisplayID display = CGMainDisplayID();
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
        NSString *uuidString = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
        printf("display=%u uuid=%s\n", display, uuidString.UTF8String);

        NSData *descriptor = makeDescriptor();
        NSDictionary *props = @{
            @"Product": @"VNV Touchscreen",
            @"VendorID": @(0x1209),
            @"ProductID": @(0x4c53),
            @"Transport": @"Virtual",
            @"ReportDescriptor": descriptor,
            @"displayUUID": uuidString ?: @"",
            @"CGDirectDisplayID": @(display),
            @"DisplayIntegrated": @YES,
            @"DigitizerCollectionDispatch": @YES,
        };
        printTouchCaps("before");
        CFTypeRef dev = create(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
        printf("create -> %p\n", dev);
        if (!dev) return 3;
        io_service_t service = copyService(dev);
        BOOL ready = NO;
        for (int i = 0; service && i < 100 && !ready; i++) {
            ready = serviceReady(service);
            if (!ready) usleep(10000);
        }
        printf("service ready=%d\n", ready);
        if (service) IOObjectRelease(service);
        usleep(200000);
        printTouchCaps("after");

        if (tap) {
            uint8_t report[6 * MAX_CONTACTS + 1] = {0};
            uint16_t x = (uint16_t)lround(fmin(fmax(nx, 0), 1) * 65535.0);
            uint16_t y = (uint16_t)lround(fmin(fmax(ny, 0), 1) * 65535.0);
            // down
            report[0] = 0x07; report[1] = 1; report[2] = x & 0xff; report[3] = x >> 8; report[4] = y & 0xff; report[5] = y >> 8;
            report[6 * MAX_CONTACTS] = 1;
            IOReturn r1 = post(dev, mach_absolute_time(), report, sizeof(report));
            usleep(80000);
            // up
            report[0] = 0x04;
            IOReturn r2 = post(dev, mach_absolute_time(), report, sizeof(report));
            printf("post down=0x%x up=0x%x\n", r1, r2);
            usleep(80000);
            printTouchCaps("after-tap");
        }

        printf("holding %.0fs...\n", hold); fflush(stdout);
        usleep((useconds_t)(hold * 1e6));
        CFRelease(dev);
    }
    return 0;
}
