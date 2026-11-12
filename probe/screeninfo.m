// screeninfo.m — 列出显示器与 macOS 27 的触控能力标记
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

int main(void) {
    @autoreleasepool {
        printf("macOS %s\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
        for (NSScreen *s in [NSScreen screens]) {
            NSNumber *n = [s deviceDescription][@"NSScreenNumber"];
            CGDirectDisplayID did = (CGDirectDisplayID)[n unsignedIntValue];
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(did);
            CFStringRef us = uuid ? CFUUIDCreateString(NULL, uuid) : NULL;
            printf("display id=%u builtin=%d frame=%s scale=%.1f touchCaps=%lu uuid=%s name=%s\n",
                   did, CGDisplayIsBuiltin(did),
                   [NSStringFromRect(s.frame) UTF8String], s.backingScaleFactor,
                   (unsigned long)s.touchCapabilities,
                   us ? [(__bridge NSString *)us UTF8String] : "?",
                   [[s localizedName] UTF8String] ?: "?");
            if (us) CFRelease(us);
            if (uuid) CFRelease(uuid);
        }
        printf("mainScreen touchCaps=%lu\n", (unsigned long)[NSScreen mainScreen].touchCapabilities);
    }
    return 0;
}
