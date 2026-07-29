// TurboModule: cửa duy nhất để JS điều khiển bar do HOST sở hữu.
//
// Bar được gắn thẳng vào key window bằng Auto Layout (không phải vào cây view của
// RN) — đó là điểm cốt tử: mini-app reload/OTA thì RN root view bị thay, còn bar
// vẫn nguyên. Ràng buộc theo safeAreaLayoutGuide nên xoay máy / đổi safe area do
// UIKit lo, không cần JS tính lại.
#import <Foundation/Foundation.h>

#ifdef __cplusplus
#import <liquidtabs/liquidtabs.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface LiquidTabsModule : NativeLiquidTabsSpecBase <NativeLiquidTabsSpec>
@end

NS_ASSUME_NONNULL_END
