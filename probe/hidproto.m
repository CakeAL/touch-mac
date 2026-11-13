#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static void dumpProto(const char *name) {
    Protocol *p = objc_getProtocol(name);
    if (!p) { printf("protocol %s: NOT FOUND\n", name); return; }
    printf("== protocol %s\n", name);
    unsigned int n = 0;
    struct objc_method_description *req = protocol_copyMethodDescriptionList(p, YES, YES, &n);
    for (unsigned int i = 0; i < n; i++) printf("  @required %s  %s\n", sel_getName(req[i].name), req[i].types);
    free(req);
    req = protocol_copyMethodDescriptionList(p, NO, YES, &n);
    for (unsigned int i = 0; i < n; i++) printf("  @optional %s  %s\n", sel_getName(req[i].name), req[i].types);
    free(req);
}
int main(void) { @autoreleasepool {
    if (!dlopen("/System/Library/PrivateFrameworks/HID.framework/Versions/A/HID", RTLD_NOW)) return 1;
    dumpProto("HIDVirtualEventServiceDelegate");
    dumpProto("HIDEventSystemClientDelegate");
    int n = objc_getClassList(NULL, 0); Class *cs = (__unsafe_unretained Class *)malloc(sizeof(Class)*n); n = objc_getClassList(cs, n);
    for (int i=0;i<n;i++){const char *cn=class_getName(cs[i]); if(strncmp(cn,"HID",3)==0) printf("class %s\n", cn);}
    free(cs);
} return 0; }
