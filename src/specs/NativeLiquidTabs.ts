// TurboModule spec — tab bar do HOST sở hữu, KHÔNG phải component trong cây RN.
//
// Vì sao đổi khỏi Fabric component (kiến trúc trước): bar nằm trong cây RN của
// mini-app thì nó bị dựng lại mỗi lần mini-app nạp/reload — và mini-app nạp bằng
// bundle OTA chính là pha mà UIKit BỎ glass material (ma trận 6 pha,
// docs/2026-07-ios26-tabbar-liquid-glass/01). Bar do host tạo một lần lúc boot
// (binary embedded) không nằm trong pha nào cả, và sống qua mọi lần OTA của
// mini-app. Đây là lý do kiến trúc, không phải sở thích.
//
// ⚠️ HỢP ĐỒNG HAI CHIỀU — phần host PHẢI làm, mini-app không làm thay được:
//   1. Host tự ẩn bar khi RN world tear down (mini-app crash / reload / đóng).
//      Không có bước này, bar treo lại trên màn trống.
//   2. Host đặt bar trên key window, TRÊN view của mini-app, và giữ nó ngoài
//      vòng đời của RN instance.
//
// ⚠️ Phía mini-app: `setVisible(false)` khi rời màn có tab (Chat / Login / modal
// full). Neo vào cleanup của effect để React vẫn là nơi quyết định — quên một
// chỗ là bar lơ lửng trên màn khác.
import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type { EventEmitter } from 'react-native/Libraries/Types/CodegenTypes';

export type TabItemNative = {
  key: string;
  label: string;
  sfSymbol: string;
  sfSymbolSelected: string;
  imageUrl: string;
  badge: string;
};

export type TabSelectedEvent = { key: string };

export interface Spec extends TurboModule {
  /**
   * Bar kính có dựng được THẬT không. Native probe `UIGlassEffect` bằng
   * `NSClassFromString` + thử tạo effect — KHÔNG so số version.
   *
   * Lý do: `Platform.Version` trả `systemVersion` nên beta không để lại dấu vết
   * nào ("26.0" y như bản chính thức), và version ≥ 26 KHÔNG bảo đảm có API —
   * chính header UIKit ghi `API_UNAVAILABLE(visionos, watchos)`. Gate theo "API
   * có thật không" đúng ở mọi beta/seed/nền tảng lạ; gate theo số thì không.
   */
  isGlassAvailable(): boolean;

  /** Có bar (kính HOẶC nền vẽ tay) dùng được không. iOS → true; nền tảng khác →
   *  false, phía gọi tự dùng bar riêng. Tách khỏi `isGlassAvailable` để phía gọi
   *  phân biệt "không có bar" với "có bar nhưng không phải kính". */
  isAvailable(): boolean;

  /** Thay toàn bộ danh sách tab. Idempotent. */
  setTabs(items: Array<TabItemNative>): void;

  /** Tab đang chọn. Khoá không khớp item nào ⇒ native không vẽ lens. */
  setActive(key: string): void;

  /** Ẩn/hiện. `animated` chỉ ảnh hưởng hiệu ứng, không ảnh hưởng trạng thái. */
  setVisible(visible: boolean, animated: boolean): void;

  /** Geometry — phía gọi giữ nguồn số (mini-app có `tabBarMetrics.ts`
   *  device-verified). Đơn vị point. */
  setGeometry(
    height: number,
    horizontalInset: number,
    bottomInset: number,
    cornerRadius: number,
  ): void;

  /** Màu icon/nhãn/lens. Chuỗi hex `#RRGGBB` hoặc `#RRGGBBAA`. Truyền tường minh
   *  chứ không để native lấy màu hệ — nếu app ép theme thì màu hệ sẽ lệch. */
  setTint(activeHex: string, inactiveHex: string): void;

  /** `spacing` của UIGlassContainerEffect — khoảng cách lens và nền bắt đầu
   *  MERGE (hiệu ứng liquid). 0 ⇒ không merge. */
  setMergeSpacing(spacing: number): void;

  readonly onTabSelected: EventEmitter<TabSelectedEvent>;
}

// getEnforcing sẽ THROW nếu host chưa build native — đó là hành vi muốn có, và
// `optionalLiquidTabs` phía mini-app bắt trong try/catch rồi degrade có tiếng.
export default TurboModuleRegistry.getEnforcing<Spec>('LiquidTabs');
