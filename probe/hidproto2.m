#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
int main(void) { @autoreleasepool {
    if (!dlopen("/System/Library/PrivateFrameworks/HID.framework/Versions/A/HID", RTLD_NOW)) return 1;
    unsigned int n = 0;
    Protocol * __unsafe_unretained *ps = objc_copyProtocolList(&n);
    for (unsigned int i = 0; i < n; i++) {
        const char *pn = protocol_getName(ps[i]);
        if (strstr(pn, "Virtual") || strstr(pn, "HIDEventService")) printf("protocol %s\n", pn);
    }
    free(ps);
} return 0; }
