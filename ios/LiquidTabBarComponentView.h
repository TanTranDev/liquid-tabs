// Fabric ComponentView cho `LiquidTabBar`. Tên class PHẢI khớp
// codegenConfig.ios.componentProvider trong package.json — lệch tên thì RN
// không tìm được view và ném "component not found" lúc render, không phải lúc
// build.
#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LiquidTabBarComponentView : RCTViewComponentView
@end

NS_ASSUME_NONNULL_END
