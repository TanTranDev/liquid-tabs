import {
  toNativeItems,
  encodeBadge,
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

  it('sentinel dot KHÁC chuỗi rỗng và KHÁC "0"', () => {
    // Nếu sentinel trùng '' thì native không phân biệt được "chấm" với "không
    // badge"; nếu là '0' thì badge số 0 hợp lệ về hình thức sẽ thành chấm.
    expect(BADGE_DOT).not.toBe('');
    expect(BADGE_DOT).not.toBe('0');
    expect(BADGE_DOT.length).toBe(1);
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
      { key: 'AIHub', label: 'AI Hub', sfSymbol: 'sparkles' },
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
