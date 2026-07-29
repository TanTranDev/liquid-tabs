// Một ô tab: icon (SF Symbol hoặc ảnh remote bo tròn) + nhãn + badge.
// Là UIControl để có tap + accessibility miễn phí; ComponentView chỉ addTarget.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTBItemView : UIControl

/// Khoá do JS đặt — ComponentView đọc lại khi phát event onSelect.
@property (nonatomic, copy) NSString *itemKey;

/// Cấu hình lại ô. Gọi mỗi lần props đổi; idempotent.
/// `badge`: rỗng = không badge, một khoảng trắng = chấm không số, còn lại = text.
- (void)configureWithLabel:(NSString *)label
                  sfSymbol:(NSString *)sfSymbol
          sfSymbolSelected:(NSString *)sfSymbolSelected
                  imageURL:(NSString *)imageURL
                     badge:(NSString *)badge
                  selected:(BOOL)selected
                 tintColor:(UIColor *)tintColor
         inactiveTintColor:(UIColor *)inactiveTintColor;

@end

NS_ASSUME_NONNULL_END
