# CloseTargetApp

一个给自己 MacBook 用的菜单栏小工具：在菜单栏放一个按钮，点击后可以一键关闭配置好的应用，也可以打开设置窗口管理目标应用和开机自启动。

## 功能

- 菜单栏按钮
- 自定义 App 图标
- 一键关闭指定应用
- 设置窗口中添加/移除目标应用
- 开机自启动开关
- 自动保存配置

## 图标

如果之后想替换 App 图标，可以替换 `Resources/AppIcon-source.png`，然后执行：

```bash
./scripts/generate_app_icon.sh
./scripts/build_app.sh
```

## 打包

```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

打包完成后会生成：

```text
dist/CloseTargetApp.app
```

建议把它移动到 `/Applications` 后再开启「开机自启动」，这样 macOS 的登录项注册更稳定。

## 使用

1. 打开 `dist/CloseTargetApp.app`。
2. 在菜单栏点击 `xmark.octagon` 图标。
3. 进入「设置...」，添加你想关闭的应用。
4. 回到菜单栏点击「一键关闭指定软件」。
5. 如果需要，打开「开机自启动」。

## 测试建议

不需要把整个项目本地跑起来调试。可以按下面几步手动验收：

1. 执行打包脚本，确认生成 `dist/CloseTargetApp.app`。
2. 打开 App 后确认菜单栏出现按钮，Dock 中不出现常驻图标。
3. 在设置里添加一个无重要数据的测试应用，例如「备忘录」或「预览」。
4. 打开该测试应用，点击「一键关闭指定软件」，确认应用收到退出请求。
5. 切换「开机自启动」，若提示需要允许，到系统设置的登录项中确认状态。
