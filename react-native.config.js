// Chỉ đường cho autolinking. Khai tường minh vì tên package Kotlin
// (LiquidTabsPackage trong com.tantrancover.liquidtabs) không suy ra được từ tên
// npm '@tantrancover/liquid-tabs' theo quy ước mặc định — thiếu file này thì
// Android build xanh nhưng module KHÔNG được đăng ký, và JS chỉ thấy bar biến mất.
module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: 'android',
        packageImportPath: 'import com.tantrancover.liquidtabs.LiquidTabsPackage;',
        packageInstance: 'new LiquidTabsPackage()',
      },
      ios: {},
    },
  },
};
