import type { ColorValue, StyleProp, ViewStyle } from 'react-native';

/** Một tab do phía gọi (mini-app) truyền vào. Mọi field ngoài `key` đều optional
 *  — wrapper điền mặc định trước khi xuống native (xem LUẬT ở spec codegen). */
export type TabItem = {
  /** Khoá ổn định; trả về nguyên văn trong `onSelect`. */
  key: string;
  /** Nhãn dưới icon. Bỏ trống ⇒ không vẽ nhãn (dùng cho tab avatar). */
  label?: string;
  /** SF Symbol trạng thái thường. */
  sfSymbol?: string;
  /** SF Symbol khi active. Bỏ trống ⇒ dùng lại `sfSymbol`. */
  sfSymbolSelected?: string;
  /** Ảnh remote thay icon, vẽ bo tròn (tab You). Thắng `sfSymbol` khi có. */
  imageUrl?: string;
  /** Số badge. `0`/`undefined` ⇒ không badge. Vượt `badgeCap` ⇒ "N+". */
  badge?: number;
  /** Chấm nhỏ không số (vd có bản update). Bị `badge` số ghi đè khi cả hai có. */
  dot?: boolean;
  /**
   * Icon cho ANDROID (không có SF Symbols): **nguyên chuỗi SVG**, ví dụ
   * `'<svg viewBox="0 0 24 24"><path fill-rule="evenodd" d="…"/></svg>'`.
   *
   * Native parse bằng một SVG parser đầy đủ (androidsvg) nên phía gọi KHÔNG phải
   * bóc path, không phải khai `viewBox`/`translate`/`fill-rule` riêng — mọi thứ
   * đó nằm trong chuỗi và parser tự xử lý, kể cả `<g transform>` lồng nhau.
   * Đây là lý do hợp đồng này đơn giản hơn bản bóc-path trước đó, không phải
   * phức tạp hơn.
   *
   * Màu: native render rồi tint bằng `ColorFilter(SRC_IN)` theo trạng thái
   * active/inactive, nên màu ghi trong chuỗi SVG **bị bỏ qua** — cứ để nguyên
   * `currentColor`/`#000` cũng được.
   *
   * `androidSvgSelected` vắng ⇒ dùng lại `androidSvg`.
   */
  androidSvg?: string;
  androidSvgSelected?: string;
};

export type LiquidTabBarProps = {
  items: ReadonlyArray<TabItem>;
  /** Khoá tab đang chọn. Không khớp item nào ⇒ không vẽ lens. */
  activeKey: string;
  onSelect: (key: string) => void;
  /** Màu icon/nhãn/lens của tab active. */
  tintColor?: ColorValue;
  /** Màu icon/nhãn tab không active. */
  inactiveTintColor?: ColorValue;
  /** Kính chuẩn (mặc định) hoặc kính trong. */
  glassStyle?: 'regular' | 'clear';
  /** Bo góc platter; mặc định nửa chiều cao thường dùng (32). */
  cornerRadius?: number;
  /** Khoảng cách để lens và platter bắt đầu MERGE (hiệu ứng liquid). */
  mergeSpacing?: number;
  /** Ngưỡng badge trước khi rút thành "N+". Mặc định 9. */
  badgeCap?: number;
  /** Geometry (chiều cao / vị trí) đi qua đây — không có prop riêng. */
  style?: StyleProp<ViewStyle>;
  testID?: string;
};
