import {
  toNativeItems,
  encodeBadge,
  encodeAndroidSvg,
  BADGE_DOT,
  DEFAULT_BADGE_CAP,
} from '../toNativeItems';

describe('encodeBadge — 3 trạng thái nhồi vào 1 string (codegen không có union)', () => {
  it('số > 0 → text; vượt cap → "N+"', () => {
    expect(encodeBadge(1, false, 9)).toBe('1');
    expect(encodeBadge(9, false, 9)).toBe('9');
    expect(encodeBadge(10, false, 9)).toBe('9+');
    expect(encodeBadge(999, false, 9)).toBe('9+');
  });

  it('cap tuỳ biến được', () => {
    expect(encodeBadge(50, false, 99)).toBe('50');
    expect(encodeBadge(100, false, 99)).toBe('99+');
  });

  it('số 0 / âm / NaN / Infinity → KHÔNG badge (không phải "0")', () => {
    // "0 tin chưa đọc" mà vẽ badge "0" là lỗi thị giác kinh điển.
    for (const v of [0, -1, NaN, Infinity, -Infinity]) {
      expect(encodeBadge(v, false, 9)).toBe('');
    }
  });

  it('dot khi không có số → sentinel khoảng trắng', () => {
    expect(encodeBadge(undefined, true, 9)).toBe(BADGE_DOT);
    expect(encodeBadge(0, true, 9)).toBe(BADGE_DOT);
  });

  it('SỐ THẮNG dot khi có cả hai', () => {
    // Có 3 tin chưa đọc thì "3" hữu ích hơn một chấm vô nghĩa.
    expect(encodeBadge(3, true, 9)).toBe('3');
  });

  it('không số không dot → rỗng', () => {
    expect(encodeBadge(undefined, undefined, 9)).toBe('');
    expect(encodeBadge(undefined, false, 9)).toBe('');
  });

  it('sentinel dot GHIM ĐÚNG GIÁ TRỊ " " — hợp đồng với native', () => {
    // GHIM GIÁ TRỊ, không chỉ ghim tính chất. Đây là hợp đồng LIÊN-NGÔN-NGỮ:
    // đầu kia là `kBadgeDotSentinel` trong ios/LTBItemView.mm. Bản trước chỉ
    // assert `!== ''`, `!== '0'`, `length === 1` ⇒ đổi BADGE_DOT thành 'x' thì
    // CẢ suite vẫn xanh, còn native thôi nhận ra chấm và vẽ badge text "x".
    // Đúng dạng fixture mù: assertion thỏa được bởi cả code đúng lẫn code sai.
    // Đổi giá trị ở đây ⇒ PHẢI đổi kBadgeDotSentinel trong .mm cùng lúc.
    expect(BADGE_DOT).toBe(' ');
    // Giữ luôn 2 tính chất cũ vì chúng nói LÝ DO chọn khoảng trắng: trùng ''
    // thì native không phân biệt "chấm" với "không badge"; là '0' thì badge số 0
    // hợp lệ về hình thức sẽ bị đọc thành chấm.
    expect(BADGE_DOT).not.toBe('');
    expect(BADGE_DOT).not.toBe('0');
  });
});

describe('encodeAndroidSvg — chuỗi SVG cho Android', () => {
  it('vắng / trắng / không phải string → RỖNG (native khỏi phải parse để biết trống)', () => {
    // Parse SVG là việc đắt; không nên trả giá đó chỉ để biết "không có icon".
    for (const v of [undefined, '', '   ', '\n\t']) {
      expect(encodeAndroidSvg(v as string | undefined)).toBe('');
    }
  });

  it('chuỗi hợp lệ → giữ nguyên, chỉ trim hai đầu', () => {
    const svg = '<svg viewBox="0 0 24 24"><path d="M1"/></svg>';
    expect(encodeAndroidSvg(`  ${svg}\n`)).toBe(svg);
  });

  it('KHÔNG validate cấu trúc — chuỗi lạ vẫn đi qua để parser NATIVE phán quyết', () => {
    // Validator nửa vời ở JS hoặc bác chuỗi hợp lệ, hoặc cho qua chuỗi hỏng.
    expect(encodeAndroidSvg('<svg>chưa đóng')).toBe('<svg>chưa đóng');
  });

  it('androidSvgSelected vắng → dùng lại androidSvg (một luật, ở tầng JS)', () => {
    const svg = '<svg><path d="M1"/></svg>';
    const [item] = toNativeItems([{ key: 'Chats', androidSvg: svg }]);
    expect(item?.androidSvg).toBe(svg);
    expect(item?.androidSvgSelected).toBe(svg);
  });

  it('androidSvgSelected là chuỗi RỖNG → vẫn fallback (|| chứ không ??)', () => {
    const svg = '<svg><path d="M1"/></svg>';
    const [item] = toNativeItems([
      { key: 'AIHub', androidSvg: svg, androidSvgSelected: '' },
    ]);
    expect(item?.androidSvgSelected).toBe(svg);
  });

  it('androidSvgSelected khác → giữ riêng, không bị ghi đè', () => {
    const [item] = toNativeItems([
      { key: 'Chats', androidSvg: '<svg>a</svg>', androidSvgSelected: '<svg>b</svg>' },
    ]);
    expect(item?.androidSvg).toBe('<svg>a</svg>');
    expect(item?.androidSvgSelected).toBe('<svg>b</svg>');
  });

  it('không có icon Android → cả hai field RỖNG, không undefined', () => {
    const [item] = toNativeItems([{ key: 'You' }]);
    expect(item?.androidSvg).toBe('');
    expect(item?.androidSvgSelected).toBe('');
  });
});

describe('toNativeItems — mọi field xuống native là string, không undefined', () => {
  it('item tối thiểu (chỉ key) → mọi field còn lại là chuỗi rỗng', () => {
    expect(toNativeItems([{ key: 'You' }])).toEqual([
      {
        key: 'You',
        label: '',
        sfSymbol: '',
        sfSymbolSelected: '',
        imageUrl: '',
        badge: '',
        androidSvg: '',
        androidSvgSelected: '',
      },
    ]);
  });

  it('KHÔNG có field nào là undefined (native nhận undefined ⇒ rác ở tầng C++)', () => {
    const out = toNativeItems([{ key: 'a' }, { key: 'b', label: 'B', badge: 4 }]);
    for (const item of out) {
      for (const [k, v] of Object.entries(item)) {
        expect(typeof v).toBe('string');
        expect(v).not.toBeUndefined();
        expect(k).toBeTruthy();
      }
    }
  });

  it('sfSymbolSelected vắng → dùng lại sfSymbol (luật fallback ở MỘT chỗ)', () => {
    const [item] = toNativeItems([{ key: 'Chats', sfSymbol: 'house' }]);
    expect(item?.sfSymbolSelected).toBe('house');
  });

  it('sfSymbolSelected là chuỗi RỖNG → vẫn fallback về sfSymbol', () => {
    // Đây là ca app THẬT đi qua: mini-app gửi '' cho AI Hub vì `sparkles` không
    // có biến thể .fill. Bản trước dùng `??` nên '' đi thẳng xuống native, và
    // test "5 tab thật" lại BỎ TRỐNG field thay vì gửi '' ⇒ mutant bỏ fallback
    // chỉ bị bắt ở đường mà app không bao giờ đi.
    const [item] = toNativeItems([
      { key: 'AIHub', sfSymbol: 'sparkles', sfSymbolSelected: '' },
    ]);
    expect(item?.sfSymbolSelected).toBe('sparkles');
  });

  it('sfSymbolSelected có → giữ nguyên, không bị sfSymbol ghi đè', () => {
    const [item] = toNativeItems([
      { key: 'Chats', sfSymbol: 'house', sfSymbolSelected: 'house.fill' },
    ]);
    expect(item?.sfSymbolSelected).toBe('house.fill');
  });

  it('cả hai symbol vắng nhưng có imageUrl → symbol rỗng, url giữ', () => {
    const [item] = toNativeItems([{ key: 'You', imageUrl: 'https://x/y.jpg' }]);
    expect(item?.sfSymbol).toBe('');
    expect(item?.sfSymbolSelected).toBe('');
    expect(item?.imageUrl).toBe('https://x/y.jpg');
  });

  it('giữ NGUYÊN thứ tự và số lượng item', () => {
    const keys = ['Chats', 'Messages', 'AIHub', 'Activity', 'You'];
    const out = toNativeItems(keys.map((key) => ({ key })));
    expect(out.map((i) => i.key)).toEqual(keys);
  });

  it('mảng rỗng → mảng rỗng (không nổ)', () => {
    expect(toNativeItems([])).toEqual([]);
  });

  it('badgeCap mặc định là 9 khi không truyền', () => {
    const [item] = toNativeItems([{ key: 'Activity', badge: 10 }]);
    expect(item?.badge).toBe('9+');
    expect(DEFAULT_BADGE_CAP).toBe(9);
  });

  it('5 tab thật của mini-app → xuống native đúng hình dạng mong đợi', () => {
    const out = toNativeItems([
      { key: 'Chats', label: 'Home', sfSymbol: 'house', sfSymbolSelected: 'house.fill' },
      { key: 'Messages', label: 'Chats', sfSymbol: 'message', sfSymbolSelected: 'message.fill' },
      // Gửi '' ĐÚNG NHƯ mini-app gửi (không bỏ trống) — xem ca riêng ở trên.
      { key: 'AIHub', label: 'AI Hub', sfSymbol: 'sparkles', sfSymbolSelected: '' },
      { key: 'Activity', label: 'Activity', sfSymbol: 'bell', sfSymbolSelected: 'bell.fill', badge: 12 },
      { key: 'You', imageUrl: 'https://lh3.googleusercontent.com/a=s256', dot: true },
    ]);

    expect(out[2]?.sfSymbolSelected).toBe('sparkles'); // không có .fill → dùng lại
    expect(out[3]?.badge).toBe('9+');
    expect(out[4]?.label).toBe(''); // tab You không nhãn
    expect(out[4]?.badge).toBe(BADGE_DOT);
    expect(out[4]?.sfSymbol).toBe('');
  });
});
