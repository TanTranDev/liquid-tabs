// Lớp JS mỏng gọi TurboModule. Không có UI ở đây — bar là view native do host sở
// hữu, gắn vào key window, nằm NGOÀI cây RN của mini-app.
//
// ⚠️ Nghĩa vụ của phía gọi (không tự động được): gọi `setVisible(false)` khi rời
// màn có tab. Neo vào cleanup của effect để React vẫn là nơi quyết định:
//
//     React.useEffect(() => {
//       LiquidTabsHost.setVisible(true);
//       return () => LiquidTabsHost.setVisible(false);
//     }, []);
//
// Quên một chỗ là bar lơ lửng trên màn khác — đó là cái giá của việc bar sống
// ngoài cây React, đổi lấy việc nó không chết theo mỗi lần OTA.
import { Platform } from 'react-native';

import { toNativeItems } from './toNativeItems';
import type { TabItem } from './types';

export type HostTabItem = TabItem;

export type HostGeometry = {
  /** Chiều cao bar (point). */
  height: number;
  /** Lề ngang từ mép màn tới mép bar. */
  horizontalInset: number;
  /** Khoảng từ đáy bar tới đáy màn. */
  bottomInset: number;
  cornerRadius: number;
};

type Spec = typeof import('./specs/NativeLiquidTabs').default;

/**
 * Nạp TurboModule một lần. Vắng (host chưa build native / non-iOS) → null.
 * `getEnforcing` THROW nên phải bọc — và đây là đường THẬT ở mọi máy chưa rebuild.
 */
let cached: Spec | null | undefined;
const mod = (): Spec | null => {
  if (cached !== undefined) return cached;
  if (Platform.OS !== 'ios') {
    cached = null;
    return cached;
  }
  try {
    cached = require('./specs/NativeLiquidTabs').default as Spec;
  } catch {
    cached = null;
  }
  return cached;
};

/**
 * Kính có dựng được THẬT không — native probe `UIGlassEffect`, KHÔNG so số
 * version. `Platform.Version` trả `systemVersion` nên beta không để lại dấu vết
 * ("26.0" y như bản chính thức), và ≥ 26 vẫn có thể thiếu API (header UIKit ghi
 * `API_UNAVAILABLE(visionos, watchos)`).
 */
export const isGlassAvailable = (): boolean => {
  const m = mod();
  return m != null && m.isGlassAvailable();
};

/** Có bar dùng được không (kính HOẶC nền vẽ tay của thư viện). Phía gọi chỉ cần
 *  hàm này để quyết định có tự vẽ bar hay không. */
export const isBarAvailable = (): boolean => {
  const m = mod();
  return m != null && m.isAvailable();
};

export const LiquidTabsHost = {
  isGlassAvailable,
  isAvailable: isBarAvailable,

  /** Thay toàn bộ tab. Chuẩn hoá qua `toNativeItems` nên phía gọi dùng API dễ
   *  (badge số, dot, field optional) — cùng một luật với kiến trúc Fabric. */
  setTabs(items: ReadonlyArray<HostTabItem>, badgeCap?: number): void {
    mod()?.setTabs([...toNativeItems(items, badgeCap)]);
  },

  setActive(key: string): void {
    mod()?.setActive(key);
  },

  setVisible(visible: boolean, animated = true): void {
    mod()?.setVisible(visible, animated);
  },

  setGeometry(g: HostGeometry): void {
    mod()?.setGeometry(g.height, g.horizontalInset, g.bottomInset, g.cornerRadius);
  },

  /** Hex `#RRGGBB` / `#RRGGBBAA`. Truyền tường minh chứ không để native lấy màu
   *  hệ — app ép theme thì màu hệ sẽ lệch. */
  setTint(activeHex: string, inactiveHex: string): void {
    mod()?.setTint(activeHex, inactiveHex);
  },

  setMergeSpacing(spacing: number): void {
    mod()?.setMergeSpacing(spacing);
  },

  /** Đăng ký nhận tap. Trả hàm huỷ đăng ký — gọi trong cleanup của effect. */
  onTabSelected(listener: (key: string) => void): () => void {
    const m = mod();
    if (m == null) return () => {};
    const sub = m.onTabSelected((e) => listener(e.key));
    return () => sub.remove();
  },
};
