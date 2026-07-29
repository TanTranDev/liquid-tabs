// Lưới cho gate NỀN TẢNG của `LiquidTabsHost`.
//
// Bug thật (v0.2.0): `mod()` viết `if (Platform.OS !== 'ios') return null`, nên
// trên Android TurboModule KHÔNG BAO GIỜ được nạp ⇒ `isAvailable()` trả false ⇒
// phía gọi tự vẽ bar ⇒ toàn bộ bar Kotlin + androidsvg thành code chết. Và nó
// chết IM LẶNG: không exception, không warn, chỉ là "Android không có bar của
// thư viện" — trông y hệt hành vi đúng.
//
// Lưới cũ mù chỗ này vì `availability.test.ts` chỉ phủ `isLiquidTabBarAvailable`
// — gate theo số version của kiến trúc Fabric CŨ, nơi Android=false là ĐÚNG. Hai
// hàm tên gần giống nhau, ngược nghĩa nhau: một cái hỏi "có kính không", cái kia
// hỏi "có bar không".
//
// `mod()` cache module-scope nên mỗi ca phải `resetModules()` + require lại;
// dùng `doMock` (KHÔNG `virtual`) vì cả hai module bị mock đều tồn tại thật.

type HostModule = typeof import('../LiquidTabsHost');

/** Nạp lại `LiquidTabsHost` với `Platform.OS` và TurboModule chỉ định. */
const loadHost = (os: string, native: unknown): HostModule => {
  jest.resetModules();
  jest.doMock('react-native', () => ({ Platform: { OS: os } }));
  jest.doMock('../specs/NativeLiquidTabs', () => ({ default: native }));
  return require('../LiquidTabsHost') as HostModule;
};

/** Native giả: bar dùng được, kính thì tuỳ nền tảng (Android luôn false). */
const fakeNative = (glass: boolean) => ({
  isAvailable: () => true,
  isGlassAvailable: () => glass,
});

// `resetModules` xoá module registry nhưng KHÔNG xoá mock registry. Thứ tự hiện tại
// an toàn vì mọi ca đều đăng ký lại CẢ HAI path, nhưng ca thêm sau mà chỉ
// `require('../LiquidTabsHost')` sẽ âm thầm thừa hưởng mock cuối còn hiệu lực
// (`Platform.OS='ios'` + factory THROW) ⇒ `cached=null` ⇒ XANH GIẢ.
afterEach(() => {
  jest.resetModules();
  jest.resetAllMocks();
});

describe('isSupportedPlatform', () => {
  it('ios và android đều có bản native → true', () => {
    const { isSupportedPlatform } = loadHost('ios', fakeNative(true));
    expect(isSupportedPlatform('ios')).toBe(true);
    expect(isSupportedPlatform('android')).toBe(true);
  });

  it('nền tảng không có bản native → false', () => {
    const { isSupportedPlatform } = loadHost('ios', fakeNative(true));
    for (const os of ['web', 'windows', 'macos', '', 'IOS']) {
      expect(isSupportedPlatform(os)).toBe(false);
    }
  });
});

describe('isBarAvailable — bar (KHÔNG phải kính) theo nền tảng', () => {
  it('ANDROID có native → true (bar nền vẽ tay của thư viện)', () => {
    // Đây là ca REGRESSION của bug v0.2.0. Trước fix: false.
    const { isBarAvailable } = loadHost('android', fakeNative(false));
    expect(isBarAvailable()).toBe(true);
  });

  it('iOS có native → true', () => {
    const { isBarAvailable } = loadHost('ios', fakeNative(true));
    expect(isBarAvailable()).toBe(true);
  });

  it('nền tảng không hỗ trợ → false, và KHÔNG require module native', () => {
    // Gate phải short-circuit TRƯỚC `require`: factory dưới đây throw, nên nếu
    // gate cho qua thì `cached` vẫn null (catch) — test vẫn xanh và mutation
    // "bỏ gate" sẽ sống. Vì vậy đếm luôn số lần factory bị gọi.
    let required = 0;
    jest.resetModules();
    jest.doMock('react-native', () => ({ Platform: { OS: 'web' } }));
    jest.doMock('../specs/NativeLiquidTabs', () => {
      required += 1;
      throw new Error('không có native trên nền tảng này');
    });
    const { isBarAvailable, isGlassAvailable } = require('../LiquidTabsHost') as HostModule;
    expect(isBarAvailable()).toBe(false);
    // Cùng lý do: không ca nào gọi `isGlassAvailable()` khi `m == null` thì mutant
    // bỏ `m != null` khỏi hàm đó sống, và lỗi thật sẽ là TypeError lúc chạy.
    expect(() => isGlassAvailable()).not.toThrow();
    expect(isGlassAvailable()).toBe(false);
    expect(required).toBe(0);
  });

  it('nền tảng hỗ trợ nhưng native VẮNG (host chưa rebuild) → false, không throw', () => {
    jest.resetModules();
    jest.doMock('react-native', () => ({ Platform: { OS: 'ios' } }));
    jest.doMock('../specs/NativeLiquidTabs', () => {
      throw new Error("Cannot find module 'LiquidTabs'");
    });
    const { isBarAvailable } = require('../LiquidTabsHost') as HostModule;
    expect(() => isBarAvailable()).not.toThrow();
    expect(isBarAvailable()).toBe(false);
  });

  it('native CÓ nhưng tự khai không khả dụng → false (toán hạng thứ hai của AND)', () => {
    // Không có ca này thì mutant `return m != null` (bỏ `&& m.isAvailable()`) SỐNG:
    // mọi fixture khác hardcode `isAvailable: () => true`. Đúng toán hạng canh
    // hazard đã khai — ngày nào một nền tảng trả false, lưới phải thấy.
    const { isBarAvailable } = loadHost('android', {
      isAvailable: () => false,
      isGlassAvailable: () => false,
    });
    expect(isBarAvailable()).toBe(false);
  });
});

describe('isGlassAvailable — tách hẳn khỏi isBarAvailable', () => {
  it('Android: có bar nhưng KHÔNG có kính', () => {
    // Hai câu hỏi khác nhau. Gộp chúng lại là cách bug v0.2.0 lọt: "Android
    // không có kính" bị hiểu thành "Android không có bar".
    const { isBarAvailable, isGlassAvailable } = loadHost('android', fakeNative(false));
    expect(isBarAvailable()).toBe(true);
    expect(isGlassAvailable()).toBe(false);
  });

  it('iOS 26+: có cả hai', () => {
    const { isBarAvailable, isGlassAvailable } = loadHost('ios', fakeNative(true));
    expect(isBarAvailable()).toBe(true);
    expect(isGlassAvailable()).toBe(true);
  });

  it('iOS < 26: có bar (nền vẽ tay), không kính', () => {
    const { isBarAvailable, isGlassAvailable } = loadHost('ios', fakeNative(false));
    expect(isBarAvailable()).toBe(true);
    expect(isGlassAvailable()).toBe(false);
  });
});

describe('LiquidTabsHost — mặt tiền object', () => {
  it('isAvailable của object trùng isBarAvailable (một nguồn sự thật)', () => {
    const { LiquidTabsHost, isBarAvailable } = loadHost('android', fakeNative(false));
    expect(LiquidTabsHost.isAvailable).toBe(isBarAvailable);
  });

  it('lệnh gọi tới native đi qua trên ANDROID, không bị gate chặn', () => {
    // `setTabs`/`setActive` dùng `mod()?.` nên gate sai làm chúng thành no-op
    // im lặng — bar Android sẽ rỗng chứ không báo lỗi.
    const calls: string[] = [];
    const native = {
      ...fakeNative(false),
      setTabs: () => calls.push('setTabs'),
      setActive: () => calls.push('setActive'),
      setVisible: () => calls.push('setVisible'),
    };
    const { LiquidTabsHost } = loadHost('android', native);
    LiquidTabsHost.setTabs([{ key: 'Chats', androidSvg: '<svg/>' }]);
    LiquidTabsHost.setActive('Chats');
    LiquidTabsHost.setVisible(true);
    expect(calls).toEqual(['setTabs', 'setActive', 'setVisible']);
  });
});
