package com.tantrancover.liquidtabs

import android.graphics.Color
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import com.facebook.react.bridge.Arguments
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
  NativeLiquidTabsSpec(reactContext) {

  companion object {
    const val NAME = "LiquidTabs"
  }

  private var bar: LTBBarView? = null
  private var visible = false
  private var heightPx = 0
  private var hInsetPx = 0
  private var bottomInsetPx = 0

  override fun getName() = NAME

  /**
   * Dựng bar + gắn vào decor view. Idempotent. Activity chưa có (gọi quá sớm) ⇒
   * trả null và KHÔNG dựng gì: lần gọi sau thử lại. Dựng vào một parent nil rồi
   * "để đó" là đường sinh bar mồ côi.
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
      view.visibility = if (visible) android.view.View.VISIBLE else android.view.View.GONE
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

  private inline fun onUi(crossinline block: (LTBBarView) -> Unit) {
    if (reactApplicationContext.hasActiveReactInstance().not() &&
      reactApplicationContext.currentActivity == null
    ) {
      return
    }
    com.facebook.react.bridge.UiThreadUtil.runOnUiThread {
      ensureBar()?.let { block(it) }
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
    this.visible = visible
    onUi { view ->
      if (!animated) {
        view.alpha = if (visible) 1f else 0f
        view.visibility = if (visible) android.view.View.VISIBLE else android.view.View.GONE
        return@onUi
      }
      if (visible) view.visibility = android.view.View.VISIBLE
      view.animate().alpha(if (visible) 1f else 0f).setDuration(200).withEndAction {
        // Chỉ ẩn khi trạng thái MONG MUỐN vẫn là ẩn — hai lệnh chồng nhau (ẩn rồi
        // hiện ngay) không được để callback cũ ẩn mất bar.
        if (!this.visible) view.visibility = android.view.View.GONE
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
