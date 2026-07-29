package com.tantrancover.liquidtabs

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import com.caverock.androidsvg.SVG
import java.net.URL
import java.util.concurrent.Executors

/**
 * Thanh tab Android — ĐỘC LẬP với React: host sở hữu và gắn vào decor view, nên
 * class này không biết gì về RN.
 *
 * Android không có Liquid Glass, nên nền là bản VẼ TAY clone platter iOS 26 (cùng
 * geometry, cùng công thức tint đục + hairline) — mục tiêu là hai nền tảng nhìn ra
 * cùng một bar, không phải Android bắt chước hiệu ứng kính.
 *
 * Icon: nguyên chuỗi SVG do phía gọi gửi, parse bằng androidsvg (xử lý viewBox,
 * `<g transform>` lồng nhau, fill-rule) rồi tint bằng ColorFilter(SRC_IN) — vì
 * vậy MÀU trong chuỗi SVG bị bỏ qua, một chuỗi dùng cho cả hai trạng thái.
 */
class LTBBarView(context: Context) : View(context) {

  data class Item(
    val key: String,
    val label: String,
    val svg: String,
    val svgSelected: String,
    val imageUrl: String,
    val badge: String,
  )

  var onSelect: ((String) -> Unit)? = null

  private var items: List<Item> = emptyList()
  private var activeKey: String = ""
  private var cornerRadius = dp(32f)
  private var tintActive = Color.BLACK
  private var tintInactive = Color.GRAY

  // ── Vật liệu nền: khớp GlassSurface của mini-app ([device-verify] 18/07).
  //    Tint đục ~92% + hairline định biên. Dark dùng hairline SÁNG-trên-tối vì
  //    0.06 quá mờ để tách bar khỏi nền đen.
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val edgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = 1f
  }
  private val lensPaint = Paint(Paint.ANTI_ALIAS_FLAG)
  private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    textAlign = Paint.Align.CENTER
    textSize = sp(10f)
  }
  private val badgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#FF3B30") }
  private val badgeTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    textAlign = Paint.Align.CENTER
    textSize = sp(11f)
  }
  private val iconPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

  private val barRect = RectF()
  private val lensRect = RectF()
  private var lensAnim: ValueAnimator? = null

  /** TÂM của lens theo trục X; -1 = không có tab nào để vẽ. Dùng tâm (không phải mép
   *  trái như bản trước) vì lúc vuốt lens dính theo ngón và giãn hai phía — mép trái
   *  không còn là đại lượng tự nhiên. */
  private var lensCenterX = -1f

  // ── Vuốt-để-chọn (yêu cầu USER 29/07). Cùng luật với iOS: lens theo ngón liên
  //    tục, tab chỉ đổi khi NHẢ tay. "Bóng nước" ở Android là do TA vẽ (giãn ngang
  //    theo tốc độ + bẹp dọc bù lại) — nền tảng này không có vật liệu kính.
  /** Tab đang VẼ nhưng JS chưa xác nhận. Rỗng = không có. Chống nháy một nhịp bridge. */
  private var pendingKey: String = ""
  /** Index dưới ngón khi đang kéo; -1 = không kéo. */
  private var dragIndex = -1
  private var downX = 0f
  private var lensStretch = 0f
  private var velocityTracker: VelocityTracker? = null
  private val pendingHandler = Handler(Looper.getMainLooper())
  private val revertPending = Runnable {
    if (pendingKey.isNotEmpty()) {
      pendingKey = ""
      animateLens()
      invalidate()
    }
  }

  /** Bitmap icon đã render, khoá theo (svg, kích thước). Parse SVG là việc đắt —
   *  không làm lại mỗi lần vẽ. LruCache tự nhả khi thiếu bộ nhớ. */
  private val iconCache = LruCache<String, Bitmap>(16)
  private val avatarCache = LruCache<String, Bitmap>(4)
  private val io = Executors.newSingleThreadExecutor()
  /** URL avatar đang được yêu cầu — chặn lượt CŨ về muộn ghi đè lượt mới. */
  private val pendingAvatar = HashMap<String, String>()

  init {
    applyThemeColors()
    isClickable = true
  }

  private fun isDark(): Boolean =
    (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
      android.content.res.Configuration.UI_MODE_NIGHT_YES

  private fun applyThemeColors() {
    if (isDark()) {
      fillPaint.color = Color.argb((0.94f * 255).toInt(), 44, 44, 46)
      edgePaint.color = Color.argb((0.14f * 255).toInt(), 255, 255, 255)
      lensPaint.color = Color.argb((0.10f * 255).toInt(), 255, 255, 255)
    } else {
      fillPaint.color = Color.argb((0.92f * 255).toInt(), 252, 252, 252)
      edgePaint.color = Color.argb((0.06f * 255).toInt(), 0, 0, 0)
      lensPaint.color = Color.argb((0.05f * 255).toInt(), 0, 0, 0)
    }
  }

  override fun onConfigurationChanged(newConfig: android.content.res.Configuration?) {
    super.onConfigurationChanged(newConfig)
    // Màu paint là giá trị đã resolve, KHÔNG tự đổi theo Dark Mode như dynamic
    // color của iOS — phải tính lại, nếu không bar giữ màu của mode cũ.
    applyThemeColors()
    invalidate()
  }

  fun setItems(next: List<Item>) {
    items = next
    invalidate()
  }

  fun setActiveKey(key: String) {
    // JS đã lên tiếng ⇒ sự thật về tay nó, kể cả khi giá trị không đổi; huỷ watchdog
    // (nó chỉ tồn tại cho trường hợp JS IM LẶNG).
    val wasPending = pendingKey.isNotEmpty()
    pendingKey = ""
    pendingHandler.removeCallbacks(revertPending)
    if (key == activeKey && !wasPending) return
    val had = activeKey.isNotEmpty()
    activeKey = key
    // Đang kéo thì ngón là chủ, không giật lens về ô nghỉ giữa cú vuốt.
    if (dragIndex >= 0) { invalidate(); return }
    if (had) animateLens() else { snapLens(); invalidate() }
  }

  /** Tab đang VẼ. Khác [activeKey] khi đang chờ JS xác nhận. */
  private fun visualActiveKey(): String = pendingKey.ifEmpty { activeKey }

  /** Hiện [key] ngay (lạc quan) rồi hẹn giờ trả về sự thật nếu JS không xác nhận.
   *  Bar sống NGOÀI cây React nên không ai tự sửa nó — thiếu lưới này thì một lần
   *  app từ chối đổi tab là bar kẹt sai vĩnh viễn. */
  private fun showPendingKey(key: String) {
    if (key.isEmpty()) return
    pendingKey = key
    pendingHandler.removeCallbacks(revertPending)
    pendingHandler.postDelayed(revertPending, PENDING_REVERT_MS)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    // Handler giữ tham chiếu tới view — không dọn là callback vẫn chạy sau khi bar
    // đã rời window.
    pendingHandler.removeCallbacks(revertPending)
    lensAnim?.cancel()
    velocityTracker?.recycle()
    velocityTracker = null
  }

  fun setTint(active: Int, inactive: Int) {
    tintActive = active
    tintInactive = inactive
    // Icon được cache SAU khi tint, nên đổi màu phải xoá cache — không xoá thì
    // icon giữ màu cũ và không có gì báo sai.
    iconCache.evictAll()
    invalidate()
  }

  fun setCornerRadius(r: Float) {
    cornerRadius = r
    invalidate()
  }

  // ── Layout & vẽ

  override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
    super.onSizeChanged(w, h, ow, oh)
    barRect.set(0f, 0f, w.toFloat(), h.toFloat())
    snapLens()
  }

  private fun itemWidth(): Float =
    if (items.isEmpty()) 0f else width.toFloat() / items.size

  /** Theo tab đang VẼ, không theo [activeKey]: lúc chờ JS xác nhận, lens phải nằm ở
   *  ô người dùng vừa chọn, nếu không nó giật về ô cũ rồi mới sang. */
  private fun activeIndex(): Int = items.indexOfFirst { it.key == visualActiveKey() }

  /** Tâm ô nghỉ của item thứ [i]. */
  private fun restCenterX(i: Int): Float = itemWidth() * (i + 0.5f)

  private fun snapLens() {
    val i = activeIndex()
    lensCenterX = if (i < 0) -1f else restCenterX(i)
    lensStretch = 0f
  }

  private fun animateLens() {
    val i = activeIndex()
    if (i < 0) { lensCenterX = -1f; invalidate(); return }
    val target = restCenterX(i)
    val from = if (lensCenterX < 0f) target else lensCenterX
    val fromStretch = lensStretch
    lensAnim?.cancel()
    lensAnim = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = LENS_ANIM_MS
      addUpdateListener {
        val t = it.animatedValue as Float
        lensCenterX = from + (target - from) * t
        // Giãn co về 0 cùng lúc ⇒ khối nước "đàn" lại thay vì nhảy về hình nghỉ.
        lensStretch = fromStretch * (1f - t)
        invalidate()
      }
      start()
    }
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    canvas.drawRoundRect(barRect, cornerRadius, cornerRadius, fillPaint)

    val inset = edgePaint.strokeWidth / 2f
    canvas.drawRoundRect(
      barRect.left + inset, barRect.top + inset, barRect.right - inset, barRect.bottom - inset,
      cornerRadius, cornerRadius, edgePaint,
    )

    if (items.isEmpty()) return
    val iw = itemWidth()

    if (lensCenterX >= 0f) {
      val restW = iw - dp(4f) * 2f
      val restH = height - dp(6f) * 2f
      val w = restW + lensStretch
      val h = max(1f, restH - lensStretch * LENS_SQUASH_RATIO)
      // Kẹp tâm để lens không tràn khỏi nền bar.
      val minCX = dp(4f) + w / 2f
      val maxCX = width - dp(4f) - w / 2f
      val cx = if (minCX > maxCX) width / 2f else max(minCX, min(maxCX, lensCenterX))
      val cy = height / 2f
      lensRect.set(cx - w / 2f, cy - h / 2f, cx + w / 2f, cy + h / 2f)
      // Capsule: bán kính = nửa chiều cao HIỆN TẠI (bản trước cố định 18dp nên lúc
      // bẹp sẽ ra hình viên thuốc méo).
      val r = h / 2f
      canvas.drawRoundRect(lensRect, r, r, lensPaint)
    }

    val visual = visualActiveKey()
    items.forEachIndexed { index, item ->
      drawItem(canvas, item, iw * index, iw, item.key == visual)
    }
  }

  private fun drawItem(canvas: Canvas, item: Item, left: Float, w: Float, selected: Boolean) {
    val ink = if (selected) tintActive else tintInactive
    val hasLabel = item.label.isNotEmpty()
    val iconSide = if (item.imageUrl.isNotEmpty()) dp(30f) else dp(24f)
    val labelH = if (hasLabel) labelPaint.textSize * 1.2f else 0f
    val blockH = iconSide + if (hasLabel) dp(2f) + labelH else 0f
    val top = (height - blockH) / 2f
    val cx = left + w / 2f

    val bmp = if (item.imageUrl.isNotEmpty()) {
      avatarBitmap(item.imageUrl, iconSide.toInt())
    } else {
      iconBitmap(if (selected && item.svgSelected.isNotEmpty()) item.svgSelected else item.svg,
        iconSide.toInt(), ink)
    }
    if (bmp != null) {
      // Avatar giữ MÀU GỐC; icon đã được tint lúc render nên không filter lần nữa.
      iconPaint.colorFilter = null
      canvas.drawBitmap(bmp, null,
        RectF(cx - iconSide / 2f, top, cx + iconSide / 2f, top + iconSide), iconPaint)
    }

    if (hasLabel) {
      labelPaint.color = ink
      canvas.drawText(item.label, cx, top + iconSide + dp(2f) + labelPaint.textSize, labelPaint)
    }

    if (item.badge.isNotEmpty()) drawBadge(canvas, item.badge, cx + iconSide / 2f, top)
  }

  /** `" "` (một khoảng trắng) = chấm không số — PHẢI khớp BADGE_DOT ở
   *  src/toNativeItems.ts và kBadgeDotSentinel ở ios/LTBItemView.mm. */
  private fun drawBadge(canvas: Canvas, badge: String, anchorX: Float, anchorY: Float) {
    val isDot = badge == " "
    if (isDot) {
      canvas.drawCircle(anchorX, anchorY + dp(2f), dp(4f), badgePaint)
      return
    }
    val textW = badgeTextPaint.measureText(badge)
    val h = dp(16f)
    val bw = maxOf(h, textW + dp(8f))
    val r = RectF(anchorX - dp(4f), anchorY - dp(4f), anchorX - dp(4f) + bw, anchorY - dp(4f) + h)
    canvas.drawRoundRect(r, h / 2f, h / 2f, badgePaint)
    canvas.drawText(badge, r.centerX(), r.centerY() - (badgeTextPaint.ascent() + badgeTextPaint.descent()) / 2f, badgeTextPaint)
  }

  // ── Icon SVG → bitmap đã tint

  private fun iconBitmap(svg: String, side: Int, tint: Int): Bitmap? {
    if (svg.isEmpty() || side <= 0) return null
    val key = "$svg|$side|$tint"
    iconCache.get(key)?.let { return it }
    val bmp = try {
      val parsed = SVG.getFromString(svg)
      // documentWidth < 0 khi SVG chỉ khai viewBox mà không khai width/height —
      // ép kích thước để androidsvg scale vào ô thay vì render 0×0.
      parsed.setDocumentWidth(side.toFloat())
      parsed.setDocumentHeight(side.toFloat())
      val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
      parsed.renderToCanvas(Canvas(out))
      // Tint SAU khi render: phủ màu lên phần alpha đã vẽ. Nhờ vậy màu ghi trong
      // chuỗi SVG không cần đúng, và một chuỗi dùng cho cả hai trạng thái.
      val tinted = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
      val c = Canvas(tinted)
      val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        colorFilter = PorterDuffColorFilter(tint, PorterDuff.Mode.SRC_IN)
      }
      c.drawBitmap(out, 0f, 0f, p)
      out.recycle()
      tinted
    } catch (t: Throwable) {
      // SVG hỏng ⇒ KHÔNG vẽ icon, KHÔNG làm sập bar. Cache null không được nên
      // ghi log một lần rồi bỏ qua; bar vẫn dùng được, chỉ thiếu một icon.
      android.util.Log.w("LiquidTabs", "SVG không parse được, bỏ icon", t)
      null
    }
    if (bmp != null) iconCache.put(key, bmp)
    return bmp
  }

  // ── Avatar remote

  private fun avatarBitmap(url: String, side: Int): Bitmap? {
    avatarCache.get(url)?.let { return it }
    if (pendingAvatar[url] == url) return null
    pendingAvatar[url] = url
    io.execute {
      val loaded = try {
        URL(url).openStream().use { BitmapFactory.decodeStream(it) }
      } catch (t: Throwable) {
        null
      }
      post {
        pendingAvatar.remove(url)
        if (loaded != null) {
          avatarCache.put(url, circleCrop(loaded, side))
          invalidate()
        }
      }
    }
    return null
  }

  private fun circleCrop(src: Bitmap, side: Int): Bitmap {
    val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
    val c = Canvas(out)
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    c.drawCircle(side / 2f, side / 2f, side / 2f, p)
    p.xfermode = android.graphics.PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
    c.drawBitmap(src, Rect(0, 0, src.width, src.height), Rect(0, 0, side, side), p)
    return out
  }

  // ── Touch

  /** Index của item tại toạ độ x, kẹp vào [0, n-1] để kéo ra ngoài mép không mất bám. */
  private fun indexAtX(x: Float): Int {
    if (items.isEmpty()) return -1
    val iw = itemWidth()
    if (iw <= 0f) return -1
    return (x / iw).toInt().coerceIn(0, items.size - 1)
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (items.isEmpty()) return super.onTouchEvent(event)

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        downX = event.x
        dragIndex = -1
        velocityTracker?.recycle()
        velocityTracker = VelocityTracker.obtain().apply { addMovement(event) }
        // PHẢI trả true ở DOWN, nếu không Android không gửi MOVE/UP tiếp — đó là lý
        // do bản trước (chỉ bắt ACTION_UP) không thể vuốt được.
        return true
      }

      MotionEvent.ACTION_MOVE -> {
        velocityTracker?.addMovement(event)
        // Ngưỡng slop chỉ tính trục X: vuốt DỌC (vd kéo lên đóng app) không được
        // biến thành đổi tab.
        if (dragIndex < 0 && abs(event.x - downX) < dp(DRAG_SLOP_DP)) return true
        val idx = indexAtX(event.x)
        if (idx < 0) return true
        dragIndex = idx
        val key = items[idx].key
        // Highlight theo ngón NGAY, nhưng KHÔNG báo JS (USER chốt: đổi màn khi nhả).
        if (key != visualActiveKey()) pendingKey = key
        lensAnim?.cancel()
        val vx = velocityTracker?.let {
          it.computeCurrentVelocity(1000)
          it.xVelocity
        } ?: 0f
        lensCenterX = event.x
        lensStretch = min(dp(LENS_STRETCH_MAX_DP), abs(vx) * dp(LENS_STRETCH_MAX_DP) / STRETCH_VEL_FULL)
        invalidate()
        return true
      }

      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        velocityTracker?.recycle()
        velocityTracker = null
        val dragged = dragIndex >= 0
        val idx = if (dragged) dragIndex else indexAtX(event.x)
        dragIndex = -1
        if (idx < 0) return true
        val key = items[idx].key
        // Huỷ cũng CHỐT theo ô cuối dưới ngón: người dùng đã thấy highlight ở đó, trả
        // về ô cũ sẽ đọc thành "app ăn mất cú vuốt".
        showPendingKey(key)
        animateLens()
        invalidate()
        onSelect?.invoke(key)
        return true
      }
    }
    return super.onTouchEvent(event)
  }

  private fun dp(v: Float) = v * resources.displayMetrics.density
  private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity

  private companion object {
    const val LENS_ANIM_MS = 320L
    /** Giãn ngang tối đa (dp) khi ngón đi nhanh. */
    const val LENS_STRETCH_MAX_DP = 26f
    /** Tốc độ (px/s) tại đó giãn chạm trần. */
    const val STRETCH_VEL_FULL = 1200f
    /** Giãn ngang thì bẹp dọc — giữ cảm giác bảo toàn thể tích. */
    const val LENS_SQUASH_RATIO = 0.18f
    const val DRAG_SLOP_DP = 6f
    /** JS không xác nhận trong khoảng này ⇒ trả highlight về sự thật. */
    const val PENDING_REVERT_MS = 600L
  }
}
