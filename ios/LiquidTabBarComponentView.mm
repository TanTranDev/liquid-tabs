#import "LiquidTabBarComponentView.h"
#import "LTBItemView.h"

#import <React/RCTConversions.h>
#import <react/renderer/components/liquidtabs/ComponentDescriptors.h>
#import <react/renderer/components/liquidtabs/EventEmitters.h>
#import <react/renderer/components/liquidtabs/Props.h>
#import <react/renderer/components/liquidtabs/RCTComponentViewHelpers.h>

using namespace facebook::react;

// Cấu trúc view (theo đúng hợp đồng UIGlassContainerEffect trong UIKit header:
// "the glass container will render all glass elements in one combined view,
//  BEHIND the visual effect view's contentView"):
//
//   self
//   └── _container   UIVisualEffectView(UIGlassContainerEffect)   ← merge ở đây
//       └── contentView
//           ├── _platter  UIVisualEffectView(UIGlassEffect)   ← nền bar
//           ├── _lens     UIVisualEffectView(UIGlassEffect, interactive)
//           └── _itemsHost UIView  ← icon/nhãn/badge, vẽ TRÊN kính
//
// Vì cả _platter và _lens là glass element trong CÙNG container, khi lens trượt
// lại gần platter chúng MERGE theo `spacing` — đó chính là hiệu ứng liquid, và
// nó là public API, không phải _UILiquidLensView.
static const CGFloat kLensInsetY = 6.0;
static const CGFloat kLensCornerRadius = 18.0;
static const NSTimeInterval kLensAnimDuration = 0.32;
static const CGFloat kLensSpringDamping = 0.86;

@implementation LiquidTabBarComponentView {
  UIVisualEffectView *_container;
  UIVisualEffectView *_platter;
  UIVisualEffectView *_lens;
  UIView *_itemsHost;
  NSMutableArray<LTBItemView *> *_items;
  NSString *_activeKey;
  CGFloat _cornerRadius;
  /// Giá trị đã áp cho container effect. Chỉ dựng effect MỚI khi nó đổi thật:
  /// gán `.effect` mới lên một effect view đang hiển thị là đúng nguyên nhân
  /// làm wrapper @sbaiahmed1 vỡ render khi đổi theme (hồ sơ 02/07). Ở đây tint
  /// nằm trên item view chứ không trên kính, nên đường này gần như không bao giờ
  /// chạy lại sau lần đầu.
  CGFloat _appliedMergeSpacing;
  BOOL _appliedClearStyle;
  BOOL _glassBuilt;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<LiquidTabBarComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const LiquidTabBarProps>();
    _props = defaultProps;

    _items = [NSMutableArray new];
    _activeKey = @"";
    _cornerRadius = 32.0;
    _appliedMergeSpacing = -1.0;
    _appliedClearStyle = NO;
    _glassBuilt = NO;

    // Cắt theo bounds: bug 02/07 là glass phủ TOÀN MÀN HÌNH vì wrapper cố ý
    // masksToBounds = NO. Đánh đổi đã biết: nếu animation merge phình ra ngoài
    // frame thì bị cắt — đổi cờ này là một dòng, [device-verify] rồi quyết.
    self.clipsToBounds = YES;

    _itemsHost = [UIView new];
    [self addSubview:_itemsHost];
  }
  return self;
}

#pragma mark - Dựng kính (chỉ 1 lần, iOS 26+)

- (void)buildGlassIfNeededWithSpacing:(CGFloat)spacing clearStyle:(BOOL)clearStyle
{
  if (@available(iOS 26.0, *)) {
    if (_glassBuilt && spacing == _appliedMergeSpacing && clearStyle == _appliedClearStyle) {
      return;
    }

    const UIGlassEffectStyle style = clearStyle ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular;

    if (!_glassBuilt) {
      UIGlassContainerEffect *containerEffect = [UIGlassContainerEffect new];
      containerEffect.spacing = spacing;
      _container = [[UIVisualEffectView alloc] initWithEffect:containerEffect];
      [self insertSubview:_container belowSubview:_itemsHost];

      _platter = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:style]];
      _platter.layer.cornerCurve = kCACornerCurveContinuous;
      _platter.clipsToBounds = YES;
      [_container.contentView addSubview:_platter];

      UIGlassEffect *lensEffect = [UIGlassEffect effectWithStyle:style];
      lensEffect.interactive = YES;
      _lens = [[UIVisualEffectView alloc] initWithEffect:lensEffect];
      _lens.layer.cornerCurve = kCACornerCurveContinuous;
      _lens.layer.cornerRadius = kLensCornerRadius;
      _lens.clipsToBounds = YES;
      _lens.hidden = YES;
      [_container.contentView addSubview:_lens];

      // itemsHost phải ở TRÊN container để icon không bị kính đè.
      [_container.contentView addSubview:_itemsHost];

      _glassBuilt = YES;
    } else {
      // Chỉ tới đây khi prop đổi thật (hiếm). Dựng lại effect có kiểm soát.
      UIGlassContainerEffect *containerEffect = [UIGlassContainerEffect new];
      containerEffect.spacing = spacing;
      _container.effect = containerEffect;
      _platter.effect = [UIGlassEffect effectWithStyle:style];
      UIGlassEffect *lensEffect = [UIGlassEffect effectWithStyle:style];
      lensEffect.interactive = YES;
      _lens.effect = lensEffect;
    }

    _appliedMergeSpacing = spacing;
    _appliedClearStyle = clearStyle;
    [self setNeedsLayout];
  }
  // iOS < 26: KHÔNG dựng gì. Wrapper JS đã chặn (isLiquidTabBarAvailable), nên
  // tới được đây là phía gọi bỏ qua gate — thà bar trống còn hơn crash.
}

#pragma mark - Props

- (void)updateProps:(const Props::Shared &)props oldProps:(const Props::Shared &)oldProps
{
  const auto &newProps = *std::static_pointer_cast<const LiquidTabBarProps>(props);

  const BOOL clearStyle = newProps.glassStyle == "clear";
  [self buildGlassIfNeededWithSpacing:(CGFloat)newProps.mergeSpacing clearStyle:clearStyle];

  // cornerRadius chỉ được GÁN vào layer trong layoutSubviews, mà prop đổi một
  // mình không sinh layout pass ⇒ phải tự yêu cầu. Thiếu dòng này thì prop công
  // khai `cornerRadius` âm thầm không có tác dụng cho tới lần relayout kế tiếp.
  const CGFloat newRadius = (CGFloat)newProps.cornerRadius;
  if (newRadius != _cornerRadius) {
    _cornerRadius = newRadius;
    [self setNeedsLayout];
  }

  UIColor *tint = RCTUIColorFromSharedColor(newProps.tintColor) ?: UIColor.labelColor;
  UIColor *inactive = RCTUIColorFromSharedColor(newProps.inactiveTintColor) ?: UIColor.secondaryLabelColor;

  NSString *previousActive = _activeKey;
  _activeKey = RCTNSStringFromString(newProps.activeKey);

  [self syncItemCount:newProps.items.size()];

  NSUInteger i = 0;
  for (const auto &item : newProps.items) {
    LTBItemView *view = _items[i++];
    view.itemKey = RCTNSStringFromString(item.key);
    [view configureWithLabel:RCTNSStringFromString(item.label)
                    sfSymbol:RCTNSStringFromString(item.sfSymbol)
            sfSymbolSelected:RCTNSStringFromString(item.sfSymbolSelected)
                    imageURL:RCTNSStringFromString(item.imageUrl)
                       badge:RCTNSStringFromString(item.badge)
                    selected:[view.itemKey isEqualToString:_activeKey]
                   tintColor:tint
           inactiveTintColor:inactive];
  }

  const BOOL activeChanged = ![previousActive isEqualToString:_activeKey];
  [self layoutLensAnimated:activeChanged && previousActive.length > 0];

  [super updateProps:props oldProps:oldProps];
}

/// Thêm/bớt ô cho khớp số item. Tái dùng view cũ — dựng lại cả dãy mỗi lần props
/// đổi sẽ làm ảnh avatar nháy lại từ đầu.
- (void)syncItemCount:(NSUInteger)count
{
  while (_items.count > count) {
    [_items.lastObject removeFromSuperview];
    [_items removeLastObject];
  }
  while (_items.count < count) {
    LTBItemView *view = [LTBItemView new];
    [view addTarget:self action:@selector(onItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_itemsHost addSubview:view];
    [_items addObject:view];
  }
}

- (void)onItemTapped:(LTBItemView *)sender
{
  if (!_eventEmitter) return;
  auto emitter = std::static_pointer_cast<const LiquidTabBarEventEmitter>(_eventEmitter);
  LiquidTabBarEventEmitter::OnSelect payload;
  payload.key = sender.itemKey != nil ? std::string(sender.itemKey.UTF8String) : std::string();
  emitter->onSelect(payload);
}

#pragma mark - Layout

- (void)layoutSubviews
{
  [super layoutSubviews];

  const CGRect b = self.bounds;
  _container.frame = b;
  _platter.frame = b;
  _platter.layer.cornerRadius = _cornerRadius;
  _itemsHost.frame = b;

  const NSUInteger n = _items.count;
  if (n == 0) return;

  const CGFloat itemW = b.size.width / (CGFloat)n;
  for (NSUInteger i = 0; i < n; i++) {
    _items[i].frame = CGRectMake(floor(itemW * i), 0, ceil(itemW), b.size.height);
  }

  [self layoutLensAnimated:NO];
}

- (void)layoutLensAnimated:(BOOL)animated
{
  if (_lens == nil) return;

  const NSInteger index = [self activeIndex];
  if (index < 0 || _items.count == 0 || CGRectIsEmpty(self.bounds)) {
    _lens.hidden = YES;
    return;
  }

  const CGRect target = CGRectInset(_items[(NSUInteger)index].frame, 4.0, kLensInsetY);
  _lens.hidden = NO;

  if (!animated) {
    _lens.frame = target;
    return;
  }

  [UIView animateWithDuration:kLensAnimDuration
                        delay:0
       usingSpringWithDamping:kLensSpringDamping
        initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
                     self->_lens.frame = target;
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

#pragma mark - Recycle

- (void)prepareForRecycle
{
  // Fabric tái dùng view. Không dọn thì ô/ảnh của bar TRƯỚC còn nằm lại.
  for (LTBItemView *view in _items) {
    [view removeFromSuperview];
  }
  [_items removeAllObjects];
  _activeKey = @"";
  _lens.hidden = YES;
  [super prepareForRecycle];
}

@end

Class<RCTComponentViewProtocol> LiquidTabBarCls(void)
{
  return LiquidTabBarComponentView.class;
}
