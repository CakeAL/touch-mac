#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDKeys.h>
typedef struct __IOHIDUserDevice *IOHIDUserDeviceRef;
extern IOHIDUserDeviceRef IOHIDUserDeviceCreate(CFAllocatorRef, CFDictionaryRef);
static const uint8_t kDesc[] = {0x05,0x0D,0x09,0x04,0xA1,0x01,0x09,0x22,0xA1,0x02,0x09,0x42,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x01,0x81,0x02,0x09,0x32,0x81,0x02,0x95,0x06,0x81,0x03,0x09,0x51,0x75,0x08,0x95,0x01,0x26,0x7F,0x00,0x81,0x02,0x05,0x01,0x09,0x30,0x75,0x10,0x95,0x01,0x26,0xFF,0x7F,0x81,0x02,0x09,0x31,0x81,0x02,0xC0,0xC0};
int main(void) {
  @autoreleasepool {
    NSData *d = [NSData dataWithBytes:kDesc length:sizeof(kDesc)];
    NSArray *sets = @[
      @{@(kIOHIDReportDescriptorKey): d},
      @{@(kIOHIDReportDescriptorKey): d, @(kIOHIDPrimaryUsagePageKey): @(0x0D), @(kIOHIDPrimaryUsageKey): @(0x04)},
      @{@(kIOHIDReportDescriptorKey): d, @(kIOHIDVendorIDKey): @(0x1209), @(kIOHIDProductIDKey): @(0x0001), @(kIOHIDProductKey): @"VTouch", @(kIOHIDTransportKey): @"Virtual"},
      @{@(kIOHIDReportDescriptorKey): d, @(kIOHIDDisplayIntegratedKey): @YES},
      @{@(kIOHIDReportDescriptorKey): d, @(kIOHIDVendorIDKey): @(0x05AC), @(kIOHIDProductIDKey): @(0x0001), @(kIOHIDDisplayIntegratedKey): @YES, @(kIOHIDTransportKey): @"Virtual"},
    ];
    int i = 0;
    for (NSDictionary *p in sets) {
      IOHIDUserDeviceRef dev = IOHIDUserDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)p);
      printf("set %d -> %s\n", i++, dev ? "OK" : "NULL");
    }
    printf("uid=%d euid=%d\n", getuid(), geteuid());
  }
  return 0;
}
