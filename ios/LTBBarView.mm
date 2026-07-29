#import "LTBBarView.h"
#import "LTBItemView.h"

static const CGFloat kLensInsetX = 4.0;
static const CGFloat kLensInsetY = 6.0;
static const NSTimeInterval kLensAnimDuration = 0.32;
static const CGFloat kLensSpringDamping = 0.86;

// ── Vuốt-để-chọn (yêu cầu USER 29/07). Lens đi theo ngón LIÊN TỤC; tab chỉ đổi
// khi NHẢ tay (USER chốt: tránh mount/unmount 4 screen liên tiếp khi kéo một lượt).
//
// Phần "bóng nước" ở đây là do TA tự vẽ, KHÔNG dựa vào merge của UIKit: lens giãn
// theo trục X tỉ lệ với tốc độ ngón rồi đàn về. Lý do không dựa vào merge: lens nằm
// TRỌN trong platter nên khoảng cách giữa hai khối kính là 0, mà `spacing` của
// UIGlassContainerEffect là "khoảng cách mà các phần tử BẮT ĐẦU hợp nhất" — rất có
// thể UIKit đang hợp nhất lens vào platter, tức lens tan vào nền. Chưa phân định
// được trên máy; `setMergeSpacing` là núm xoay để thử (0 = không hợp nhất).
static const CGFloat kLensStretchMax = 26.0;
/// Đổi tốc độ ngón (pt/s) thành lượng giãn. 1200 pt/s ⇒ chạm trần.
static const CGFloat kLensStretchPerVelocity = kLensStretchMax / 1200.0;
/// Giãn ngang thì bẹp dọc — giữ cảm giác BẢO TOÀN THỂ TÍCH của khối nước.
static const CGFloat kLensSquashRatio = 0.18;
/// Ngưỡng coi là "kéo" thay vì "chạm", để tap không bị hiểu thành vuốt 1px.
static const CGFloat kDragSlop = 6.0;
/// Nếu phía JS không xác nhận lựa chọn trong khoảng này, trả highlight về sự thật.
/// Bar sống NGOÀI cây React nên không có ai tự sửa nó — thiếu lưới này thì một lần
/// app từ chối đổi tab là bar kẹt sai vĩnh viễn.
static const NSTimeInterval kPendingRevertDelay = 0.6;

// Nền VẼ TAY khi không có UIGlassEffect. Giá trị lấy nguyên từ `GlassSurface` của
// mini-app (đã device-verify 18/07, căn theo platter App Store iOS 26): tint đục
// ~92% + hairline định biên. Dùng dynamic color để tự đổi theo Dark Mode — đây là
// cách đúng ở tầng native, không cần ai bơm theme xuống.
static UIColor *LTBFallbackFill(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:44 / 255.0 green:44 / 255.0 blue:46 / 255.0 alpha:0.94]
        : [UIColor colorWithRed:252 / 255.0 green:252 / 255.0 blue:252 / 255.0 alpha:0.92];
  }];
}

static UIColor *LTBFallbackEdge(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    // Dark: hairline SÁNG-trên-tối mới tách được bar khỏi nền đen (0.06 quá mờ).
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithWhite:1.0 alpha:0.14]
        : [UIColor colorWithWhite:0.0 alpha:0.06];
  }];
}

/// Lens của nhánh fallback: một lớp sáng/tối nhẹ, KHÔNG viền — viền thẳng đọc
/// thành artifact (luật B4 của hồ sơ: cấm strip giả specular).
static UIColor *LTBFallbackLensFill(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithWhite:1.0 alpha:0.10]
        : [UIColor colorWithWhite:0.0 alpha:0.05];
  }];
}

@implementation LTBBarView {
  // Nhánh kính
  UIVisualEffectView *_container;
  UIVisualEffectView *_platter;
  UIVisualEffectView *_glassLens;
  // Nhánh fallback
  UIView *_fallbackBg;
  UIView *_fallbackLens;

  UIView *_itemsHost;
  NSMutableArray<LTBItemView *> *_items;
  NSArray<NSDictionary<NSString *, NSString *> *> *_itemProps;
  NSString *_activeKey;
  UIColor *_tintActive;
  UIColor *_tintInactive;
  CGFloat _cornerRadius;
  CGFloat _mergeSpacing;
  BOOL _useGlass;

  // ── Vuốt-để-chọn
  UIPanGestureRecognizer *_pan;
  /// Tab mà bar đang hiển thị nhưng JS CHƯA xác nhận (lạc quan). Rỗng = không có.
  /// Tồn tại để bỏ nháy: chờ một vòng bridge mới đổi highlight thì lens giật về ô
  /// cũ rồi mới sang ô mới — thấy rõ bằng mắt.
  NSString *_pendingKey;
  /// Index dưới ngón trong lúc kéo; -1 = không kéo.
  NSInteger _dragIndex;
}

+ (BOOL)isGlassAvailable
{
  // Ba lớp, cố ý dư: (1) compile-time có SDK; (2) runtime OS đủ mới; (3) class
  // CÓ THẬT và tạo được instance. Lớp (3) là lớp duy nhất đúng trên beta/seed
  // hoặc nền tảng mà UIKit không ship API này.
#if defined(__IPHONE_26_0)
  if (@available(iOS 26.0, *)) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    Class container = NSClassFromString(@"UIGlassContainerEffect");
    if (glass == nil || container == nil) return NO;
    // Thử dựng thật: class tồn tại mà khởi tạo thất bại thì vẫn coi là không có.
    UIVisualEffect *probe = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    return probe != nil;
  }
#endif
  return NO;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    _items = [NSMutableArray new];
    _itemProps = @[];
    _activeKey = @"";
    _cornerRadius = 32.0;
    _mergeSpacing = 12.0;
    _tintActive = UIColor.labelColor;
    _tintInactive = UIColor.secondaryLabelColor;
    _useGlass = [LTBBarView isGlassAvailable];

    // Cắt theo bounds: bug 02/07 là glass phủ TOÀN MÀN HÌNH vì wrapper thứ ba cố
    // ý masksToBounds = NO. Đánh đổi đã biết: animation merge phình ra ngoài frame
    // sẽ bị cắt — [device-verify] rồi quyết, đổi cờ này là một dòng.
    self.clipsToBounds = YES;

    _itemsHost = [UIView new];
    _pendingKey = @"";
    _dragIndex = -1;

    // Pan trên CHÍNH bar, không trên từng item: kéo là hành vi của cả thanh. Sống
    // chung được với tap của LTBItemView (UIControl) vì pan chỉ nhận diện sau khi
    // ngón đi quá ngưỡng — lúc đó UIKit tự huỷ tracking của UIControl, đúng khuôn
    // button-trong-scrollview. Nhờ vậy KHÔNG phải tắt userInteractionEnabled của
    // item, tức không mất tap + accessibility của UIControl.
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    _pan.cancelsTouchesInView = NO;
    [self addGestureRecognizer:_pan];

    if (_useGlass) {
      [self buildGlass];
    } else {
      [self buildFallback];
    }

    [self addSubview:_itemsHost];
    // itemsHost phải là subview CUỐI của container để icon nằm TRÊN nền.
    if (_container != nil) {
      [_container.contentView addSubview:_itemsHost];
    }
  }
  return self;
}

- (void)buildGlass
{
  if (@available(iOS 26.0, *)) {
    UIGlassContainerEffect *containerEffect = [UIGlassContainerEffect new];
    containerEffect.spacing = _mergeSpacing;
    _container = [[UIVisualEffectView alloc] initWithEffect:containerEffect];
    [self addSubview:_container];

    _platter = [[UIVisualEffectView alloc]
        initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
    _platter.layer.cornerCurve = kCACornerCurveContinuous;
    _platter.clipsToBounds = YES;
    [_container.contentView addSubview:_platter];

    UIGlassEffect *lensEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    lensEffect.interactive = YES;
    _glassLens = [[UIVisualEffectView alloc] initWithEffect:lensEffect];
    _glassLens.layer.cornerCurve = kCACornerCurveContinuous;
    // Bo góc = NỬA CHIỀU CAO (đặt trong layoutSubviews) ⇒ capsule. Trước đây cố định
    // 18 nên dù có hiệu ứng vẫn đọc thành "ô vuông bo", không ra hình giọt nước.
    // KHÔNG clip: phần phình của hiệu ứng merge nằm NGOÀI bounds của lens, cắt là
    // mất sạch. `self.clipsToBounds` vẫn giữ YES — đó là lưới chống bug 02/07
    // (kính phủ toàn màn hình), và nó chặn ở mép bar chứ không chặn ở mép lens.
    _glassLens.clipsToBounds = NO;
    _glassLens.hidden = YES;
    [_container.contentView addSubview:_glassLens];
  }
}

- (void)buildFallback
{
  _fallbackBg = [UIView new];
  _fallbackBg.backgroundColor = LTBFallbackFill();
  _fallbackBg.layer.cornerCurve = kCACornerCurveContinuous;
  _fallbackBg.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
  _fallbackBg.layer.borderColor = LTBFallbackEdge().CGColor;
  _fallbackBg.clipsToBounds = YES;
  [self addSubview:_fallbackBg];

  _fallbackLens = [UIView new];
  _fallbackLens.backgroundColor = LTBFallbackLensFill();
  _fallbackLens.layer.cornerCurve = kCACornerCurveContinuous;
  // Radius do `applyCapsuleRadiusTo:` đặt theo chiều cao thật (capsule), giống nhánh
  // kính — hằng cố định 18 đã bỏ. Nhánh này cũng vuốt được: mọi logic vuốt nằm ở
  // LTBBarView, `activeLens` chỉ chọn xem đang lái khối nào.
  _fallbackLens.hidden = YES;
  [_fallbackBg addSubview:_fallbackLens];
}

// borderColor là CGColor nên KHÔNG tự đổi theo trait — phải gán lại. Thiếu bước
// này thì đổi Dark/Light lúc đang chạy sẽ để lại hairline của mode cũ.
- (void)traitCollectionDidChange:(UITraitCollection *)previous
{
  [super traitCollectionDidChange:previous];
  if (_fallbackBg != nil &&
      self.traitCollection.userInterfaceStyle != previous.userInterfaceStyle) {
    _fallbackBg.layer.borderColor = LTBFallbackEdge().CGColor;
  }
}

#pragma mark - Setters

- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items
{
  _itemProps = items ?: @[];
  [self syncItemCount:_itemProps.count];
  [self reconfigureItems];
  [self setNeedsLayout];
}

- (void)setActiveKey:(NSString *)key
{
  NSString *next = key ?: @"";
  const BOOL had = _activeKey.length > 0;
  const BOOL changed = ![next isEqualToString:_activeKey];
  // JS đã lên tiếng ⇒ sự thật về lại tay nó, dù giá trị có đổi hay không. Huỷ luôn
  // watchdog: nó chỉ tồn tại cho trường hợp JS IM LẶNG.
  const BOOL wasPending = _pendingKey.length > 0;
  _pendingKey = @"";
  [self cancelPendingRevert];
  _activeKey = next;
  if (!changed && !wasPending) return;
  [self reconfigureItems];
  // Đang kéo thì KHÔNG giật lens về: ngón vẫn đang giữ nó. `setActive` có thể tới
  // giữa lúc kéo (JS đổi tab vì lý do khác) — lúc đó vị trí ngón mới là sự thật thị giác.
  if (_dragIndex < 0) [self layoutLensAnimated:had];
}

/// Tab mà bar ĐANG VẼ. Khác `_activeKey` khi đang chờ JS xác nhận (tap/nhả vuốt).
- (NSString *)visualActiveKey
{
  return _pendingKey.length > 0 ? _pendingKey : _activeKey;
}

/// Hiện `key` ngay (lạc quan) rồi hẹn giờ trả về sự thật nếu JS không xác nhận.
- (void)showPendingKey:(NSString *)key
{
  if (key.length == 0) return;
  _pendingKey = key;
  [self reconfigureItems];
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
  [self reconfigureItems];
  if (_dragIndex < 0) [self layoutLensAnimated:YES];
}

- (void)dealloc
{
  // `performSelector:afterDelay:` giữ target — không huỷ là view chết vẫn bị gọi.
  [self cancelPendingRevert];
}

- (void)setTintActive:(UIColor *)active inactive:(UIColor *)inactive
{
  if (active != nil) _tintActive = active;
  if (inactive != nil) _tintInactive = inactive;
  [self reconfigureItems];
}

- (void)setMergeSpacing:(CGFloat)spacing
{
  if (spacing == _mergeSpacing) return;
  _mergeSpacing = spacing;
  if (@available(iOS 26.0, *)) {
    if (_container != nil) {
      // Dựng effect MỚI ở đây là có kiểm soát: chỉ khi giá trị đổi thật (gần như
      // không bao giờ sau lần đầu). Gán `.effect` mỗi lần đổi tint là đúng lỗi đã
      // giết wrapper thứ ba — tint ở đây nằm trên item view, không trên kính.
      UIGlassContainerEffect *e = [UIGlassContainerEffect new];
      e.spacing = spacing;
      _container.effect = e;
    }
  }
}

- (void)setBarCornerRadius:(CGFloat)radius
{
  if (radius == _cornerRadius) return;
  _cornerRadius = radius;
  [self setNeedsLayout];
}

- (void)syncItemCount:(NSUInteger)count
{
  while (_items.count > count) {
    [_items.lastObject removeFromSuperview];
    [_items removeLastObject];
  }
  while (_items.count < count) {
    LTBItemView *v = [LTBItemView new];
    [v addTarget:self action:@selector(onItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_itemsHost addSubview:v];
    [_items addObject:v];
  }
}

- (void)reconfigureItems
{
  NSString *visual = [self visualActiveKey];
  NSUInteger i = 0;
  for (NSDictionary<NSString *, NSString *> *p in _itemProps) {
    if (i >= _items.count) break;
    LTBItemView *v = _items[i++];
    NSString *key = p[@"key"] ?: @"";
    v.itemKey = key;
    [v configureWithLabel:p[@"label"] ?: @""
                 sfSymbol:p[@"sfSymbol"] ?: @""
         sfSymbolSelected:p[@"sfSymbolSelected"] ?: @""
                 imageURL:p[@"imageUrl"] ?: @""
                    badge:p[@"badge"] ?: @""
                 selected:[key isEqualToString:visual]
                tintColor:_tintActive
        inactiveTintColor:_tintInactive];
  }
}

- (void)onItemTapped:(LTBItemView *)sender
{
  if (sender.itemKey == nil) return;
  // Hiện ngay rồi mới báo JS: chờ vòng bridge thì lens trễ một nhịp so với ngón.
  [self showPendingKey:sender.itemKey];
  [self layoutLensAnimated:YES];
  if (self.onSelect != nil) self.onSelect(sender.itemKey);
}

#pragma mark - Vuốt để chọn

/// Index của item tại toạ độ x. Kẹp vào [0, n-1] để kéo ra ngoài mép không mất bám.
- (NSInteger)indexAtX:(CGFloat)x
{
  const NSUInteger n = _items.count;
  if (n == 0 || self.bounds.size.width <= 0) return -1;
  const CGFloat itemW = self.bounds.size.width / (CGFloat)n;
  const NSInteger raw = (NSInteger)floor(x / itemW);
  return MAX(0, MIN((NSInteger)n - 1, raw));
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
  const NSUInteger n = _items.count;
  if (n == 0) return;
  const CGFloat x = [g locationInView:self].x;
  const NSInteger idx = [self indexAtX:x];
  if (idx < 0) return;

  switch (g.state) {
    case UIGestureRecognizerStateBegan:
    case UIGestureRecognizerStateChanged: {
      // Ngưỡng slop: pan của UIKit đã có ngưỡng riêng, nhưng nó tính theo mọi
      // hướng. Ở đây chỉ quan tâm trục X — kéo dọc (vd vuốt lên để đóng app) không
      // được kéo lens đi ngang.
      if (_dragIndex < 0 && fabs([g translationInView:self].x) < kDragSlop) return;
      _dragIndex = idx;
      NSString *key = _items[(NSUInteger)idx].itemKey ?: @"";
      // Highlight đi theo ngón NGAY, nhưng KHÔNG báo JS (USER chốt: đổi màn khi nhả).
      // Dùng pending thay vì _activeKey để không tự ý ghi sự thật.
      if (![key isEqualToString:[self visualActiveKey]]) {
        _pendingKey = key;
        [self reconfigureItems];
      }
      [self layoutLensFollowingX:x velocityX:[g velocityInView:self].x];
      break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: {
      if (_dragIndex < 0) return;  // chưa vượt slop ⇒ đây là tap, để UIControl lo
      NSString *key = _items[(NSUInteger)_dragIndex].itemKey ?: @"";
      _dragIndex = -1;
      // Huỷ/thất bại cũng CHỐT theo ô cuối dưới ngón: người dùng đã thấy highlight ở
      // đó, trả về ô cũ sẽ đọc thành "app ăn mất cú vuốt".
      [self showPendingKey:key];
      [self layoutLensAnimated:YES];
      if (self.onSelect != nil && key.length > 0) self.onSelect(key);
      break;
    }
    default:
      break;
  }
}

#pragma mark - Layout

- (void)layoutSubviews
{
  [super layoutSubviews];
  const CGRect b = self.bounds;

  _container.frame = b;
  _platter.frame = b;
  _platter.layer.cornerRadius = _cornerRadius;
  _fallbackBg.frame = b;
  _fallbackBg.layer.cornerRadius = _cornerRadius;
  _itemsHost.frame = b;

  const NSUInteger n = _items.count;
  if (n == 0) return;
  const CGFloat itemW = b.size.width / (CGFloat)n;
  for (NSUInteger i = 0; i < n; i++) {
    _items[i].frame = CGRectMake(floor(itemW * i), 0, ceil(itemW), b.size.height);
  }
  [self layoutLensAnimated:NO];
}

- (UIView *_Nullable)activeLens
{
  return _useGlass ? _glassLens : _fallbackLens;
}

/// Hình nghỉ của lens tại một item.
- (CGRect)lensRestRectForIndex:(NSInteger)idx
{
  return CGRectInset(_items[(NSUInteger)idx].frame, kLensInsetX, kLensInsetY);
}

/// Capsule: bo góc luôn bằng nửa chiều cao HIỆN TẠI. Phải gán mỗi lần đổi frame vì
/// lúc kéo lens bị bẹp dọc — giữ radius cũ sẽ ra hình viên thuốc méo.
- (void)applyCapsuleRadiusTo:(UIView *)lens
{
  lens.layer.cornerRadius = lens.bounds.size.height / 2.0;
}

/// Lens ĐI THEO NGÓN. Không animate: mỗi frame một vị trí, đó chính là cảm giác
/// "dính ngón". Phần "nước" nằm ở giãn ngang theo tốc độ + bẹp dọc bù lại.
- (void)layoutLensFollowingX:(CGFloat)x velocityX:(CGFloat)vx
{
  UIView *lens = [self activeLens];
  if (lens == nil || _dragIndex < 0) return;

  const CGRect rest = [self lensRestRectForIndex:_dragIndex];
  const CGFloat stretch = MIN(kLensStretchMax, fabs(vx) * kLensStretchPerVelocity);
  const CGFloat squash = stretch * kLensSquashRatio;
  const CGFloat w = rest.size.width + stretch;
  const CGFloat h = MAX(1.0, rest.size.height - squash);

  // Tâm dính ngón, nhưng kẹp để lens không tràn khỏi platter.
  const CGFloat minCX = kLensInsetX + w / 2.0;
  const CGFloat maxCX = self.bounds.size.width - kLensInsetX - w / 2.0;
  const CGFloat cx = MAX(minCX, MIN(maxCX, x));

  lens.hidden = NO;
  lens.frame = CGRectMake(cx - w / 2.0, rest.origin.y + squash / 2.0, w, h);
  [self applyCapsuleRadiusTo:lens];
}

- (void)layoutLensAnimated:(BOOL)animated
{
  UIView *lens = [self activeLens];
  if (lens == nil) return;
  // Đang kéo thì ngón là chủ — mọi nguồn khác (setItems, layoutSubviews, setActive)
  // không được giành quyền đặt frame, nếu không lens sẽ giật về ô nghỉ giữa cú vuốt.
  if (_dragIndex >= 0) return;

  const NSInteger idx = [self activeIndex];
  if (idx < 0 || _items.count == 0 || CGRectIsEmpty(self.bounds)) {
    lens.hidden = YES;
    return;
  }
  const CGRect target = [self lensRestRectForIndex:idx];
  lens.hidden = NO;

  if (!animated) {
    lens.frame = target;
    [self applyCapsuleRadiusTo:lens];
    return;
  }
  [UIView animateWithDuration:kLensAnimDuration
                        delay:0
       usingSpringWithDamping:kLensSpringDamping
        initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
                     lens.frame = target;
                     // Trong khối animation ⇒ cornerRadius nội suy cùng frame; gán
                     // ngoài khối thì hình bẹp của lúc kéo nhảy về capsule tức thì.
                     [self applyCapsuleRadiusTo:lens];
                   }
                   completion:nil];
}

/// Theo tab ĐANG VẼ, không theo `_activeKey`: lúc chờ JS xác nhận thì lens phải nằm
/// ở ô người dùng vừa chọn, nếu không nó giật về ô cũ rồi mới sang — thấy rõ.
- (NSInteger)activeIndex
{
  NSString *visual = [self visualActiveKey];
  for (NSUInteger i = 0; i < _items.count; i++) {
    if ([_items[i].itemKey isEqualToString:visual]) return (NSInteger)i;
  }
  return -1;
}

@end
