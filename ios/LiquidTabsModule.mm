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

/// Nói ra khi một lệnh bị BỎ vì chưa phân giải được window / chưa có root VC.
///
/// Vì sao phải có: đường này từng là false-negative IM LẶNG và đã gây bug thật — thanh tab của
/// app chủ KHÔNG ẩn khi mở app từ notification. Lệnh `setVisible(NO)` bắn ra đúng lúc scene còn
/// `ForegroundInactive` ⇒ `LTBKeyWindow()` trả nil ⇒ `route:` bỏ lệnh, không log, không retry, và
/// phía gọi không gửi lại (lệnh là EDGE-TRIGGERED — chỉ gửi khi trạng thái đổi). Kết thúc như
/// thành công khi thực ra chẳng làm gì là loại lỗi đắt nhất: không ai nghi, và mất nhiều giờ mới
/// lần ra.
///
/// Log MỘT LẦN cho mỗi chuỗi rơi (`gWarned` hạ khi có lệnh chạy được) — một cửa sổ launch không
/// window sẽ sinh 6+ dòng mỗi vòng render nếu log mọi lần. Chỉ DEBUG nên release không tốn gì.
///
/// ⚠️ CÒN NỢ, có chủ đích — và chỉ còn ĐÚNG một chỗ: `setVisible` đã tự chữa (cờ `_visiblePending`
/// + `route:healVisibility:` + hook `UIApplicationDidBecomeActiveNotification`). Các lệnh KHÁC
/// (`setTabs`/`setTint`/`setGeometry`/`setLensColor`) thì rơi là MẤT. Riêng items thì rẻ hơn tưởng:
/// `LTBSystemBar` ĐÃ latch `_itemProps` (`LTBSystemBar.mm:182`), thiếu duy nhất một bước replay
/// trong `attachToWindow` sau khi dựng `_tbc`. Chưa làm vì đường dẫn tới ca đó đã bị bịt ở
/// `ensureSystemBar` (kiểm `rootViewController` trước khi attach), nên bước replay sẽ là code chết
/// — và repo chưa có harness test native để chứng minh điều ngược lại.
static BOOL gLTBWarnedDrop = NO;

static void LTBWarnDrop(void)
{
#if DEBUG
  if (gLTBWarnedDrop) return;
  gLTBWarnedDrop = YES;
  NSLog(@"[liquid-tabs] BỎ một lệnh — thiếu tiền đề: chưa phân giải được window (scene chưa "
        @"foreground?) hoặc window chưa có rootViewController. Trạng thái hiện/ẩn sẽ được áp lại "
        @"ở lệnh kế tiếp hoặc khi app active (cờ _visiblePending, xem route:healVisibility:); "
        @"các lệnh KHÁC (setTabs/setTint/…) thì MẤT.");
#else
  gLTBWarnedDrop = YES;
#endif
}

/// Hạ cờ log-once khi một lệnh chạy được — để chuỗi rơi TIẾP THEO vẫn được nói ra thay vì im
/// vĩnh viễn sau lần đầu.
static void LTBWarnDropReset(void) { gLTBWarnedDrop = NO; }

/// Window để gắn bar. `nil` ⇒ phía gọi PHẢI coi là lệnh không thi hành được (xem `route:`).
///
/// **Nhận CẢ `ForegroundInactive`**, không chỉ `ForegroundActive` — đây là phần thật sự sửa bug:
/// đó CHÍNH LÀ trạng thái của scene trong lúc app đang được notification đưa lên foreground. Bản
/// trước loại nó ra, tức loại đúng lúc cần nhất, nên mọi lệnh bắn trong cửa sổ đó đều rơi.
/// `Background`/`Unattached` vẫn bị loại ⇒ app ở nền thật thì không dựng bar.
///
/// Đánh đổi đã biết của việc nhận `ForegroundInactive`: bar có thể attach/hiện trong pha
/// resign-active (control-center, app-switcher, cuộc gọi tới) ⇒ snapshot app-switcher có thể chụp
/// bar ở trạng thái vừa đổi. Không mồ côi, không hỏng state (re-parent của `ensureBar` idempotent).
///
/// ⚠️ Vì sao KHÔNG lấy window bừa: `connectedScenes` là **NSSet — không có thứ tự**, và
/// `ws.windows` cũng không có thứ tự được tài liệu hoá. Một app chat chắc chắn có
/// `UITextEffectsWindow`/`UIRemoteKeyboardWindow` ngay khi ô nhập được focus lần đầu, và window đó
/// thoả cả `!hidden` lẫn `rootViewController != nil`. Gặp nó trước là neo bar vào window bàn phím
/// (nhánh hệ thống còn add `_tbc` làm child của `UIInputWindowController`) ⇒ bar sai level, sai chỗ.
/// Nên: chỉ scene role **application**, và chỉ window ở `UIWindowLevelNormal`.
///
/// (Bản nháp trước của hàm này viện lý do "banner/alert HỆ THỐNG đang giữ key" — SAI: banner
/// notification do SpringBoard vẽ, KHÁC PROCESS, không bao giờ nằm trong `connectedScenes` của app.
/// Fallback tồn tại cho ca đơn giản hơn: chưa window nào được đặt key trong pha chuyển trạng thái.)
static UIWindow *_Nullable LTBKeyWindow(void)
{
  UIWindow *fallback = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    UIWindowScene *ws = (UIWindowScene *)scene;
    // CarPlay / màn hình ngoài cũng là UIWindowScene. Không lọc role thì kết quả phụ thuộc thứ tự
    // của một NSSet ⇒ KHÔNG tất định giữa các lần chạy.
    if (![ws.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
    if (ws.activationState != UISceneActivationStateForegroundActive &&
        ws.activationState != UISceneActivationStateForegroundInactive) {
      continue;
    }
    // `keyWindow` cũng phải qua lọc level: window bàn phím / alert có thể đang là key, và đó đúng
    // là rủi ro vừa chặn ở fallback — tin đường chính vô điều kiện là bất đối xứng vô cớ.
    UIWindow *key = ws.keyWindow;
    if (key != nil && key.windowLevel == UIWindowLevelNormal) return key;
    if (fallback == nil) {
      for (UIWindow *w in ws.windows) {
        if (w.windowLevel != UIWindowLevelNormal) continue;
        if (w.hidden || w.rootViewController == nil) continue;
        fallback = w;
        break;
      }
    }
  }
  return fallback;
}

@implementation LiquidTabsModule {
  LTBBarView *_bar;
  NSLayoutConstraint *_heightC;
  NSLayoutConstraint *_leadingC;
  NSLayoutConstraint *_trailingC;
  NSLayoutConstraint *_bottomC;
  BOOL _visible;
  /// `YES` = trạng thái mong muốn `_visible` CHƯA chắc đã áp được lên view.
  ///
  /// Bật lúc vào `setVisible:animated:`, chỉ hạ TRONG block của `route:` — tức chỉ hạ khi lệnh
  /// thật sự chạy. Lệnh bị bỏ vì chưa phân giải được window ⇒ cờ ở lại `YES` ⇒ lệnh KẾ TIẾP bất kỳ
  /// sẽ tự chữa. Đây là thứ thay cho giả định sai "lần gọi sau sẽ thử lại": phía gọi KHÔNG gửi lại
  /// `setVisible` vì nó là lệnh edge-triggered.
  BOOL _visiblePending;

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

- (instancetype)init
{
  if (self = [super init]) {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(onAppDidBecomeActive)
                                              name:UIApplicationDidBecomeActiveNotification
                                            object:nil];
    // CẢ hai: notification cấp app KHÔNG nổ khi iPad/Stage Manager kích lại MỘT scene trong lúc app
    // vẫn active — mà đó đúng là ca cần chữa. Cùng handler, idempotent nên nổ hai lần vô hại.
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(onAppDidBecomeActive)
                                              name:UISceneDidActivateNotification
                                            object:nil];
  }
  return self;
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// Chữa trạng thái hiện/ẩn khi app trở lại active.
///
/// Vì sao KHÔNG đủ nếu chỉ dựa vào "lệnh kế tiếp tự chữa": app ở nền (scene `Background`, vẫn bị
/// `LTBKeyWindow` loại) mà JS điều hướng khỏi màn có tab ⇒ `setVisible(NO)` rơi. Khi app active
/// lại thì có thể KHÔNG còn lệnh nào tới nữa — phía gọi edge-triggered, và ở màn không-có-tab thì
/// không ai gửi `setTabs`/`setActive`/`setGeometry`. Thiếu hook này thì bar vẫn hiện sai, tức ĐÚNG
/// triệu chứng gốc, chỉ vào bằng cửa hẹp hơn: lô này sẽ chỉ "thu hẹp" chứ không "đóng" lớp lỗi.
///
/// Heal do MÔI TRƯỜNG kích, không ăn theo một lệnh không liên quan. Notification này post ở main
/// thread nên đọc `_visiblePending` ở đây là an toàn.
- (void)onAppDidBecomeActive
{
  if (!_visiblePending) return;
  // CHỈ chữa, KHÔNG dựng. `route:` không phải no-op: `ensureBar`/`ensureSystemBar` sẽ TẠO bar nếu
  // chưa có, và `useSystemBar` chốt nhánh sớm hơn mọi lệnh JS. Chưa có bar thì cũng chẳng có gì
  // sai trên màn để chữa — lệnh JS kế tiếp sẽ dựng với `hidden = !_visible` đúng ngay từ đầu.
  //
  // Gác này cũng thu hẹp một rủi ro thật: sau OTA reload, instance module CŨ có thể còn sống một
  // nhịp và vẫn nhận notification. Chưa từng sở hữu bar ⇒ nó im lặng thay vì dựng bar thứ hai.
  if (_bar == nil && _systemBar == nil) return;
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    // Bước tự chữa nằm trong `route:healVisibility:`; block này cố ý rỗng.
  }];
}

/// Dựng bar + gắn vào key window. Idempotent. PHẢI ở main thread.
/// Window chưa có (gọi quá sớm) ⇒ trả nil và KHÔNG dựng gì. Cố dựng vào window nil rồi "để đó"
/// là đường sinh bar mồ côi.
///
/// ⚠️ Bản trước ghi "lần gọi sau sẽ thử lại" và ĐÓ LÀ GIẢ ĐỊNH SAI đã gây bug: nó đúng cho các
/// lệnh mà phía gọi lặp lại theo mỗi lần render (geometry, tint), nhưng SAI cho `setVisible` —
/// lệnh đó EDGE-TRIGGERED, phía gọi chỉ gửi khi trạng thái đổi, nên không có "lần gọi sau" nào.
/// Bù lại nằm ở `route:healVisibility:` (cờ `_visiblePending`), KHÔNG ở đây: đặt bước tự chữa
/// trong hàm này thì nó chạy cả trong CHÍNH lời gọi `setVisible` và snap mất `animated:YES`.
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
  // HỎI kết quả attach, không đoán theo tiền đề. `attachToWindow:` bail khi window chưa có
  // `rootViewController`, và khi đó `_tbc`/`_host` KHÔNG được dựng nên MỌI setter của
  // `LTBSystemBar` no-op CÂM (`setItems`, `syncSelection`, `setTintActive`, `setVisible`…). Trả
  // non-nil ở tình huống đó là nói dối `route:`: nó sẽ không gọi `LTBWarnDrop`, sẽ reset cờ
  // log-once, và sẽ hạ `_visiblePending` — ba lời khẳng định sai cùng lúc.
  //
  // Ca thật bị bịt: cold launch có key window mà root VC chưa gán ⇒ `setTabs` mất items không một
  // dòng log ⇒ khi root VC xuất hiện thì `attachToWindow` dựng `_tbc` với 0 viewController và
  // `_host.hidden = NO` ⇒ một thanh bar RỖNG hiện trên màn.
  if (![_systemBar attachToWindow:window]) return nil;
  return _systemBar;
}

/// Điều phối duy nhất: đưa ĐÚNG MỘT trong hai nhánh, nhánh kia là nil. Mọi lệnh của spec
/// đi qua đây để không có lệnh nào lỡ chỉ hiện thực một nhánh — đó là kiểu lỗi im lặng
/// (một nền tảng mất tính năng mà không ai báo).
- (void)route:(void (^)(LTBSystemBar *_Nullable sys, LTBBarView *_Nullable bar))block
{
  [self route:block healVisibility:YES];
}

/// `healVisibility = NO` CHỈ dành cho chính lệnh `setVisible:animated:`.
///
/// Vì sao phải có tham số này thay vì tự chữa trong `ensureBar`/`ensureSystemBar`: bước tự chữa
/// gán thẳng `hidden`/`alpha` (không animation). Đặt nó trong `ensure*` thì nó chạy cả trong CHÍNH
/// lời gọi `setVisible:animated:YES` — snap tới trạng thái đích TRƯỚC khi block kịp chạy
/// `animateWithDuration:` ⇒ `animated:YES` mất tác dụng hoàn toàn. Mà `animated` mặc định của API
/// JS là `true`, nên đó sẽ là regression cho mọi consumer khác.
- (void)route:(void (^)(LTBSystemBar *_Nullable sys, LTBBarView *_Nullable bar))block
    healVisibility:(BOOL)heal
{
  dispatch_block_t work = ^{
    if ([self useSystemBar]) {
      LTBSystemBar *sys = [self ensureSystemBar];
      if (sys == nil) {
        LTBWarnDrop();
        return;
      }
      LTBWarnDropReset();
      // TỰ CHỮA: một lệnh `setVisible` trước đó đã bị bỏ (window chưa phân giải được) ⇒ áp lại
      // trạng thái mong muốn NGAY, nhân dịp lệnh này đã có window. Không có bước này thì
      // `_visible` và `hidden` của view lệch VĨNH VIỄN, vì caller không gửi lại setVisible.
      if (heal && self->_visiblePending) {
        [sys setVisible:self->_visible animated:NO];
        self->_visiblePending = NO;
      }
      block(sys, nil);
      return;
    }
    LTBBarView *bar = [self ensureBar];
    if (bar == nil) {
      LTBWarnDrop();
      return;
    }
    LTBWarnDropReset();
    if (heal && self->_visiblePending) {
      bar.hidden = !self->_visible;
      bar.alpha = self->_visible ? 1.0 : 0.0;
      self->_visiblePending = NO;
    }
    block(nil, bar);
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
  // Ghi state trên MAIN thread, KHÔNG trên thread gọi (TurboModule chạy ở JS thread).
  //
  // Mọi nơi ĐỌC `_visible`/`_visiblePending` đều ở main: `ensureBar`, `ensureSystemBar`, bước tự
  // chữa trong `route:healVisibility:`, và completion block của animation. Ghi ở thread khác là
  // data race, và có một interleaving làm MẤT LUÔN bước chữa: main đọc `_visiblePending == YES`
  // nhưng `_visible` còn giá trị CŨ (hai store là plain, không barrier) ⇒ heal áp trạng thái lạc
  // hậu rồi hạ cờ ⇒ lệnh mới rơi ⇒ không còn đường chữa nào. Đúng bug gốc, vào qua chính cơ chế
  // chữa. `dispatch_async` ở đây cũng giữ ĐÚNG thứ tự với các lệnh khác đã vào main queue.
  dispatch_block_t apply = ^{
    self->_visible = visible;
    // Coi như CHƯA áp được, cho tới khi block dưới thật sự chạy. Lệnh bị bỏ vì chưa phân giải được
    // window ⇒ cờ ở lại `YES` ⇒ lệnh kế tiếp bất kỳ (hoặc lúc app active) sẽ tự chữa.
    self->_visiblePending = YES;
    [self doSetVisible:visible animated:animated];
  };
  if (NSThread.isMainThread) {
    apply();
  } else {
    dispatch_async(dispatch_get_main_queue(), apply);
  }
}

/// Thân thật của `setVisible:animated:`, LUÔN chạy ở main thread (xem lý do ở hàm trên).
- (void)doSetVisible:(BOOL)visible animated:(BOOL)animated
{
  [self route:^(LTBSystemBar *sys, LTBBarView *bar) {
    // Hạ cờ NGAY đầu block — trước mọi `return` sớm bên dưới — vì tới được đây nghĩa là lệnh đã
    // có view để áp lên.
    self->_visiblePending = NO;
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
  } healVisibility:NO];
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
