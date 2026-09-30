/** 商店数据模型，字段与 hapstore-sync 产出的 apps.json 对齐。 */

export interface AssetInfo {
  name: string;
  size: number;
  downloadUrl: string;
  contentType: string;
}

export interface ReleaseInfo {
  tag: string;
  name: string;
  publishedAt: string;
  hapAssets?: AssetInfo[];
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
