// Fabric component spec — codegen đọc CHÍNH file này để sinh props C++/ObjC.
//
// ⚠️ LUẬT VIẾT SPEC (không phải sở thích — codegen RN 0.85 hẹp hơn TypeScript):
//   1. Field trong object của MẢNG đều KHÔNG optional. Codegen xử lý `?` trong
//      object lồng mảng không nhất quán giữa các version; wrapper JS
//      (`LiquidTabBar.tsx`) lo phần điền mặc định để API công khai vẫn dễ dùng.
//      Rẻ hơn nhiều so với việc debug một prop im lặng biến thành undefined ở
//      tầng C++.
//   2. Số phải là `Double`/`Int32` của CodegenTypes, không dùng `number` trần.
//   3. Event là `DirectEventHandler` — bar nằm trong cây view của mini-app nên
//      bubbling không cần thiết, và direct event rẻ hơn.
//
// Geometry (chiều cao, inset, đáy) đi qua `style` của ViewProps — KHÔNG thêm
// prop riêng: mini-app đã có nguồn số duy nhất `tabBarMetrics.ts` (device-verify
// 18/07), giữ nguyên chỗ chỉnh đó thay vì mở thêm một chỗ thứ hai để lệch.
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
import type {
  Double,
  DirectEventHandler,
  WithDefault,
} from 'react-native/Libraries/Types/CodegenTypes';
import type { ColorValue, HostComponent, ViewProps } from 'react-native';

export type NativeTabItem = Readonly<{
  /** Khoá ổn định do mini-app đặt; đi nguyên văn trong event onSelect. */
  key: string;
  /** Nhãn dưới icon. Rỗng ⇒ không vẽ nhãn (tab You). */
  label: string;
  /** SF Symbol trạng thái thường. Rỗng ⇒ không dùng symbol (phải có imageUrl). */
  sfSymbol: string;
  /** SF Symbol khi tab active. Rỗng ⇒ dùng lại `sfSymbol`. */
  sfSymbolSelected: string;
  /** Ảnh remote thay icon (tab You). Rỗng ⇒ dùng SF Symbol. Bo tròn. */
  imageUrl: string;
  /** Badge: rỗng ⇒ không badge; ' ' ⇒ chấm nhỏ không số; còn lại ⇒ text ('9+'). */
  badge: string;
}>;

export interface NativeProps extends ViewProps {
  items: ReadonlyArray<NativeTabItem>;
  /** Khoá tab đang chọn. Không khớp item nào ⇒ native không vẽ lens. */
  activeKey: string;
  /** Màu icon/nhãn/lens của tab active. */
  tintColor?: ColorValue;
  /** Màu icon/nhãn tab không active. */
  inactiveTintColor?: ColorValue;
  /**
   * `regular` = kính chuẩn, `clear` = kính trong (UIGlassEffectStyle).
   * Cố ý khai `string` chứ KHÔNG phải union: union sinh ra một enum C++ mà tên
   * đổi theo version codegen, và native phải gọi đúng tên đó mới biên dịch
   * được. String thì không phụ thuộc tên sinh. Ràng buộc giá trị vẫn còn ở API
   * công khai (`LiquidTabBarProps.glassStyle`), tức chỗ người dùng thực sự gõ.
   */
  glassStyle?: WithDefault<string, 'regular'>;
  /** Bo góc platter. Mặc định 32 = HEIGHT 64 / 2 của mini-app. */
  cornerRadius?: WithDefault<Double, 32>;
  /**
   * `UIGlassContainerEffect.spacing` — khoảng cách mà các khối kính bắt đầu
   * MERGE. Đây là thứ tạo hiệu ứng liquid khi lens trượt về gần platter.
   * 0 ⇒ không bao giờ merge (lens là đảo kính rời).
   */
  mergeSpacing?: WithDefault<Double, 12>;
  onSelect?: DirectEventHandler<Readonly<{ key: string }>>;
}

export default codegenNativeComponent<NativeProps>(
  'LiquidTabBar',
) as HostComponent<NativeProps>;
