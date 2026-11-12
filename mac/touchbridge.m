// touchbridge.m — macOS 27 虚拟触屏 + 触摸通道（骨架实现）
//
// ⚠️ 现状（2026-11-12）：macOS 27.2 起，内核拒绝用户态创建虚拟 HID 设备
//    （IOHIDResourceDeviceUserClient: ... is not entitled），root 也不行。
//    本文件保留作参考：若未来系统放开或拿到 entitlement，可直接复用。
//    当前可行路线是“真 USB HID 触屏”（见 android/hid_gadget.sh 与 plan.md）。
//
// 用法：
//   touchbridge --list                      列出显示器
//   touchbridge --display 3 --port 5288     绑定显示并监听触摸
//   touchbridge --dry --port 5288           不创建设备，只打印收到的触摸（联调用）
//
// 触摸协议（TCP，大端，8 字节定长）：
//   u8  type    1=down 2=move 3=up 4=cancel_all 5=hover
//   u8  id      0..15
//   u16 x       0..65535 归一化
//   u16 y       0..65535 归一化
//   u8  flags   bit0 tip, bit1 in-range, bit2 confidence, bit3 barrel
//   u8  pressure 0..255（S Pen 阶段使用）
//
// 若 create 返回 NULL：27.2 上是内核 entitlement 拒绝（不是 TCC，root 也无法绕过），
// 只有 27.0/27.1 或持有对应私有权限时才能成功。

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_CONTACTS 16
#define RECORD_SIZE 8

typedef struct {
    uint8_t flags;
    uint8_t id;
    uint16_t x;
    uint16_t y;
} contact_t;

static contact_t gContacts[MAX_CONTACTS];
static CFTypeRef gDevice = NULL;
static BOOL gDryRun = NO;

static void logLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "%s\n", s.UTF8String);
}

#pragma mark - HID 设备

static void appendFinger(NSMutableData *d) {
    const uint8_t finger[] = {
        0x05, 0x0d, 0x09, 0x22, 0xa1, 0x02,
        0x09, 0x42, 0x09, 0x32, 0x09, 0x47,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
        0x75, 0x05, 0x95, 0x01, 0x81, 0x03,
        0x09, 0x51, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x27, 0xff, 0xff, 0x00, 0x00,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xc0
    };
    [d appendBytes:finger length:sizeof(finger)];
}

static NSData *makeDescriptor(void) {
    NSMutableData *d = [NSMutableData data];
    const uint8_t header[] = {0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01};
    [d appendBytes:header length:sizeof(header)];
    for (int i = 0; i < MAX_CONTACTS; i++) appendFinger(d);
    const uint8_t end[] = {0x05, 0x0d, 0x09, 0x54, 0x15, 0x00, 0x25, MAX_CONTACTS,
                           0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xc0};
    [d appendBytes:end length:sizeof(end)];
    return d;
}

static BOOL serviceReady(io_service_t service) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return NO;
    BOOL found = NO;
    io_object_t e;
    while ((e = IOIteratorNext(it))) {
        if (IOObjectConformsTo(e, "AppleUserHIDEventService")) found = YES;
        IOObjectRelease(e);
        if (found) break;
    }
    IOObjectRelease(it);
    return found;
}

static BOOL createTouchDevice(CGDirectDisplayID display) {
    typedef CFTypeRef (*create_fn)(CFAllocatorRef, CFDictionaryRef, uint32_t);
    typedef io_service_t (*service_fn)(CFTypeRef);
    create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCreateWithProperties");
    service_fn copyService = (service_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCopyService");
    if (!create || !copyService) {
        logLine(@"缺少 IOHIDUserDeviceCreateWithProperties（需要 macOS 27+）");
        return NO;
    }
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return NO;
    NSString *uuidString = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
    CFRelease(uuid);

    NSDictionary *props = @{
        @"Product": @"Tablet Touchscreen",
        @"VendorID": @(0x1209),
        @"ProductID": @(0x4c53),
        @"Transport": @"Virtual",
        @"ReportDescriptor": makeDescriptor(),
        @"displayUUID": uuidString,
        @"CGDirectDisplayID": @(display),
        @"DisplayIntegrated": @YES,
        @"DigitizerCollectionDispatch": @YES,
    };
    gDevice = create(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
    if (!gDevice) {
        logLine(@"create 返回 NULL：多半是缺少输入监控授权，或系统版本低于 27");
        return NO;
    }
    io_service_t service = copyService(gDevice);
    BOOL ready = NO;
    for (int i = 0; service && i < 100 && !ready; i++) {
        ready = serviceReady(service);
        if (!ready) usleep(10000);
    }
    if (service) IOObjectRelease(service);
    if (!ready) {
        logLine(@"digitizer 未就绪（AppleUserHIDEventService 未出现）");
        CFRelease(gDevice);
        gDevice = NULL;
        return NO;
    }
    usleep(150000);  // 等 WindowServer 注册
    return YES;
}

static void clearContacts(void) {
    memset(gContacts, 0, sizeof(gContacts));
}

static void postReport(void) {
    uint8_t report[6 * MAX_CONTACTS + 1] = {0};
    int count = 0;
    for (int i = 0; i < MAX_CONTACTS; i++) {
        contact_t *c = &gContacts[i];
        if (!c->id) continue;
        uint8_t *p = report + i * 6;
        p[0] = c->flags;
        p[1] = c->id;
        p[2] = c->x & 0xff;
        p[3] = c->x >> 8;
        p[4] = c->y & 0xff;
        p[5] = c->y >> 8;
        count++;
    }
    report[6 * MAX_CONTACTS] = (uint8_t)count;

    if (gDryRun || !gDevice) {
        fprintf(stderr, "report count=%d\n", count);
        return;
    }
    typedef IOReturn (*post_fn)(CFTypeRef, uint64_t, const uint8_t *, CFIndex);
    static post_fn post = NULL;
    if (!post) post = (post_fn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceHandleReportWithTimeStamp");
    if (!post) return;
    post(gDevice, mach_absolute_time(), report, sizeof(report));
}

// 触摸状态机：down/move 更新槽位，up 先发一帧“抬起”再释放槽位
static void handleTouch(uint8_t type, uint8_t id, uint16_t x, uint16_t y, uint8_t flags) {
    if (type == 4) {  // cancel all
        for (int i = 0; i < MAX_CONTACTS; i++) {
            if (gContacts[i].id) gContacts[i].flags = 0x04;  // confidence only
        }
        postReport();
        clearContacts();
        return;
    }
    int slot = -1;
    for (int i = 0; i < MAX_CONTACTS; i++) {
        if (gContacts[i].id == id && id != 0) { slot = i; break; }
    }
    if (type == 1) {  // down
        if (slot < 0) {
            for (int i = 0; i < MAX_CONTACTS; i++) {
                if (gContacts[i].id == 0) { slot = i; break; }
            }
        }
        if (slot < 0) return;
        gContacts[slot] = (contact_t){.flags = 0x07, .id = id, .x = x, .y = y};
    } else if (type == 2) {  // move
        if (slot < 0) return;
        gContacts[slot].x = x;
        gContacts[slot].y = y;
        gContacts[slot].flags = 0x07;
    } else if (type == 3) {  // up
        if (slot < 0) return;
        gContacts[slot].x = x;
        gContacts[slot].y = y;
        gContacts[slot].flags = 0x04;  // tip 清零，这一帧后释放
        postReport();
        gContacts[slot] = (contact_t){0};
        return;
    } else {
        return;
    }
    postReport();
}

#pragma mark - TCP

static void serve(int port) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return; }
    listen(srv, 1);
    logLine(@"listening on 127.0.0.1:%d", port);

    uint8_t buf[4096];
    size_t used = 0;
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) continue;
        logLine(@"client connected");
        used = 0;
        for (;;) {
            ssize_t n = read(fd, buf + used, sizeof(buf) - used);
            if (n <= 0) break;
            used += (size_t)n;
            size_t off = 0;
            while (used - off >= RECORD_SIZE) {
                uint8_t *r = buf + off;
                uint8_t type = r[0];
                uint8_t id = r[1];
                uint16_t x = (uint16_t)((r[2] << 8) | r[3]);
                uint16_t y = (uint16_t)((r[4] << 8) | r[5]);
                uint8_t flags = r[6];
                handleTouch(type, id, x, y, flags);
                off += RECORD_SIZE;
            }
            memmove(buf, buf + off, used - off);
            used -= off;
        }
        logLine(@"client gone");
        close(fd);
        clearContacts();
    }
}

#pragma mark - main

static void listDisplays(void) {
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = (CGDirectDisplayID)[[s deviceDescription][@"NSScreenNumber"] unsignedIntValue];
        printf("%u\tbuiltin=%d\t%s\ttouchCaps=%lu\n", did, CGDisplayIsBuiltin(did),
               [NSStringFromRect(s.frame) UTF8String], (unsigned long)s.touchCapabilities);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        CGDirectDisplayID display = CGMainDisplayID();
        int port = 5288;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--list")) { listDisplays(); return 0; }
            if (!strcmp(argv[i], "--dry")) gDryRun = YES;
            if (!strcmp(argv[i], "--display") && i + 1 < argc) display = (CGDirectDisplayID)atoi(argv[++i]);
            if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        }
        if (!gDryRun) {
            if (!createTouchDevice(display)) return 2;
            logLine(@"虚拟触屏就绪，绑定 display=%u", display);
            for (NSScreen *s in [NSScreen screens]) {
                CGDirectDisplayID did = (CGDirectDisplayID)[[s deviceDescription][@"NSScreenNumber"] unsignedIntValue];
                logLine(@"  display %u touchCaps=%lu", did, (unsigned long)s.touchCapabilities);
            }
        }
        serve(port);
    }
    return 0;
}
