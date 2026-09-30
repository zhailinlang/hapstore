"""从 GitHub 仓库里找应用图标，缩放到统一尺寸后落到本地 icons/ 目录。

设计要点：
1. 图标最终会以 base64 内嵌进 apps.json，所以尺寸要小（默认 64x64 + 256 色）。
2. 只认 png/jpg/webp（Pillow 能解码的），svg 跳过 —— ArkUI 虽支持 svg base64，
   但没有现成的光栅化手段，与其塞个矢量进去不如退到头像兜底。
3. 三级兜底：仓库内图标 → 作者头像 → 无（App 侧画首字母色块）。
4. 抓过的图标落盘缓存，重跑不会重复下载。
"""

import base64
import io
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

from PIL import Image

ICONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icons')
UA = 'hapstore-sync/1.0'
API = 'https://api.github.com'
RAW = 'https://raw.githubusercontent.com'
WEB = 'https://github.com'

ICON_SIZE = 64

# 仓库内图标的候选路径，按优先级从高到低。匹配规则：小写路径 contains
ICON_HINTS = [
    'appscope/resources/base/media/app_icon.png',
    'app_icon.png',
    'entry/src/main/resources/base/media/startwindow',
    '/media/icon.png',
    '/media/logo.png',
    '/media/app_icon.jpg',
    '/media/icon.jpg',
    'icon.png',
    'logo.png',
    'app_icon.jpg',
    'icon.jpg',
    'logo.jpg',
]

# 这些文件虽然也是 png，但不是应用图标
EXCLUDE_PAT = re.compile(
    r'(screenshot|preview|banner|cover|readme|docs?/|example|demo|test|'
    r'background|foreground|layered|splash|startwindow|/rawfile/|ohos_test)',
    re.I)

VALID_EXT = ('.png', '.jpg', '.jpeg', '.webp')


def _get(url: str, token: str | None = None, timeout: int = 30, raw: bool = False):
    """raw=True 时返回 bytes，否则返回 dict/list。"""
    headers = {'User-Agent': UA, 'Accept': 'application/vnd.github+json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            return resp.status, data
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


def _list_files(owner: str, repo: str, token: str | None, timeout: int = 30) -> list[str]:
    """用 git trees API 递归列出仓库文件路径。"""
    status, data = _get(f'{API}/repos/{owner}/{repo}/git/trees/HEAD?recursive=1',
                        token, timeout)
    if status != 200 or not data:
        return []
    try:
        tree = json.loads(data.decode('utf-8', 'replace'))
    except Exception:
        return []
    return [t['path'] for t in tree.get('tree', []) if t.get('type') == 'blob']


def _pick_icon_path(files: list[str]) -> str | None:
    """按优先级挑一个最像应用图标的文件。"""
    candidates = [p for p in files if p.lower().endswith(VALID_EXT)]
    # 先排除明显不是图标的
    narrowed = [p for p in candidates if not EXCLUDE_PAT.search(p)]
    pool = narrowed if narrowed else candidates

    low = [(p, p.lower()) for p in pool]
    for hint in ICON_HINTS:
        for path, lpath in low:
            if hint in lpath:
                return path
    return None


def _download_raw(owner: str, repo: str, path: str, timeout: int = 30) -> bytes | None:
    url = f'{RAW}/{owner}/{repo}/HEAD/{urllib.parse.quote(path)}'
    status, data = _get(url, None, timeout, raw=True)
    return data if status == 200 else None


def _avatar(owner: str, timeout: int = 30) -> bytes | None:
    status, data = _get(f'{WEB}/{owner}.png?size=200', None, timeout, raw=True)
    return data if status == 200 else None


def _normalize(raw: bytes) -> bytes | None:
    """缩到 ICON_SIZE、转 PNG、压到 256 色，返回编码后的字节。"""
    try:
        im = Image.open(io.BytesIO(raw))
        im.load()
    except Exception:
        return None
    try:
        if im.mode not in ('RGB', 'RGBA'):
            im = im.convert('RGBA')
        # 裁成正方形（取中间），避免非方图拉伸变形
        w, h = im.size
        if w != h:
            side = min(w, h)
            left, top = (w - side) // 2, (h - side) // 2
            im = im.crop((left, top, left + side, top + side))
        im = im.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
        if im.mode == 'RGBA':
            alpha = im.getchannel('A')
            if alpha.getextrema()[0] < 255:
                # 有透明通道：垫白底，否则深色主题下会糊成一团
                bg = Image.new('RGB', (ICON_SIZE, ICON_SIZE), (255, 255, 255))
                bg.paste(im, mask=alpha)
                im = bg
        im = im.convert('RGB')
        im = im.quantize(colors=256, method=Image.FASTOCTREE)
        buf = io.BytesIO()
        im.save(buf, format='PNG', optimize=True)
        return buf.getvalue()
    except Exception:
        return None


def cache_file(owner: str, repo: str) -> str:
    safe = re.sub(r'[^A-Za-z0-9._-]', '_', f'{owner}__{repo}')
    return os.path.join(ICONS_DIR, f'{safe}.png')


def ensure_icon(owner: str, repo: str, token: str | None = None,
                force: bool = False, timeout: int = 30) -> dict | None:
    """返回一个 dict：{'file': 本地缓存文件名, 'source': 'repo'|'avatar', 'path': 仓库内路径}
    失败返回 None。"""
    os.makedirs(ICONS_DIR, exist_ok=True)
    dest = cache_file(owner, repo)
    if os.path.exists(dest) and not force:
        return {'file': os.path.basename(dest), 'source': 'cache', 'path': ''}

    raw = None
    picked = None
    files = _list_files(owner, repo, token, timeout)
    if files:
        picked = _pick_icon_path(files)
        if picked:
            raw = _download_raw(owner, repo, picked, timeout)

    source = 'repo'
    if raw is None:
        # 兜底：作者头像
        raw = _avatar(owner, timeout)
        source = 'avatar'
        picked = ''
    if raw is None:
        return None

    png = _normalize(raw)
    if not png:
        return None
    with open(dest, 'wb') as f:
        f.write(png)
    return {'file': os.path.basename(dest), 'source': source, 'path': picked or ''}


def as_data_url(file_name: str) -> str | None:
    """把 icons/ 下的缓存文件转成 data URL。"""
    if not file_name:
        return None
    p = os.path.join(ICONS_DIR, file_name)
    if not os.path.exists(p):
        return None
    try:
        with open(p, 'rb') as f:
            return 'data:image/png;base64,' + base64.b64encode(f.read()).decode('ascii')
    except Exception:
        return None
