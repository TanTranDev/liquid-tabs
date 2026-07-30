// Tab bar HỆ THỐNG — `UITabBarController` thật, host sở hữu.
//
// Vì sao không tự vẽ nữa (quyết định USER 29/07 sau khi tra tài liệu Apple + thực tế
// cộng đồng RN):
//   · Hiệu ứng Liquid Glass đầy đủ — capsule chọn, nở khi nhấn, vuốt-để-chọn, tán sắc ở
//     mép, minimize-on-scroll — là của `UITabBarController`/SwiftUI `TabView`. KHÔNG có
//     API công khai nào dựng lại được nó: `UIGlassEffect` chỉ cho vật liệu, phần tương
//     tác thì UIKit làm bằng máy móc riêng.
//   · `UITabBar` ĐỨNG MỘT MÌNH (không có controller) KHÔNG được cấp Liquid Glass — đây là
//     lý do mọi nỗ lực trước thất bại ngay từ tiền đề.
//   · Apple ghi rõ: "Prefer system views and controls", và "avoid overlapping glass
//     elements" — mà lens-đè-platter đúng là overlapping. Ta đã tự vẽ 5 vòng và mỗi vòng
//     lại lộ ra một quy tắc bị vi phạm.
//   · Thư viện RN duy nhất làm được việc này cũng chỉ BỌC LẠI tab bar hệ thống.
//
// Kiến trúc: controller được gắn vào window của HOST (không nằm trong cây RN của
// mini-app), nên nó không bị dựng lại khi mini-app nạp/reload bằng bundle OTA — chính pha
// mà UIKit bỏ glass material. Đây vẫn là lý do gốc của cả thư viện này.
//
// Nội dung: các child VC đều TRONG SUỐT. Nội dung thật do RN vẽ ở lớp dưới, nên bar chỉ
// là một lớp nổi; touch ngoài vùng bar được trả về cho RN (xem `LTBPassthroughView`).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTBSystemBar : NSObject

/// Bar hệ thống có cho Liquid Glass trên máy này không. Cùng phép probe với
/// `LTBBarView.isGlassAvailable` — dưới ngưỡng đó thì `UITabBarController` chỉ ra thanh
/// bar đặc kiểu cũ, KHÔNG phải cái ta muốn, nên nhánh vẽ tay vẫn tốt hơn.
+ (BOOL)isSupported;

/// Bắn khi user chọn một tab. `key` nguyên văn do phía gọi đặt.
@property (nonatomic, copy, nullable) void (^onSelect)(NSString *key);

/// Gắn vào window (idempotent). Trả `NO` khi KHÔNG gắn được (chưa có `rootViewController`) —
/// phía gọi PHẢI coi đó là "lệnh chưa áp được", vì khi chưa gắn thì mọi setter dưới đây no-op.
///
/// Vì sao trả `BOOL` chứ không để phía gọi tự đoán: bản trước `void`, nên `LiquidTabsModule` phải
/// SAO CHÉP tiền đề (`window.rootViewController == nil`) để biết lệnh có áp được không. Ba thứ treo
/// lên bản sao đó (ý nghĩa của `sys != nil`, reset cờ log-once, hạ `_visiblePending`) ⇒ thêm một
/// đường bail vào đây là cả ba nói dối cùng lúc, IM LẶNG. Trả kết quả thật thì không còn bản sao.
- (BOOL)attachToWindow:(UIWindow *)window;

/// Mỗi phần tử: `key`/`label`/`sfSymbol`/`sfSymbolSelected`/`imageUrl`/`badge`.
- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items;
- (void)setActiveKey:(NSString *)key;
- (void)setVisible:(BOOL)visible animated:(BOOL)animated;

/// Màu icon/nhãn. Hệ thống tự lo capsule chọn — KHÔNG có API công khai để đổi màu nó, và
/// cố ép sẽ mất luôn hiệu ứng (đúng bài học của 5 vòng tự vẽ).
- (void)setTintActive:(nullable UIColor *)active inactive:(nullable UIColor *)inactive;

/// Chiều cao thanh bar hệ thống đang chiếm (kể cả safe area), để phía JS chừa đúng inset.
/// 0 nếu chưa gắn.
- (CGFloat)barHeight;

@end

NS_ASSUME_NONNULL_END
