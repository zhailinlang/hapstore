#!/usr/bin/env python3
"""把 Zitann/HarmonyOS-Haps 的 apps.yaml 同步成 App 可直接消费的 apps.json。

用法：
    export GITHUB_TOKEN=ghp_xxx          # 可选，但没有会被限流到 60 次/小时
    python3 sync.py                      # 增量同步
    python3 sync.py --force              # 忽略 ETag，全量重抓
    python3 sync.py --limit 50           # 本轮最多处理 50 个仓库（未鉴权时控量）
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import github  # noqa: E402
import icons  # noqa: E402
import tagger  # noqa: E402

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
STATE_PATH = os.path.join(BASE, 'state.json')
# 默认直接写仓库根下的 data/；apps.json 不入库（体积太大），只作为 Release 资产发布
OUT_PATH = os.path.join(ROOT, 'data', 'apps.json')

YAML_URL = 'https://raw.githubusercontent.com/Zitann/HarmonyOS-Haps/main/apps.yaml'
REPO_RE = re.compile(r'github\.com/([^/]+)/([^/?#]+)')
HAP_EXT = ('.hap', '.hsp', '.app')
# 详情页展示最近几个 Release（每个 Release 都要额外请求一次资产列表，别调太大）
RELEASE_COUNT = 2


# ---------- 工具 ----------

def load_state() -> dict:
    if os.path.exists(STATE_PATH):
        try:
            with open(STATE_PATH, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {'yaml_etag': None, 'yaml_sha': None, 'repos': {}}


def save_state(state: dict) -> None:
    # 直接覆盖写，不用 tmp + os.replace：后者需要先 unlink 已存在的文件，
    # 在受限沙箱下会被拒绝（Brokered host rename overwrite refused），
    # 结果就是跑了十几分钟的抓取全部丢失。
    # default=str：YAML 解析出的 date 对象（如未加引号的 2025-08-30）转成字符串
    with open(STATE_PATH, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False, indent=2, default=str)


def fetch_yaml(etag: str | None, force: bool):
    """返回 (text, etag, changed)。"""
    headers = {'User-Agent': github.UA}
    if etag and not force:
        headers['If-None-Match'] = etag
    req = urllib.request.Request(YAML_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode('utf-8', 'replace'), resp.headers.get('ETag'), True
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return None, etag, False
        raise


def parse_owner_repo(url: str):
    m = REPO_RE.search(url or '')
    if not m:
        return None, None
    return m.group(1), m.group(2).removesuffix('.git')


def normalize_time(raw, today: dt.date) -> str | None:
    """'09-26' → 补年份（若晚于今天则算去年）；'2025-08-30' → 原样。

    PyYAML 会把未加引号的 2025-08-30 解析成 datetime.date，需要一并处理。
    """
    if not raw:
        return None
    if isinstance(raw, dt.datetime):
        return raw.date().isoformat()
    if isinstance(raw, dt.date):
        # PyYAML 对 MM-DD 也可能解析成 date（年份不定），只取月日再补年
        candidate = raw
        try:
            if raw.year == today.year and (raw.month, raw.day) >= (today.month, today.day):
                candidate = dt.date(today.year - 1, raw.month, raw.day)
            elif raw.year != today.year:
                candidate = dt.date(today.year, raw.month, raw.day)
                if candidate > today:
                    candidate = dt.date(today.year - 1, raw.month, raw.day)
        except Exception:
            pass
        return candidate.isoformat()
    raw = str(raw).strip()
    try:
        if re.fullmatch(r'\d{4}-\d{2}-\d{2}', raw):
            return raw
        if re.fullmatch(r'\d{2}-\d{2}', raw):
            mm, dd = raw.split('-')
            year = today.year
            candidate = dt.date(year, int(mm), int(dd))
            if candidate > today:
                year -= 1
                candidate = dt.date(year, int(mm), int(dd))
            return candidate.isoformat()
    except Exception:
        pass
    return None


def split_assets(assets: list) -> tuple:
    hap, other = [], []
    for a in assets or []:
        item = {
            'name': a.get('name', ''),
            'size': a.get('size', 0),
            'downloadUrl': a.get('browser_download_url', ''),
            'contentType': a.get('content_type', ''),
        }
        if item['name'].lower().endswith(HAP_EXT):
            hap.append(item)
        else:
            other.append(item)
    return hap, other


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--force', action='store_true', help='忽略 ETag，全量重抓')
    ap.add_argument('--limit', type=int, default=0, help='本轮最多处理多少个仓库（0=不限）')
    ap.add_argument('--mode', choices=['auto', 'api', 'html'], default='auto',
                    help='数据获取方式：auto=有配额走 API 否则抓 HTML；api=只用 API；html=只抓网页')
    ap.add_argument('--sleep', type=float, default=0.1, help='请求间隔秒')
    ap.add_argument('--workers', type=int, default=6,
                    help='网页抓取模式的并发数（API 模式始终串行，避免触发限流）')
    ap.add_argument('--no-icons', action='store_true', help='跳过图标抓取（快速重跑数据时用）')
    ap.add_argument('--force-icons', action='store_true', help='忽略本地图标缓存，重新下载')
    ap.add_argument('--icon-workers', type=int, default=6, help='图标抓取并发数')
    ap.add_argument('--out', default=OUT_PATH, help=f'输出路径（默认 {OUT_PATH}）')
    args = ap.parse_args()

    out_path = os.path.abspath(args.out)
    state = load_state()
    today = dt.date.today()

    # 1) 拉 apps.yaml
    print('[1/3] 拉取 apps.yaml ...')
    try:
        text, yaml_etag, changed = fetch_yaml(state.get('yaml_etag'), args.force)
    except Exception as e:
        print(f'  拉取失败：{e}')
        if not os.path.exists(out_path):
            sys.exit(1)
        print('  沿用上次产物，退出')
        return

    if changed:
        state['yaml_etag'] = yaml_etag
        data = yaml.safe_load(text)
        categories_raw = data.get('categories', {})
        print(f'  已更新，共 {len(categories_raw)} 个分类')
    else:
        print('  未变化（304），沿用缓存的解析结果')
        categories_raw = state.get('_last_categories')
        if not categories_raw:
            print('  本地无缓存，强制重新解析')
            text, yaml_etag, _ = fetch_yaml(None, True)
            data = yaml.safe_load(text)
            categories_raw = data.get('categories', {})
            state['yaml_etag'] = yaml_etag
    state['_last_categories'] = categories_raw

    # 2) 展开应用列表
    apps = []
    for ci, (cname, items) in enumerate(categories_raw.items(), start=1):
        for it in items or []:
            url = it.get('url', '')
            owner, repo = parse_owner_repo(url)
            if not owner:
                continue
            apps.append({
                'id': f'{owner}/{repo}'.lower(),
                'name': it.get('name', repo),
                'desc': it.get('desc', ''),
                'category': cname,
                'categoryId': f'c{ci}',
                'owner': owner,
                'repo': repo,
                'repoUrl': url,
                'releaseUrl': it.get('link', ''),
                'iconUrl': '',
                'updatedAt': normalize_time(it.get('time', ''), today),
                'status': 'unknown',
                'release': None,
                'releases': [],
                'hapAssets': [],
                'otherAssets': [],
            })
    unique_repos = {a['id']: (a['owner'], a['repo']) for a in apps}
    print(f'[2/3] 共 {len(apps)} 个应用、{len(unique_repos)} 个独立仓库')

    # 3) 打 GitHub API
    rl = github.rate_limit()
    remaining = rl.get('remaining', 0)
    limit = rl.get('limit', 0)
    print(f'  配额：{remaining}/{limit} 剩余'
          + ('' if github._token() else '（未配置 GITHUB_TOKEN，限流 60/小时）'))

    repos_state = state.setdefault('repos', {})
    processed = 0
    hit, reused, failed = 0, 0, 0
    stale = False

    use_api = args.mode == 'api' or (args.mode == 'auto' and remaining > 2)
    if not use_api:
        print('  无可用 API 配额，改用网页抓取模式（体积信息不可用）')

    NO_RELEASE: dict = {'status': 'no_release', 'release': None, 'releases': [],
                        'hapAssets': [], 'otherAssets': [], 'fail': 0}

    def build_entry(releases: list, etag) -> dict:
        """把 release 列表转成 entry 的更新内容。"""
        rels = []
        for r in releases[:RELEASE_COUNT]:
            hap, other = split_assets(r.get('assets'))
            rels.append({
                'tag': r.get('tag_name', ''),
                'name': r.get('name', ''),
                'publishedAt': r.get('published_at', ''),
                'hapAssets': hap,
                'otherAssets': other,
            })
        if not rels:
            return dict(NO_RELEASE)
        return {
            'etag': etag,
            'tag': rels[0]['tag'],
            'releases': rels,
            # 兼容字段：列表页/卡片仍按「最新一次」渲染
            'release': rels[0],
            'hapAssets': rels[0]['hapAssets'],
            'otherAssets': rels[0]['otherAssets'],
            'status': 'ok' if rels[0]['hapAssets'] else 'no_hap',
            'fail': 0,
        }

    def mark_failed(entry: dict, rid: str, e: Exception) -> None:
        if failed < 3:
            print(f'  ! {rid} 失败：{type(e).__name__} {e}')
        entry['fail'] = entry.get('fail', 0) + 1
        if entry.get('fail', 0) >= 3:
            entry['status'] = 'fetch_error'

    # --- API 模式：串行（配额敏感，且需按响应动态降级） ---
    if use_api:
        for rid, (owner, repo) in unique_repos.items():
            if args.limit and processed >= args.limit:
                print(f'  达到本轮上限 {args.limit}，剩余留到下一轮')
                stale = True
                break
            if remaining <= 2:
                print('  配额即将耗尽，剩余改用网页抓取')
                use_api = False
                break
            entry = repos_state.get(rid, {})
            try:
                status, releases, etag = github.releases_list(
                    owner, repo, per_page=RELEASE_COUNT, etag=entry.get('etag'))
                remaining -= 1
                time.sleep(args.sleep)
                processed += 1
                if status == 304:
                    reused += 1
                    continue
                if status == 200 and releases is not None:
                    entry.update(build_entry(releases, etag))
                    hit += 1
                elif status == 404:
                    entry.update(dict(NO_RELEASE))
                    hit += 1
                else:
                    raise RuntimeError(f'HTTP {status}')
            except github.RateLimitExceeded:
                use_api = False
                break
            except Exception as e:
                mark_failed(entry, rid, e)
                failed += 1
                stale = True
            repos_state[rid] = entry

    # --- 网页模式：并发抓取（不受 API 限流，并发别开太大以免被判滥用） ---
    if not use_api:
        items = list(unique_repos.items())
        if args.limit:
            items = items[:args.limit]
            if len(items) < len(unique_repos):
                stale = True

        def fetch_one(item):
            rid, (owner, repo) = item
            try:
                st, rels = github.recent_releases_html(owner, repo, RELEASE_COUNT)
                return rid, st, rels, None
            except Exception as ex:
                return rid, 0, None, ex

        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            for rid, status, releases, err in pool.map(fetch_one, items):
                processed += 1
                entry = repos_state.get(rid, {})
                try:
                    if err:
                        raise err
                    if status == 200 and releases is not None:
                        entry.update(build_entry(releases, None))
                        hit += 1
                    elif status == 404:
                        entry.update(dict(NO_RELEASE))
                        hit += 1
                    else:
                        raise RuntimeError(f'HTTP {status}')
                except Exception as ex2:
                    mark_failed(entry, rid, ex2)
                    failed += 1
                    stale = True
                repos_state[rid] = entry
                if processed % 20 == 0:
                    # 分批落盘：万一后面中断，前面的抓取不白跑
                    save_state(state)
                    print(f'  进度 {processed}/{len(items)}（已落盘）', flush=True)

    # 4) 回填到应用
    for a in apps:
        e = repos_state.get(a['id'])
        if not e:
            a['status'] = 'unknown'
            continue
        a['status'] = e.get('status', 'unknown')
        a['release'] = e.get('release')
        a['releases'] = e.get('releases', [])
        a['hapAssets'] = e.get('hapAssets', [])
        a['otherAssets'] = e.get('otherAssets', [])

    # 4.5) 打标：功能类型 / 设备类型 / 属性标签（规则引擎，离线零成本）
    tagger.tag_all(apps)
    func_stat: dict = {}
    for a in apps:
        func_stat[a['funcType']] = func_stat.get(a['funcType'], 0) + 1
    print('  打标分布：' + '、'.join(f'{k} {v}' for k, v in
                                  sorted(func_stat.items(), key=lambda x: -x[1])))

    # 4.6) 图标：并发抓仓库内图标 → 落盘缓存 → base64 内嵌进 apps.json
    #     内嵌而非外链，是为了绕开 raw.githubusercontent.com 在国内的不稳定性
    icon_map: dict = {}
    if not args.no_icons:
        repo_apps = {}
        for a in apps:
            repo_apps.setdefault(a['id'], a)

        def fetch_icon(item):
            rid, a = item
            try:
                return rid, icons.ensure_icon(a['owner'], a['repo'], github._token(),
                                              force=args.force_icons)
            except Exception:
                return rid, None

        with ThreadPoolExecutor(max_workers=args.icon_workers) as pool:
            for rid, info in pool.map(fetch_icon, repo_apps.items()):
                icon_map[rid] = icons.as_data_url(info['file']) if info else ''

        for a in apps:
            a['iconUrl'] = icon_map.get(a['id'], '')
        got = sum(1 for a in apps if a['iconUrl'])
        print(f'  图标：{got}/{len(apps)} 个应用拿到图标（内嵌 base64）')

    # 5) 组装输出
    cats = []
    for ci, (cname, items) in enumerate(categories_raw.items(), start=1):
        cid = f'c{ci}'
        cat_apps = [a for a in apps if a['categoryId'] == cid]
        if cat_apps:
            cats.append({'id': cid, 'name': cname, 'apps': cat_apps})

    ok = sum(1 for a in apps if a['status'] == 'ok')
    # 标签维度统计：UI 直接拿去渲染筛选项，不必自己遍历全量
    func_dims, device_dims, tag_dims = {}, {}, {}
    for a in apps:
        func_dims[a['funcType']] = func_dims.get(a['funcType'], 0) + 1
        for d in a['deviceTypes']:
            device_dims[d] = device_dims.get(d, 0) + 1
        for t in a['tags']:
            tag_dims[t] = tag_dims.get(t, 0) + 1
    out = {
        'schemaVersion': 2,
        'generatedAt': dt.datetime.now().astimezone().isoformat(timespec='seconds'),
        'stale': stale,
        'totalApps': len(apps),
        'availableApps': ok,
        'categories': cats,
        'dimensions': {
            'funcType': [{'name': k, 'count': v} for k, v in
                         sorted(func_dims.items(), key=lambda x: -x[1])],
            'deviceType': [{'name': k, 'count': v} for k, v in
                           sorted(device_dims.items(), key=lambda x: -x[1])],
            'tag': [{'name': k, 'count': v} for k, v in
                    sorted(tag_dims.items(), key=lambda x: -x[1])],
        },
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    # 同上：直接覆盖写，避免 os.replace 触发 unlink 被拦截
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2, default=str)

    save_state(state)
    print(f'[3/3] 完成：处理 {processed} / 复用 {reused} / 失败 {failed}')
    print(f'  可用 HAP：{ok}/{len(apps)}，stale={stale}')
    print(f'  输出：{out_path}')


if __name__ == '__main__':
    main()
