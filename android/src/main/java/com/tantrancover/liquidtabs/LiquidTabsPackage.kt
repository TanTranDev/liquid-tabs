package com.tantrancover.liquidtabs

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * Autolinking Android tìm class này qua `react-native.config.js` (hoặc mặc định
 * `<javaPackageName>.<PascalCasePackageName>Package`). Khai TurboModule ở đây —
 * `isTurboModule = true` là bắt buộc, thiếu nó thì New Architecture bỏ qua module
 * và JS nhận `getEnforcing` throw, tức bar biến mất mà không lỗi build.
 */
class LiquidTabsPackage : BaseReactPackage() {

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
    if (name == LiquidTabsModule.NAME) LiquidTabsModule(reactContext) else null

  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      LiquidTabsModule.NAME to ReactModuleInfo(
        /* name = */ LiquidTabsModule.NAME,
        /* className = */ LiquidTabsModule.NAME,
        /* canOverrideExistingModule = */ false,
        /* needsEagerInit = */ false,
        /* isCxxModule = */ false,
        /* isTurboModule = */ true,
      ),
    )
  }
}
