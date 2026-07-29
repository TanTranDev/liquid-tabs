#import "LTBSystemBar.h"

/// Sentinel badge dạng chấm — trùng `BADGE_DOT` ở tầng JS (`toNativeItems.ts`). Giá trị
/// là MỘT dấu cách; đổi ở một bên là mất chấm im lặng, nên bên JS có test ghim giá trị.
static NSString *const kBadgeDotSentinel = @" ";

/// Trễ watchdog trả `_pendingKey` về sự thật của JS khi JS IM LẶNG (mini-app từ chối đổi
/// tab, hoặc không ai nghe `onSelect`).
///
/// Giá trị này nhân bản ở BA nhánh và không có cách kiểm bằng máy (3 ngôn ngữ, 2 nền tảng)
/// — guard duy nhất là ba comment trỏ chéo nhau, nên đổi một chỗ thì đổi cả ba:
/// `LTBBarView.mm::kPendingRevertDelay` (iOS vẽ tay) · `LTBBarView.kt::PENDING_REVERT_MS`
/// (Android, 600L). Lệch nhau thì cùng một cú tap cho hai hành vi khác nhau tuỳ máy — loại
/// lệch rất khó truy vì mỗi máy chỉ chạy một nhánh.
///
/// "0,6 s" là xấp xỉ: `performSelector:afterDelay:` chỉ schedule ở `NSDefaultRunLoopMode`,
/// nên trong lúc user đang scroll (`UITrackingRunLoopMode`) nó bị hoãn. Chấp nhận được vì
/// đây là lưới sửa-sai, không phải cam kết thời gian — nhưng đừng đọc con số này thành SLA.
static const NSTimeInterval kPendingRevertDelay = 0.6;

#pragma mark - Passthrough

/// Chứa `UITabBarController` nhưng CHỈ nhận touch trong vùng thanh bar.
///
/// Bắt buộc phải có: view của controller phủ toàn màn hình, không chặn thì nó ăn hết touch
/// của nội dung RN phía dưới và app thành không bấm được gì ngoài tab bar.
@interface LTBPassthroughView : UIView
@property (nonatomic, weak, nullable) UITabBar *interactiveBar;
@end

@implementation LTBPassthroughView

- (UIView *_Nullable)hitTest:(CGPoint)point withEvent:(UIEvent *_Nullable)event
{
  UITabBar *bar = self.interactiveBar;
  if (bar == nil || self.hidden || self.alpha < 0.01) return nil;
  // Hỏi CHÍNH thanh bar xem điểm có thuộc nó không, thay vì so với `bar.frame`: iOS 26 vẽ
  // bar dạng pill nổi, có inset riêng, và nó tự biết vùng nhận touch của mình.
  const CGPoint p = [self convertPoint:point toView:bar];
  if (![bar pointInside:p withEvent:event]) return nil;
  return [super hitTest:point withEvent:event];
}

@end

#pragma mark - Child VC

/// Child VC rỗng, TRONG SUỐT. `UITabBarController` đòi có child cho mỗi tab, nhưng nội
/// dung thật do RN vẽ ở lớp dưới — nên mỗi tab ở đây chỉ là một chỗ trống để controller
/// có cái mà chuyển.
@interface LTBEmptyViewController : UIViewController
@end

@implementation LTBEmptyViewController

- (void)loadView
{
  UIView *v = [UIView new];
  v.backgroundColor = UIColor.clearColor;
  // Không nhận touch: nội dung nằm dưới, mọi touch ngoài bar phải xuyên qua.
  v.userInteractionEnabled = NO;
  self.view = v;
}

@end

#pragma mark - LTBSystemBar

@interface LTBSystemBar () <UITabBarControllerDelegate>
@end

@implementation LTBSystemBar {
  UITabBarController *_tbc;
  LTBPassthroughView *_host;
  NSArray<NSString *> *_keys;
  NSArray<NSDictionary<NSString *, NSString *> *> *_itemProps;
  NSString *_activeKey;
  /// Tab UIKit ĐANG hiển thị sau một cú tap, trong lúc chờ JS xác nhận. Khác `_activeKey`
  /// đúng bằng độ dài của vòng bridge. Không có nó thì `setItems:` (badge/avatar đổi) chạy
  /// `syncSelection` với `_activeKey` CŨ và kéo bar về tab trước — đúng bug "bấm tab, nháy
  /// về tab cũ rồi mới sang". Hai nhánh còn lại (`LTBBarView.mm`, `LTBBarView.kt`) đã có
  /// cơ chế này từ đầu; nó bị bỏ sót khi chuyển sang `UITabBarController`.
  NSString *_pendingKey;
  /// Bật trong lúc TA gán `selectedIndex`. Lưới cho khả năng UIKit gọi
  /// `didSelectViewController:` cả khi selection do code đặt: nếu điều đó xảy ra mà không
  /// chặn, mỗi lần sync sẽ bắn thêm một `onSelect` về JS ⇒ JS đổi state ⇒ sync tiếp ⇒ bar
  /// dao động qua lại. Legacy `viewControllers` được cho là chỉ gọi delegate khi USER tap,
  /// nhưng giá của việc điều đó đổi giữa các bản iOS là app nháy liên tục.
  BOOL _applyingSelection;
  /// Số `onSelect` đã bắn mà JS chưa trả lời. Lọc echo lạc hậu theo SỐ LƯỢNG thay vì theo giá
  /// trị key — xem lý do dài ở `setActiveKey:`. Có thể đếm dư khi re-tap (re-tap không sinh
  /// echo), nhưng `revertPendingKey` reset về 0 nên lệch luôn bị chặn trong một cửa sổ
  /// `kPendingRevertDelay`.
  NSUInteger _outstandingEchoes;
  UIColor *_tintActive;
  UIColor *_tintInactive;
  BOOL _visible;
  NSCache<NSString *, UIImage *> *_imageCache;
  NSMutableSet<NSString *> *_inFlight;
}

+ (BOOL)isSupported
{
#if defined(__IPHONE_26_0)
  if (@available(iOS 26.0, *)) {
    // Cùng phép probe với nhánh vẽ tay: class có thật VÀ dựng được instance. `@available`
    // một mình không đủ trên beta/seed (xem `LTBBarView.isGlassAvailable`).
    Class glass = NSClassFromString(@"UIGlassEffect");
    if (glass == nil) return NO;
    return [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular] != nil;
  }
#endif
  return NO;
}

- (instancetype)init
{
  if (self = [super init]) {
    _keys = @[];
    _itemProps = @[];
    _activeKey = @"";
    _pendingKey = @"";
    _visible = NO;
    _imageCache = [NSCache new];
    _imageCache.countLimit = 8;
    _inFlight = [NSMutableSet new];
  }
  return self;
}

#pragma mark Attach

- (void)attachToWindow:(UIWindow *)window
{
  UIViewController *root = window.rootViewController;
  if (root == nil) return;  // chưa có root ⇒ để lần gọi sau lo, không dựng nửa vời

  if (_tbc == nil) {
    _tbc = [UITabBarController new];
    _tbc.delegate = self;
    _tbc.view.backgroundColor = UIColor.clearColor;

    _host = [LTBPassthroughView new];
    _host.backgroundColor = UIColor.clearColor;
    _host.interactiveBar = _tbc.tabBar;
    _host.hidden = !_visible;
  }

  if (_host.superview != root.view) {
    [_host removeFromSuperview];
    [root.view addSubview:_host];
    _host.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_host.leadingAnchor constraintEqualToAnchor:root.view.leadingAnchor],
      [_host.trailingAnchor constraintEqualToAnchor:root.view.trailingAnchor],
      [_host.topAnchor constraintEqualToAnchor:root.view.topAnchor],
      [_host.bottomAnchor constraintEqualToAnchor:root.view.bottomAnchor],
    ]];

    // Child VC thật sự: thiếu bước này thì trait/safe-area/rotation của `_tbc` không được
    // truyền đúng, và tab bar hệ thống tính sai vị trí.
    [root addChildViewController:_tbc];
    _tbc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [_host addSubview:_tbc.view];
    [NSLayoutConstraint activateConstraints:@[
      [_tbc.view.leadingAnchor constraintEqualToAnchor:_host.leadingAnchor],
      [_tbc.view.trailingAnchor constraintEqualToAnchor:_host.trailingAnchor],
      [_tbc.view.topAnchor constraintEqualToAnchor:_host.topAnchor],
      [_tbc.view.bottomAnchor constraintEqualToAnchor:_host.bottomAnchor],
    ]];
    [_tbc didMoveToParentViewController:root];
  }

  // Luôn ở trên cùng: RN có thể thêm view (modal, overlay) sau khi bar đã gắn.
  [root.view bringSubviewToFront:_host];
}

#pragma mark Items

- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items
{
  _itemProps = items ?: @[];
  if (_tbc == nil) return;

  NSMutableArray<NSString *> *keys = [NSMutableArray new];
  NSMutableArray<UIViewController *> *vcs = [NSMutableArray new];

  NSUInteger i = 0;
  for (NSDictionary<NSString *, NSString *> *p in _itemProps) {
    NSString *key = p[@"key"] ?: @"";
    [keys addObject:key];

    // Tái dùng child VC cũ khi số lượng không đổi: dựng lại toàn bộ sẽ làm
    // `UITabBarController` chạy animation chuyển tab mỗi lần badge đổi.
    UIViewController *vc = i < _tbc.viewControllers.count ? _tbc.viewControllers[i]
                                                          : [LTBEmptyViewController new];
    UITabBarItem *item = vc.tabBarItem;
    item.title = p[@"label"].length > 0 ? p[@"label"] : nil;
    item.image = [self imageForProps:p index:i];
    // Badge: hệ thống tự vẽ, kể cả dạng chấm — sentinel một dấu cách cho ra đúng chấm nhỏ.
    NSString *badge = p[@"badge"] ?: @"";
    item.badgeValue = badge.length > 0 ? badge : nil;
    [vcs addObject:vc];
    i++;
  }

  _keys = keys;
  if (![_tbc.viewControllers isEqualToArray:vcs]) {
    // Bọc `_applyingSelection` y như chỗ gán `selectedIndex`: đây là lần ghi selection
    // programmatic THỨ HAI. Gán `viewControllers` mà VC đang chọn bị loại khỏi danh sách
    // thì UIKit tự đặt `selectedIndex = 0` — đúng loại "selection do code" mà cờ tồn tại
    // để không báo về JS. Che một chỗ mà hở chỗ kia là lưới nửa vời: nó gãy đúng theo kiểu
    // "trông vẫn đúng", ở vùng chỉ sửa được bằng rebuild native.
    _applyingSelection = YES;
    _tbc.viewControllers = vcs;
    _applyingSelection = NO;
  }
  [self syncSelection];
}

/// Ảnh cho một item: ưu tiên ảnh remote (tab You), không có thì SF Symbol.
- (UIImage *_Nullable)imageForProps:(NSDictionary<NSString *, NSString *> *)p
                              index:(NSUInteger)index
{
  NSString *url = p[@"imageUrl"] ?: @"";
  if (url.length > 0) {
    UIImage *cached = [_imageCache objectForKey:url];
    if (cached != nil) return cached;
    [self fetchImage:url];  // về sau sẽ setItems lại
    // Trong lúc chờ ảnh: dùng SF Symbol làm chỗ đứng để bar không nhảy layout.
  }
  NSString *symbol = p[@"sfSymbol"] ?: @"";
  if (symbol.length == 0) return nil;
  return [UIImage systemImageNamed:symbol];
}

/// Tải ảnh avatar rồi bo tròn. De-dup theo URL: `setItems:` bị gọi lại mỗi lần badge đổi,
/// không chặn thì mỗi lần là một request.
- (void)fetchImage:(NSString *)urlString
{
  if ([_inFlight containsObject:urlString]) return;
  NSURL *url = [NSURL URLWithString:urlString];
  if (url == nil) return;
  [_inFlight addObject:urlString];

  __weak __typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [NSURLSession.sharedSession
      dataTaskWithURL:url
    completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable r, NSError *_Nullable e) {
      UIImage *img = data != nil ? [UIImage imageWithData:data] : nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        __typeof(self) s = weakSelf;
        if (s == nil) return;
        [s->_inFlight removeObject:urlString];
        if (img == nil) return;
        UIImage *circular = [s circularImage:img side:28.0];
        if (circular == nil) return;
        [s->_imageCache setObject:circular forKey:urlString];
        // Vẽ lại item bằng props hiện tại — KHÔNG giữ index cũ: danh sách có thể đã đổi.
        [s setItems:s->_itemProps];
      });
    }];
  [task resume];
}

- (UIImage *_Nullable)circularImage:(UIImage *)src side:(CGFloat)side
{
  const CGSize size = CGSizeMake(side, side);
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
  UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    const CGRect rect = CGRectMake(0, 0, side, side);
    [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
    [src drawInRect:rect];
  }];
  // `alwaysOriginal`: ảnh avatar KHÔNG được tint theo màu tab, nếu không nó thành một
  // vệt màu đơn sắc.
  return [out imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark Selection

- (void)setActiveKey:(NSString *)key
{
  NSString *next = key ?: @"";
  // BẤT BIẾN: ghi `_activeKey` TRƯỚC guard bên dưới, không phải sở thích sắp xếp. Nếu chỉ ghi
  // sau khi đã nhận echo khớp thì ca "JS phủ quyết" gãy VĨNH VIỄN: echo phủ quyết bị guard bỏ
  // qua, `_activeKey` giữ giá trị trước cú tap, watchdog revert bar về một tab CỔ, và vì
  // `active` phía JS không đổi nữa nên không còn echo nào tới sửa.
  _activeKey = next;

  // ECHO LẠC HẬU. Mỗi cú tap gửi một `onSelect` rồi chờ JS trả lời; tap tiếp theo tạo cú
  // chờ MỚI trong khi câu trả lời của cú trước còn đang trên đường về. Tin câu trả lời cũ
  // là kéo bar về tab người ta đã bỏ:
  //
  //   tap item 1 → emit(Chats) · tap item 2 → emit(Messages)
  //   echo(Chats) về TRƯỚC  ⇒ bản cũ gán selectedIndex = 0 ⇒ bóng nước "về lại item 1"
  //   echo(Messages) về sau ⇒ lại sang item 2
  //
  // Mỗi nhịp cách nhau đúng MỘT vòng bridge — đó là cái "nhảy qua lại có delay" user báo
  // 29/07, và nó KHÁC đường `setItems:` mà `_pendingKey` đã cắt: ở đây kẻ ghi đè là chính
  // JS, không phải badge.
  //
  // Lọc bằng ĐẾM số echo đang bay, KHÔNG bằng so giá trị với pending. So giá trị hở đúng một
  // ca tất định: chuỗi 3 tap A → B → A thì echo(A) ĐẦU TIÊN tình cờ trùng pending=A nên được
  // nhận là "câu trả lời của cú tap mới nhất" ⇒ retire pending + huỷ watchdog ⇒ echo(B) và
  // echo(A) còn lại đi qua trần trụi ⇒ bar nhảy sang B rồi về A, đúng triệu chứng đang sửa.
  // Đếm thì bất kể giá trị: chỉ echo CUỐI CÙNG mới hạ số về 0 và mới được chốt.
  //
  // Vì sao đếm được mà tập `_emitted` thì không: re-tap cùng tab KHÔNG sinh echo (effect phía
  // JS chỉ chạy khi `active` đổi) ⇒ số đếm dư. Với tập key thì rác đó sống VĨNH VIỄN; với số
  // đếm thì `revertPendingKey` reset về 0 ⇒ lệch bị chặn cứng trong một cửa sổ
  // `kPendingRevertDelay`, và trong cửa sổ đó `_pendingKey == _activeKey` nên hiển thị vẫn đúng.
  if (_outstandingEchoes > 0) _outstandingEchoes--;

  // Cố ý KHÔNG gia hạn watchdog ở đường bỏ qua: timer đang chạy thuộc cú tap MỚI NHẤT, nên để
  // nguyên thì có bound cứng "≤ kPendingRevertDelay kể từ cú tap cuối". Gia hạn sẽ cho một
  // chuỗi echo lạc hậu đẩy hạn đi vô hạn ⇒ bar kẹt ở pending.
  if (_pendingKey.length > 0 &&
      (_outstandingEchoes > 0 || ![next isEqualToString:_pendingKey])) {
    return;
  }

  // JS đã trả lời ĐÚNG cú tap mới nhất (hoặc JS tự đổi tab khi không có cú tap nào đang
  // chờ) ⇒ sự thật về lại tay nó hoàn toàn. Watchdog chỉ tồn tại cho trường hợp JS IM LẶNG.
  _outstandingEchoes = 0;
  _pendingKey = @"";
  [self cancelPendingRevert];
  [self syncSelection];
}

/// Tab bar ĐANG hiển thị. Khác `_activeKey` khi đang chờ JS xác nhận một cú tap.
- (NSString *)visualActiveKey
{
  return _pendingKey.length > 0 ? _pendingKey : _activeKey;
}

- (void)syncSelection
{
  if (_tbc == nil || _keys.count == 0) return;
  // Theo tab ĐANG VẼ, không theo `_activeKey`: `setItems:` bị gọi mỗi lần badge/avatar đổi
  // và rất hay rơi vào đúng cửa sổ chờ echo (đổi tab làm unread đổi ⇒ cùng một commit
  // React gửi `setTabs` TRƯỚC `setActive` — đo được ở `tabOrder` probe của mini-app). Đọc
  // `_activeKey` ở đây là kéo bar về tab trước rồi mới sang tab mới ⇒ giật thấy rõ vì
  // capsule Liquid Glass có animation trượt.
  NSUInteger idx = [_keys indexOfObject:[self visualActiveKey]];
  // Pending trỏ một key KHÔNG còn trong danh sách (consumer đổi tập tab giữa lúc chờ echo)
  // ⇒ rơi về sự thật của JS thay vì bỏ cuộc. Không có dòng này thì bar đứng ở tab UIKit
  // vừa tự chọn (index 0) cho tới khi watchdog nổ — mini-app hiện tại có tập tab cố định
  // nên không tới được, nhưng thư viện phục vụ 2 host và mọi mini-app.
  if (idx == NSNotFound) idx = [_keys indexOfObject:_activeKey];
  if (idx == NSNotFound || idx >= _tbc.viewControllers.count) return;
  if (_tbc.selectedIndex == idx) return;
  _applyingSelection = YES;
  _tbc.selectedIndex = idx;
  _applyingSelection = NO;
}

/// Nhớ tab user vừa chọn (UIKit đã tự hiển thị nó) rồi hẹn giờ trả về sự thật của JS nếu
/// JS không xác nhận.
///
/// PRECONDITION: chỉ gọi từ nơi UIKit ĐÃ tự chuyển selection sang `key` — hiện tại là
/// `didSelectViewController:`. Vì thế ở đây KHÔNG gọi `syncSelection`: index đã đúng sẵn,
/// gán lại chỉ mời thêm một lượt delegate. Thêm call site khác (long-press, accessibility
/// action, swipe) thì call site đó PHẢI tự `syncSelection`, nếu không bar ghi nhận pending
/// mà không đổi hình. Tiền đề này thuộc call site, không phải tính chất của hàm.
- (void)showPendingKey:(NSString *)key
{
  if (key.length == 0) return;
  _pendingKey = key;
  [self cancelPendingRevert];
  [self performSelector:@selector(revertPendingKey)
             withObject:nil
             afterDelay:kPendingRevertDelay];
}

- (void)cancelPendingRevert
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(revertPendingKey)
                                             object:nil];
}

- (void)revertPendingKey
{
  if (_pendingKey.length == 0) return;
  _pendingKey = @"";
  // Reset bộ đếm ở ĐÂY là thứ chặn drift của nó: re-tap bắn `onSelect` mà JS không echo lại,
  // nên số đếm có thể dư. Nhờ dòng này, lệch chỉ sống trong một cửa sổ `kPendingRevertDelay`
  // chứ không tích vĩnh viễn — đó là lý do đếm SỐ an toàn hơn giữ TẬP key đã emit.
  _outstandingEchoes = 0;
  // Về đúng thứ JS đang giữ. JS im lặng nghĩa là nó KHÔNG nhận cú đổi tab này (mini-app
  // chặn, hoặc chưa ai đăng ký listener) ⇒ bar không được ở lại tab mà app không mở.
  [self syncSelection];
}

- (void)dealloc
{
  // `performSelector:afterDelay:` RETAIN target ⇒ không có đường gọi vào object đã chết:
  // còn perform treo thì `dealloc` chưa chạy được. Huỷ ở đây chỉ để bar không bị neo sống
  // thêm 600 ms sau khi chủ đã bỏ nó. Đừng đọc dòng này thành "dealloc đang bảo vệ khỏi
  // callback chết" — ai đổi sang `NSTimer` weak-target hay `dispatch_after` + `weak self`
  // sẽ mất chỗ dựa đó mà tưởng vẫn còn.
  [self cancelPendingRevert];
}

- (void)tabBarController:(UITabBarController *)tabBarController
 didSelectViewController:(UIViewController *)viewController
{
  // Selection do TA đặt thì không phải ý user ⇒ không báo JS (xem `_applyingSelection`).
  if (_applyingSelection) return;
  const NSUInteger idx = [tabBarController.viewControllers indexOfObject:viewController];
  if (idx == NSNotFound || idx >= _keys.count) return;
  NSString *key = _keys[idx];
  if (key.length == 0) return;
  // Ghi vào `_pendingKey`, KHÔNG vào `_activeKey`: sự thật vẫn thuộc JS (nó có quyền phủ
  // quyết bằng cách gửi key khác). Nhưng từ giây này bar ĐANG hiển thị `key`, nên mọi
  // `syncSelection` xen vào phải tôn trọng nó thay vì kéo về quá khứ.
  [self showPendingKey:key];
  // Re-tap chính tab đang chọn vẫn phải báo: mini-app dùng nó để đóng panel topics
  // (`isHomeTabReTap`). Nên KHÔNG chặn theo "key không đổi".
  //
  // Tăng bộ đếm NGAY TRƯỚC khi bắn, trong cùng nhánh: đếm ở chỗ khác (vd trong
  // `showPendingKey:`) sẽ lệch pha với số echo thật khi có đường nào chỉ hiện pending mà
  // không báo JS.
  if (self.onSelect != nil) {
    _outstandingEchoes++;
    self.onSelect(key);
  }
}

#pragma mark Appearance

- (void)setVisible:(BOOL)visible animated:(BOOL)animated
{
  _visible = visible;
  if (_host == nil) return;
  if (!animated) {
    _host.hidden = !visible;
    _host.alpha = visible ? 1.0 : 0.0;
    return;
  }
  if (visible) _host.hidden = NO;
  [UIView animateWithDuration:0.2
      animations:^{
        self->_host.alpha = visible ? 1.0 : 0.0;
      }
      completion:^(BOOL done) {
        if (!visible) self->_host.hidden = YES;
      }];
}

- (void)setTintActive:(UIColor *_Nullable)active inactive:(UIColor *_Nullable)inactive
{
  if (active != nil) _tintActive = active;
  if (inactive != nil) _tintInactive = inactive;
  if (_tbc == nil) return;
  // Đặt trực tiếp trên tabBar, KHÔNG qua `UITabBarAppearance`: đổi appearance trên iOS 26
  // là đường làm mất capsule chọn (nhiều báo cáo trên forum Apple), mà capsule chính là
  // thứ ta cần.
  if (_tintActive != nil) _tbc.tabBar.tintColor = _tintActive;
  if (_tintInactive != nil) _tbc.tabBar.unselectedItemTintColor = _tintInactive;
}

- (CGFloat)barHeight
{
  if (_tbc == nil) return 0.0;
  return _tbc.tabBar.bounds.size.height;
}

@end
