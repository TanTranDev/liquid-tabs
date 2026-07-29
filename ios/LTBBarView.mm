#import "LTBBarView.h"
#import "LTBItemView.h"

static const CGFloat kLensInsetX = 4.0;
static const CGFloat kLensInsetY = 6.0;
static const CGFloat kLensCornerRadius = 18.0;
static const NSTimeInterval kLensAnimDuration = 0.32;
static const CGFloat kLensSpringDamping = 0.86;

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
    _glassLens.layer.cornerRadius = kLensCornerRadius;
    _glassLens.clipsToBounds = YES;
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
  _fallbackLens.layer.cornerRadius = kLensCornerRadius;
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
  _activeKey = next;
  if (!changed) return;
  [self reconfigureItems];
  [self layoutLensAnimated:had];
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
                 selected:[key isEqualToString:_activeKey]
                tintColor:_tintActive
        inactiveTintColor:_tintInactive];
  }
}

- (void)onItemTapped:(LTBItemView *)sender
{
  if (self.onSelect != nil && sender.itemKey != nil) {
    self.onSelect(sender.itemKey);
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

- (void)layoutLensAnimated:(BOOL)animated
{
  UIView *lens = [self activeLens];
  if (lens == nil) return;

  const NSInteger idx = [self activeIndex];
  if (idx < 0 || _items.count == 0 || CGRectIsEmpty(self.bounds)) {
    lens.hidden = YES;
    return;
  }
  const CGRect target = CGRectInset(_items[(NSUInteger)idx].frame, kLensInsetX, kLensInsetY);
  lens.hidden = NO;

  if (!animated) {
    lens.frame = target;
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
                   }
                   completion:nil];
}

- (NSInteger)activeIndex
{
  for (NSUInteger i = 0; i < _items.count; i++) {
    if ([_items[i].itemKey isEqualToString:_activeKey]) return (NSInteger)i;
  }
  return -1;
}

@end
