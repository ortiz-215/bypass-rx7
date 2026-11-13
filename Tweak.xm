#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSDictionary *gCfg = nil;
static BOOL gDone = NO;
static UIButton *gBtn = nil;
static UIView *gPanel = nil;

static void BLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[BYPASS] %@", s);
}

static NSDictionary *loadCfg(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *a = [docs stringByAppendingPathComponent:@"bypass.plist"];
    NSString *b = [[NSBundle mainBundle] pathForResource:@"bypass" ofType:@"plist"];
    for (NSString *p in @[a, b ?: @""]) {
        if (!p.length) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) { BLog(@"config desde %@", p); return d; }
    }
    return @{
        @"mode": @"rootSwap",
        @"delay": @1.0,
        @"loginClassSubstrings": @[@"Login", @"SignIn", @"Auth", @"OTP", @"Verif", @"Session"],
        @"rootClassSubstrings": @[@"TabBarController", @"MainViewController", @"HomeViewController", @"RootViewController", @"Dashboard"],
        @"boolGetters": @[@"isLoggedIn", @"isSignedIn", @"isAuthenticated", @"hasSession", @"loggedIn", @"isGuest"],
        @"defaultsTrueKeys": @[@"logged", @"signed", @"auth", @"session", @"token", @"onboard"]
    };
}

static NSArray *classesMatching(NSString *needle) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0; Class *cs = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromClass(cs[i]);
        if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
            [out addObject:name];
    }
    free(cs);
    return out;
}

static UIWindow *mainWindow(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows)
            if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].keyWindow;
}

static void swapRoot(UIViewController *vc) {
    UIWindow *w = mainWindow();
    if (!w) { BLog(@"sin ventana"); return; }
    BOOL hidden = w.hidden;
    [UIView transitionWithView:w duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ w.rootViewController = vc; w.hidden = hidden; }
                    completion:nil];
    BLog(@"root -> %@", NSStringFromClass([vc class]));
}

static UIViewController *findRootVC(void) {
    for (NSString *s in gCfg[@"rootClassSubstrings"]) {
        for (NSString *cls in classesMatching(s)) {
            Class c = NSClassFromString(cls);
            if (![c isSubclassOfClass:[UIViewController class]]) continue;
            @try {
                UIViewController *vc = [[UIStoryboard storyboardWithName:@"Main" bundle:nil]
                                          instantiateViewControllerWithIdentifier:cls];
                if (vc) { BLog(@"root por storyboard: %@", cls); return vc; }
            } @catch (NSException *e) {}
            @try {
                UIViewController *vc = [[c alloc] init];
                if (vc) { BLog(@"root por init: %@", cls); return vc; }
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

static void performBypass(UIViewController *from) {
    if (gDone) return;
    gDone = YES;
    NSString *mode = gCfg[@"mode"] ?: @"rootSwap";
    BLog(@"modo %@ desde %@", mode, NSStringFromClass([from class]));

    if ([mode isEqualToString:@"rootSwap"]) {
        UIViewController *root = findRootVC();
        if (root) {
            if ([root isKindOfClass:[UINavigationController class]] ||
                [root isKindOfClass:[UITabBarController class]]) swapRoot(root);
            else swapRoot([[UINavigationController alloc] initWithRootViewController:root]);
            return;
        }
        BLog(@"sin VC raiz, paso a dismiss");
        mode = @"dismiss";
    }
    if ([mode isEqualToString:@"dismiss"]) {
        [from.navigationController popToRootViewControllerAnimated:NO];
        [from dismissViewControllerAnimated:NO completion:nil];
    }
}

static void (*origVDA)(id, SEL, BOOL);
static void newVDA(id self, SEL _cmd, BOOL animated) {
    origVDA(self, _cmd, animated);
    if (gDone) return;
    NSString *cls = NSStringFromClass([self class]);
    for (NSString *s in gCfg[@"loginClassSubstrings"]) {
        if ([cls rangeOfString:s options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        BLog(@"login detectado: %@", cls);
        double d = [gCfg[@"delay"] doubleValue] ?: 1.0;
        __weak UIViewController *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *vc = ws ?: mainWindow().rootViewController;
            if (vc) performBypass(vc);
        });
        return;
    }
}

static void hookViewDidAppear(void) {
    Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (!m) return;
    origVDA = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)newVDA);
}

static void hookBoolGetters(void) {
    NSArray *names = gCfg[@"boolGetters"];
    unsigned int n = 0; Class *cs = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        unsigned int mc = 0; Method *ms = class_copyMethodList(cs[i], &mc);
        for (unsigned int j = 0; j < mc; j++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[j]));
            if (![names containsObject:sel]) continue;
            const char *rt = method_getTypeEncoding(ms[j]);
            if (!rt || (rt[0] != 'B' && rt[0] != 'c')) continue;
            method_setImplementation(ms[j], imp_implementationWithBlock(^BOOL(id _s) { return YES; }));
            BLog(@"BOOL -> YES: %@ %@", NSStringFromClass(cs[i]), sel);
        }
        free(ms);
    }
    free(cs);
}

static BOOL (*origBoolForKey)(id, SEL, NSString *);
static BOOL newBoolForKey(id self, SEL _cmd, NSString *key) {
    for (NSString *p in gCfg[@"defaultsTrueKeys"])
        if ([key rangeOfString:p options:NSCaseInsensitiveSearch].location != NSNotFound) {
            BLog(@"defaults %@ -> YES", key);
            return YES;
        }
    return origBoolForKey(self, _cmd, key);
}

static void hookDefaults(void) {
    Class c = object_getClass([NSUserDefaults standardUserDefaults]);
    Method m = class_getInstanceMethod(c, @selector(boolForKey:));
    if (!m) return;
    origBoolForKey = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)newBoolForKey);
}

@interface BypassTap : NSObject
@end

@implementation BypassTap

- (void)show { gPanel.hidden = NO; gBtn.hidden = YES; [self refresh]; }
- (void)hide { gPanel.hidden = YES; gBtn.hidden = NO; }
- (void)bypass { gDone = NO; performBypass(mainWindow().rootViewController); }

- (void)forceRoot {
    UIViewController *r = findRootVC();
    if (r) swapRoot(r); else BLog(@"no hay root");
}

- (void)copyText {
    UITextView *tv = (UITextView *)[gPanel viewWithTag:99];
    [UIPasteboard generalPasteboard].string = tv.text ?: @"";
    BLog(@"copiado");
}

- (void)refresh {
    UITextView *tv = (UITextView *)[gPanel viewWithTag:99];
    NSMutableString *s = [NSMutableString string];
    for (NSString *pat in gCfg[@"loginClassSubstrings"]) {
        NSArray *hit = classesMatching(pat);
        [s appendFormat:@"== %@ (%lu)\n", pat, (unsigned long)hit.count];
        for (NSString *c in hit) {
            [s appendFormat:@"  %@\n", c];
            Class cls = NSClassFromString(c);
            unsigned int mc = 0; Method *ms = class_copyMethodList(cls, &mc);
            for (unsigned int i = 0; i < mc && i < 25; i++)
                [s appendFormat:@"    - %s\n", sel_getName(method_getName(ms[i]))];
            free(ms);
        }
    }
    for (NSString *pat in gCfg[@"rootClassSubstrings"]) {
        NSArray *hit = classesMatching(pat);
        if (!hit.count) continue;
        [s appendFormat:@"== ROOT %@\n", pat];
        for (NSString *c in hit) [s appendFormat:@"  %@\n", c];
    }
    tv.text = s;
}

@end

static BypassTap *gTap = nil;

static void installPanel(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *w = mainWindow();
        if (!w) return;
        gTap = [BypassTap new];

        gBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gBtn.frame = CGRectMake(16, 110, 58, 58);
        gBtn.backgroundColor = [UIColor colorWithRed:0 green:0.55 blue:1 alpha:0.9];
        gBtn.layer.cornerRadius = 29;
        [gBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [gBtn setTitle:@"DBG" forState:UIControlStateNormal];
        [gBtn addTarget:gTap action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:gBtn];

        CGFloat W = w.bounds.size.width - 32;
        gPanel = [[UIView alloc] initWithFrame:CGRectMake(16, 110, W, 340)];
        gPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
        gPanel.layer.cornerRadius = 12;
        gPanel.clipsToBounds = YES;

        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(8, 8, W - 16, 260)];
        tv.tag = 99;
        tv.backgroundColor = [UIColor clearColor];
        tv.textColor = [UIColor colorWithRed:0.6 green:1 blue:0.7 alpha:1];
        tv.font = [UIFont fontWithName:@"Menlo" size:10];
        tv.editable = NO;
        [gPanel addSubview:tv];

        NSArray *titles = @[@"BYPASS", @"ROOT", @"COPY", @"REFRESH", @"OCULTAR"];
        NSArray *sels = @[@"bypass", @"forceRoot", @"copyText", @"refresh", @"hide"];
        CGFloat bw = (W - 40) / 5;
        for (int i = 0; i < 5; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = CGRectMake(8 + i * (bw + 4), 274, bw, 34);
            b.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
            b.layer.cornerRadius = 8;
            b.titleLabel.font = [UIFont boldSystemFontOfSize:10];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [b setTitle:titles[i] forState:UIControlStateNormal];
            [b addTarget:gTap action:NSSelectorFromString(sels[i]) forControlEvents:UIControlEventTouchUpInside];
            [gPanel addSubview:b];
        }
        gPanel.hidden = YES;
        [w addSubview:gPanel];
        [gTap refresh];
    });
}

__attribute__((constructor)) static void initBypass(void) {
    gCfg = loadCfg();
    BLog(@"cargado en %@", [[NSBundle mainBundle] bundleIdentifier]);
    hookDefaults();
    hookBoolGetters();
    hookViewDidAppear();
    installPanel();
}
