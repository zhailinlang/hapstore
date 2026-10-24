/**
 * 「检查更新」的统一结果。
 *
 * 远端快照检查与 App 自身更新检查是两条独立链路，但对外都归一成这个结构，
 * 这样 UI 层只需要处理一种结果：成功有更新 / 成功无更新 / 失败带原因。
 */

/** 检查结果的三种状态。 */
export const CHECK_OK: string = 'ok';
export const CHECK_UPDATED: string = 'updated';
export const CHECK_FAILED: string = 'failed';

/** 快照更新链路的结果。 */
export interface SnapshotCheckOutcome {
  /** ok / updated / failed */
  status: string;
  /** 给用户看的一句话结论 */
  message: string;
  /** 失败原因（status=failed 时有值） */
  reason: string;
  /** 本次真正生效的新快照（没变化或失败时为空） */
  applied: boolean;
  /** 新增 + 版本更新 + 移除的条数 */
  added: number;
  versionChanged: number;
  removed: number;
}

/** App 自身更新的结果。 */
export interface SelfUpdateOutcome {
  status: string;
  message: string;
  reason: string;
  /** 有新版本时可下载的 release */
  hasUpdate: boolean;
  versionName: string;
  currentVersionName: string;
}

/** 一次完整检查（快照 + App 自身）的汇总。 */
export interface CheckOutcome {
  snapshot: SnapshotCheckOutcome;
  self: SelfUpdateOutcome;
  /** 本机当前版本 */
  selfVersionName: string;
  /** 是否有任何一条链路发现了值得提示用户的更新 */
  notable: boolean;
}
