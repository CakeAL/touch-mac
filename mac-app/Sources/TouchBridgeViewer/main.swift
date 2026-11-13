import AppKit
import Darwin

// 日志立即落盘，便于从终端/后台任务观察状态。
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// 纯悬浮预览：不抢前台焦点、不显示 Dock 图标，点击画面只发触控。
app.setActivationPolicy(.accessory)
app.run()
