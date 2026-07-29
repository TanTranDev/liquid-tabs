// Chuẩn hoá item công khai → item native. Tách khỏi component vì đây là phần
// DUY NHẤT có nhánh trong tầng JS ⇒ chỗ duy nhất đáng test (test theo rủi ro).
//
// Hợp đồng với native (spec codegen): mọi field là string KHÔNG optional; chuỗi
// RỖNG là tín hiệu "không có". Native không được nhận `undefined` — nó sẽ thành
// giá trị rác ở tầng C++ tuỳ version codegen.
//
// Badge encode 3 trạng thái vào MỘT string vì codegen không có union type:
//   ''    → không badge
//   ' '   → chấm nhỏ, không số   (một khoảng trắng — sentinel)
//   '9+'  → badge có text
// Sentinel là khoảng trắng chứ không phải '0'/'dot' vì '0' là badge số hợp lệ về
// hình thức và 'dot' có thể là text badge người ta muốn hiện thật.
import type { TabItem } from './types';
import type { NativeTabItem } from './specs/LiquidTabBarNativeComponent';

export const BADGE_DOT = ' ';
export const DEFAULT_BADGE_CAP = 9;

/** Badge số → text native. Ưu tiên số trước chấm: có 3 tin chưa đọc thì hiện
 *  "3" hữu ích hơn một chấm vô nghĩa. */
export const encodeBadge = (
  badge: number | undefined,
  dot: boolean | undefined,
  cap: number,
): string => {
  if (typeof badge === 'number' && Number.isFinite(badge) && badge > 0) {
    return badge > cap ? `${cap}+` : String(badge);
  }
  return dot === true ? BADGE_DOT : '';
};

export const toNativeItems = (
  items: ReadonlyArray<TabItem>,
  badgeCap: number = DEFAULT_BADGE_CAP,
): ReadonlyArray<NativeTabItem> =>
  items.map((it) => ({
    key: it.key,
    label: it.label ?? '',
    sfSymbol: it.sfSymbol ?? '',
    // Rỗng ⇒ native dùng lại `sfSymbol`; điền sẵn ở đây để native khỏi phải
    // biết luật fallback (một luật, một chỗ).
    sfSymbolSelected: it.sfSymbolSelected ?? it.sfSymbol ?? '',
    imageUrl: it.imageUrl ?? '',
    badge: encodeBadge(it.badge, it.dot, badgeCap),
  }));
