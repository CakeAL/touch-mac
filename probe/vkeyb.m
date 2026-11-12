// vkeyb.m — 用同一个 SPI 造一个最简虚拟键盘，用来区分"整类被拒"还是"只有触屏/显示绑定被拒"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
int main(void) {
    @autoreleasepool {
        typedef CFTypeRef (*create_fn)(CFAllocatorRef, CFDictionaryRef, uint32_t);
        create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCreateWithProperties");
        printf("create=%p\n", (void *)create);
        if (!create) return 2;
        const uint8_t kb[] = {
            0x05,0x01, 0x09,0x06, 0xa1,0x01, 0x05,0x07, 0x19,0xe0, 0x29,0xe7,
            0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
            0x95,0x01, 0x75,0x08, 0x81,0x01, 0x95,0x05, 0x75,0x01, 0x05,0x08,
            0x19,0x01, 0x29,0x05, 0x91,0x02, 0x95,0x01, 0x75,0x03, 0x91,0x01,
            0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65, 0x05,0x07, 0x19,0x00,
            0x29,0x65, 0x81,0x00, 0xc0
        };
        NSDictionary *props = @{
            @"Product": @"VNV Keyboard",
            @"VendorID": @(0x1209),
            @"ProductID": @(0x4c54),
            @"Transport": @"Virtual",
            @"ReportDescriptor": [NSData dataWithBytes:kb length:sizeof(kb)],
        };
        CFTypeRef dev = create(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
        printf("keyboard create -> %p\n", dev);
        if (dev) CFRelease(dev);
    }
    return 0;
}
