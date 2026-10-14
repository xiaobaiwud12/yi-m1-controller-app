[English](README.md) | 简体中文

# yi-m1-controller-app

面向小蚁 YI M1（型号 `C59Y1`）的开源 Android 控制器。应用通过低功耗蓝牙（BLE）配对，加入相机 Wi-Fi，发送 HTTP 控制命令，接收 UDP JPEG 取景流，并可将用户选择的相机文件复制到手机。

本项目独立开发，与相机厂商无隶属或背书关系。

## 发布状态

当前源码版本为 **`0.2.2+4`**。已发布版本和 APK 下载请查看 [GitHub Releases](https://github.com/xiaobaiwud12/yi-m1-controller-app/releases)。应用版本唯一来源是 `app/pubspec.yaml`；版本变化记在 `CHANGELOG.md`。本次维护包括内部架构拆分和主底栏稳定 key，没有新增页面或相机功能。

维护者确认原交付 App 可用。相机目前已损坏，因此当前源码尚未用真机相机验证。离线或模拟器检查不能证明真实相机行为。

## 功能与操作边界

- 通过 BLE 与 YI M1 配对并获取相机 Wi-Fi 设置。
- 连接相机热点并发送支持的 HTTP 控制。
- 显示相机的 JPEG 取景流。
- 浏览相机存储卡媒体，并选择文件传输到手机。

相机按串行方式处理 HTTP 请求。选择媒体只会加入队列；用户需在同步控件中显式开始传输，连接就绪不会自动开始下载。相机同时生成的 RAW 与 JPEG 会配对显示，选择一组会将两个文件都加入队列。缩略图请求返回 `204` 表示对应尺寸无法生成，不代表文件不存在；RAW 文件需要请求原图尺寸。

快门使用按住操作；相机报告 Continuous 驱动模式时不提供拍摄操作。暂停或恢复取景流是显式实验，默认关闭。

## 环境要求

- YI M1（`C59Y1`）相机和 Android 7.0（API 24）或更新版本、支持 BLE 与 Wi-Fi 的手机。
- 发布 APK 面向 **`arm64-v8a`**，请在兼容设备上安装。Android 可能要求允许从打开 APK 的来源安装应用。
- 从源码构建需要 Flutter/Dart、Android SDK、JDK 和 Git。

带假相机参数的模拟器仅用于界面和集成检查，不会连接实体相机。

## 检查与 APK 验证

在仓库的 `app/` 目录运行统一离线验证入口：

```bash
dart tool/verify.dart
```

也可在同一目录检查发布 APK：

```bash
dart tool/verify.dart --apk build/app/outputs/flutter-apk/app-release.apk --stamp <commit-stamp>
```

APK 检查会核对打包权限、拒绝测试标记、确认内嵌构建 stamp，并拒绝使用公开 Android debug key 签名的产物。

`MARIONETTE`、`FAKE_CAMERA` 和 `DIRECT_CAMERA` 是测试或实验参数，正式 APK 不得启用。

## 许可

应用采用 **Apache-2.0**，详见 `LICENSE`。`NOTICE` 列出第三方组件及适用声明，包括 MIT 许可的生成协议材料。再分发源码或随附组件时须保留相应声明。应用内许可页列出随附组件。

## 项目链接

- [版本记录](CHANGELOG.md)
- [发布说明](RELEASING.md)
- [贡献指南](CONTRIBUTING.md)
- [安全政策](SECURITY.md)
- [协议说明](app/docs/PROTOCOL.md)
- [问题反馈](https://github.com/xiaobaiwud12/yi-m1-controller-app/issues)
