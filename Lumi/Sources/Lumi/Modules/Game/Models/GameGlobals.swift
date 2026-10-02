import AppKit
import SwiftUI
import WebKit

import SwiftUI
import WebKit
import AppKit

// MARK: - TapTap 小游戏模块

/// 默认加载的 H5 小游戏地址。
/// 说明：TapTap 的游戏详情页（如 https://www.taptap.cn/app/889164 ）只是介绍/下载页，
/// 并不内嵌可玩的 H5 游戏；要在面板里「即点即玩」，需加载真正运行的 H5 承载页。
/// 这里默认用 4399《星球大合成》（与 TapTap 那款合成玩法同类，纯 H5 即点即玩、鼠标操作）。
/// 想换成 TapTap 那款的 H5 或任意其他在线小游戏，直接改这个地址即可。
let tapTapGameURL = URL(string: "https://www.4399.com/swf.htm?gamepath=//sda.4399.com/4399swf/upload_swf/ftp46/gamehwq/20240304/10/index.html")!
