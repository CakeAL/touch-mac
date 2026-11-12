// touchlab.m — 在 macOS 27 上观察 direct touch 是否真的送到 AppKit 手势识别器
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

static NSString *gLogPath = @"/tmp/touchlab.log";
static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    printf("%s", [line UTF8String]);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath]; }
    [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
}

@interface TouchLogger : NSGestureRecognizer
@property(nonatomic) NSInteger seen;
@end

@implementation TouchLogger
- (instancetype)initWithTarget:(id)t action:(SEL)a {
    if ((self = [super initWithTarget:t action:a])) { self.allowedTouchTypes = NSTouchTypeMaskDirect; }
    return self;
}
- (void)dump:(NSEvent *)event phase:(NSString *)phase {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self.view];
    for (NSTouch *t in touches) {
        self.seen++;
        NSPoint p = [t locationInView:self.view];
        LG(@"[touch] %@ type=%ld id=%p norm=(%.4f,%.4f) view=(%.1f,%.1f) device=%@ size=%@ resting=%d",
           phase, (long)t.type, (__bridge void *)t.identity,
           t.normalizedPosition.x, t.normalizedPosition.y, p.x, p.y,
           t.device ?: @"nil", NSStringFromSize(t.deviceSize), t.isResting);
    }
    if (touches.count == 0) LG(@"[touch] %@ (empty set)", phase);
}
- (void)touchesBeganWithEvent:(NSEvent *)e { [self dump:e phase:@"began"]; [super touchesBeganWithEvent:e]; }
- (void)touchesMovedWithEvent:(NSEvent *)e { [self dump:e phase:@"moved"]; [super touchesMovedWithEvent:e]; }
- (void)touchesEndedWithEvent:(NSEvent *)e { [self dump:e phase:@"ended"]; [super touchesEndedWithEvent:e]; }
- (void)touchesCancelledWithEvent:(NSEvent *)e { [self dump:e phase:@"cancelled"]; [super touchesCancelledWithEvent:e]; }
- (NSPoint)locationInView:(NSView *)view {
    NSPoint p = [super locationInView:view];
    return p;
}
@end

@interface LabView : NSView
@property(nonatomic) NSInteger clicks, pans;
@end
@implementation LabView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor windowBackgroundColor] setFill]; NSRectFill(dirty);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:22], NSForegroundColorAttributeName: [NSColor labelColor]};
    [@"TouchLab — 用手指点这里\n（若只看到 mouse 事件，说明没拿到 direct touch）" drawAtPoint:NSMakePoint(40, 60) withAttributes:attrs];
}
- (void)didClick { self.clicks++; LG(@"[gesture] click #%ld", (long)self.clicks); }
- (void)didPan:(NSPanGestureRecognizer *)g {
    if (g.state == NSGestureRecognizerStateBegan) { self.pans++; LG(@"[gesture] pan began #%ld", (long)self.pans); }
}
- (void)didMagnify:(NSMagnificationGestureRecognizer *)g {
    if (g.state == NSGestureRecognizerStateBegan) LG(@"[gesture] magnify began");
}
// 传统 mouse 路径，用于对比
- (void)mouseDown:(NSEvent *)e { LG(@"[mouse] down at %@ touchPoint=%@", NSStringFromPoint(e.locationInWindow), NSStringFromPoint([e locationInWindow])); [super mouseDown:e]; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSWindow *window;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    for (NSScreen *s in [NSScreen screens])
        LG(@"[screen] %@ touchCaps=%lu", [s localizedName] ?: @"?", (unsigned long)s.touchCapabilities);

    NSRect frame = NSMakeRect(0, 0, 900, 600);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"TouchLab (macOS 27 direct-touch probe)";
    [self.window center];

    NSView *content = self.window.contentView;
    LabView *lab = [[LabView alloc] initWithFrame:content.bounds];
    lab.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [content addSubview:lab];

    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:lab action:@selector(didClick)];
    click.allowedTouchTypes = NSTouchTypeMaskDirect | NSTouchTypeMaskIndirect;
    [lab addGestureRecognizer:click];

    NSPanGestureRecognizer *pan = [[NSPanGestureRecognizer alloc] initWithTarget:lab action:@selector(didPan:)];
    [lab addGestureRecognizer:pan];

    NSMagnificationGestureRecognizer *mag = [[NSMagnificationGestureRecognizer alloc] initWithTarget:lab action:@selector(didMagnify:)];
    [lab addGestureRecognizer:mag];

    TouchLogger *logger = [[TouchLogger alloc] initWithTarget:nil action:NULL];
    [lab addGestureRecognizer:logger];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    LG(@"[app] window up; NSIsTouchNative=%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSIsTouchNative"] ?: @"(absent)");
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--probe") != 0) gLogPath = [NSString stringWithUTF8String:argv[1]];
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
            printf("probe mode: 只报告显示器触控能力，不开窗口\n");
            for (NSScreen *s in [NSScreen screens])
                printf("  %s touchCaps=%lu frame=%s\n", [[s localizedName] UTF8String] ?: "?", (unsigned long)s.touchCapabilities, [NSStringFromRect(s.frame) UTF8String]);
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
