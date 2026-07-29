#import "LTBItemView.h"

// Kích thước — hằng một chỗ, [device-verify] rồi chỉnh tại đây.
static const CGFloat kIconPointSize = 23.0;   // SF Symbol pointSize
static const CGFloat kAvatarDiameter = 30.0;  // ảnh remote (tab You)
static const CGFloat kLabelFontSize = 10.0;
static const CGFloat kIconLabelGap = 2.0;
static const CGFloat kBadgeMinDiameter = 16.0;
static const CGFloat kBadgeDotDiameter = 8.0;
static const CGFloat kBadgeFontSize = 11.0;

/// Sentinel "chấm không số" — PHẢI khớp BADGE_DOT ở toNativeItems.ts.
static NSString *const kBadgeDotSentinel = @" ";

/// Cache ảnh avatar theo URL, dùng chung mọi item. NSCache tự nhả khi máy thiếu
/// bộ nhớ. Cố ý KHÔNG đi qua RCTImageLoader: kéo image loader vào một Fabric
/// ComponentView đòi thêm phụ thuộc bridge, mà ở đây chỉ cần đúng một ảnh nhỏ.
/// Đánh đổi: không dùng chung cache với <Image> của RN.
static NSCache<NSString *, UIImage *> *LTBImageCache(void)
{
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    cache.countLimit = 16;
  });
  return cache;
}

@implementation LTBItemView {
  UIImageView *_iconView;
  UILabel *_labelView;
  UIView *_badgeView;
  UILabel *_badgeLabel;
  /// URL đang được yêu cầu — chặn ảnh của lượt CŨ ghi đè lượt mới (đổi avatar
  /// nhanh hai lần: response về không theo thứ tự gửi).
  NSString *_pendingImageURL;
  BOOL _hasRemoteImage;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _labelView = [UILabel new];
    _labelView.font = [UIFont systemFontOfSize:kLabelFontSize weight:UIFontWeightMedium];
    _labelView.textAlignment = NSTextAlignmentCenter;
    _labelView.userInteractionEnabled = NO;
    [self addSubview:_labelView];

    _badgeView = [UIView new];
    _badgeView.backgroundColor = UIColor.systemRedColor;
    _badgeView.userInteractionEnabled = NO;
    _badgeView.hidden = YES;
    [self addSubview:_badgeView];

    _badgeLabel = [UILabel new];
    _badgeLabel.font = [UIFont systemFontOfSize:kBadgeFontSize weight:UIFontWeightSemibold];
    _badgeLabel.textColor = UIColor.whiteColor;
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    [_badgeView addSubview:_badgeLabel];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
  }
  return self;
}

- (void)configureWithLabel:(NSString *)label
                  sfSymbol:(NSString *)sfSymbol
          sfSymbolSelected:(NSString *)sfSymbolSelected
                  imageURL:(NSString *)imageURL
                     badge:(NSString *)badge
                  selected:(BOOL)selected
                 tintColor:(UIColor *)tintColor
         inactiveTintColor:(UIColor *)inactiveTintColor
{
  UIColor *ink = selected ? tintColor : inactiveTintColor;

  // Nhãn rỗng ⇒ ẩn hẳn (tab avatar), không chỉ để chuỗi rỗng — layout phải
  // biết để icon được căn giữa cả ô thay vì lệch lên.
  _labelView.text = label;
  _labelView.hidden = label.length == 0;
  _labelView.textColor = ink;

  self.accessibilityLabel = label.length > 0 ? label : self.itemKey;
  self.accessibilityValue = selected ? @"selected" : nil;

  _hasRemoteImage = imageURL.length > 0;
  if (_hasRemoteImage) {
    // Ảnh giữ MÀU GỐC (không template) — avatar không được nhuộm theo tint.
    _iconView.tintColor = nil;
    [self loadRemoteImage:imageURL];
  } else {
    _pendingImageURL = nil;
    NSString *name = selected && sfSymbolSelected.length > 0 ? sfSymbolSelected : sfSymbol;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:kIconPointSize
                                                       weight:UIImageSymbolWeightRegular];
    UIImage *img = name.length > 0 ? [UIImage systemImageNamed:name withConfiguration:cfg] : nil;
    _iconView.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _iconView.tintColor = ink;
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.layer.cornerRadius = 0;
    _iconView.clipsToBounds = NO;
  }

  BOOL isDot = [badge isEqualToString:kBadgeDotSentinel];
  _badgeView.hidden = badge.length == 0;
  _badgeLabel.text = isDot ? @"" : badge;
  _badgeLabel.hidden = isDot;

  [self setNeedsLayout];
}

- (void)loadRemoteImage:(NSString *)urlString
{
  // De-dup lượt ĐANG BAY. `configureWith…` được gọi lại mỗi lần props xuống, và
  // props xuống mỗi lần phía JS render (unread count đổi, store đổi…) vì `items`
  // là literal mới mỗi render. Không có chốt này thì cold start mạng chậm bắn
  // vài GET trùng nhau cho cùng một URL cho tới khi cache lấp.
  if ([urlString isEqualToString:_pendingImageURL] && _iconView.image != nil) {
    return;
  }
  _pendingImageURL = urlString;

  UIImage *cached = [LTBImageCache() objectForKey:urlString];
  if (cached != nil) {
    [self applyRemoteImage:cached forURL:urlString];
    return;
  }

  NSURL *url = [NSURL URLWithString:urlString];
  if (url == nil) return;

  __weak __typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [NSURLSession.sharedSession
      dataTaskWithURL:url
    completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
      if (data == nil || error != nil) return;
      UIImage *image = [UIImage imageWithData:data];
      if (image == nil) return;
      [LTBImageCache() setObject:image forKey:urlString];
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf applyRemoteImage:image forURL:urlString];
      });
    }];
  [task resume];
}

- (void)applyRemoteImage:(UIImage *)image forURL:(NSString *)urlString
{
  // Lượt cũ về muộn ⇒ bỏ. Không có chốt này thì đổi avatar liên tiếp có thể
  // đứng lại ở ảnh của lần đổi TRƯỚC.
  if (![urlString isEqualToString:_pendingImageURL]) return;
  _iconView.image = image;
  _iconView.contentMode = UIViewContentModeScaleAspectFill;
  _iconView.layer.cornerRadius = kAvatarDiameter / 2.0;
  _iconView.clipsToBounds = YES;
  [self setNeedsLayout];
}

- (void)layoutSubviews
{
  [super layoutSubviews];

  const CGFloat w = self.bounds.size.width;
  const CGFloat h = self.bounds.size.height;
  const CGFloat iconSide = _hasRemoteImage ? kAvatarDiameter : kIconPointSize + 6.0;

  CGFloat labelH = 0;
  if (!_labelView.hidden) {
    labelH = ceil(_labelView.font.lineHeight);
  }

  const CGFloat blockH = iconSide + (labelH > 0 ? kIconLabelGap + labelH : 0);
  const CGFloat top = floor((h - blockH) / 2.0);

  _iconView.frame = CGRectMake(floor((w - iconSide) / 2.0), top, iconSide, iconSide);
  if (labelH > 0) {
    _labelView.frame = CGRectMake(0, top + iconSide + kIconLabelGap, w, labelH);
  }

  if (!_badgeView.hidden) {
    const BOOL isDot = _badgeLabel.hidden;
    CGFloat diameter = kBadgeDotDiameter;
    if (!isDot) {
      CGSize textSize = [_badgeLabel.text sizeWithAttributes:@{NSFontAttributeName : _badgeLabel.font}];
      diameter = MAX(kBadgeMinDiameter, ceil(textSize.width) + 8.0);
    }
    const CGFloat badgeH = isDot ? kBadgeDotDiameter : kBadgeMinDiameter;
    // Neo vào góc trên-phải của ICON, không phải của ô — ô rộng hơn icon nhiều
    // nên neo theo ô sẽ đẩy badge ra xa, trông như của tab bên cạnh.
    const CGFloat x = CGRectGetMaxX(_iconView.frame) - diameter * 0.35;
    const CGFloat y = CGRectGetMinY(_iconView.frame) - badgeH * 0.25;
    _badgeView.frame = CGRectMake(x, y, diameter, badgeH);
    _badgeView.layer.cornerRadius = badgeH / 2.0;
    _badgeLabel.frame = _badgeView.bounds;
  }
}

@end
