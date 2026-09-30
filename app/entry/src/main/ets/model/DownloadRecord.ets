/** 下载任务记录（持久化在 filesDir/downloads.json，跨会话保留）。 */

export const DL_DOWNLOADING: string = 'downloading';
export const DL_PAUSED: string = 'paused';
export const DL_DONE: string = 'done';
export const DL_FAILED: string = 'failed';
export const DL_CANCELED: string = 'canceled';

export interface DownloadRecord {
  /** request.agent 的任务 id，同时作为记录主键 */
  tid: string;
  /** 所属应用的 id（owner/repo 小写），用于「已下载应用的新版本提醒」 */
  appId: string;
  appName: string;
  assetName: string;
  /** 所属 Release 版本号 */
  tag: string;
  /** 原始下载链接（未做镜像改写） */
  url: string;
  size: number;
  status: string;
  /** 用户选择的保存位置（Picker URI） */
  saveUri: string;
  /** 最终文件名，安装引导页与「另存为」要用 */
  fileName: string;
  /** 应用沙箱内的正式文件（下载完成后由 .part 改名而来） */
  localPath: string;
  /** 实际发起下载时用的链接（镜像改写后），排查镜像问题全靠它 */
  finalUrl: string;
  /** 失败时的错误码 / 错误说明 */
  errCode: number;
  errMsg: string;
  /** 本次下载走的链路描述，如「镜像 gh-proxy.com」 */
  via: string;
  startedAt: number;
  finishedAt: number;
  processed: number;
}

/** 列表展示用：把持久记录与 request.agent 的实时状态合成一条。 */
export interface DownloadItem extends DownloadRecord {
  /** 实时进度百分比 0-100 */
  percent: number;
  /** 实时状态文案 */
  stateText: string;
  /** 是否仍受系统下载服务托管（可暂停/继续/取消） */
  alive: boolean;
  /** 系统下载服务给出的状态码，仅 alive 时有效 */
  sysState: number;
}

export const DL_STATUS_TEXT: Record<string, string> = {
  'downloading': '下载中',
  'paused': '已暂停',
  'done': '已完成',
  'failed': '失败',
  'canceled': '已取消'
};

export function downloadStatusText(status: string): string {
  return DL_STATUS_TEXT[status] ?? '未知';
}

/** 补齐老记录缺的字段，避免 UI 里到处判空。 */
export function normalizeRecord(raw: DownloadRecord): DownloadRecord {
  const rec: DownloadRecord = {
    tid: raw.tid ?? '',
    appId: raw.appId ?? '',
    appName: raw.appName ?? '',
    assetName: raw.assetName ?? '',
    tag: raw.tag ?? '',
    url: raw.url ?? '',
    size: raw.size ?? 0,
    status: raw.status ?? DL_FAILED,
    saveUri: raw.saveUri ?? '',
    fileName: raw.fileName ?? (raw.assetName ?? ''),
    localPath: raw.localPath ?? '',
    finalUrl: raw.finalUrl ?? (raw.url ?? ''),
    errCode: raw.errCode ?? 0,
    errMsg: raw.errMsg ?? '',
    via: raw.via ?? '',
    startedAt: raw.startedAt ?? 0,
    finishedAt: raw.finishedAt ?? 0,
    processed: raw.processed ?? 0
  };
  return rec;
}
