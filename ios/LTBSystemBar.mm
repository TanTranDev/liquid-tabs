#import "LTBSystemBar.h"

/// Sentinel badge dạng chấm — trùng `BADGE_DOT` ở tầng JS (`toNativeItems.ts`). Giá trị
/// là MỘT dấu cách; đổi ở một bên là mất chấm im lặng, nên bên JS có test ghim giá trị.
static NSString *const kBadgeDotSentinel = @" ";

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
    _tbc.viewControllers = vcs;
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
  _activeKey = key ?: @"";
  [self syncSelection];
}

- (void)syncSelection
{
  if (_tbc == nil || _keys.count == 0) return;
  const NSUInteger idx = [_keys indexOfObject:_activeKey];
  if (idx == NSNotFound || idx >= _tbc.viewControllers.count) return;
  if (_tbc.selectedIndex != idx) _tbc.selectedIndex = idx;
}

- (void)tabBarController:(UITabBarController *)tabBarController
 didSelectViewController:(UIViewController *)viewController
{
  const NSUInteger idx = [tabBarController.viewControllers indexOfObject:viewController];
  if (idx == NSNotFound || idx >= _keys.count) return;
  NSString *key = _keys[idx];
  // KHÔNG tự ghi `_activeKey`: sự thật thuộc JS. Nó sẽ gọi `setActiveKey:` về, và
  // `syncSelection` là no-op nếu index đã đúng ⇒ không có vòng lặp.
  if (self.onSelect != nil && key.length > 0) self.onSelect(key);
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
