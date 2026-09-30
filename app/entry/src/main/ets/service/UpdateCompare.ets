import { AppInfo, StoreData, appReleases } from '../model/AppInfo';
import { InstalledUpdate, StoreDiff, TimelineItem, VersionChange } from '../model/UpdateInfo';
import { DownloadRecord, DL_DONE } from '../model/DownloadRecord';

/** 把分类展开成一维列表。 */
export function flatApps(data: StoreData): AppInfo[] {
  const list: AppInfo[] = [];
  if (!data || !data.categories) {
    return list;
  }
  for (let i = 0; i < data.categories.length; i++) {
    const apps: AppInfo[] = data.categories[i].apps ?? [];
    for (let j = 0; j < apps.length; j++) {
      list.push(apps[j]);
    }
  }
  return list;
}

/** 线性查找：ArkTS 里 Record 索引返回类型不含 undefined，用遍历更稳。 */
export function findIndexById(apps: AppInfo[], id: string): number {
  for (let i = 0; i < apps.length; i++) {
    if (apps[i].id === id) {
      return i;
    }
  }
  return -1;
}

function latestTag(app: AppInfo): string {
  const rel = appReleases(app);
  return rel.length > 0 ? (rel[0].tag ?? '') : '';
}

function latestPublishedAt(app: AppInfo): string {
  const rel = appReleases(app);
  return rel.length > 0 ? (rel[0].publishedAt ?? '') : '';
}

/** 对比两份快照：新增 / 移除 / 版本变化。 */
export function diffStore(local: StoreData, remote: StoreData): StoreDiff {
  const la: AppInfo[] = flatApps(local);
  const ra: AppInfo[] = flatApps(remote);
  const added: AppInfo[] = [];
  const removed: AppInfo[] = [];
  const versionChanged: VersionChange[] = [];

  for (let i = 0; i < ra.length; i++) {
    const j: number = findIndexById(la, ra[i].id);
    if (j < 0) {
      added.push(ra[i]);
      continue;
    }
    const oldTag: string = latestTag(la[j]);
    const newTag: string = latestTag(ra[i]);
    if (oldTag !== newTag) {
      const change: VersionChange = {
        id: ra[i].id,
        name: ra[i].name,
        oldTag: oldTag,
        newTag: newTag,
        publishedAt: latestPublishedAt(ra[i])
      };
      versionChanged.push(change);
    }
  }

  for (let i = 0; i < la.length; i++) {
    if (findIndexById(ra, la[i].id) < 0) {
      removed.push(la[i]);
    }
  }

  const diff: StoreDiff = {
    oldGeneratedAt: local.generatedAt ?? '',
    newGeneratedAt: remote.generatedAt ?? '',
    oldSchemaVersion: local.schemaVersion ?? 0,
    newSchemaVersion: remote.schemaVersion ?? 0,
    added: added,
    removed: removed,
    versionChanged: versionChanged,
    changeCount: added.length + versionChanged.length,
    checkedAt: Date.now()
  };
  return diff;
}

/** 最近更新时间线：按最新 release 的发布时间倒序，没发布时间的排后面。 */
export function buildTimeline(data: StoreData, limit: number): AppInfo[] {
  const apps: AppInfo[] = flatApps(data);
  const withTime: AppInfo[] = [];
  const withoutTime: AppInfo[] = [];
  for (let i = 0; i < apps.length; i++) {
    if (latestPublishedAt(apps[i]).length > 0) {
      withTime.push(apps[i]);
    } else {
      withoutTime.push(apps[i]);
    }
  }
  withTime.sort((a: AppInfo, b: AppInfo) => {
    const at: string = latestPublishedAt(a);
    const bt: string = latestPublishedAt(b);
    if (at === bt) {
      return 0;
    }
    return at > bt ? -1 : 1;
  });
  const all: AppInfo[] = withTime.concat(withoutTime);
  if (all.length > limit) {
    return all.slice(0, limit);
  }
  return all;
}

/** 已下载过的应用里，哪些在当前快照中有了新版本。 */
export function findInstalledUpdates(data: StoreData, records: DownloadRecord[]): InstalledUpdate[] {
  const apps: AppInfo[] = flatApps(data);
  const out: InstalledUpdate[] = [];
  const seen: string[] = [];
  for (let i = 0; i < records.length; i++) {
    const rec: DownloadRecord = records[i];
    if (rec.status !== DL_DONE) {
      continue;
    }
    const idx: number = findAppIndex(apps, rec);
    if (idx < 0) {
      continue;
    }
    const app: AppInfo = apps[idx];
    const latest: string = latestTag(app);
    if (latest.length === 0 || rec.tag === latest) {
      continue;
    }
    if (seen.indexOf(app.id) >= 0) {
      continue;
    }
    seen.push(app.id);
    const item: InstalledUpdate = {
      appId: app.id,
      appName: app.name,
      downloadedTag: rec.tag,
      latestTag: latest
    };
    out.push(item);
  }
  return out;
}

function findAppIndex(apps: AppInfo[], rec: DownloadRecord): number {
  const appId: string = rec.appId ?? '';
  if (appId.length > 0) {
    return findIndexById(apps, appId);
  }
  // 老记录没有 appId，退化成按名字匹配
  for (let i = 0; i < apps.length; i++) {
    if (apps[i].name === rec.appName) {
      return i;
    }
  }
  return -1;
}

export function findAppById(data: StoreData, id: string): AppInfo | null {
  const apps: AppInfo[] = flatApps(data);
  const idx: number = findIndexById(apps, id);
  return idx >= 0 ? apps[idx] : null;
}
