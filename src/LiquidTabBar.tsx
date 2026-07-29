// Wrapper công khai. Nhiệm vụ: chuẩn hoá props → native, và CHẶN mọi thứ trước
// iOS 26 (UIGlassEffect chỉ có từ 26.0 — dưới đó native view sẽ dựng một hộp
// rỗng, tệ hơn hẳn so với để phía gọi tự fallback).
//
// Trả `null` khi không khả dụng là CÓ CHỦ ĐÍCH: phía gọi kiểm
// `isLiquidTabBarAvailable()` rồi chọn bar riêng của mình. Không tự vẽ fallback
// ở đây — thư viện này chỉ hứa MỘT việc: kính native iOS 26+.
import * as React from 'react';
import { Platform } from 'react-native';

import LiquidTabBarNative from './specs/LiquidTabBarNativeComponent';
import { toNativeItems, DEFAULT_BADGE_CAP } from './toNativeItems';
import type { LiquidTabBarProps } from './types';

/** iOS major từ Platform.Version ("26.2" → 26). Không parse được ⇒ 0 (an toàn:
 *  mọi gate theo version đều đóng khi thiếu thông tin). */
export const parseIOSMajor = (version: unknown): number => {
  if (typeof version === 'number') {
    return Number.isFinite(version) && version > 0 ? Math.floor(version) : 0;
  }
  if (typeof version !== 'string' || version.trim() === '') return 0;
  const major = Number.parseInt(version, 10);
  return Number.isFinite(major) && major > 0 ? major : 0;
};

export const MIN_IOS = 26;

/** Có dựng được kính native không: iOS 26+ VÀ view đã đăng ký (host đã build
 *  native). Thiếu view mà vẫn render ⇒ RN ném lỗi component không tồn tại. */
export const isLiquidTabBarAvailable = (
  os: string = Platform.OS,
  version: unknown = Platform.Version,
): boolean =>
  os === 'ios' && parseIOSMajor(version) >= MIN_IOS && LiquidTabBarNative != null;

export const LiquidTabBar: React.FC<LiquidTabBarProps> = ({
  items,
  activeKey,
  onSelect,
  tintColor,
  inactiveTintColor,
  glassStyle,
  cornerRadius,
  mergeSpacing,
  badgeCap = DEFAULT_BADGE_CAP,
  style,
  testID,
}) => {
  // Hook PHẢI chạy trước mọi early-return — gọi có điều kiện là vi phạm rules
  // of hooks (và eslint sẽ chặn). Chi phí map 5 item khi không khả dụng là 0.
  const nativeItems = React.useMemo(
    () => toNativeItems(items, badgeCap),
    [items, badgeCap],
  );

  if (!isLiquidTabBarAvailable()) return null;

  return (
    <LiquidTabBarNative
      style={style}
      testID={testID}
      items={nativeItems}
      activeKey={activeKey}
      tintColor={tintColor}
      inactiveTintColor={inactiveTintColor}
      glassStyle={glassStyle}
      cornerRadius={cornerRadius}
      mergeSpacing={mergeSpacing}
      onSelect={(e) => onSelect(e.nativeEvent.key)}
    />
  );
};
