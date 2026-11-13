// touchwatch — 全屏窗口，记录收到的 NSTouch 事件，用于验证 WindowServer 原生多点触控投递。
// clang -fobjc-arc bridge/touchwatch.m -framework Cocoa -o bridge/touchwatch
#import <Cocoa/Cocoa.h>

static FILE *g_log;
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(g_log, "%.6f %s\n", CFAbsoluteTimeGetCurrent(), s.UTF8String); fflush(g_log);
}

@interface TV : NSView
@end
@implementation TV
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    self.acceptsTouchEvents = YES;
    self.allowedTouchTypes = NSTouchTypeMaskDirect | NSTouchTypeMaskIndirect;
    self.wantsRestingTouches = NO;
    [self.window makeFirstResponder:self];
}
- (void)magnifyWithEvent:(NSEvent *)e { L(@"MAGNIFY %f", e.magnification); }
- (void)rotateWithEvent:(NSEvent *)e { L(@"ROTATE %f", e.rotation); }
- (void)scrollWheel:(NSEvent *)e { L(@"SCROLL %.2f %.2f", e.scrollingDeltaX, e.scrollingDeltaY); }
- (void)smartMagnifyWithEvent:(NSEvent *)e { L(@"SMARTMAGNIFY"); }
- (void)swipeWithEvent:(NSEvent *)e { L(@"SWIPE %.2f %.2f", e.deltaX, e.deltaY); }
- (void)mouseDown:(NSEvent *)e { L(@"MOUSEDOWN loc=%.1f,%.1f", e.locationInWindow.x, e.locationInWindow.y); }
- (void)mouseUp:(NSEvent *)e { L(@"MOUSEUP loc=%.1f,%.1f", e.locationInWindow.x, e.locationInWindow.y); }
- (void)mouseMoved:(NSEvent *)e { L(@"MOUSEMOVED loc=%.1f,%.1f", e.locationInWindow.x, e.locationInWindow.y); }
- (void)touchesBeganWithEvent:(NSEvent *)event {
    NSSet *t = [event touchesMatchingPhase:NSTouchPhaseBegan inView:self];
    for (NSTouch *x in t) L(@"BEGAN id=%llu dev=%@ type=%ld x=%.4f y=%.4f", x.identity, x.device, (long)x.type, x.normalizedPosition.x, x.normalizedPosition.y);
    if (t.count == 0) L(@"BEGAN phase-began n=%lu", (unsigned long)[event touchesMatchingPhase:NSTouchPhaseAny inView:self].count);
}
- (void)touchesMovedWithEvent:(NSEvent *)event {
    NSSet *t = [event touchesMatchingPhase:NSTouchPhaseMoved inView:self];
    for (NSTouch *x in t) L(@"MOVED id=%llu x=%.4f y=%.4f", x.identity, x.normalizedPosition.x, x.normalizedPosition.y);
}
- (void)touchesEndedWithEvent:(NSEvent *)event {
    NSSet *t = [event touchesMatchingPhase:NSTouchPhaseEnded inView:self];
    for (NSTouch *x in t) L(@"ENDED id=%llu x=%.4f y=%.4f", x.identity, x.normalizedPosition.x, x.normalizedPosition.y);
}
- (void)touchesCancelledWithEvent:(NSEvent *)event {
    L(@"CANCELLED");
}
@end

@interface TWWindow : NSWindow
@end
@implementation TWWindow
- (void)sendEvent:(NSEvent *)e {
    NSSet *any = nil;
    if (e.type == NSEventTypeBeginGesture || e.type == NSEventTypeGesture || e.type == NSEventTypeEndGesture) {
        // ignore
    }
    L(@"EVENT type=%ld subtype=%ld win=%ld loc=%.1f,%.1f", (long)e.type, (long)e.subtype, (long)e.windowNumber, e.locationInWindow.x, e.locationInWindow.y);
    if (e.type == NSEventTypeGesture) {
        NSSet *all = [e touchesMatchingPhase:NSTouchPhaseAny inView:self.contentView];
        L(@"  GESTURE sub=%ld touches=%lu", (long)e.subtype, (unsigned long)all.count);
        for (NSTouch *t in all) {
            L(@"    touch id=%llu phase=%ld x=%.3f y=%.3f", t.identity, (long)t.phase, t.normalizedPosition.x, t.normalizedPosition.y);
        }
    }
    [super sendEvent:e];
}
@end

@interface AD : NSObject <NSApplicationDelegate>
@end
@implementation AD
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSRect f = NSScreen.mainScreen.frame;
    TWWindow *w = [[TWWindow alloc] initWithContentRect:f styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    const char *lvl = getenv("TW_LEVEL");
    w.level = lvl ? atol(lvl) : (NSMainMenuWindowLevel + 1);
    w.backgroundColor = [NSColor colorWithCalibratedWhite:0.1 alpha:1.0];
    TV *v = [[TV alloc] initWithFrame:f];
    w.contentView = v;
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    L(@"READY frame=%@ win=%ld", NSStringFromRect(f), (long)w.windowNumber);
}
@end

int main(int argc, const char **argv) {
    g_log = fopen(argc > 1 ? argv[1] : "/tmp/touchwatch.log", "w");
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AD *d = [AD new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
