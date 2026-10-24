#!/usr/bin/env python3
"""把 state.json 里已抓到的资产按新规则重新分类（补 hapZipAssets）。

背景：split_assets 增加了「装着 HAP 的 zip」这一类，但 state.json 里存的是
按旧规则分类好的结果（zip 全在 otherAssets 里）。全量重抓要 4 分钟且可能撞限流，
这里直接用已缓存的原始资产离线重跑一遍分类，再重写 apps.json。

前提：state.json 的 entry 里保留了原始的 otherAssets/hapAssets，
      而 zip 之前就是落在 otherAssets 里，所以信息是全的。
"""

import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
sys.path.insert(0, BASE)

import sync  # noqa: E402

STATE_PATH = os.path.join(BASE, 'state.json')
APPS_PATH = os.path.join(ROOT, 'data', 'apps.json')


def reclassify(entry: dict) -> dict:
    """按新规则重跑一次资产分类。"""
    rels = entry.get('releases') or []
    new_rels = []
    for rel in rels:
        hap = list(rel.get('hapAssets') or [])
        other = list(rel.get('otherAssets') or [])
        # 把 old other 里的 zip 重新分出来：合成的资产列表再走一遍 split_assets
        merged = list(hap) + list(other)
        nhap, nzip, nother = sync.split_assets(merged)
        new_rels.append({
            'tag': rel.get('tag', ''),
            'name': rel.get('name', ''),
            'publishedAt': rel.get('publishedAt', ''),
            'hapAssets': nhap,
            'hapZipAssets': nzip,
            'otherAssets': nother,
        })
    if not new_rels:
        return entry
    first = new_rels[0]
    out = dict(entry)
    out['releases'] = new_rels
    out['release'] = first
    out['hapAssets'] = first['hapAssets']
    out['hapZipAssets'] = first['hapZipAssets']
    out['otherAssets'] = first['otherAssets']
    out['status'] = 'ok' if (first['hapAssets'] or first['hapZipAssets']) else 'no_hap'
    return out


def main():
    with open(STATE_PATH, 'r', encoding='utf-8') as f:
        state = json.load(f)
    repos = state.get('repos', {})
    changed = 0
    for rid, entry in repos.items():
        new = reclassify(entry)
        if new != entry:
            repos[rid] = new
            changed += 1
    with open(STATE_PATH, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False, indent=2, default=str)
    print(f'state.json：重新分类 {changed}/{len(repos)} 个仓库')

    # 重写 apps.json：套用 state 里的最新分类
    with open(APPS_PATH, 'r', encoding='utf-8') as f:
        apps_data = json.load(f)
    n_zip = 0
    n_new_ok = 0
    for cat in apps_data.get('categories', []):
        for app in cat.get('apps', []):
            e = repos.get(app.get('id'))
            if not e:
                continue
            app['hapAssets'] = e.get('hapAssets', [])
            app['hapZipAssets'] = e.get('hapZipAssets', [])
            app['otherAssets'] = e.get('otherAssets', [])
            rels = e.get('releases') or []
            app['releases'] = rels
            if rels:
                app['release'] = rels[0]
            app['status'] = e.get('status', app.get('status', 'unknown'))
            if app['hapZipAssets']:
                n_zip += 1
    with open(APPS_PATH, 'w', encoding='utf-8') as f:
        json.dump(apps_data, f, ensure_ascii=False, indent=1)
    print(f'apps.json：{n_zip} 个应用有可下载的 zip 包')

    ok = sum(1 for c in apps_data.get('categories', []) for a in c.get('apps', [])
             if a.get('status') == 'ok')
    print(f'可下载应用数：{ok}')


if __name__ == '__main__':
    main()
