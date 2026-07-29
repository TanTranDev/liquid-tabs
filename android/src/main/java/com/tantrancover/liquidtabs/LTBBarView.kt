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
import android.util.LruCache
import android.view.MotionEvent
import android.view.View
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
  private var lensX = 0f

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
    if (key == activeKey) return
    val had = activeKey.isNotEmpty()
    activeKey = key
    if (had) animateLens() else { snapLens(); invalidate() }
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

  private fun activeIndex(): Int = items.indexOfFirst { it.key == activeKey }

  private fun snapLens() {
    val i = activeIndex()
    lensX = if (i < 0) -1f else itemWidth() * i
  }

  private fun animateLens() {
    val i = activeIndex()
    if (i < 0) { lensX = -1f; invalidate(); return }
    val target = itemWidth() * i
    lensAnim?.cancel()
    lensAnim = ValueAnimator.ofFloat(if (lensX < 0f) target else lensX, target).apply {
      duration = 320
      addUpdateListener { lensX = it.animatedValue as Float; invalidate() }
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

    if (lensX >= 0f) {
      lensRect.set(lensX + dp(4f), dp(6f), lensX + iw - dp(4f), height - dp(6f))
      canvas.drawRoundRect(lensRect, dp(18f), dp(18f), lensPaint)
    }

    items.forEachIndexed { index, item ->
      drawItem(canvas, item, iw * index, iw, item.key == activeKey)
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

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (event.action == MotionEvent.ACTION_UP && items.isNotEmpty()) {
      val iw = itemWidth()
      val index = (event.x / iw).toInt().coerceIn(0, items.size - 1)
      onSelect?.invoke(items[index].key)
      return true
    }
    return super.onTouchEvent(event)
  }

  private fun dp(v: Float) = v * resources.displayMetrics.density
  private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity
}
