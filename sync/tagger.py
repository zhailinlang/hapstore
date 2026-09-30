"""基于规则的标签引擎：给每个应用打「功能类型 / 设备类型 / 属性标签」。

设计取舍：
- 零依赖、离线、可解释，87 个应用毫秒级出结果，不需要 API Key 也不花钱。
- 关键词表是针对 HarmonyOS-Haps 实际数据人工调过的，不是通用词表。
- 后续若要换成真 LLM 打标，只需实现 tag_with_llm() 并在 sync.py 里切换，
  输出结构（funcType / deviceTypes / tags）保持不变，App 侧无需改动。

匹配规则：
- funcType 取**第一个**命中的类型（列表顺序 = 优先级，越具体越靠前）。
- deviceTypes / tags 取**所有**命中的项。
"""

# ---------- 功能类型：有序，第一个命中即为主类型 ----------

FUNC_RULES = [
    ('游戏启动', [
        '游戏', 'game', 'minecraft', 'mc', '启动器', 'launcher', '模拟器', 'emulator',
        'galgame', 'ons', 'xbox', 'mindustry', 'phira', '像素', 'rpg', '关卡',
    ]),
    ('网络代理', [
        '代理', 'vpn', 'clash', 'mihomo', 'sing-box', 'singbox', 'xray', 'v2ray',
        '组网', 'tailscale', 'easytier', 'zerotier', 'tun', 'dns', '过滤', 'adguard',
        '广告拦截', '翻墙', '节点', '订阅',
    ]),
    ('影音播放', [
        '播放器', '视频', '音乐', '影视', '番剧', '动漫', '动画', '弹幕', '直播',
        '播客', '有声书', '听书', 'bili', 'bilibili', 'youtube', 'jellyfin', 'emby',
        'plex', 'navidrome', 'audiobookshelf', 'vlc', '音频', '白噪音', '曲库',
        'tvbox', '解析', '投屏', '字幕', '电台', 'mp3', '视频源',
    ]),
    ('阅读漫画', [
        '阅读', '小说', '漫画', 'comic', '书源', '画廊', 'gallery', 'hentai',
        'pixiv', '图鉴', 'rss', '新闻', '资讯', '书籍', '看书', '文库',
    ]),
    ('社区社交', [
        '社区', '论坛', '社交', '聊天', '私信', '帖子', '板块', 'bbs', 'nga',
        '贴吧', '微博', 'twitter', 'telegram', 'tg', 'v2ex', 'reddit', '知乎',
        '时间线', '回帖', '发帖', '关注', '动态', '群组',
    ]),
    ('开发工具', [
        '终端', 'terminal', 'shell', 'ssh', 'linux', '命令行', '编译器', 'sdk',
        'docker', '服务器', 'bt ', '下载', 'aria2', 'qbittorrent', 'scrcpy',
        '远程', 'adb', 'hdc', '抓包', 'git', '运行linux', '运行windows',
    ]),
    ('系统工具', [
        '兼容层', '清理', '控件识别', '开屏', '包名', '跑分', '性能', 'soc',
        '系统', 'root', '备份系统', '启动管理',
    ]),
    ('效率工具', [
        '密码', 'password', 'bitwarden', 'keepass', '2fa', '认证', '笔记', 'note',
        'obsidian', '待办', 'todo', '日历', '计算器', 'calculator', '备份',
        '传输', 'localsend', '文件', '相册', '图库', 'immich', 'nextcloud',
        '云盘', '扫描', 'ocr', '翻译', '刷题', '学习', '米家', '智能家居',
        '设备控制', '图鉴', '查询',
    ]),
    ('浏览器', [
        '浏览器', 'browser', 'webview', 'servo', 'webkit', '网页浏览',
    ]),
]

# ---------- 设备类型：命中即加入，可多选 ----------

DEVICE_RULES = [
    ('电脑', ['pc', '电脑', '桌面', 'desktop', 'windows程序', 'linux程序']),
    ('平板', ['平板', 'pad', 'tablet']),
    ('穿戴', ['手表', 'watch', '穿戴', '手环']),
]

# ---------- 属性标签：命中即加入 ----------

PROP_RULES = [
    ('自托管', [
        '自托管', '自建', '自部署', '私人服务器', '私有源', 'nas', 'nextcloud',
        'immich', 'jellyfin', 'emby', 'plex', 'navidrome', 'audiobookshelf',
        'bitwarden', '连接自建', '服务器',
    ]),
    ('第三方客户端', ['第三方', '非官方', '客户端']),
    ('多端适配', ['多端', '多平台', '跨平台', '手机、平板', 'tablet', '多设备']),
    ('Flutter', ['flutter']),
    ('免root', ['免root', '无需root']),
]

DEFAULT_DEVICE = ['手机']


def _text(app: dict) -> str:
    """拼接所有可用于判断的文本，统一转小写。"""
    return ' '.join([
        str(app.get('name', '')),
        str(app.get('desc', '')),
        str(app.get('repo', '')),
        str(app.get('category', '')),
    ]).lower()


def _hits(text: str, keywords) -> bool:
    for kw in keywords:
        if kw in text:
            return True
    return False


def tag_app(app: dict) -> dict:
    """给单个应用打标，返回 {'funcType', 'deviceTypes', 'tags'}。"""
    text = _text(app)

    func_type = '其他'
    for name, kws in FUNC_RULES:
        if _hits(text, kws):
            func_type = name
            break

    devices = [name for name, kws in DEVICE_RULES if _hits(text, kws)]
    # 分类本身就是强信号：官方把应用归到「鸿蒙电脑」就一定支持电脑
    if app.get('category') == '鸿蒙电脑' and '电脑' not in devices:
        devices.append('电脑')
    if not devices:
        devices = list(DEFAULT_DEVICE)

    tags = [name for name, kws in PROP_RULES if _hits(text, kws)]

    return {
        'funcType': func_type,
        'deviceTypes': devices,
        'tags': tags,
    }


def tag_all(apps: list) -> None:
    """就地给每个 app 补上打标字段。"""
    for a in apps:
        a.update(tag_app(a))


def tag_with_llm(apps: list, api_key: str, endpoint: str = '') -> None:
    """占位：后续接真 LLM 打标时的入口。

    约定：与 tag_app 返回同样的 funcType / deviceTypes / tags 字段，
    这样 sync.py 只需把 tag_all 换成 tag_with_llm，App 侧完全不用改。
    """
    raise NotImplementedError('LLM 打标未接入，当前使用规则引擎 tag_all()')
