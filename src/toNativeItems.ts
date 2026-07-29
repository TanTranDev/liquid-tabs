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
import type { TabItemNative } from './specs/NativeLiquidTabs';

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

/**
 * Chuỗi SVG cho Android → dạng gửi qua bridge. Chuỗi trắng / không phải string ⇒
 * RỖNG, để native chỉ cần một phép kiểm `length == 0` (không phải parse rồi mới
 * biết là trống — parse SVG là việc đắt, không nên trả giá đó để biết "không có").
 *
 * KHÔNG validate cấu trúc SVG ở đây: đó là việc của parser native, và một
 * validator nửa vời ở JS sẽ hoặc bác chuỗi hợp lệ, hoặc cho qua chuỗi hỏng —
 * cả hai đều tệ hơn là để parser thật phán quyết.
 */
export const encodeAndroidSvg = (svg: string | undefined): string =>
  typeof svg === 'string' && svg.trim() !== '' ? svg.trim() : '';

export const toNativeItems = (
  items: ReadonlyArray<TabItem>,
  badgeCap: number = DEFAULT_BADGE_CAP,
): ReadonlyArray<TabItemNative> =>
  items.map((it) => ({
    key: it.key,
    label: it.label ?? '',
    sfSymbol: it.sfSymbol ?? '',
    // Fallback selected → thường: dùng `||` chứ KHÔNG `??`. Phía gọi có thể gửi
    // chuỗi RỖNG một cách chủ đích ("symbol này không có biến thể .fill" — vd
    // `sparkles`), mà `??` chỉ bắt null/undefined nên `''` sẽ đi thẳng xuống
    // native. Trước đây icon vẫn đúng, nhưng chỉ nhờ native TỰ fallback lần thứ
    // hai — tức luật nằm ở HAI chỗ trong khi comment này nói là một. Nay chuẩn
    // hoá tại đây để native chỉ còn là lưới cuối, không phải nguồn luật.
    sfSymbolSelected: it.sfSymbolSelected || it.sfSymbol || '',
    imageUrl: it.imageUrl ?? '',
    badge: encodeBadge(it.badge, it.dot, badgeCap),
    androidSvg: encodeAndroidSvg(it.androidSvg),
    // Fallback selected → thường bằng `||` (không `??`) vì lý do y như
    // sfSymbolSelected: phía gọi có thể gửi chuỗi rỗng một cách chủ đích.
    androidSvgSelected: encodeAndroidSvg(it.androidSvgSelected || it.androidSvg),
  }));
