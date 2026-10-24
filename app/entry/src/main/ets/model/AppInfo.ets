/** 商店数据模型，字段与 hapstore-sync 产出的 apps.json 对齐。 */

export interface AssetInfo {
  name: string;
  size: number;
  downloadUrl: string;
  contentType: string;
  /** true 表示这是装着 HAP 的 zip 压缩包 */
  isZip?: boolean;
}

export interface ReleaseInfo {
  tag: string;
  name: string;
  publishedAt: string;
  hapAssets?: AssetInfo[];
  /** 装着 HAP 的 zip 包 */
  hapZipAssets?: AssetInfo[];
  otherAssets?: AssetInfo[];
}

export interface AppInfo {
  id: string;
  name: string;
  desc: string;
  category: string;
  categoryId: string;
  owner: string;
  repo: string;
  repoUrl: string;
  releaseUrl: string;
  iconUrl: string;
  updatedAt: string;
  status: string;
  /** 最近若干次发布，按新→旧排列；[0] 即最新 */
  releases?: ReleaseInfo[];
  /** 兼容字段：最新一次发布 */
  release?: ReleaseInfo;
  hapAssets: AssetInfo[];
  /** 装着 HAP 的 zip 包（发布方把 .hap 打包发的情况） */
  hapZipAssets: AssetInfo[];
  otherAssets: AssetInfo[];
  /** 打标结果：功能类型（单选） */
  funcType?: string;
  /** 打标结果：设备类型（多选） */
  deviceTypes?: string[];
  /** 打标结果：属性标签（多选），如 自托管 / 第三方客户端 */
  tags?: string[];
}

export interface CategoryInfo {
  id: string;
  name: string;
  apps: AppInfo[];
}

export interface DimensionItem {
  name: string;
  count: number;
}

export interface Dimensions {
  funcType: DimensionItem[];
  deviceType: DimensionItem[];
  tag: DimensionItem[];
}

export interface StoreData {
  schemaVersion: number;
  generatedAt: string;
  stale: boolean;
  totalApps: number;
  availableApps: number;
  categories: CategoryInfo[];
  dimensions?: Dimensions;
}

export const STATUS_TEXT: Record<string, string> = {
  'ok': '可下载',
  'no_release': '暂无 Release',
  'no_hap': 'Release 中无 HAP',
  'fetch_error': '获取失败',
  'unknown': '未同步'
};

export function statusText(status: string): string {
  return STATUS_TEXT[status] ?? '未同步';
}

/** 最近若干次发布。旧数据只有 release 时兜底成单元素数组。 */
export function appReleases(app: AppInfo): ReleaseInfo[] {
  if (app.releases && app.releases.length > 0) {
    return app.releases;
  }
  return app.release ? [app.release] : [];
}

/** 主 HAP 资产：体积最大的那个。 */
export function primaryAsset(app: AppInfo): AssetInfo | undefined {
  if (!app.hapAssets || app.hapAssets.length === 0) {
    return undefined;
  }
  let best: AssetInfo = app.hapAssets[0];
  for (let i = 1; i < app.hapAssets.length; i++) {
    if (app.hapAssets[i].size > best.size) {
      best = app.hapAssets[i];
    }
  }
  return best;
}

/**
 * 首选下载资产：有 HAP 就用 HAP，没有就退到 zip 包。
 *
 * zip 包下载后会被解压出里面的 HAP 再交给装机工具，体验上跟直接下 HAP 一致。
 */
export function preferredAsset(app: AppInfo): AssetInfo | undefined {
  const hap: AssetInfo | undefined = primaryAsset(app);
  if (hap) {
    return hap;
  }
  const zips: AssetInfo[] = appZipAssets(app);
  if (zips.length === 0) {
    return undefined;
  }
  let best: AssetInfo = zips[0];
  for (let i = 1; i < zips.length; i++) {
    if (zips[i].size > best.size) {
      best = zips[i];
    }
  }
  return best;
}

export function formatSize(size: number): string {
  if (!size || size <= 0) {
    return '未知大小';
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(0)} KB`;
  }
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

export function formatDate(raw: string): string {
  if (!raw) {
    return '未知';
  }
  return raw.length >= 10 ? raw.substring(0, 10) : raw;
}

/* ---------- 列表排序 ---------- */

/** 排序方式。存的是短 id，设置里持久化。 */
export const SORT_UPDATED: string = 'updated';
export const SORT_NAME: string = 'name';
export const SORT_SIZE: string = 'size';
export const SORT_DOWNLOADABLE: string = 'downloadable';

export interface SortOption {
  id: string;
  label: string;
}

export const SORT_OPTIONS: SortOption[] = [
  { id: SORT_UPDATED, label: '最近更新' },
  { id: SORT_NAME, label: '名称' },
  { id: SORT_SIZE, label: '体积' },
  { id: SORT_DOWNLOADABLE, label: '可下载优先' }
];

export function sortOptionLabel(id: string): string {
  for (let i = 0; i < SORT_OPTIONS.length; i++) {
    if (SORT_OPTIONS[i].id === id) {
      return SORT_OPTIONS[i].label;
    }
  }
  return SORT_OPTIONS[0].label;
}

/** 主下载体积；没有 HAP 时退到 zip 包的体积，都没有则为 0。 */
export function appAssetSize(app: AppInfo): number {
  const a: AssetInfo | undefined = preferredAsset(app);
  return a ? a.size : 0;
}

/** 排序用的时间戳：优先 release 发布时间，其次 updatedAt。 */
export function appSortTime(app: AppInfo): number {
  const rels: ReleaseInfo[] = appReleases(app);
  if (rels.length > 0 && rels[0].publishedAt.length > 0) {
    const t: number = Date.parse(rels[0].publishedAt);
    if (!isNaN(t)) {
      return t;
    }
  }
  if (app.updatedAt.length > 0) {
    const t2: number = Date.parse(app.updatedAt);
    if (!isNaN(t2)) {
      return t2;
    }
  }
  return 0;
}

/** 是不是当前能拿到安装包（有 HAP 或有 zip）。 */
export function isDownloadable(app: AppInfo): boolean {
  if ((app.hapAssets ?? []).length > 0) {
    return true;
  }
  return appZipAssets(app).length > 0;
}

/**
 * 可下载的 zip 资产。
 *
 * 有些上游只发 .zip（里面装的是 HAP），这类包同样要能下。
 * 排除掉明显是桌面端/安卓端的包（windows / macos / linux / apk 等），
 * 它们在鸿蒙上装了也没用，混进来只会让列表变脏。
 */
export function appZipAssets(app: AppInfo): AssetInfo[] {
  const out: AssetInfo[] = [];
  const pool: AssetInfo[] = [];
  if (app.hapZipAssets) {
    for (let i = 0; i < app.hapZipAssets.length; i++) {
      pool.push(app.hapZipAssets[i]);
    }
  }
  if (app.otherAssets) {
    for (let i = 0; i < app.otherAssets.length; i++) {
      const name: string = app.otherAssets[i].name.toLowerCase();
      // 老数据没有 hapZipAssets 字段，从 otherAssets 里兜底捞一遍
      if (name.endsWith('.zip') && !isDesktopOnlyAsset(name)) {
        pool.push(app.otherAssets[i]);
      }
    }
  }
  for (let i = 0; i < pool.length; i++) {
    const name: string = pool[i].name.toLowerCase();
    if (!name.endsWith('.zip')) {
      continue;
    }
    if (isDesktopOnlyAsset(name)) {
      continue;
    }
    out.push(pool[i]);
  }
  return out;
}

/** 名字里带这些平台标记的 zip 是给别的系统用的，不算鸿蒙安装包。 */
export function isDesktopOnlyAsset(lowerName: string): boolean {
  const marks: string[] = [
    'windows', 'win32', 'win64', 'win-x64', 'win_x64', '-win', '_win',
    'macos', 'mac-arm', 'mac_x', 'mac-', 'mac_arm', 'darwin', 'osx',
    'linux', 'ubuntu', 'deb', 'rpm', 'appimage',
    'apk', 'android'
  ];
  for (let i = 0; i < marks.length; i++) {
    if (lowerName.indexOf(marks[i]) >= 0) {
      return true;
    }
  }
  // 网页壳 / 纯前端包，不是有鸿蒙能力的应用
  const nonHarmony: string[] = ['web', 'webview', 'h5'];
  for (let i = 0; i < nonHarmony.length; i++) {
    if (lowerName.indexOf(nonHarmony[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 按指定方式排序，原地改数组。 */
export function sortApps(apps: AppInfo[], sortId: string): void {
  if (sortId === SORT_NAME) {
    apps.sort((a: AppInfo, b: AppInfo): number => {
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    });
    return;
  }
  if (sortId === SORT_SIZE) {
    // 没包的应用（体积 0）排最后，否则「体积」排序第一屏全是不可下载的
    apps.sort((a: AppInfo, b: AppInfo): number => {
      const sa: number = appAssetSize(a);
      const sb: number = appAssetSize(b);
      const ea: number = sa > 0 ? 0 : 1;
      const eb: number = sb > 0 ? 0 : 1;
      if (ea !== eb) {
        return ea - eb;
      }
      if (ea === 1) {
        return appSortTime(b) - appSortTime(a);
      }
      return sa - sb;
    });
    return;
  }
  if (sortId === SORT_DOWNLOADABLE) {
    apps.sort((a: AppInfo, b: AppInfo): number => {
      const da: number = isDownloadable(a) ? 0 : 1;
      const db: number = isDownloadable(b) ? 0 : 1;
      if (da !== db) {
        return da - db;
      }
      return appSortTime(b) - appSortTime(a);
    });
    return;
  }
  // 默认：最近更新优先
  apps.sort((a: AppInfo, b: AppInfo): number => {
    return appSortTime(b) - appSortTime(a);
  });
}
