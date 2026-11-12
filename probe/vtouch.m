// vtouch.m — 在 macOS 27.2 上探测：用户态虚拟 HID 触屏能否被系统当成 direct touch
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#define K(x) [NSString stringWithUTF8String:(x)]

typedef struct __IOHIDUserDevice *IOHIDUserDeviceRef;
extern IOHIDUserDeviceRef IOHIDUserDeviceCreate(CFAllocatorRef allocator, CFDictionaryRef properties);
extern IOReturn IOHIDUserDeviceHandleReport(IOHIDUserDeviceRef device, const uint8_t *report, CFIndex reportLength);

static const uint8_t kReportDesc[] = {
    0x05, 0x0D,        // Usage Page (Digitizer)
    0x09, 0x04,        // Usage (Touch Screen)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x22,        //   Usage (Finger)
    0xA1, 0x02,        //   Collection (Logical)
    0x09, 0x42,        //     Usage (Tip Switch)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x75, 0x01,        //     Report Size (1)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x09, 0x32,        //     Usage (In Range)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x95, 0x06,        //     Report Count (6)
    0x81, 0x03,        //     Input (Const)
    0x09, 0x51,        //     Usage (Contact Identifier)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x01,        //     Report Count (1)
    0x26, 0x7F, 0x00,  //     Logical Maximum (127)
    0x81, 0x02,        //     Input
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x75, 0x10,        //     Report Size (16)
    0x95, 0x01,        //     Report Count (1)
    0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
    0x81, 0x02,        //     Input
    0x09, 0x31,        //     Usage (Y)
    0x81, 0x02,        //     Input
    0xC0,              //   End Collection
    0xC0               // End Collection
};

static void printScreens(void) {
    for (NSScreen *s in [NSScreen screens]) {
        printf("  screen %-24s frame=%s touchCaps=%lu\n",
               [[s localizedName] UTF8String] ?: "(nil)",
               [NSStringFromRect(s.frame) UTF8String],
               (unsigned long)s.touchCapabilities);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL sendTap = (argc > 1 && strcmp(argv[1], "tap") == 0);
        BOOL integrated = (argc > 2 && strcmp(argv[2], "nointegrated") == 0) ? NO : YES;
        NSData *desc = [NSData dataWithBytes:kReportDesc length:sizeof(kReportDesc)];
        NSDictionary *props = @{
            @(kIOHIDReportDescriptorKey): desc,
            @(kIOHIDPrimaryUsagePageKey): @(0x0D),
            @(kIOHIDPrimaryUsageKey): @(0x04),
            @(kIOHIDVendorIDKey): @(0x1209),
            @(kIOHIDProductIDKey): @(0x0001),
            @(kIOHIDProductKey): @"Virtual Touchscreen",
            @(kIOHIDTransportKey): @"Virtual",
            @(kIOHIDDisplayIntegratedKey): @(integrated),
        };
        IOHIDUserDeviceRef dev = IOHIDUserDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)props);
        printf("device create: %s (integrated=%d)\n", dev ? "OK" : "FAILED", integrated);
        if (!dev) { printf("  (needs entitlement com.apple.security.device.hid? or root?)\n"); return 2; }
        [NSThread sleepForTimeInterval:1.0];
        printf("screens after device creation:\n");
        printScreens();
        fflush(stdout);
        system("hidutil list 2>/dev/null | grep -i -E 'Virtual|Touchscreen|Touch Screen' || echo '  (not listed by hidutil)'");

        if (sendTap) {
            // tap at normalized (0.25, 0.75) of a 1920x1080 point screen
            const double sx = 1920 * 0.25, sy = 1080 * 0.75;
            uint16_t x = (uint16_t)(sx / 1920.0 * 32767.0);
            uint16_t y = (uint16_t)((1080.0 - sy) / 1080.0 * 32767.0); // HID Y up
            uint8_t down[6] = {0x03, 0x01, 0, 0, 0, 0};
            uint8_t up[6]   = {0x00, 0x01, 0, 0, 0, 0};
            memcpy(down + 2, &x, 2); memcpy(down + 4, &y, 2);
            memcpy(up + 2, &x, 2);   memcpy(up + 4, &y, 2);
            printf("sending touch down at (%.0f,%.0f) -> hid (%u,%u)\n", sx, sy, x, y);
            IOReturn r1 = IOHIDUserDeviceHandleReport(dev, down, sizeof(down));
            [NSThread sleepForTimeInterval:0.15];
            IOReturn r2 = IOHIDUserDeviceHandleReport(dev, up, sizeof(up));
            printf("handle report returns: 0x%x 0x%x\n", r1, r2);
        }
        printf("holding device 6s...\n"); fflush(stdout);
        [NSThread sleepForTimeInterval:6.0];
    }
    return 0;
}
