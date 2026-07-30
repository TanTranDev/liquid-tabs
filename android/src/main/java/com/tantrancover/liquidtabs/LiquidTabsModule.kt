package com.tantrancover.liquidtabs

import android.graphics.Color
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.module.annotations.ReactModule

/**
 * TurboModule Android — cửa duy nhất để JS điều khiển bar.
 *
 * Bar được gắn vào **decor view của Activity**, KHÔNG vào cây view của React. Đó
 * là điểm cốt tử giống bên iOS: mini-app reload/OTA thì React root bị thay, bar
 * vẫn nguyên. Đổi lại, không ai tự ẩn nó khi màn unmount ⇒ JS phải gọi
 * `setVisible(false)`, và host phải ẩn khi RN world tear down.
 */
@ReactModule(name = LiquidTabsModule.NAME)
class LiquidTabsModule(reactContext: ReactApplicationContext) :
  NativeLiquidTabsSpec(reactContext), LifecycleEventListener {

  companion object {
    const val NAME = "LiquidTabs"
  }

  /**
   * Chữa trạng thái hiện/ẩn khi app trở lại foreground.
   *
   * Vì sao KHÔNG đủ nếu chỉ dựa vào "lệnh kế tiếp tự chữa": app ở nền (Activity null) mà JS điều
   * hướng khỏi màn có tab ⇒ `setVisible(false)` rơi. Lên foreground rồi thì có thể KHÔNG còn lệnh
   * nào tới nữa — phía gọi edge-triggered, và ở màn không-có-tab thì không ai gửi
   * `setTabs`/`setActive`/`setGeometry`. Thiếu hook này thì bar vẫn hiện sai, tức đúng triệu chứng
   * gốc, chỉ vào bằng cửa hẹp hơn. Heal do MÔI TRƯỜNG kích, không ăn theo một lệnh không liên quan.
   */
  override fun onHostResume() {
    if (!synchronized(stateLock) { visiblePending }) return
    // CHỈ chữa, KHÔNG dựng: `onUi` → `ensureBar` sẽ TẠO bar nếu chưa có. Chưa có bar thì cũng chẳng
    // có gì sai trên màn để chữa — lệnh JS kế tiếp sẽ dựng với `visibility` đúng ngay từ đầu.
    if (bar == null) return
    onUi { /* bước tự chữa nằm trong `onUi`; block này cố ý rỗng */ }
  }

  override fun onHostPause() = Unit

  override fun onHostDestroy() = Unit

  private var bar: LTBBarView? = null

  /**
   * Khoá cho CẶP (`visible`, `visiblePending`).
   *
   * `@Volatile` một mình KHÔNG đủ: hố không phải visibility mà là **check-then-act xuyên thread**.
   * Bước tự chữa đọc cờ, đọc `visible`, rồi chạy ba lệnh view — cửa sổ đó không nhỏ, và một
   * `setVisible` mới từ thread JS xen vào giữa sẽ bị bước "hạ cờ" của heal ĐÈ MẤT; nếu lệnh mới đó
   * rồi lại rơi thì không còn đường chữa nào. Đúng bug gốc, vào qua chính cơ chế chữa.
   *
   * Vì sao KHÔNG bọc `setVisible` trong `runOnUiThread` cho giống iOS: `UiThreadUtil.runOnUiThread`
   * LUÔN post (cả khi đã ở UI thread), nên post lồng nhau sẽ ĐẢO thứ tự với lệnh khác —
   * `setVisible` post P1, `setTabs` post P2, P1 chạy rồi post P3 ⇒ `setTabs` áp TRƯỚC `setVisible`.
   * Đó là regression nặng hơn thứ đang sửa. iOS không gặp vì `route:` có fast path
   * `NSThread.isMainThread` nên chạy đồng bộ trong cùng một turn.
   */
  private val stateLock = Any()

  /** Chỉ đọc/ghi trong `synchronized(stateLock)` — xem doc của `stateLock`. */
  private var visible = false

  /**
   * `true` = trạng thái mong muốn `visible` CHƯA chắc đã áp được lên view.
   *
   * Bật lúc vào `setVisible`, chỉ hạ TRONG block của `onUi` — tức chỉ hạ khi lệnh thật sự chạy.
   * Lệnh bị bỏ vì thiếu Activity/decorView ⇒ cờ ở lại `true` ⇒ lệnh KẾ TIẾP bất kỳ sẽ tự chữa,
   * và `onHostResume` chữa cả khi KHÔNG có lệnh kế tiếp nào. Đây là thứ thay cho giả định sai
   * "lần gọi sau thử lại": phía gọi KHÔNG gửi lại `setVisible` vì nó là lệnh edge-triggered.
   *
   * Chỉ đọc/ghi trong `synchronized(stateLock)`.
   */
  private var visiblePending = false

  // Đăng ký SAU các property ở trên: `init` và property initializer chạy theo ĐÚNG thứ tự khai
  // báo, nên đặt trước chúng là đăng ký listener khi `visible`/`visiblePending` chưa khởi tạo.
  init {
    reactContext.addLifecycleEventListener(this)
  }
  private var heightPx = 0
  private var hInsetPx = 0
  private var bottomInsetPx = 0

  override fun getName() = NAME

  /**
   * Dựng bar + gắn vào decor view. Idempotent. Activity chưa có (gọi quá sớm) ⇒
   * trả null và KHÔNG dựng gì. Dựng vào một parent nil rồi "để đó" là đường sinh
   * bar mồ côi.
   *
   * ⚠️ Bản trước ghi "lần gọi sau thử lại" và ĐÓ LÀ GIẢ ĐỊNH SAI đã gây bug ở nhánh
   * iOS cùng hình dạng: nó đúng cho các lệnh phía gọi lặp lại mỗi lần render
   * (geometry, tint), nhưng SAI cho `setVisible` — lệnh đó EDGE-TRIGGERED, phía gọi
   * chỉ gửi khi trạng thái đổi, nên không có "lần gọi sau" nào. Một lệnh rơi vì
   * Activity đang tái tạo / app ở nền là lệch VĨNH VIỄN.
   *
   * Bù lại KHÔNG nằm ở hàm này — nó ở `onUi` (cờ `visiblePending`) và `onHostResume`. Đặt bước
   * tự chữa vào đây thì nó chạy cả trong CHÍNH lời gọi `setVisible(animated = true)` và snap mất
   * animation. Đừng "sửa" bằng cách chuyển nó lên đây.
   */
  private fun ensureBar(): LTBBarView? {
    val activity = reactApplicationContext.currentActivity ?: return null
    val decor = activity.window?.decorView as? ViewGroup ?: return null

    var view = bar
    if (view == null) {
      view = LTBBarView(activity)
      view.onSelect = { key ->
        emitOnTabSelected(Arguments.createMap().apply { putString("key", key) })
      }
      view.visibility =
        if (synchronized(stateLock) { visible }) android.view.View.VISIBLE
        else android.view.View.GONE
      bar = view
    }
    if (view.parent !== decor) {
      (view.parent as? ViewGroup)?.removeView(view)
      decor.addView(view, layoutParams())
    }
    // Luôn kéo lên trên cùng: React có thể thêm view (modal, dev overlay) sau bar.
    view.bringToFront()
    return view
  }

  private fun layoutParams(): FrameLayout.LayoutParams =
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      if (heightPx > 0) heightPx else dp(64f),
    ).apply {
      gravity = Gravity.BOTTOM
      leftMargin = hInsetPx
      rightMargin = hInsetPx
      bottomMargin = bottomInsetPx
    }

  /** Đã cảnh báo cho chuỗi rơi hiện tại chưa — chống spam khi app ở nền mà JS vẫn bắn lệnh. */
  private var warnedDrop = false

  /**
   * Nói ra khi một lệnh bị BỎ vì chưa phân giải được Activity/decorView.
   *
   * Vì sao phải có: đường này là false-negative IM LẶNG. Nhánh iOS cùng hình dạng đã gây bug thật
   * — thanh tab không ẩn khi mở app từ notification, không log, không crash, mất nhiều giờ mới lần
   * ra. Kết thúc như thành công khi thực ra chẳng làm gì là loại lỗi đắt nhất.
   */
  private fun warnDrop(why: String) {
    if (warnedDrop) return
    warnedDrop = true
    android.util.Log.w(
      NAME,
      "BỎ một lệnh — thiếu tiền đề: $why. Trạng thái hiện/ẩn sẽ được áp lại ở lệnh kế tiếp " +
        "hoặc ở onHostResume (cờ visiblePending); các lệnh KHÁC (setTabs/setTint/…) thì MẤT.",
    )
  }

  /**
   * `healVisibility = false` CHỈ dành cho chính lệnh `setVisible`.
   *
   * Vì sao cần tham số này thay vì tự chữa trong `ensureBar`: bước tự chữa gán thẳng `visibility`
   * (không animation). Đặt nó trong `ensureBar` thì nó chạy cả trong CHÍNH lời gọi
   * `setVisible(animated = true)` — snap tới trạng thái đích TRƯỚC khi block kịp chạy
   * `view.animate()` ⇒ `animated` mất tác dụng hoàn toàn. Mà `animated` mặc định của API JS là
   * `true`, nên đó sẽ là regression cho mọi consumer khác.
   */
  private inline fun onUi(healVisibility: Boolean = true, crossinline block: (LTBBarView) -> Unit) {
    if (reactApplicationContext.hasActiveReactInstance().not() &&
      reactApplicationContext.currentActivity == null
    ) {
      warnDrop("không có React instance đang hoạt động VÀ không có Activity")
      return
    }
    com.facebook.react.bridge.UiThreadUtil.runOnUiThread {
      val view = ensureBar()
      if (view == null) {
        warnDrop("ensureBar trả null — thiếu Activity hoặc decorView")
        return@runOnUiThread
      }
      warnedDrop = false
      // TỰ CHỮA: một lệnh `setVisible` trước đó đã bị bỏ (thiếu Activity) ⇒ áp lại trạng thái
      // mong muốn NGAY, nhân dịp lệnh này đã có view. Không có bước này thì `visible` và
      // `view.visibility` lệch VĨNH VIỄN, vì caller không gửi lại setVisible.
      //
      // Đọc-và-hạ-cờ phải ATOMIC (xem doc `stateLock`): tách ra thì một `setVisible` xen vào giữa
      // sẽ bị bước hạ cờ này đè mất ý muốn. Lấy giá trị ra ngoài lock rồi mới chạm view — giữ
      // critical section ngắn, không gọi UIKit/animator bên trong lock.
      var healTo: Boolean? = null
      if (healVisibility) {
        synchronized(stateLock) {
          if (visiblePending) {
            healTo = visible
            visiblePending = false
          }
        }
      }
      val target = healTo
      if (target != null) {
        // `cancel()` vì cùng lý do như nhánh `!animated` của `setVisible`: một animator còn bay từ
        // lệnh trước sẽ ghi đè `alpha` mà ta vừa đặt, và kết thúc ở giá trị CŨ.
        view.animate().cancel()
        view.alpha = if (target) 1f else 0f
        view.visibility = if (target) android.view.View.VISIBLE else android.view.View.GONE
      }
      block(view)
    }
  }

  // ── Spec

  /** Android KHÔNG có Liquid Glass — luôn false. Bar vẫn có (nền vẽ tay), nên
   *  `isAvailable` mới là thứ phía gọi dùng để quyết định. */
  override fun isGlassAvailable(): Boolean = false

  override fun isAvailable(): Boolean = true

  override fun setTabs(items: ReadableArray) {
    val parsed = ArrayList<LTBBarView.Item>(items.size())
    for (i in 0 until items.size()) {
      val m = items.getMap(i) ?: continue
      val key = m.getString("key") ?: ""
      if (key.isEmpty()) continue // không key ⇒ không tap được
      parsed.add(
        LTBBarView.Item(
          key = key,
          label = m.getString("label") ?: "",
          svg = m.getString("androidSvg") ?: "",
          svgSelected = m.getString("androidSvgSelected") ?: "",
          imageUrl = m.getString("imageUrl") ?: "",
          badge = m.getString("badge") ?: "",
        ),
      )
    }
    onUi { it.setItems(parsed) }
  }

  override fun setActive(key: String?) {
    val k = key ?: ""
    onUi { it.setActiveKey(k) }
  }

  override fun setVisible(visible: Boolean, animated: Boolean) {
    // Coi như CHƯA áp được, cho tới khi block dưới thật sự chạy. Lệnh bị bỏ vì thiếu Activity ⇒
    // cờ ở lại `true` ⇒ lệnh kế tiếp bất kỳ, hoặc `onHostResume`, sẽ tự chữa.
    synchronized(stateLock) {
      this.visible = visible
      visiblePending = true
    }
    onUi(healVisibility = false) { view ->
      // Hạ cờ đầu block — trước mọi `return@onUi` — vì tới được đây nghĩa là lệnh đã có view.
      //
      // CHỈ hạ khi ý muốn hiện tại vẫn đúng là cái lệnh NÀY mang: hai lệnh post liên tiếp thì block
      // của lệnh CŨ chạy trước, và nếu nó hạ cờ vô điều kiện rồi block của lệnh MỚI lại rơi (mất
      // Activity giữa hai lượt) thì ý muốn mới mất im lặng. So `visible` là đủ: khác ⇒ có lệnh mới
      // hơn chưa áp, để cờ lại cho nó.
      synchronized(stateLock) {
        if (this.visible == visible) visiblePending = false
      }
      if (!animated) {
        // HUỶ animator đang bay TRƯỚC khi ghi thẳng. Không huỷ là bug lệch-vĩnh-viễn:
        // `view.animate()` ghi lại `alpha` MỖI FRAME, nên một `setVisible(false, animated=true)`
        // rồi `setVisible(true, animated=false)` trong 200 ms sẽ kết thúc ở `alpha = 0f` trong khi
        // `visibility = VISIBLE` và module tin là đang hiện ⇒ bar VÔ HÌNH và không ai sửa lại
        // (phía gọi edge-triggered). `withEndAction` dưới chỉ gác `visibility`, KHÔNG gác `alpha`.
        view.animate().cancel()
        view.alpha = if (visible) 1f else 0f
        view.visibility = if (visible) android.view.View.VISIBLE else android.view.View.GONE
        return@onUi
      }
      if (visible) view.visibility = android.view.View.VISIBLE
      view.animate().alpha(if (visible) 1f else 0f).setDuration(200).withEndAction {
        // Chỉ ẩn khi trạng thái MONG MUỐN vẫn là ẩn — hai lệnh chồng nhau (ẩn rồi
        // hiện ngay) không được để callback cũ ẩn mất bar.
        if (!synchronized(stateLock) { this.visible }) view.visibility = android.view.View.GONE
      }.start()
    }
  }

  override fun setGeometry(
    height: Double,
    horizontalInset: Double,
    bottomInset: Double,
    cornerRadius: Double,
  ) {
    heightPx = dp(height.toFloat())
    hInsetPx = dp(horizontalInset.toFloat())
    bottomInsetPx = dp(bottomInset.toFloat())
    onUi { view ->
      view.layoutParams = layoutParams()
      view.setCornerRadius(dp(cornerRadius.toFloat()).toFloat())
      view.requestLayout()
    }
  }

  override fun setTint(activeHex: String?, inactiveHex: String?) {
    val a = parseHex(activeHex)
    val i = parseHex(inactiveHex)
    onUi { view -> view.setTint(a ?: Color.BLACK, i ?: Color.GRAY) }
  }

  override fun setLensColor(hex: String?) {
    // nil/hex sai ⇒ KHÔNG gọi xuống: view giữ màu hiện tại. Tô trong suốt ở đây là
    // mất vùng chọn mà không có lỗi ở đâu.
    parseHex(hex)?.let { c -> onUi { view -> view.setLensColor(c) } }
  }

  /** Android không có glass nên merge-spacing vô nghĩa — nhận rồi bỏ qua, KHÔNG
   *  ném lỗi: phía gọi dùng cùng một đoạn code cho hai nền tảng. */
  override fun setMergeSpacing(spacing: Double) = Unit

  /** Hex `#RRGGBB` / `#RRGGBBAA` → color. Chuỗi lạ ⇒ null để caller GIỮ màu cũ
   *  thay vì tô đen (đen im lặng là lỗi thị giác khó truy). */
  private fun parseHex(hex: String?): Int? {
    if (hex == null || (hex.length != 7 && hex.length != 9) || !hex.startsWith("#")) return null
    return try {
      if (hex.length == 7) Color.parseColor(hex)
      else {
        // Android muốn #AARRGGBB, hợp đồng của ta là #RRGGBBAA.
        val rgb = hex.substring(1, 7)
        val alpha = hex.substring(7, 9)
        Color.parseColor("#$alpha$rgb")
      }
    } catch (t: IllegalArgumentException) {
      null
    }
  }

  private fun dp(v: Float): Int =
    (v * reactApplicationContext.resources.displayMetrics.density).toInt()
}
