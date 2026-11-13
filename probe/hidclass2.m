#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static void dump(const char *name) {
    Class cls = objc_getClass(name); if (!cls) { printf("class %s NOT FOUND\n", name); return; }
    printf("== %s super=%s\n", name, class_getName(class_getSuperclass(cls)));
    unsigned int n=0; Method *m;
    m = class_copyMethodList(object_getClass(cls), &n);
    for (unsigned i=0;i<n;i++) printf("  + %s %s\n", sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
    free(m);
    m = class_copyMethodList(cls, &n);
    for (unsigned i=0;i<n;i++) printf("  - %s %s\n", sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
    free(m);
}
int main(void){@autoreleasepool{
    if(!dlopen("/System/Library/PrivateFrameworks/HID.framework/Versions/A/HID",RTLD_NOW)) return 1;
    dump("HIDEventSystemClient"); dump("HIDEvent"); dump("HIDServiceClient");
    unsigned int n=0; Protocol * __unsafe_unretained *ps = objc_copyProtocolList(&n);
    printf("total protocols %u\n", n);
    for (unsigned i=0;i<n;i++){const char*pn=protocol_getName(ps[i]); if(strstr(pn,"HID")) printf("proto %s\n",pn);}
    free(ps);
}return 0;}
