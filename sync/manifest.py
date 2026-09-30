#!/usr/bin/env python3
"""生成 data/manifest.json —— 快照指针 + App 最新版本信息。

App 端先拉这个约 700B 的小文件，再决定要不要拉 528KB 的 apps.json，
顺便从这里拿到 App 自身的最新版本。

用法：
    # 只刷新 snapshot 段（每轮快照跑完调用），app 段原样保留
    python3 manifest.py --repo OWNER/REPO

    # 发版时刷新 app 段（需要先有 HAP 资产，才能算出 size / sha256）
    python3 manifest.py --repo OWNER/REPO --set-app-version 1.0.1 \
        --asset out/HapStore-v1.0.1.hap
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
APPS_PATH = os.path.join(ROOT, 'data', 'apps.json')
MANIFEST_PATH = os.path.join(ROOT, 'data', 'manifest.json')
APP_JSON5 = os.path.join(ROOT, 'app', 'AppScope', 'app.json5')

MANIFEST_SCHEMA = 1
DEFAULT_MIN_APP_VERSION_CODE = 1000000
SNAPSHOT_TAG = 'snapshot-latest'
CST = timezone(timedelta(hours=8))


def now_iso() -> str:
    return datetime.now(CST).isoformat(timespec='seconds')


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def guess_repo() -> str:
    """从 git remote 推 OWNER/REPO，推不出来就返回空串。"""
    try:
        out = subprocess.run(['git', '-C', ROOT, 'remote', 'get-url', 'origin'],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ''
    m = re.search(r'github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?$', out)
    return f'{m.group(1)}/{m.group(2)}' if m else ''


def read_app_version() -> tuple:
    """从 app.json5 读 (versionCode, versionName)。"""
    try:
        s = open(APP_JSON5, encoding='utf-8').read()
    except OSError:
        return DEFAULT_MIN_APP_VERSION_CODE, '1.0.0'
    mc = re.search(r'"versionCode"\s*:\s*(\d+)', s)
    mn = re.search(r'"versionName"\s*:\s*"([^"]+)"', s)
    code = int(mc.group(1)) if mc else DEFAULT_MIN_APP_VERSION_CODE
    name = mn.group(1) if mn else '1.0.0'
    return code, name


def load_old() -> dict:
    try:
        return json.load(open(MANIFEST_PATH, encoding='utf-8'))
    except Exception:
        return {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default='', help='OWNER/REPO，默认从 git remote 推')
    ap.add_argument('--branch', default='main', help='默认分支名')
    ap.add_argument('--alt-branch', default='snapshot-data',
                    help='raw 兜底分支名（每轮单提交强推，不产生历史膨胀）')
    ap.add_argument('--apps', default=APPS_PATH, help='快照路径')
    ap.add_argument('--out', default=MANIFEST_PATH, help='manifest 输出路径')
    ap.add_argument('--set-app-version', default='', help='把 app 段刷新到这个版本')
    ap.add_argument('--asset', default='', help='本次发版的 HAP 文件路径，用于算 size/sha256')
    ap.add_argument('--notes', default='', help='发版说明')
    args = ap.parse_args()

    repo = args.repo or guess_repo()
    if not repo:
        print('无法确定 OWNER/REPO，请用 --repo 指定', file=sys.stderr)
        return 1

    old = load_old()
    old_snap = old.get('snapshot', {}) or {}
    old_app = old.get('app', {}) or {}

    # ---- snapshot 段 ----
    snap = {
        'url': f'https://github.com/{repo}/releases/download/{SNAPSHOT_TAG}/apps.json',
        'altUrl': f'https://raw.githubusercontent.com/{repo}/{args.alt_branch}/apps.json',
        'size': 0,
        'sha256': '',
        'schemaVersion': 2,
        'generatedAt': '',
        'minAppVersionCode': old_snap.get('minAppVersionCode', DEFAULT_MIN_APP_VERSION_CODE),
    }
    if os.path.exists(args.apps):
        snap['size'] = os.path.getsize(args.apps)
        snap['sha256'] = sha256_of(args.apps)
        try:
            data = json.load(open(args.apps, encoding='utf-8'))
            snap['schemaVersion'] = data.get('schemaVersion', 2)
            snap['generatedAt'] = data.get('generatedAt', '')
        except Exception as e:
            print(f'读取快照失败，snapshot 段留空：{e}', file=sys.stderr)
    else:
        print(f'快照不存在：{args.apps}，snapshot 段留空', file=sys.stderr)

    # ---- app 段 ----
    if args.set_app_version:
        ver = args.set_app_version
        asset = args.asset
        if not asset:
            asset = os.path.join(ROOT, 'out', f'HapStore-v{ver}.hap')
        size = os.path.getsize(asset) if os.path.exists(asset) else 0
        sha = sha256_of(asset) if os.path.exists(asset) else ''
        if not os.path.exists(asset):
            print(f'警告：找不到 HAP {asset}，size/sha256 记为 0/空', file=sys.stderr)
        app = {
            'versionCode': old_app.get('versionCode', DEFAULT_MIN_APP_VERSION_CODE),
            'versionName': ver,
            'tag': f'v{ver}',
            'downloadUrl': f'https://github.com/{repo}/releases/download/v{ver}/HapStore-v{ver}.hap',
            'size': size,
            'sha256': sha,
            'publishedAt': now_iso(),
            'releaseUrl': f'https://github.com/{repo}/releases/latest',
            'notes': args.notes,
        }
        # versionCode 优先跟 app.json5 保持一致
        code, name = read_app_version()
        if name == ver:
            app['versionCode'] = code
    else:
        # 只刷新快照信息，app 段原样保留（发版时会单独重写）
        app = old_app or {
            'versionCode': DEFAULT_MIN_APP_VERSION_CODE,
            'versionName': '1.0.0',
            'tag': 'v1.0.0',
            'downloadUrl': '',
            'size': 0,
            'sha256': '',
            'publishedAt': '',
            'releaseUrl': '',
            'notes': '',
        }
        # 但 URL 里的 repo 必须跟着当前 --repo 走：换仓库名时不能沿用旧地址，
        # 否则 App 自更新会一直指向已经失效的旧仓库。
        app['releaseUrl'] = f'https://github.com/{repo}/releases/latest'
        # 只有已经发过版（downloadUrl 非空）才重写下载地址，否则会凭空造出一个
        # 指向不存在资产的 URL，让 App 以为有新版可下、一点就 404
        if app.get('downloadUrl') and app.get('versionName'):
            ver = app['versionName']
            app['downloadUrl'] = (
                f'https://github.com/{repo}/releases/download/v{ver}/HapStore-v{ver}.hap'
            )

    out = {
        'schemaVersion': MANIFEST_SCHEMA,
        'generatedAt': now_iso(),
        'repo': repo,
        'snapshot': snap,
        'app': app,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write('\n')

    print(f'已写入 {args.out}')
    print(f'  snapshot: {snap["size"]} 字节  schema={snap["schemaVersion"]}  {snap["generatedAt"]}')
    print(f'  app: v{app["versionName"]} ({app["versionCode"]})  {app["size"]} 字节')
    return 0


if __name__ == '__main__':
    sys.exit(main())
