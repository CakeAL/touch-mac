// Probe: inspect HID.framework's HIDVirtualEventService class at runtime.
// Purpose: determine whether a normal (unentitled) process can create a virtual
// HID event service and attach creation-time properties such as displayUUID.
//
// Build: clang -fobjc-arc -framework Foundation -framework IOKit -o hidclass hidclass.m

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static void dumpClass(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) {
        printf("class %s: NOT FOUND\n", name);
        return;
    }
    printf("== class %s (%p) super=%s\n", name, cls, class_getName(class_getSuperclass(cls)));

    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    printf("  instance methods (%u):\n", n);
    for (unsigned int i = 0; i < n; i++) {
        printf("    - %s  types=%s\n", sel_getName(method_getName(methods[i])),
               method_getTypeEncoding(methods[i]));
    }
    free(methods);

    methods = class_copyMethodList(object_getClass(cls), &n);
    printf("  class methods (%u):\n", n);
    for (unsigned int i = 0; i < n; i++) {
        printf("    + %s  types=%s\n", sel_getName(method_getName(methods[i])),
               method_getTypeEncoding(methods[i]));
    }
    free(methods);

    Ivar *ivars = class_copyIvarList(cls, &n);
    printf("  ivars (%u):\n", n);
    for (unsigned int i = 0; i < n; i++) {
        printf("    %s  type=%s off=%td\n", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]),
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    // protocols adopted by the class
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(cls, &n);
    printf("  protocols (%u):\n", n);
    for (unsigned int i = 0; i < n; i++) {
        printf("    %s\n", protocol_getName(protos[i]));
    }
    free(protos);
}

int main(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/HID.framework/Versions/A/HID",
                         RTLD_NOW);
        printf("dlopen HID.framework: %p %s\n", h, h ? "" : dlerror());
        if (!h) return 1;

        dumpClass("HIDVirtualEventService");

        // Any related classes exported by the framework?
        unsigned int count = 0;
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *cn = class_getName(classes[i]);
            if (strncmp(cn, "HID", 3) == 0 && strstr(cn, "Virtual")) {
                printf("related class: %s\n", cn);
                count++;
            }
        }
        free(classes);
        printf("related virtual classes: %u\n", count);
    }
    return 0;
}
