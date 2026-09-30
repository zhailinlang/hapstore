"""GitHub API 封装：PAT 鉴权、ETag 增量、限流保护、失败退避。"""

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

API = 'https://api.github.com'
WEB = 'https://github.com'
UA = 'hapstore-sync/1.0 (Mozilla compatible)'


def _token() -> str:
    return os.environ.get('GITHUB_TOKEN', '').strip()


def _headers(extra: dict | None = None) -> dict:
    h = {
        'User-Agent': UA,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }
    tok = _token()
    if tok:
        h['Authorization'] = f'Bearer {tok}'
    if extra:
        h.update(extra)
    return h


class RateLimitExceeded(Exception):
    pass


def get(url: str, etag: str | None = None, timeout: int = 30):
    """返回 (status, data, etag)。304 时 data 为 None。"""
    req = urllib.request.Request(url, headers=_headers({'If-None-Match': etag} if etag else None))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode('utf-8', 'replace')
            return resp.status, json.loads(body) if body else None, resp.headers.get('ETag')
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return 304, None, etag
        if e.code in (403, 429):
            raise RateLimitExceeded(f'{e.code} {e.reason}')
        return e.code, None, None
    except Exception as e:  # 网络错误
        return 0, None, None


def rate_limit() -> dict:
    """查询剩余配额。失败返回保守值。"""
    try:
        status, data, _ = get(f'{API}/rate_limit')
        if status == 200 and data:
            core = data.get('resources', {}).get('core', {})
            return {'remaining': core.get('remaining', 0), 'limit': core.get('limit', 0),
                    'reset': core.get('reset', 0)}
    except Exception:
        pass
    return {'remaining': 0, 'limit': 0, 'reset': 0}


def latest_release(owner: str, repo: str, etag: str | None = None):
    """取最新 release。返回 (status, payload, etag)，status: 200/304/404/0。"""
    return get(f'{API}/repos/{owner}/{repo}/releases/latest', etag=etag)


def releases_list(owner: str, repo: str, per_page: int = 2, etag: str | None = None):
    """取最近 N 个 release（一次调用拿多个，省配额）。

    返回 (status, list_of_release, etag)。列表按发布时间倒序（最新的在前）。
    """
    status, data, new_etag = get(
        f'{API}/repos/{owner}/{repo}/releases?per_page={per_page}', etag=etag)
    if status == 200 and isinstance(data, list):
        return 200, data, new_etag
    return status, None, new_etag


def latest_release_html(owner: str, repo: str, timeout: int = 30):
    """无 Token / 配额耗尽时的兜底：抓 releases 页面 HTML 解析下载直链。

    返回 (status, payload)；payload 结构与 API 的 release 对齐，但 assets 的 size 恒为 0。
    """
    url = f'{WEB}/{owner}/{repo}/releases/latest'
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            final_url = resp.geturl()
            html = resp.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None

    tag = ''
    m = re.search(r'/releases/tag/([^"?#]+)', final_url)
    if m:
        tag = urllib.parse.unquote(m.group(1))
    if not tag:
        # 仓库改名等情况下会重定向到 /releases 列表页，此时从列表里取第一个 tag
        m0 = re.search(r'/releases/tag/([^"?#<>\\]+)', html)
        if m0:
            tag = urllib.parse.unquote(m0.group(1))
        else:
            tag = _first_tag_from_list(owner, repo, timeout)
    if not tag:
        return 200, {'tag_name': '', 'name': '', 'published_at': '', 'assets': []}

    return 200, {
        'tag_name': tag,
        'name': tag,
        'published_at': '',
        'assets': _assets_for_tag(owner, repo, tag, timeout),
    }


def _assets_for_tag(owner: str, repo: str, tag: str, timeout: int = 30) -> list:
    """抓某个 tag 的资产列表。

    GitHub 的资源列表是异步加载的，必须单独请求 expanded_assets 片段页。
    """
    frag_url = f'{WEB}/{owner}/{repo}/releases/expanded_assets/{urllib.parse.quote(tag, safe="")}'
    try:
        req = urllib.request.Request(frag_url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            html = resp.read().decode('utf-8', 'replace')
    except Exception:
        return []

    # 注意：GitHub 的链接大小写与原仓库名可能不一致，用通用匹配而非 escape(owner/repo)
    assets, seen = [], set()
    for m in re.finditer(r'href="(/[^"]+/releases/download/[^"]+)"', html):
        href = m.group(1)
        if href in seen:
            continue
        seen.add(href)
        assets.append({
            'name': urllib.parse.unquote(href.rsplit('/', 1)[-1]),
            'size': probe_size(WEB + href),
            'browser_download_url': WEB + href,
            'content_type': 'application/octet-stream',
        })
    return assets


def _tags_from_list_page(owner: str, repo: str, count: int = 2, timeout: int = 30) -> list:
    """从 releases 列表页按出现顺序提取前 count 个 tag。"""
    try:
        req = urllib.request.Request(f'{WEB}/{owner}/{repo}/releases',
                                     headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            page = resp.read().decode('utf-8', 'replace')
    except Exception:
        return []

    tags, seen = [], set()
    for m in re.finditer(r'/releases/tag/([^"?#<>\\]+)', page):
        tag = urllib.parse.unquote(m.group(1))
        if tag in seen:
            continue
        seen.add(tag)
        tags.append(tag)
        if len(tags) >= count:
            break
    return tags


def _latest_tag(owner: str, repo: str, timeout: int = 30) -> str:
    """只取官方认定的 latest tag（跟随 /releases/latest 的 302）。

    列表页的出现顺序不等于发布时间顺序（置顶、pre-release 都会打乱），
    所以第一个 release 必须以这个为准。
    """
    try:
        req = urllib.request.Request(f'{WEB}/{owner}/{repo}/releases/latest',
                                     headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            final_url = resp.geturl()
        m = re.search(r'/releases/tag/([^"?#]+)', final_url)
        if m:
            return urllib.parse.unquote(m.group(1))
    except Exception:
        pass
    return ''


def recent_releases_html(owner: str, repo: str, count: int = 2, timeout: int = 30):
    """无 Token / 配额耗尽时的兜底：抓最近 count 个 release。

    返回 (status, [release, ...])；每个 release 结构与 API 对齐，但 published_at 为空
    （网页模式拿不到发布时间）、assets 的 size 靠 HEAD 探测。
    """
    tags = _tags_from_list_page(owner, repo, count + 2, timeout)
    if not tags:
        # 列表页拿不到（如仓库无 release），退回 latest 通道
        status, payload = latest_release_html(owner, repo, timeout)
        return status, [payload] if payload else []

    # 第一个必须是官方 latest，其余按列表页顺序补齐
    latest = _latest_tag(owner, repo, timeout)
    ordered = [latest] if latest else []
    for t in tags:
        if t != latest and t not in ordered:
            ordered.append(t)
    ordered = ordered[:count]

    releases = []
    for tag in ordered:
        releases.append({
            'tag_name': tag,
            'name': tag,
            'published_at': '',
            'assets': _assets_for_tag(owner, repo, tag, timeout),
        })
    return 200, releases


def _first_tag_from_list(owner: str, repo: str, timeout: int = 30) -> str:
    """/releases/latest 拿不到 tag 时，从 releases 列表页取第一个 tag。"""
    try:
        req = urllib.request.Request(f'{WEB}/{owner}/{repo}/releases', headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            page = resp.read().decode('utf-8', 'replace')
        m = re.search(r'/releases/tag/([^"?#<>\\]+)', page)
        return urllib.parse.unquote(m.group(1)) if m else ''
    except Exception:
        return ''


def probe_size(url: str, timeout: int = 15) -> int:
    """HEAD 探测文件体积，失败返回 0。"""
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA}, method='HEAD')
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return int(resp.headers.get('Content-Length', 0) or 0)
    except Exception:
        return 0
