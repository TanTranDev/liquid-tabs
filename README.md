# @tantrancover/liquid-tabs

Thanh tab bar nổi **Liquid Glass cho iOS 26+**, dựng bằng **public API**
(`UIGlassEffect` + `UIGlassContainerEffect`). Host build native; mini-app nạp qua
Module Federation `shared` singleton.

**Chỉ là thanh bar.** Không phải `UITabBarController`: thư viện không sở hữu view
controller của từng tab, không quản navigation state. Việc chuyển tab do JS phía
gọi tự làm. Đó là quyết định có chủ đích — xem [Vì sao chỉ là bar](#vì-sao-chỉ-là-bar).

## Cài (phía HOST)

```bash
npm i @tantrancover/liquid-tabs      # hoặc pnpm add
cd ios && pod install                # autolink qua podspec
```

Rồi khai vào `shared` của Module Federation ở **cả host và mini-app**:

```js
'@tantrancover/liquid-tabs': {
  singleton: true,
  eager: false,
  import: false,          // ⚠️ BẮT BUỘC — xem dưới
  requiredVersion: '^0.1.0',
  version: '0.1.0',
},
```

> ⚠️ **`import: false` không phải tuỳ chọn.** Đây là package có **view native**.
> Nếu mini-app bundle bản riêng của nó, view sẽ được đăng ký **hai lần** với host
> và app crash: *"Tried to register two views with the same name"*. Đã xảy ra thật
> trong hệ này với `PasteTextInput`.

## Dùng

```tsx
import { LiquidTabBar, isLiquidTabBarAvailable } from '@tantrancover/liquid-tabs';

if (!isLiquidTabBarAvailable()) return <MyOwnTabBar />;   // iOS <26 / host chưa build

<LiquidTabBar
  style={{ position: 'absolute', left: 10, right: 10, bottom: 20, height: 64 }}
  cornerRadius={32}
  items={[
    { key: 'Chats',    label: 'Home',     sfSymbol: 'house',   sfSymbolSelected: 'house.fill' },
    { key: 'Messages', label: 'Chats',    sfSymbol: 'message', sfSymbolSelected: 'message.fill' },
    { key: 'AIHub',    label: 'AI Hub',   sfSymbol: 'sparkles' },
    { key: 'Activity', label: 'Activity', sfSymbol: 'bell', sfSymbolSelected: 'bell.fill', badge: 12 },
    { key: 'You',      imageUrl: avatarUrl, dot: hasUpdate },   // ảnh → bo tròn, không nhãn
  ]}
  activeKey={active}
  onSelect={setActive}
/>
```

- **Geometry đi qua `style`**, không có prop riêng — để phía gọi giữ đúng một
  nguồn số (mini-app đã có `tabBarMetrics.ts` device-verified).
- `label` bỏ trống ⇒ không vẽ nhãn. `imageUrl` thắng `sfSymbol`.
- `badge` số: `0`/vắng ⇒ không badge; vượt `badgeCap` (mặc định 9) ⇒ `"9+"`.
  `dot: true` ⇒ chấm nhỏ không số; có `badge` số thì **số thắng**.
- `sfSymbolSelected` vắng ⇒ dùng lại `sfSymbol`.

## Hiệu ứng liquid đến từ đâu

`UIGlassContainerEffect.spacing` — theo UIKit header: *"the distance between
elements at which they begin to merge"*. Platter (nền bar) và lens (bong bóng sau
tab active) là **hai glass element trong cùng một container**, nên khi lens trượt
lại gần platter, UIKit tự merge chúng. Đây là cơ chế chính hãng, **không dùng view
private** (`_UILiquidLensView`). `mergeSpacing={0}` ⇒ lens là đảo kính rời.

## Giới hạn đã biết (non-goals)

| Không có | Vì sao |
|---|---|
| `tabBarMinimizeBehavior` (bar co khi cuộn) | Thuộc `UITabBarController`. Bar-only thì không có. Trong hệ mini-app còn khó hơn: bar ở host, scroll ở mini-app. |
| Android | Phía gọi tự dùng bar riêng; `isLiquidTabBarAvailable()` trả `false`. |
| iOS < 26 | `UIGlassEffect` chưa tồn tại. Component trả `null`. |
| Sidebar / More tab / iPad mode | Ngoài phạm vi bar-only. |
| Cache ảnh chung với `<Image>` của RN | Avatar tải bằng `NSURLSession` + `NSCache` riêng, không qua `RCTImageLoader` — đổi lại không phải kéo bridge image loader vào một Fabric ComponentView. |

## Rủi ro CHƯA loại trừ

**Glass material ở pha boot OTA.** Trong hệ này, mini-app có thể boot bằng bundle
nhúng (embedded) hoặc bundle tải về (OTA). Đã ghi nhận: platter Liquid Glass của
`UITabBar` **mất** khi boot OTA, và một wrapper `UIGlassEffect` của bên thứ ba
cũng *"chết cùng bệnh"*. Chưa ai tách được **bệnh của wrapper** khỏi **bệnh của
API** — wrapper đó có 3 lỗi thiết kế đã chứng minh (`masksToBounds = NO` cố ý,
không bọc container effect, tái tạo `UIGlassEffect` trên effect view đang sống mỗi
lần đổi tint).

Thư viện này tránh cả ba: clip theo bounds, dùng container effect đúng cách, và
**không bao giờ gán `.effect` mới** trừ khi prop đổi thật (tint nằm trên item view
chứ không trên kính). Nhưng nếu bệnh thuộc chính API thì bar vẫn mất nền ở pha OTA.
**Phép thử quyết định**: chạy device iOS 26 với bundle OTA và xem nền còn không.

## Checklist `[device-verify]` (jest + typecheck KHÔNG bắt được)

1. iOS 26 device, boot **embedded**: kính gọn trong frame, không tràn ra màn hình.
2. iOS 26 device, boot **OTA**: kính **vẫn còn** ← phép thử rủi ro ở trên.
3. Đổi tab: lens trượt + merge với platter, không nháy.
4. Đổi Dark/Light hệ thống giữa phiên: bar đổi theo, không vỡ render.
5. Avatar tab You: bo tròn, nét trên Retina, đổi user thì ảnh đổi theo.
6. Badge `12` → `"9+"`; `dot` → chấm nhỏ; hết badge → mất hẳn.
7. Animation merge có bị `clipsToBounds = YES` cắt xấu không (đổi cờ là một dòng
   trong `LiquidTabBarComponentView.mm`).

## Vì sao chỉ là bar

Nhánh cũ dùng `UITabBarController` (qua `react-native-screens`) đã kéo theo: 6 lớp
patch native trên thư viện thứ ba, một oval tự vẽ đắp bù khi UIKit bỏ platter, và
một bộ luật về trait (cấm `Appearance.setColorScheme`, cấm override window lúc
boot…) vì floating bar iOS 26 sống ngoài chuỗi trait của controller. Bỏ
`UITabBarController` là bỏ **toàn bộ** lớp vấn đề đó cùng lúc; giá phải trả là
`minimizeBehavior` và việc tự quản state tab — mà phía gọi vốn đã tự quản cho
Android.

## Phát triển

```bash
npm install
npm run typecheck
npm test          # tầng JS: chuẩn hoá props + gate version
npm run build     # sinh lib/
```

Native **không có test tự động** — nó là render UIKit, phải xem bằng mắt trên
device theo checklist trên.
