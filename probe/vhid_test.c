// Minimal virtual HID creation test (needs com.apple.developer.hid.virtual.device)
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct __IOHIDUserDevice *IOHIDUserDeviceRef;
extern IOHIDUserDeviceRef IOHIDUserDeviceCreateWithProperties(CFDictionaryRef, CFDictionaryRef);
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDLib.h>

int main(void) {
    // Minimal 3-button mouse-ish descriptor is enough to prove creation rights
    unsigned char desc[] = {
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x09,0x01, 0xA1,0x00,
        0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01,
        0x95,0x03, 0x75,0x01, 0x81,0x02, 0x95,0x01, 0x75,0x05, 0x81,0x03,
        0xC0, 0xC0
    };
    CFDataRef d = CFDataCreate(NULL, desc, sizeof(desc));
    CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(p, CFSTR(kIOHIDReportDescriptorKey), d);
    CFDictionarySetValue(p, CFSTR(kIOHIDProductKey), CFSTR("VHID-Probe"));
    CFDictionarySetValue(p, CFSTR(kIOHIDVendorIDKey), CFSTR("0x1209"));
    CFDictionarySetValue(p, CFSTR(kIOHIDProductIDKey), CFSTR("0x4c53"));
    IOHIDUserDeviceRef dev = IOHIDUserDeviceCreateWithProperties(p, NULL);
    printf("IOHIDUserDeviceCreateWithProperties -> %p\n", (void*)dev);
    return dev ? 0 : 1;
}
