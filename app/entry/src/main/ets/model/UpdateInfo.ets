import { AppInfo } from './AppInfo';

/** 单个应用的版本变化。 */
export interface VersionChange {
  id: string;
  name: string;
  oldTag: string;
  newTag: string;
  publishedAt: string;
}

/** 本地快照 vs 远端 apps.json 的差异。 */
export interface StoreDiff {
  oldGeneratedAt: string;
  newGeneratedAt: string;
  oldSchemaVersion: number;
  newSchemaVersion: number;
  added: AppInfo[];
  removed: AppInfo[];
  versionChanged: VersionChange[];
  /** added + versionChanged，用于「更新」Tab 的红点 */
  changeCount: number;
  checkedAt: number;
}

/** 最近更新时间线的一条。 */
export interface TimelineItem {
  appId: string;
  appName: string;
  tag: string;
  publishedAt: string;
  iconUrl: string;
  status: string;
}

/** 已下载过、但当前快照里有新版本的应用。 */
export interface InstalledUpdate {
  appId: string;
  appName: string;
  downloadedTag: string;
  latestTag: string;
}
