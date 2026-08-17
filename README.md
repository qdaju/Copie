# Copie

Copie 是一个 macOS 菜单栏小工具，用于辅助复制和粘贴操作，并在复制后显示文本提示。

## 功能

- 通过辅助功能权限监听和模拟键盘操作
- 复制后显示文本 HUD，并按每 50 个字符换行
- 支持 macOS 13 及以上的登录时启动
- 以菜单栏应用运行，不在 Dock 中显示

## 开发

1. 使用 Xcode 打开 `Copie/Copie.xcodeproj`。
2. 选择 `Copie` scheme。
3. 运行项目。
4. 首次运行时，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Copie。

## 项目结构

- `Copie/Copie/`：应用源码、资源和权限配置
- `Copie/CopieTests/`：单元测试
- `Copie/CopieUITests/`：UI 测试
- `Copie/Copie.xcodeproj/`：Xcode 项目文件

## 注意事项

Copie 需要辅助功能权限才能完成全局复制/粘贴相关操作。请只对自己信任的构建版本授予该权限。
