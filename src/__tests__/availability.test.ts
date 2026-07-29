import { parseIOSMajor, isLiquidTabBarAvailable, MIN_IOS } from '../LiquidTabBar';

describe('parseIOSMajor', () => {
  it('string iOS thường gặp → major', () => {
    expect(parseIOSMajor('26.2')).toBe(26);
    expect(parseIOSMajor('26')).toBe(26);
    expect(parseIOSMajor('18.5.1')).toBe(18);
  });

  it('number (Android Platform.Version) → floor', () => {
    expect(parseIOSMajor(34)).toBe(34);
    expect(parseIOSMajor(26.9)).toBe(26);
  });

  it('thiếu/không hợp lệ → 0, KHÔNG phải giá trị lớn', () => {
    // 0 là chiều an toàn: mọi gate theo version đóng lại khi thiếu thông tin.
    // Trả số lớn ở đây sẽ bật kính trên máy không hỗ trợ.
    for (const v of [undefined, null, '', '   ', 'abc', {}, [], NaN, -5, 0]) {
      expect(parseIOSMajor(v)).toBe(0);
    }
  });
});

describe('isLiquidTabBarAvailable — gate iOS 26+', () => {
  it('ngưỡng là 26', () => {
    expect(MIN_IOS).toBe(26);
  });

  it('iOS 26+ → true', () => {
    expect(isLiquidTabBarAvailable('ios', '26.0')).toBe(true);
    expect(isLiquidTabBarAvailable('ios', '27.1')).toBe(true);
  });

  it('iOS < 26 → false (UIGlassEffect chưa tồn tại)', () => {
    expect(isLiquidTabBarAvailable('ios', '25.9')).toBe(false);
    expect(isLiquidTabBarAvailable('ios', '18.5')).toBe(false);
  });

  it('Android → false dù version số lớn', () => {
    expect(isLiquidTabBarAvailable('android', 36)).toBe(false);
  });

  it('version thiếu → false', () => {
    expect(isLiquidTabBarAvailable('ios', undefined)).toBe(false);
    expect(isLiquidTabBarAvailable('ios', '')).toBe(false);
  });
});
