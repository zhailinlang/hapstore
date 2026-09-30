/**
 * data/manifest.json 的数据结构，由 sync/manifest.py 生成。
 *
 * App 端先拉这个约 700B 的小文件，再决定要不要拉 528KB 的 apps.json，
 * 顺便从这里拿到 App 自身的最新版本 —— 这样就不必去打 api.github.com
 * （未鉴权只有 60 次/小时/出口 IP，移动网络 NAT 下极易被耗光）。
 */

export interface SnapshotInfo {
  url: string;
  altUrl: string;
  size: number;
  sha256: string;
  schemaVersion: number;
  generatedAt: string;
  /** 这份快照要求的最低 App 版本；本机低于它就先升级 App，别拉新数据 */
  minAppVersionCode: number;
}

export interface AppReleaseInfo {
  versionCode: number;
  versionName: string;
  tag: string;
  downloadUrl: string;
  size: number;
  sha256: string;
  publishedAt: string;
  releaseUrl: string;
  notes: string;
}

export interface ManifestInfo {
  schemaVersion: number;
  generatedAt: string;
  repo: string;
  snapshot: SnapshotInfo;
  app: AppReleaseInfo;
}

/** 检查 App 更新的结果。 */
export interface AppUpdateResult {
  /** 本机版本 */
  currentVersionCode: number;
  currentVersionName: string;
  /** 有新版本时为 true */
  hasUpdate: boolean;
  /** 最新版本信息，无更新时也可能有值（用于展示「已是最新 vX.Y.Z」） */
  latest: AppReleaseInfo | null;
  /** 快照要求的 App 版本高于本机：先升级 App，否则新数据解析不了 */
  snapshotNeedsNewerApp: boolean;
  message: string;
}
