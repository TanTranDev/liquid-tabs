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

/// Màu MẶC ĐỊNH của vùng chọn. Giá trị lấy nguyên từ `tokens.color.brand.soft` của
/// mini-app (accent-soft) — chính pill mà bản TabBar JS đang vẽ và đã được duyệt bằng
/// mắt. Phía gọi nên ghi đè qua `setLensColor:` để theme sống ở JS; hằng này chỉ để
/// thư viện dùng được ngay khi chưa ai truyền gì.
///
/// ⚠️ Vùng chọn KHÔNG dùng UIGlassEffect, dù bar đang ở chế độ kính. Hai lý do đo
/// được: (1) alpha của accent-soft là 0.10 — một khối kính tint ở alpha đó gần như vô
/// hình, và kính-trên-kính thì không có tương phản; (2) lens nằm TRỌN trong platter
/// nên khoảng cách hai khối kính là 0, mà `UIGlassContainerEffect.spacing` là "khoảng
/// cách mà các phần tử BẮT ĐẦU hợp nhất" ⇒ UIKit hợp nhất lens VÀO platter, tức lens
/// tan vào nền. Đó là hiện tượng user báo 29/07: "lướt được rồi nhưng không có vùng
/// chọn". Pill phẳng có tint là đúng thứ bản JS vẽ, và là đúng thứ cần khớp.
static UIColor *LTBDefaultLensFill(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:82 / 255.0 green:156 / 255.0 blue:202 / 255.0 alpha:0.16]
        : [UIColor colorWithRed:35 / 255.0 green:131 / 255.0 blue:226 / 255.0 alpha:0.10];
  }];
}

@implementation LTBBarView {
  // Nhánh kính
  UIVisualEffectView *_container;
  UIVisualEffectView *_platter;
  // Nhánh fallback
  UIView *_fallbackBg;

  /// Vùng chọn — MỘT view cho CẢ HAI chế độ nền, luôn là UIView tint phẳng (xem
  /// `LTBDefaultLensFill` về lý do không dùng kính ở đây). Trước đây có hai lens
  /// riêng cho hai nhánh; gộp lại vì toàn bộ logic vuốt/morph không quan tâm nền là
  /// gì, và hai đường song song chỉ tạo chỗ cho một nhánh câm.
  UIView *_lens;

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

    // KHÔNG cắt. Hiệu ứng Liquid Glass của lens PHẢI tràn ra ngoài mép bar mới thấy
    // được: đo trên bản tham chiếu (App Store iOS 26 + clip user gửi 29/07), khối kính
    // chọn phình cao hơn cả platter và mang viền tán sắc cầu vồng — phần tràn đó CHÍNH
    // LÀ phần nhìn thấy. Bản trước đặt YES nên cắt sạch, và triệu chứng là "lướt được
    // nhưng không có vùng chọn, không có morph".
    //
    // Vì sao an toàn (khác bug 02/07 "glass phủ toàn màn hình"): ca đó là một WRAPPER
    // mang chính UIGlassEffect và có frame cỡ màn hình. Ở đây `self` là UIView TRƠN,
    // không mang effect nào; mọi view mang kính (`_container`, `_platter`, `_lens`) đều
    // có frame bám bounds của bar hoặc nhỏ hơn. Không có đường nào để kính lan ra màn.
    self.clipsToBounds = NO;

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

    // Vùng chọn = KHỐI KÍNH THẬT, để UIKit tự lo morph. Đây là điểm cốt lõi: hiệu
    // ứng "bóng nước" khi lướt là do UIGlassEffect + UIGlassContainerEffect sinh ra,
    // KHÔNG phải do ta vẽ. Bằng chứng nó là kính native: mép khối mang tán sắc cầu
    // vồng — không view tự vẽ nào tạo được (xem App Store iOS 26, tab "Games").
    UIGlassEffect *lensEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    // `interactive` = khối kính phản ứng theo chạm (nhún/phình). Chính nó tạo cảm
    // giác chất lỏng khi ngón kéo.
    lensEffect.interactive = YES;
    UIVisualEffectView *glassLens = [[UIVisualEffectView alloc] initWithEffect:lensEffect];
    glassLens.layer.cornerCurve = kCACornerCurveContinuous;
    // KHÔNG clip: phần phình của morph nằm NGOÀI bounds của lens.
    glassLens.clipsToBounds = NO;
    glassLens.userInteractionEnabled = NO;  // không được ăn tap của item nằm trên
    glassLens.hidden = YES;
    _lens = glassLens;
    // Lens nằm TRÊN platter, DƯỚI itemsHost (itemsHost được add sau, ở init).
    [_container.contentView addSubview:_lens];
    // Container cũng không được cắt, nếu không nó chặn đúng phần tràn vừa mở ở `self`.
    _container.clipsToBounds = NO;
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

  // Nhánh KHÔNG kính (iOS < 26): chỉ cần VÙNG CHỌN, không cần hiệu ứng (USER chốt
  // 29/07). Pill tint phẳng, trượt sang ô mới — không morph, không giãn. Cố mô phỏng
  // "bóng nước" bằng UIView ở đây là làm giả một thứ mà nền tảng không có.
  UIView *plainLens = [UIView new];
  plainLens.backgroundColor = LTBDefaultLensFill();
  plainLens.layer.cornerCurve = kCACornerCurveContinuous;
  plainLens.userInteractionEnabled = NO;
  plainLens.hidden = YES;
  _lens = plainLens;
  // Con của SELF, không của `_fallbackBg` — thằng đó clip theo bounds.
  [self addSubview:_lens];
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

/// Màu vùng chọn. Theme sống ở JS nên phía gọi truyền xuống; nil ⇒ giữ màu hiện tại
/// (KHÔNG tô trong suốt — mất vùng chọn mà không có lỗi ở đâu là đúng lớp lỗi im lặng
/// vừa mất một buổi để truy).
- (void)setLensColor:(UIColor *)color
{
  if (color == nil) return;
  if (!_useGlass) {
    _lens.backgroundColor = color;
    return;
  }
  if (@available(iOS 26.0, *)) {
    // Nhánh kính: màu đi vào `tintColor` của effect, KHÔNG vào backgroundColor —
    // backgroundColor sẽ đè lên vật liệu kính và giết luôn tán sắc ở mép.
    // Dựng effect mới ở đây là có kiểm soát: chỉ khi màu đổi thật, tức gần như không
    // bao giờ sau lần đầu. (Gán `.effect` MỖI LẦN đổi tint là đúng lỗi đã giết wrapper
    // thứ ba hồi 02/07 — đừng gọi hàm này trong vòng render.)
    UIGlassEffect *e = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    e.interactive = YES;
    e.tintColor = color;
    ((UIVisualEffectView *)_lens).effect = e;
  }
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
      [self layoutLensFollowingX:x];
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
  return _lens;
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

/// Lens ĐI THEO NGÓN. Chỉ đổi VỊ TRÍ, giữ nguyên kích thước.
///
/// Cố ý KHÔNG tự giãn/bẹp: trên iOS 26 hiệu ứng chất lỏng do UIGlassEffect sinh ra,
/// tự vẽ thêm là hai animation đánh nhau — và bản tự vẽ không bao giờ có tán sắc ở mép
/// nên nó lộ ra là đồ giả. Trên nhánh không kính thì USER chốt KHÔNG cần hiệu ứng, chỉ
/// cần vùng chọn. Cả hai đường đều dẫn tới: chỉ dời chỗ.
///
/// Không bọc trong khối animation: mỗi frame một vị trí — đó chính là cảm giác dính ngón.
- (void)layoutLensFollowingX:(CGFloat)x
{
  UIView *lens = [self activeLens];
  if (lens == nil || _dragIndex < 0) return;

  const CGRect rest = [self lensRestRectForIndex:_dragIndex];
  // Tâm dính ngón, kẹp để lens không trượt khỏi hai đầu bar.
  const CGFloat minCX = kLensInsetX + rest.size.width / 2.0;
  const CGFloat maxCX = self.bounds.size.width - kLensInsetX - rest.size.width / 2.0;
  const CGFloat cx = MAX(minCX, MIN(maxCX, x));

  lens.hidden = NO;
  lens.frame = CGRectMake(cx - rest.size.width / 2.0, rest.origin.y, rest.size.width,
                          rest.size.height);
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
