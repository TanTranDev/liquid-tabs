// Phân phối dạng SOURCE (main/types = src/index.ts, không build ra lib/): cài từ
// git thì pnpm ≥10 chặn build script nên `prepare` không chạy được ⇒ lib/ sẽ vắng
// và `types` trỏ vào chỗ trống. Metro/rspack transpile TS trực tiếp nên không mất
// gì; đổi lại Node thuần `require()` package này thì không chạy — chấp nhận, đây
// là thư viện React Native.

// ── Kiến trúc ĐANG DÙNG: bar do HOST sở hữu, sống ngoài vòng đời RN của mini-app.
// Đây là đường nên dùng — bar không bị dựng lại khi mini-app nạp/reload bằng
// bundle OTA (chính pha mà UIKit bỏ glass material).
export {
  LiquidTabsHost,
  isGlassAvailable,
  isBarAvailable,
} from './LiquidTabsHost';
export type { HostTabItem, HostGeometry } from './LiquidTabsHost';

// ── Kiến trúc CŨ (Fabric component trong cây RN của mini-app). Giữ lại vì nó là
// đường lùi đã device-verify được phần biên dịch, và vì việc bỏ nó là một lô
// riêng. KHÔNG dùng cho code mới: bar sẽ bị dựng lại mỗi lần mini-app reload.
export { LiquidTabBar, isLiquidTabBarAvailable, parseIOSMajor, MIN_IOS } from './LiquidTabBar';
export { toNativeItems, encodeBadge, BADGE_DOT, DEFAULT_BADGE_CAP } from './toNativeItems';
export type { TabItem, LiquidTabBarProps } from './types';
export type { NativeTabItem } from './specs/LiquidTabBarNativeComponent';
