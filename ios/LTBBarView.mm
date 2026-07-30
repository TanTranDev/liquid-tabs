#import "LTBBarView.h"
#import "LTBItemView.h"

static const CGFloat kLensInsetX = 4.0;
static const CGFloat kLensInsetY = 6.0;

// ⚠️ KHÔNG có hằng thời lượng cho việc lens DỜI CHỖ — cố ý, từ 0.8.3.
//
// Bản trước có `kLensAnimDuration = 0.32` + spring damping 0.86 để lens trượt sang ô mới. USER
// chốt 30/07: đọc thành "chậm", cần TỨC THÌ, không trượt. Xem `layoutLensAndPress:`. Đừng thêm
// lại một hằng như vậy mà không có yêu cầu mới — thứ còn animate ở nhánh tự vẽ CHỈ là hiệu ứng
// nhấn (`kLensPress*` bên dưới) và cú vuốt-để-chọn (đi theo ngón, vốn không có animation).

// ── Vuốt-để-chọn (yêu cầu USER 29/07). Lens đi theo ngón LIÊN TỤC; tab chỉ đổi
// khi NHẢ tay (USER chốt: tránh mount/unmount 4 screen liên tiếp khi kéo một lượt).
//
// Phần "bóng nước" ở đây là do TA tự vẽ, KHÔNG dựa vào merge của UIKit: lens giãn
// theo trục X tỉ lệ với tốc độ ngón rồi đàn về. Lý do không dựa vào merge: lens nằm
// TRỌN trong platter nên khoảng cách giữa hai khối kính là 0, mà `spacing` của
// UIGlassContainerEffect là "khoảng cách mà các phần tử BẮT ĐẦU hợp nhất" — rất có
// thể UIKit đang hợp nhất lens vào platter, tức lens tan vào nền. Chưa phân định
// được trên máy; `setMergeSpacing` là núm xoay để thử (0 = không hợp nhất).
// ── NỞ KHI NHẤN (yêu cầu USER 29/07, chốt phạm vi: nở ngay lúc ngón đụng, GIỮ suốt
// lúc nhấn và lúc kéo, thu về khi nhả).
//
// Vì sao ta tự đổi kích thước thay vì để `UIGlassEffect.interactive` tự lo: `interactive`
// chỉ phản ứng khi CHÍNH view kính nhận được touch, mà ở bar này icon (`_itemsHost`) nằm
// TRÊN lens và ăn hết touch, còn pan thì gắn trên `self` ⇒ lens không bao giờ nhận một
// touch nào ⇒ không có gì để nó phản ứng.
//
// Đây KHÔNG phải mô phỏng hiệu ứng: ta chỉ đổi FRAME của một view kính thật, nên phần
// phình vẫn do UIGlassEffect render — vẫn có tán sắc ở mép, vẫn tràn ra ngoài mép bar
// (nhờ clipsToBounds = NO). Trigger là của ta, vật liệu là của UIKit.
/// Lens nở khi nhấn — nhưng CHỈ trong lòng platter, không vượt ra ngoài.
///
/// Hai bản trước cho lens vượt khỏi khung bar để "tràn ra ngoài", và cả hai lần phần
/// vượt đó render thành MIẾNG DÁN phẳng che nội dung (device 29/07). Cái tạo ra vẻ
/// "tràn" ở bản Apple là thứ khác: CẢ THANH BAR phóng to (xem `kBarPressScale`). Nhờ vậy
/// khối kính đi ra ngoài đường viền CŨ của bar mà vẫn luôn nằm trong khung của chính nó
/// ⇒ luôn có backdrop ⇒ luôn là kính thật.
static const CGFloat kLensPressGrowX = 4.0;
static const CGFloat kLensPressGrowY = 5.0;
static const NSTimeInterval kLensPressDuration = 0.24;
static const CGFloat kLensPressDamping = 0.74;

/// Trần bán kính. Bán kính = nửa chiều cao cho ra hình gần TRÒN trên khối đã nở, đọc
/// thành elip chứ không phải capsule ôm ô tab (user báo 29/07).
static const CGFloat kLensMaxRadius = 26.0;

/// Khi nhấn, TOÀN BỘ bar phóng to (user chỉ ra 29/07 — đây là mảnh còn thiếu). Dùng
/// `transform` trên chính bar view nên platter, lens và icon phóng CÙNG NHAU: mọi thứ
/// vẫn nằm trong khung của nó, chỉ là khung đó lớn hơn ⇒ không có chỗ nào mất backdrop.
/// Transform áp SAU layout nên không đụng gì tới Auto Layout của host, và
/// `locationInView:` vẫn trả toạ độ trong hệ bounds chưa transform ⇒ toán vuốt không đổi.
static const CGFloat kBarPressScale = 1.06;

/// Ngưỡng coi là "kéo" thay vì "chạm", để tap không bị hiểu thành vuốt 1px.
static const CGFloat kDragSlop = 6.0;
/// Nếu phía JS không xác nhận lựa chọn trong khoảng này, trả highlight về sự thật.
/// Bar sống NGOÀI cây React nên không có ai tự sửa nó — thiếu lưới này thì một lần
/// app từ chối đổi tab là bar kẹt sai vĩnh viễn.
static const NSTimeInterval kPendingRevertDelay = 0.6;

// Nền VẼ TAY khi không có UIGlassEffect. Giá trị lấy nguyên từ `GlassSurface` của
// mini-app (đã device-verify 18/07, căn theo platter App Store iOS 26): tint đục
// ~92% + hairline định biên. Dùng dynamic color để tự đổi theo Dark Mode — đây là
// cách đúng ở tầng native, không cần ai bơm theme xuống.
static UIColor *LTBFallbackFill(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:44 / 255.0 green:44 / 255.0 blue:46 / 255.0 alpha:0.94]
        : [UIColor colorWithRed:252 / 255.0 green:252 / 255.0 blue:252 / 255.0 alpha:0.92];
  }];
}

static UIColor *LTBFallbackEdge(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    // Dark: hairline SÁNG-trên-tối mới tách được bar khỏi nền đen (0.06 quá mờ).
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithWhite:1.0 alpha:0.14]
        : [UIColor colorWithWhite:0.0 alpha:0.06];
  }];
}

/// Màu MẶC ĐỊNH của vùng chọn. Giá trị lấy nguyên từ `tokens.color.brand.soft` của
/// mini-app (accent-soft) — chính pill mà bản TabBar JS đang vẽ và đã được duyệt bằng
/// mắt. Phía gọi nên ghi đè qua `setLensColor:` để theme sống ở JS; hằng này chỉ để
/// thư viện dùng được ngay khi chưa ai truyền gì.
///
/// ⚠️ Vùng chọn KHÔNG dùng UIGlassEffect, dù bar đang ở chế độ kính. Hai lý do đo
/// được: (1) alpha của accent-soft là 0.10 — một khối kính tint ở alpha đó gần như vô
/// hình, và kính-trên-kính thì không có tương phản; (2) lens nằm TRỌN trong platter
/// nên khoảng cách hai khối kính là 0, mà `UIGlassContainerEffect.spacing` là "khoảng
/// cách mà các phần tử BẮT ĐẦU hợp nhất" ⇒ UIKit hợp nhất lens VÀO platter, tức lens
/// tan vào nền. Đó là hiện tượng user báo 29/07: "lướt được rồi nhưng không có vùng
/// chọn". Pill phẳng có tint là đúng thứ bản JS vẽ, và là đúng thứ cần khớp.
static UIColor *LTBDefaultLensFill(void)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:82 / 255.0 green:156 / 255.0 blue:202 / 255.0 alpha:0.16]
        : [UIColor colorWithRed:35 / 255.0 green:131 / 255.0 blue:226 / 255.0 alpha:0.10];
  }];
}

@implementation LTBBarView {
  // Nhánh kính
  UIVisualEffectView *_container;
  UIVisualEffectView *_platter;
  // Nhánh fallback
  UIView *_fallbackBg;

  /// Vùng chọn — MỘT view cho CẢ HAI chế độ nền, luôn là UIView tint phẳng (xem
  /// `LTBDefaultLensFill` về lý do không dùng kính ở đây). Trước đây có hai lens
  /// riêng cho hai nhánh; gộp lại vì toàn bộ logic vuốt/morph không quan tâm nền là
  /// gì, và hai đường song song chỉ tạo chỗ cho một nhánh câm.
  UIView *_lens;

  UIView *_itemsHost;
  NSMutableArray<LTBItemView *> *_items;
  NSArray<NSDictionary<NSString *, NSString *> *> *_itemProps;
  NSString *_activeKey;
  /// Số `onSelect` đã bắn mà JS chưa trả lời — lọc ECHO LẠC HẬU. Giữ giống
  /// `LTBSystemBar::_outstandingEchoes` (lý do dài ở `setActiveKey:` bên đó): lệch nhánh ở
  /// đúng cơ chế này là lỗi im lặng, vì mỗi máy chỉ chạy một nhánh.
  NSUInteger _outstandingEchoes;
  UIColor *_tintActive;
  UIColor *_tintInactive;
  CGFloat _cornerRadius;
  CGFloat _mergeSpacing;
  BOOL _useGlass;

  // ── Vuốt-để-chọn
  UIPanGestureRecognizer *_pan;
  /// Tab mà bar đang hiển thị nhưng JS CHƯA xác nhận (lạc quan). Rỗng = không có.
  /// Tồn tại để bỏ nháy: chờ một vòng bridge mới đổi highlight thì lens giật về ô
  /// cũ rồi mới sang ô mới — thấy rõ bằng mắt.
  NSString *_pendingKey;
  /// Index dưới ngón trong lúc kéo; -1 = không kéo.
  NSInteger _dragIndex;
  /// Ngón đang đặt trên bar (nhấn giữ HOẶC đang kéo) ⇒ lens ở trạng thái NỞ.
  BOOL _pressed;
  /// Pan đã nhận diện và chưa kết thúc. Bật ở `.began` (TRƯỚC ngưỡng slop riêng của ta),
  /// nên nó là cờ duy nhất nói được "cú chạm này đã thành cú vuốt" — `_dragIndex` bật
  /// muộn hơn nên không dùng thay được: giữa hai mốc đó có cửa sổ mà UIControl bị huỷ
  /// tracking và ta sẽ hiểu nhầm thành "nhấn rồi bỏ".
  BOOL _panActive;
}

+ (BOOL)isGlassAvailable
{
  // Ba lớp, cố ý dư: (1) compile-time có SDK; (2) runtime OS đủ mới; (3) class
  // CÓ THẬT và tạo được instance. Lớp (3) là lớp duy nhất đúng trên beta/seed
  // hoặc nền tảng mà UIKit không ship API này.
#if defined(__IPHONE_26_0)
  if (@available(iOS 26.0, *)) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    Class container = NSClassFromString(@"UIGlassContainerEffect");
    if (glass == nil || container == nil) return NO;
    // Thử dựng thật: class tồn tại mà khởi tạo thất bại thì vẫn coi là không có.
    UIVisualEffect *probe = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    return probe != nil;
  }
#endif
  return NO;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    _items = [NSMutableArray new];
    _itemProps = @[];
    _activeKey = @"";
    _cornerRadius = 32.0;
    _mergeSpacing = 12.0;
    _tintActive = UIColor.labelColor;
    _tintInactive = UIColor.secondaryLabelColor;
    _useGlass = [LTBBarView isGlassAvailable];

    // KHÔNG cắt. Hiệu ứng Liquid Glass của lens PHẢI tràn ra ngoài mép bar mới thấy
    // được: đo trên bản tham chiếu (App Store iOS 26 + clip user gửi 29/07), khối kính
    // chọn phình cao hơn cả platter và mang viền tán sắc cầu vồng — phần tràn đó CHÍNH
    // LÀ phần nhìn thấy. Bản trước đặt YES nên cắt sạch, và triệu chứng là "lướt được
    // nhưng không có vùng chọn, không có morph".
    //
    // Vì sao an toàn (khác bug 02/07 "glass phủ toàn màn hình"): ca đó là một WRAPPER
    // mang chính UIGlassEffect và có frame cỡ màn hình. Ở đây `self` là UIView TRƠN,
    // không mang effect nào; mọi view mang kính (`_container`, `_platter`, `_lens`) đều
    // có frame bám bounds của bar hoặc nhỏ hơn. Không có đường nào để kính lan ra màn.
    self.clipsToBounds = NO;

    _itemsHost = [UIView new];
    _pendingKey = @"";
    _dragIndex = -1;

    // Pan trên CHÍNH bar, không trên từng item: kéo là hành vi của cả thanh. Sống
    // chung được với tap của LTBItemView (UIControl) vì pan chỉ nhận diện sau khi
    // ngón đi quá ngưỡng — lúc đó UIKit tự huỷ tracking của UIControl, đúng khuôn
    // button-trong-scrollview. Nhờ vậy KHÔNG phải tắt userInteractionEnabled của
    // item, tức không mất tap + accessibility của UIControl.
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    // ⚠️ PHẢI để mặc định YES. Bản 0.6.0 đặt NO (nghĩ rằng cần thế để tap còn hoạt động)
    // và đó là BUG user báo 29/07: "vuốt từ icon 1 sang icon x thì giật về icon 1 rồi qua
    // icon x, liên tục, màn hình nháy, lâu dài break app".
    //
    // Vì `NO` nên khi pan đã nhận diện, `LTBItemView` (UIControl) VẪN hoàn tất tracking và
    // vẫn bắn `TouchUpInside` lúc nhả ⇒ MỘT cú vuốt phát HAI lần `onSelect`: một của item
    // nơi ngón BẮT ĐẦU (icon 1) và một của item cuối dưới ngón (icon X). Mini-app đổi tab
    // hai lần mỗi cú vuốt ⇒ mount/unmount dây ⇒ nháy màn, và tích lại thì gãy app.
    //
    // Với YES, UIKit gửi touchesCancelled cho control ngay khi pan thắng ⇒ không có
    // TouchUpInside ⇒ đúng một event mỗi cú vuốt. Tap vẫn chạy bình thường vì không có
    // di chuyển thì pan không bao giờ nhận diện — đúng khuôn button-trong-scrollview.
    [self addGestureRecognizer:_pan];

    if (_useGlass) {
      [self buildGlass];
    } else {
      [self buildFallback];
    }

    [self addSubview:_itemsHost];
    // itemsHost phải là subview CUỐI của container để icon nằm TRÊN nền.
    if (_container != nil) {
      [_container.contentView addSubview:_itemsHost];
    }
  }
  return self;
}

- (void)buildGlass
{
  if (@available(iOS 26.0, *)) {
    UIGlassContainerEffect *containerEffect = [UIGlassContainerEffect new];
    containerEffect.spacing = _mergeSpacing;
    _container = [[UIVisualEffectView alloc] initWithEffect:containerEffect];
    [self addSubview:_container];

    // ⚠️ Platter nằm NGOÀI `_container`, KHÔNG phải trong contentView của nó.
    //
    // Lý do, lấy nguyên văn từ header `UIGlassEffect.h`: container "render ALL glass
    // elements in ONE COMBINED view". Mà lens nằm TRỌN trong platter ⇒ hợp nhất hai
    // hình cho ra đúng hình platter ⇒ lens KHÔNG CÒN hình riêng để phình. Đó là lý do
    // device 29/07 chỉ thấy một pill phẳng có màu (chính `tintColor` của lens hiện
    // qua) mà không có khối kính, không có morph — hai lần đoán trước của tôi
    // (clipsToBounds, rồi bỏ kính dùng UIView) đều không phải gốc.
    //
    // Đặt platter ngoài container ⇒ lens là glass element DUY NHẤT trong container ⇒
    // không có gì hấp thụ nó ⇒ nó giữ hình riêng và `interactive` có chỗ tác dụng.
    // Hai lớp kính xếp lên nhau đúng như bản Apple: nền kính + khối kính chọn.
    _platter = [[UIVisualEffectView alloc]
        initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
    _platter.layer.cornerCurve = kCACornerCurveContinuous;
    _platter.clipsToBounds = YES;
    [self insertSubview:_platter belowSubview:_container];

    // Vùng chọn = KHỐI KÍNH THẬT, để UIKit tự lo morph. Đây là điểm cốt lõi: hiệu
    // ứng "bóng nước" khi lướt là do UIGlassEffect + UIGlassContainerEffect sinh ra,
    // KHÔNG phải do ta vẽ. Bằng chứng nó là kính native: mép khối mang tán sắc cầu
    // vồng — không view tự vẽ nào tạo được (xem App Store iOS 26, tab "Games").
    UIGlassEffect *lensEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    // `interactive` = khối kính phản ứng theo chạm (nhún/phình). Chính nó tạo cảm
    // giác chất lỏng khi ngón kéo.
    lensEffect.interactive = YES;
    UIVisualEffectView *glassLens = [[UIVisualEffectView alloc] initWithEffect:lensEffect];
    glassLens.layer.cornerCurve = kCACornerCurveContinuous;
    // KHÔNG clip: phần phình của morph nằm NGOÀI bounds của lens.
    glassLens.clipsToBounds = NO;
    glassLens.userInteractionEnabled = NO;  // không được ăn tap của item nằm trên
    glassLens.hidden = YES;
    _lens = glassLens;
    // Lens nằm TRÊN platter, DƯỚI itemsHost (itemsHost được add sau, ở init).
    [_container.contentView addSubview:_lens];
    // Container cũng không được cắt, nếu không nó chặn đúng phần tràn vừa mở ở `self`.
    _container.clipsToBounds = NO;
  }
}

- (void)buildFallback
{
  _fallbackBg = [UIView new];
  _fallbackBg.backgroundColor = LTBFallbackFill();
  _fallbackBg.layer.cornerCurve = kCACornerCurveContinuous;
  _fallbackBg.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
  _fallbackBg.layer.borderColor = LTBFallbackEdge().CGColor;
  _fallbackBg.clipsToBounds = YES;
  [self addSubview:_fallbackBg];

  // Nhánh KHÔNG kính (iOS < 26): chỉ cần VÙNG CHỌN, không cần hiệu ứng (USER chốt
  // 29/07). Pill tint phẳng, trượt sang ô mới — không morph, không giãn. Cố mô phỏng
  // "bóng nước" bằng UIView ở đây là làm giả một thứ mà nền tảng không có.
  UIView *plainLens = [UIView new];
  plainLens.backgroundColor = LTBDefaultLensFill();
  plainLens.layer.cornerCurve = kCACornerCurveContinuous;
  plainLens.userInteractionEnabled = NO;
  plainLens.hidden = YES;
  _lens = plainLens;
  // Con của SELF, không của `_fallbackBg` — thằng đó clip theo bounds.
  [self addSubview:_lens];
}

// borderColor là CGColor nên KHÔNG tự đổi theo trait — phải gán lại. Thiếu bước
// này thì đổi Dark/Light lúc đang chạy sẽ để lại hairline của mode cũ.
- (void)traitCollectionDidChange:(UITraitCollection *)previous
{
  [super traitCollectionDidChange:previous];
  if (_fallbackBg != nil &&
      self.traitCollection.userInterfaceStyle != previous.userInterfaceStyle) {
    _fallbackBg.layer.borderColor = LTBFallbackEdge().CGColor;
  }
}

#pragma mark - Setters

- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items
{
  _itemProps = items ?: @[];
  [self syncItemCount:_itemProps.count];
  [self reconfigureItems];
  [self setNeedsLayout];
}

- (void)setActiveKey:(NSString *)key
{
  NSString *next = key ?: @"";
  // `had`/`changed` PHẢI tính trước khi ghi `_activeKey`.
  const BOOL had = _activeKey.length > 0;
  const BOOL changed = ![next isEqualToString:_activeKey];
  // BẤT BIẾN: ghi `_activeKey` TRƯỚC guard echo lạc hậu. Ghi sau thì ca "JS phủ quyết" gãy
  // vĩnh viễn — echo phủ quyết bị guard bỏ qua, watchdog revert về một tab CỔ, và JS không
  // đổi `active` nữa nên không còn echo nào tới sửa.
  _activeKey = next;

  // ECHO LẠC HẬU — cùng bug, cùng cách chặn với `LTBSystemBar::setActiveKey:` (xem giải thích
  // dài ở đó). Bản trước xoá `_pendingKey` + huỷ watchdog VÔ ĐIỀU KIỆN ngay đầu hàm, nên câu
  // trả lời của một cú tap đã bị cú tap sau thay thế vẫn kéo lens về tab người ta vừa bỏ:
  // tap item 1 → tap item 2 → echo(1) về trước ⇒ lens "về lại item 1". Nhánh này còn có
  // vuốt-để-chọn nên guard phủ luôn ca vuốt-rồi-vuốt-lại.
  if (_outstandingEchoes > 0) _outstandingEchoes--;
  if (_pendingKey.length > 0 &&
      (_outstandingEchoes > 0 || ![next isEqualToString:_pendingKey])) {
    return;
  }

  // JS đã trả lời đúng cú tap mới nhất ⇒ sự thật về lại tay nó. Huỷ watchdog: nó chỉ tồn tại
  // cho trường hợp JS IM LẶNG.
  const BOOL wasPending = _pendingKey.length > 0;
  _outstandingEchoes = 0;
  _pendingKey = @"";
  [self cancelPendingRevert];
  if (!changed && !wasPending) return;
  [self reconfigureItems];
  // Đang kéo thì KHÔNG giật lens về: ngón vẫn đang giữ nó. `setActive` có thể tới
  // giữa lúc kéo (JS đổi tab vì lý do khác) — lúc đó vị trí ngón mới là sự thật thị giác.
  if (_dragIndex < 0) [self layoutLensAndPress:had];
}

/// Tab mà bar ĐANG VẼ. Khác `_activeKey` khi đang chờ JS xác nhận (tap/nhả vuốt).
- (NSString *)visualActiveKey
{
  return _pendingKey.length > 0 ? _pendingKey : _activeKey;
}

/// Hiện `key` ngay (lạc quan) rồi hẹn giờ trả về sự thật nếu JS không xác nhận.
- (void)showPendingKey:(NSString *)key
{
  if (key.length == 0) return;
  _pendingKey = key;
  [self reconfigureItems];
  [self cancelPendingRevert];
  [self performSelector:@selector(revertPendingKey)
             withObject:nil
             afterDelay:kPendingRevertDelay];
}

- (void)cancelPendingRevert
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                          selector:@selector(revertPendingKey)
                                            object:nil];
}

- (void)revertPendingKey
{
  if (_pendingKey.length == 0) return;
  _pendingKey = @"";
  // Reset bộ đếm ở đây là thứ chặn drift của nó (re-tap bắn `onSelect` mà JS không echo lại
  // ⇒ đếm dư). Nhờ vậy lệch chỉ sống trong một cửa sổ `kPendingRevertDelay`.
  _outstandingEchoes = 0;
  [self reconfigureItems];
  if (_dragIndex < 0) [self layoutLensAndPress:YES];
}

- (void)dealloc
{
  // `performSelector:afterDelay:` RETAIN target ⇒ không có đường gọi vào view đã chết: còn
  // perform treo thì `dealloc` chưa chạy được. Huỷ ở đây chỉ để view không bị neo sống thêm
  // 600 ms. (Bản trước viết ngược nửa sau — xem cùng chỗ ở `LTBSystemBar.mm`.)
  [self cancelPendingRevert];
}

- (void)setTintActive:(UIColor *)active inactive:(UIColor *)inactive
{
  if (active != nil) _tintActive = active;
  if (inactive != nil) _tintInactive = inactive;
  [self reconfigureItems];
}

/// Màu vùng chọn. Theme sống ở JS nên phía gọi truyền xuống; nil ⇒ giữ màu hiện tại
/// (KHÔNG tô trong suốt — mất vùng chọn mà không có lỗi ở đâu là đúng lớp lỗi im lặng
/// vừa mất một buổi để truy).
- (void)setLensColor:(UIColor *)color
{
  if (color == nil) return;
  if (!_useGlass) {
    _lens.backgroundColor = color;
    return;
  }
  if (@available(iOS 26.0, *)) {
    // Nhánh kính: màu đi vào `tintColor` của effect, KHÔNG vào backgroundColor —
    // backgroundColor sẽ đè lên vật liệu kính và giết luôn tán sắc ở mép.
    // Dựng effect mới ở đây là có kiểm soát: chỉ khi màu đổi thật, tức gần như không
    // bao giờ sau lần đầu. (Gán `.effect` MỖI LẦN đổi tint là đúng lỗi đã giết wrapper
    // thứ ba hồi 02/07 — đừng gọi hàm này trong vòng render.)
    UIGlassEffect *e = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    e.interactive = YES;
    e.tintColor = color;
    ((UIVisualEffectView *)_lens).effect = e;
  }
}

- (void)setMergeSpacing:(CGFloat)spacing
{
  if (spacing == _mergeSpacing) return;
  _mergeSpacing = spacing;
  if (@available(iOS 26.0, *)) {
    if (_container != nil) {
      // Dựng effect MỚI ở đây là có kiểm soát: chỉ khi giá trị đổi thật (gần như
      // không bao giờ sau lần đầu). Gán `.effect` mỗi lần đổi tint là đúng lỗi đã
      // giết wrapper thứ ba — tint ở đây nằm trên item view, không trên kính.
      UIGlassContainerEffect *e = [UIGlassContainerEffect new];
      e.spacing = spacing;
      _container.effect = e;
    }
  }
}

- (void)setBarCornerRadius:(CGFloat)radius
{
  if (radius == _cornerRadius) return;
  _cornerRadius = radius;
  [self setNeedsLayout];
}

- (void)syncItemCount:(NSUInteger)count
{
  while (_items.count > count) {
    [_items.lastObject removeFromSuperview];
    [_items removeLastObject];
  }
  while (_items.count < count) {
    LTBItemView *v = [LTBItemView new];
    [v addTarget:self action:@selector(onItemTapped:) forControlEvents:UIControlEventTouchUpInside];
    // TouchDown là nguồn DUY NHẤT bắt được "ngón vừa đụng" cho cú TAP: pan chỉ nhận diện
    // sau khi ngón đã đi quá ngưỡng, nên nếu chỉ dựa vào pan thì tap không bao giờ nở.
    [v addTarget:self action:@selector(onItemPressDown:) forControlEvents:UIControlEventTouchDown];
    [v addTarget:self
                action:@selector(onItemPressAborted:)
      forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_itemsHost addSubview:v];
    [_items addObject:v];
  }
}

- (void)reconfigureItems
{
  NSString *visual = [self visualActiveKey];
  NSUInteger i = 0;
  for (NSDictionary<NSString *, NSString *> *p in _itemProps) {
    if (i >= _items.count) break;
    LTBItemView *v = _items[i++];
    NSString *key = p[@"key"] ?: @"";
    v.itemKey = key;
    [v configureWithLabel:p[@"label"] ?: @""
                 sfSymbol:p[@"sfSymbol"] ?: @""
         sfSymbolSelected:p[@"sfSymbolSelected"] ?: @""
                 imageURL:p[@"imageUrl"] ?: @""
                    badge:p[@"badge"] ?: @""
                 selected:[key isEqualToString:visual]
                tintColor:_tintActive
        inactiveTintColor:_tintInactive];
  }
}

/// Ngón vừa đụng một item: nở NGAY, và dời lens sang ô đó luôn (lạc quan) để phản hồi
/// không trễ một vòng bridge.
- (void)onItemPressDown:(LTBItemView *)sender
{
  if (sender.itemKey == nil) return;
  if (![sender.itemKey isEqualToString:[self visualActiveKey]]) {
    // Qua `showPendingKey:` (không gán trực tiếp) để watchdog 600ms tự dọn nếu cú chạm
    // này rốt cuộc không chọn gì — đó là cách self-heal, thay cho việc giật lens về ngay
    // ở `onItemPressAborted:` (giật ngay sẽ nháy đúng lúc pan vừa thắng).
    [self showPendingKey:sender.itemKey];
    [self layoutLensAndPress:YES];
  }
  [self setPressed:YES];
}

/// Ngón rời khỏi item mà KHÔNG chọn (trượt ra ngoài, hoặc hệ huỷ touch — bao gồm lúc pan
/// thắng, vì `cancelsTouchesInView` = YES).
- (void)onItemPressAborted:(LTBItemView *)sender
{
  // Đang vuốt ⇒ UIControl bị huỷ tracking là CHUYỆN BÌNH THƯỜNG. Thu lens ở đây sẽ làm nó
  // nháy đúng lúc bắt đầu kéo. Nếu thứ tự event làm cờ chưa kịp bật thì cũng chỉ shrink
  // 1 frame — `.changed` ngay sau đó bật `_pressed` lại.
  if (_panActive || _dragIndex >= 0) return;
  [self setPressed:NO];
  // KHÔNG revert ở đây: watchdog của `showPendingKey:` lo phần đó sau 600ms.
}

- (void)onItemTapped:(LTBItemView *)sender
{
  if (sender.itemKey == nil) return;
  // Lưới thứ hai cho bug double-emit: với `cancelsTouchesInView = YES` thì UIKit đã không
  // gửi TouchUpInside sau khi pan thắng, nhưng tương tác gesture ↔ control là chỗ dễ đổi
  // hành vi giữa các bản iOS, và giá của việc lọt là app nháy rồi gãy.
  if (_panActive || _dragIndex >= 0) return;
  [self setPressed:NO];
  // Hiện ngay rồi mới báo JS: chờ vòng bridge thì lens trễ một nhịp so với ngón.
  [self showPendingKey:sender.itemKey];
  [self layoutLensAndPress:YES];
  // Đếm NGAY TRƯỚC khi bắn, trong cùng nhánh — xem `_outstandingEchoes`. Đếm ở
  // `showPendingKey:` sẽ lệch pha, vì có đường chỉ hiện pending mà không báo JS (kéo ngang
  // trong `onPan`).
  if (self.onSelect != nil) {
    _outstandingEchoes++;
    self.onSelect(sender.itemKey);
  }
}

#pragma mark - Vuốt để chọn

/// Index của item tại toạ độ x. Kẹp vào [0, n-1] để kéo ra ngoài mép không mất bám.
- (NSInteger)indexAtX:(CGFloat)x
{
  const NSUInteger n = _items.count;
  if (n == 0 || self.bounds.size.width <= 0) return -1;
  const CGFloat itemW = self.bounds.size.width / (CGFloat)n;
  const NSInteger raw = (NSInteger)floor(x / itemW);
  return MAX(0, MIN((NSInteger)n - 1, raw));
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
  const NSUInteger n = _items.count;
  if (n == 0) return;
  const CGFloat x = [g locationInView:self].x;
  const NSInteger idx = [self indexAtX:x];
  if (idx < 0) return;

  switch (g.state) {
    case UIGestureRecognizerStateBegan:
    case UIGestureRecognizerStateChanged: {
      // Bật NGAY, trước ngưỡng slop riêng ở dưới: đây là mốc "cú chạm này đã thành cú
      // vuốt", và `onItemTapped:`/`onItemPressAborted:` đọc nó để không bắn event thứ hai.
      _panActive = YES;
      // Ngưỡng slop: pan của UIKit đã có ngưỡng riêng, nhưng nó tính theo mọi
      // hướng. Ở đây chỉ quan tâm trục X — kéo dọc (vd vuốt lên để đóng app) không
      // được kéo lens đi ngang.
      if (_dragIndex < 0 && fabs([g translationInView:self].x) < kDragSlop) return;
      _dragIndex = idx;
      // Kéo cũng là "ngón đang đặt trên bar" ⇒ giữ trạng thái NỞ. Đặt trước
      // `layoutLensFollowingX:` để frame đầu tiên của cú kéo đã là hình nở.
      _pressed = YES;
      NSString *key = _items[(NSUInteger)idx].itemKey ?: @"";
      // Highlight đi theo ngón NGAY, nhưng KHÔNG báo JS (USER chốt: đổi màn khi nhả).
      // Dùng pending thay vì _activeKey để không tự ý ghi sự thật.
      if (![key isEqualToString:[self visualActiveKey]]) {
        _pendingKey = key;
        [self reconfigureItems];
      }
      [self layoutLensFollowingX:x];
      break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: {
      _panActive = NO;
      if (_dragIndex < 0) {
        // Pan có nhận diện nhưng chưa vượt slop trục X (vd vuốt dọc) ⇒ không chọn gì.
        // Phải thu lens ở đây: UIControl đã bị huỷ tracking nên `onItemPressAborted:`
        // đã chạy và bị cờ `_panActive` chặn — không ai thu hộ.
        [self setPressed:NO];
        return;
      }
      NSString *key = _items[(NSUInteger)_dragIndex].itemKey ?: @"";
      _dragIndex = -1;
      // Nhả tay ⇒ thu về. Gán thẳng cờ (không qua `setPressed:`) rồi để `layoutLensAndPress:`
      // lo cả hai: lens về ô nghỉ TỨC THÌ, còn bar thu lại có animation. Không gọi
      // `setPressed:NO` ở đây vì nó sẽ dựng thêm một khối animation nữa cho cùng transform —
      // hai khối chồng nhau ở đúng mốc này là chỗ từng giật.
      _pressed = NO;
      // Huỷ/thất bại cũng CHỐT theo ô cuối dưới ngón: người dùng đã thấy highlight ở
      // đó, trả về ô cũ sẽ đọc thành "app ăn mất cú vuốt".
      [self showPendingKey:key];
      [self layoutLensAndPress:YES];
      if (self.onSelect != nil && key.length > 0) {
        _outstandingEchoes++;
        self.onSelect(key);
      }
      break;
    }
    default:
      break;
  }
}

#pragma mark - Layout

- (void)layoutSubviews
{
  [super layoutSubviews];
  const CGRect b = self.bounds;

  // ⚠️ Container = ĐÚNG khung bar. ĐỪNG nới ra ngoài.
  //
  // Bản 0.7.0 nới 28pt mỗi mép với giả thuyết "phần khối kính nhô ra ngoài không có
  // backdrop nên bị đổ màu phẳng". Đã thử trên device 29/07: KHÔNG ăn — phần tràn vẫn
  // phẳng, và còn tệ hơn (thành một panel tối đặc thò ra ngoài mép bar). Giả thuyết đó
  // SAI, hoặc chưa đủ; đừng thử lại theo hướng này mà không có bằng chứng mới.
  //
  // Sự thật đã đo được, giữ làm mốc: lens render ĐÚNG vật liệu kính khi nó nằm TRONG
  // khung bar (user duyệt bản 0.5.0: "hiệu ứng đúng rồi"); chỉ phần VƯỢT RA NGOÀI khung
  // mới thành phẳng và che nội dung.
  _container.frame = b;
  _platter.frame = b;
  _platter.layer.cornerRadius = _cornerRadius;
  _fallbackBg.frame = b;
  _fallbackBg.layer.cornerRadius = _cornerRadius;
  _itemsHost.frame = b;

  const NSUInteger n = _items.count;
  if (n == 0) return;
  const CGFloat itemW = b.size.width / (CGFloat)n;
  for (NSUInteger i = 0; i < n; i++) {
    _items[i].frame = CGRectMake(floor(itemW * i), 0, ceil(itemW), b.size.height);
  }
  [self layoutLensAndPress:NO];
}

- (UIView *_Nullable)activeLens
{
  return _lens;
}

/// Hình nghỉ của lens tại một item — CHƯA tính trạng thái nhấn.
///
/// Không cần bù hệ toạ độ: container đúng khung bar và `_itemsHost` đúng `self.bounds`,
/// nên hệ của item trùng hệ của lens. (Bản 0.7.0 nới container nên phải bù — đã bỏ.)
- (CGRect)lensRestRectForIndex:(NSInteger)idx
{
  return CGRectInset(_items[(NSUInteger)idx].frame, kLensInsetX, kLensInsetY);
}

/// Hình lens THỰC TẾ: hình nghỉ, nở thêm nếu ngón đang đặt trên bar.
/// Một nguồn duy nhất cho cả ba đường (nghỉ · nhấn giữ · kéo) — tính nở ở từng chỗ gọi
/// là cách chắc chắn để một đường quên nở mà không ai thấy.
- (CGRect)lensRectForIndex:(NSInteger)idx
{
  const CGRect rest = [self lensRestRectForIndex:idx];
  if (!_pressed) return rest;
  return CGRectInset(rest, -kLensPressGrowX, -kLensPressGrowY);
}

/// Đổi trạng thái nhấn rồi vẽ lại lens. Không đổi ⇒ không làm gì (tránh animation dư
/// khi UIControl bắn TouchDown nhiều lần).
- (void)setPressed:(BOOL)pressed
{
  if (_pressed == pressed) return;
  _pressed = pressed;
  UIView *lens = [self activeLens];
  if (lens == nil || lens.hidden) return;
  const NSInteger idx = _dragIndex >= 0 ? _dragIndex : [self activeIndex];
  if (idx < 0) return;
  // Giữ nguyên TÂM đang có (lúc kéo, tâm dính ngón chứ không phải tâm ô nghỉ) và chỉ
  // nở/thu quanh nó — nếu không, nhấn xuống sẽ làm lens nhảy về giữa ô.
  const CGFloat cx = CGRectGetMidX(lens.frame);
  const CGRect target = [self lensRectForIndex:idx];
  const CGAffineTransform barT =
      pressed ? CGAffineTransformMakeScale(kBarPressScale, kBarPressScale)
              : CGAffineTransformIdentity;
  [UIView animateWithDuration:kLensPressDuration
                        delay:0
       usingSpringWithDamping:kLensPressDamping
        initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
                     // Cả bar phóng to — mảnh chính của hiệu ứng, xem `kBarPressScale`.
                     self.transform = barT;
                     lens.frame = CGRectMake(cx - target.size.width / 2.0, target.origin.y,
                                             target.size.width, target.size.height);
                     [self applyCapsuleRadiusTo:lens];
                   }
                   completion:nil];
}

/// Capsule: bo góc luôn bằng nửa chiều cao HIỆN TẠI. Phải gán mỗi lần đổi frame vì
/// lúc kéo lens bị bẹp dọc — giữ radius cũ sẽ ra hình viên thuốc méo.
- (void)applyCapsuleRadiusTo:(UIView *)lens
{
  // Chặn trần: nửa chiều cao trên khối đã nở (~70pt) cho ra hình gần TRÒN, đọc thành
  // elip chứ không phải capsule ôm ô tab (user báo 29/07).
  lens.layer.cornerRadius = MIN(kLensMaxRadius, lens.bounds.size.height / 2.0);
}

/// Lens ĐI THEO NGÓN. Chỉ đổi VỊ TRÍ, giữ nguyên kích thước.
///
/// Cố ý KHÔNG tự giãn/bẹp: trên iOS 26 hiệu ứng chất lỏng do UIGlassEffect sinh ra,
/// tự vẽ thêm là hai animation đánh nhau — và bản tự vẽ không bao giờ có tán sắc ở mép
/// nên nó lộ ra là đồ giả. Trên nhánh không kính thì USER chốt KHÔNG cần hiệu ứng, chỉ
/// cần vùng chọn. Cả hai đường đều dẫn tới: chỉ dời chỗ.
///
/// Không bọc trong khối animation: mỗi frame một vị trí — đó chính là cảm giác dính ngón.
- (void)layoutLensFollowingX:(CGFloat)x
{
  UIView *lens = [self activeLens];
  if (lens == nil || _dragIndex < 0) return;

  // Đang kéo ⇒ luôn ở trạng thái NỞ (`lensRectForIndex:` lo phần đó).
  const CGRect r = [self lensRectForIndex:_dragIndex];
  // Tâm dính ngón, kẹp theo hình ĐÃ NỞ để lens không vượt khỏi platter — phần vượt ra
  // ngoài khung render thành miếng dán phẳng (đã gặp 2 lần trên device).
  const CGFloat minCX = kLensInsetX + r.size.width / 2.0;
  const CGFloat maxCX = self.bounds.size.width - kLensInsetX - r.size.width / 2.0;
  const CGFloat cx = maxCX < minCX ? self.bounds.size.width / 2.0 : MAX(minCX, MIN(maxCX, x));

  lens.hidden = NO;
  lens.frame = CGRectMake(cx - r.size.width / 2.0, r.origin.y, r.size.width, r.size.height);
  [self applyCapsuleRadiusTo:lens];
}

/// Đặt lens về ô nghỉ của tab đang chọn, và đồng bộ transform nhấn của bar.
///
/// ⚠️ Tên hàm cố ý KHÔNG còn là `layoutLensAnimated:`: từ 0.8.3, lens dời chỗ **LUÔN TỨC THÌ**
/// (USER chốt 30/07 — animation 0,32s đọc thành "chậm"). Tham số chỉ còn điều khiển hiệu ứng
/// NHẤN (cả bar phóng `kBarPressScale` rồi thu), thứ USER giữ lại. Giữ tên cũ là để một cái tên
/// nói sai nằm lại trong code — đúng lớp lỗi đã ngốn cả ngày 30/07 ở `LiquidTabsModule`
/// ("lần gọi sau sẽ thử lại").
///
/// Vì sao phải TÁCH hai việc thay vì chỉ truyền `animated:NO`: bản trước gán `lens.frame` và
/// `self.transform` trong CÙNG một khối animation — cố ý, vì lúc nhả vuốt cần "một animation duy
/// nhất vừa dời chỗ vừa thu" (hai khối chồng nhau thì giật). Tắt khối đó để lens tức thì sẽ tắt
/// luôn hiệu ứng thu của bar ⇒ mất phản hồi khi chạm, tức làm cả thứ USER KHÔNG yêu cầu.
- (void)layoutLensAndPress:(BOOL)animatePress
{
  UIView *lens = [self activeLens];
  if (lens == nil) return;
  // Đang kéo thì ngón là chủ — mọi nguồn khác (setItems, layoutSubviews, setActive)
  // không được giành quyền đặt frame, nếu không lens sẽ giật về ô nghỉ giữa cú vuốt.
  if (_dragIndex >= 0) return;

  const NSInteger idx = [self activeIndex];
  if (idx < 0 || _items.count == 0 || CGRectIsEmpty(self.bounds)) {
    lens.hidden = YES;
    return;
  }
  const CGRect target = [self lensRectForIndex:idx];
  // Transform của bar đồng bộ NGAY TẠI ĐÂY, cùng chỗ với frame của lens: hàm này là
  // đường mà mọi nguồn (setActive, tap, nhả vuốt, layoutSubviews) đều đi qua, nên đặt ở
  // đây là cách chắc chắn không có đường nào phóng bar mà quên thu.
  const CGAffineTransform barT =
      _pressed ? CGAffineTransformMakeScale(kBarPressScale, kBarPressScale)
               : CGAffineTransformIdentity;
  lens.hidden = NO;

  // Lens: TỨC THÌ, không điều kiện. Gán ngoài mọi khối animation nên vùng chọn xuất hiện ngay ở
  // ô mới, không trượt qua các ô giữa. `applyCapsuleRadiusTo:` đi liền vì lúc vừa nhả vuốt lens
  // đang ở hình NỞ (bẹp dọc) — không gán lại radius thì ra viên thuốc méo.
  lens.frame = target;
  [self applyCapsuleRadiusTo:lens];

  if (!animatePress) {
    self.transform = barT;
    return;
  }
  // Còn animate DUY NHẤT transform của bar — đó chính là hiệu ứng nhấn. Dùng hằng `…Press…`
  // (không phải hằng lens cũ) vì thứ đang chạy ở đây là hiệu ứng nhấn, không phải dời lens.
  [UIView animateWithDuration:kLensPressDuration
                        delay:0
       usingSpringWithDamping:kLensPressDamping
        initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
                     self.transform = barT;
                   }
                   completion:nil];
}

/// Theo tab ĐANG VẼ, không theo `_activeKey`: lúc chờ JS xác nhận thì lens phải nằm
/// ở ô người dùng vừa chọn, nếu không nó giật về ô cũ rồi mới sang — thấy rõ.
- (NSInteger)activeIndex
{
  NSString *visual = [self visualActiveKey];
  for (NSUInteger i = 0; i < _items.count; i++) {
    if ([_items[i].itemKey isEqualToString:visual]) return (NSInteger)i;
  }
  return -1;
}

@end
