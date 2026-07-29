#import "LiquidTabsModule.h"
#import "LTBBarView.h"
#import "LTBSystemBar.h"

#import <UIKit/UIKit.h>

// Hex "#RRGGBB" / "#RRGGBBAA" → UIColor. Chuỗi lạ → nil (caller giữ màu cũ) chứ
// KHÔNG trả đen: đen im lặng là lỗi thị giác khó truy, giữ màu cũ thì thấy ngay
// là "màu không đổi".
static UIColor *_Nullable LTBColorFromHex(NSString *_Nullable hex)
{
  if (hex.length != 7 && hex.length != 9) return nil;
  if (![hex hasPrefix:@"#"]) return nil;
  unsigned int value = 0;
  NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
  if (![scanner scanHexInt:&value]) return nil;
  if (hex.length == 7) {
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
  }
  return [UIColor colorWithRed:((value >> 24) & 0xFF) / 255.0
                         green:((value >> 16) & 0xFF) / 255.0
                          blue:((value >> 8) & 0xFF) / 255.0
                         alpha:(value & 0xFF) / 255.0];
}

static UIWindow *_Nullable LTBKeyWindow(void)
{
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    UIWindowScene *ws = (UIWindowScene *)scene;
    if (ws.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow *w in ws.windows) {
      if (w.isKeyWindow) return w;
    }
  }
  return nil;
}

@implementation LiquidTabsModule {
  LTBBarView *_bar;
  NSLayoutConstraint *_heightC;
  NSLayoutConstraint *_leadingC;
  NSLayoutConstraint *_trailingC;
  NSLayoutConstraint *_bottomC;
  BOOL _visible;

  /// Bar HỆ THỐNG (`UITabBarController`) — đường CHÍNH trên iOS 26. Xem `LTBSystemBar.h`
  /// về lý do không tự vẽ nữa. `nil` trên máy dưới ngưỡng ⇒ rơi về `_bar` vẽ tay.
  LTBSystemBar *_systemBar;
  /// Chốt MỘT LẦN ở lần dùng đầu. Không hỏi lại mỗi lệnh: nếu giá trị đổi giữa các lệnh
  /// (vd probe lỗi nhất thời) thì hai nhánh sẽ cùng sống và có HAI thanh bar trên màn.
  BOOL _useSystemBarResolved;
  BOOL _useSystemBar;
}

RCT_EXPORT_MODULE(LiquidTabs)

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

/// Dựng bar + gắn vào key window. Idempotent. PHẢI ở main thread.
/// Window chưa có (gọi quá sớm) ⇒ trả nil và KHÔNG dựng gì: lần gọi sau sẽ thử
/// lại. Cố dựng vào window nil rồi "để đó" là đường sinh bar mồ côi.
- (LTBBarView *_Nullable)ensureBar
{
  UIWindow *window = LTBKeyWindow();
  if (window == nil) return nil;

  if (_bar == nil) {
    _bar = [LTBBarView new];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.hidden = !_visible;
    __weak __typeof(self) weakSelf = self;
    _bar.onSelect = ^(NSString *key) {
      // `emitOnTabSelected` do codegen sinh trên NativeLiquidTabsSpecBase.
      [weakSelf emitOnTabSelected:@{@"key" : key}];
    };
  }

  if (_bar.superview != window) {
    [_bar removeFromSuperview];
    [window addSubview:_bar];
    // Neo theo safeAreaLayoutGuide: xoay máy / đổi safe area do UIKit lo, JS không
    // phải tính lại. Constraint giữ lại để setGeometry chỉ đổi `constant`.
    _heightC = [_bar.heightAnchor constraintEqualToConstant:64];
    _leadingC = [_bar.leadingAnchor constraintEqualToAnchor:window.leadingAnchor constant:10];
    _trailingC = [_bar.trailingAnchor constraintEqualToAnchor:window.trailingAnchor constant:-10];
    _bottomC = [_bar.bottomAnchor constraintEqualToAnchor:window.bottomAnchor constant:-20];
    [NSLayoutConstraint activateConstraints:@[ _heightC, _leadingC, _trailingC, _bottomC ]];
  }
  // Luôn kéo lên trên cùng: RN có thể thêm view (modal, debug overlay) sau bar.
  [window bringSubviewToFront:_bar];
  return _bar;
}

/// Chọn nhánh MỘT LẦN rồi giữ nguyên suốt phiên. Hỏi lại mỗi lệnh là đường sinh HAI
/// thanh bar cùng lúc nếu probe trả khác nhau giữa các lần gọi.
- (BOOL)useSystemBar
{
  if (!_useSystemBarResolved) {
    _useSystemBar = [LTBSystemBar isSupported];
    _useSystemBarResolved = YES;
  }
  return _useSystemBar;
}

- (LTBSystemBar *_Nullable)ensureSystemBar
{
  UIWindow *window = LTBKeyWindow();
  if (window == nil) return nil;
  if (_systemBar == nil) {
    _systemBar = [LTBSystemBar new];
    __weak __typeof(self) weakSelf = self;
    _systemBar.onSelect = ^(NSString *key) {
      [weakSelf emitOnTabSelected:@{@"key" : key}];
    };
    [_systemBar setVisible:_visible animated:NO];
  }
  [_systemBar attachToWindow:window];
  return _systemBar;
}

/// Điều phối duy nhất: đưa ĐÚNG MỘT trong hai nhánh, nhánh kia là nil. Mọi lệnh của spec
/// đi qua đây để không có lệnh nào lỡ chỉ hiện thực một nhánh — đó là kiểu lỗi im lặng
/// (một nền tảng mất tính năng mà không ai báo).
- (void)route:(void (^)(LTBSystemBar *_Nullable sys, LTBBarView *_Nullable bar))block
{
  dispatch_block_t work = ^{
    if ([self useSystemBar]) {
      LTBSystemBar *sys = [self ensureSystemBar];
      if (sys != nil) block(sys, nil);
      return;
    }
    LTBBarView *bar = [self ensureBar];
    if (bar != nil) block(nil, bar);
  };
  if (NSThread.isMainThread) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

#pragma mark - Spec

- (NSNumber *)isGlassAvailable
{
  return @([LTBBarView isGlassAvailable]);
}

- (NSNumber *)isAvailable
{
  // iOS luôn có bar (kính hoặc nền vẽ tay). Module này chỉ build cho iOS nên tới
  // được đây nghĩa là có.
  return @(YES);
}

- (void)setTabs:(NSArray *)items
{
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *clean = [NSMutableArray new];
  for (id raw in items) {
    if (![raw isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *d = (NSDictionary *)raw;
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary new];
    for (NSString *k in @[ @"key", @"label", @"sfSymbol", @"sfSymbolSelected", @"imageUrl", @"badge" ]) {
      id v = d[k];
      out[k] = [v isKindOfClass:NSString.class] ? v : @"";
    }
    if (((NSString *)out[@"key"]).length == 0) continue;  // không key ⇒ không tap được
    [clean addObject:out];
  }
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      [sys setItems:clean];
      return;
    }
    [bar setItems:clean];
  }];
}

- (void)setActive:(NSString *)key
{
  NSString *k = [key isKindOfClass:NSString.class] ? key : @"";
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      [sys setActiveKey:k];
      return;
    }
    [bar setActiveKey:k];
  }];
}

- (void)setVisible:(BOOL)visible animated:(BOOL)animated
{
  _visible = visible;
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      [sys setVisible:visible animated:animated];
      return;
    }
    if (!animated) {
      bar.hidden = !visible;
      bar.alpha = visible ? 1.0 : 0.0;
      return;
    }
    if (visible) bar.hidden = NO;
    [UIView animateWithDuration:0.2
        animations:^{
          bar.alpha = visible ? 1.0 : 0.0;
        }
        completion:^(BOOL finished) {
          // Chỉ ẩn khi trạng thái MONG MUỐN vẫn là ẩn — hai lệnh chồng nhau
          // (ẩn rồi hiện ngay) không được để completion cũ ẩn mất bar.
          if (finished && !self->_visible) bar.hidden = YES;
        }];
  }];
}

- (void)setGeometry:(double)height
    horizontalInset:(double)horizontalInset
        bottomInset:(double)bottomInset
       cornerRadius:(double)cornerRadius
{
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      // Bar hệ thống tự định vị và tự bo góc theo chuẩn iOS 26 — ép geometry vào nó là
      // đường làm mất chính hiệu ứng ta vừa đổi kiến trúc để lấy. Nhận rồi bỏ qua, KHÔNG
      // ném lỗi: phía gọi dùng cùng một đoạn code cho mọi nền tảng.
      return;
    }
    self->_heightC.constant = height;
    self->_leadingC.constant = horizontalInset;
    self->_trailingC.constant = -horizontalInset;
    self->_bottomC.constant = -bottomInset;
    [bar setBarCornerRadius:cornerRadius];
    [bar.superview layoutIfNeeded];
  }];
}

- (void)setTint:(NSString *)activeHex inactiveHex:(NSString *)inactiveHex
{
  UIColor *a = LTBColorFromHex(activeHex);
  UIColor *i = LTBColorFromHex(inactiveHex);
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      [sys setTintActive:a inactive:i];
      return;
    }
    [bar setTintActive:a inactive:i];
  }];
}

- (void)setLensColor:(NSString *)hex
{
  UIColor *c = LTBColorFromHex(hex);
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    if (sys != nil) {
      // Capsule chọn của bar hệ thống KHÔNG có API công khai để đổi màu, và mọi cách ép
      // qua `UITabBarAppearance` đều làm mất luôn capsule (nhiều báo cáo forum Apple).
      // Nhận rồi bỏ qua.
      return;
    }
    [bar setLensColor:c];
  }];
}

- (void)setMergeSpacing:(double)spacing
{
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    // Bar hệ thống tự lo merge — không có gì để đặt.
    if (sys == nil) [bar setMergeSpacing:spacing];
  }];
}

#pragma mark - TurboModule

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeLiquidTabsSpecJSI>(params);
}

@end
