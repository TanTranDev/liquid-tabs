require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "tantrancover-liquid-tabs"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.license      = package["license"]
  s.authors      = { "Tan Tran" => "ton@f8a.io" }
  s.homepage     = "https://github.com/tantrancover/liquid-tabs"

  # RN 0.85 tối thiểu 15.1. Toàn bộ code Liquid Glass nằm trong @available(iOS 26)
  # nên build được cho target thấp; dưới 26 thì view không dựng kính (wrapper JS
  # đã chặn trước bằng isLiquidTabBarAvailable).
  s.platforms    = { :ios => "15.1" }

  s.source       = { :git => "https://github.com/tantrancover/liquid-tabs.git", :tag => "v#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm,cpp}"

  # Kéo React-Core + codegen + Folly… theo đúng cấu hình New Architecture của app
  # đang tích hợp. KHÔNG tự khai từng dependency: version phải khớp RN của host,
  # helper này lấy đúng từ đó.
  install_modules_dependencies(s)
end
