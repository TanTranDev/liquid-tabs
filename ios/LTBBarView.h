// Thanh bar hoàn chỉnh, ĐỘC LẬP với React: host sở hữu và gắn vào window, nên
// view này không được biết gì về Fabric/RN. Hai chế độ nền:
//   · iOS 26+ có UIGlassEffect → kính thật (platter + lens trong cùng
//     UIGlassContainerEffect ⇒ UIKit tự merge = hiệu ứng liquid).
//   · Không có → nền VẼ TAY bằng UIView (tint đục + hairline), để mini-app không
//     bao giờ phải tự dựng UI bar (yêu cầu USER 29/07).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTBBarView : UIView

/// Kính có dựng được THẬT không — probe `UIGlassEffect` qua `NSClassFromString`
/// rồi thử tạo effect. KHÔNG so số version: `systemVersion` không phân biệt beta,
/// và version ≥ 26 vẫn có thể thiếu API (`API_UNAVAILABLE(visionos, watchos)`).
+ (BOOL)isGlassAvailable;

/// Bắn khi user chạm một tab. Truyền `key` nguyên văn do phía gọi đặt.
@property (nonatomic, copy, nullable) void (^onSelect)(NSString *key);

/// Mỗi phần tử: `key`/`label`/`sfSymbol`/`sfSymbolSelected`/`imageUrl`/`badge`
/// đều là NSString (rỗng = "không có"). Idempotent, tái dùng ô cũ.
- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items;
- (void)setActiveKey:(NSString *)key;
- (void)setTintActive:(UIColor *)active inactive:(UIColor *)inactive;

/// Màu vùng chọn (pill sau tab đang chọn). nil ⇒ giữ màu hiện tại.
- (void)setLensColor:(UIColor *)color;

- (void)setMergeSpacing:(CGFloat)spacing;

/// Bo góc nền. Chiều cao/inset do host đặt qua frame.
- (void)setBarCornerRadius:(CGFloat)radius;

@end

NS_ASSUME_NONNULL_END
