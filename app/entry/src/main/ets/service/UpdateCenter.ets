import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { StoreData } from '../model/AppInfo';
import {
  CHECK_FAILED,
  CHECK_OK,
  CHECK_UPDATED,
  CheckOutcome,
  SelfUpdateOutcome,
  SnapshotCheckOutcome
} from '../model/UpdateOutcome';
import { AppUpdateResult } from '../model/ManifestData';
import { StoreDiff } from '../model/UpdateInfo';
import { HLog } from '../common/HLog';
import { AppUpdateService } from './AppUpdateService';
import { NetworkService } from './NetworkService';
import { RemoteStoreService } from './RemoteStoreService';
import { SettingsStore } from './SettingsStore';
import { StoreRepository } from './StoreRepository';
import { diffStore } from './UpdateCompare';

/**
 * 更新编排中心。
 *
 * 两条链路，统一出口：
 * 1. 远端快照（apps.json）—— 拉取 → 比对 → 直接写入本机生效，不需要用户再点一次「应用」；
 * 2. App 自身（manifest.json）—— 发现新版本后提示，下载交给安装引导页（系统不允许静默安装）。
 *
 * 设计要点：
 * - 「检查更新」按钮一次点击跑完全流程，不留中间态需要用户确认；
 * - 启动自动检查走同一套逻辑，只是把结论用 tips 弹出来，不打扰流程；
 * - 任何一步失败都要给出人能看懂的原因，而不是一句「失败」。
 */
export class UpdateCenter {
  private context: common.UIAbilityContext;
  /** 本次会话内是否已经自动检查过，避免重复弹窗 */
  private static autoChecked: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 远端快照检查 + 应用。
   *
   * 关键点：拉到的远端数据在同一个流程里直接落盘生效（applyRemoteJson），
   * 比对结果只是用来告诉用户「变了多少」，而不是再问一次「要不要应用」。
   */
  async checkAndApplySnapshot(): Promise<SnapshotCheckOutcome> {
    const settings = SettingsStore.shared().get();
    if (settings.sourceUrl.trim().length === 0) {
      return UpdateCenter.snapshotFailed('没有配置数据源地址', '请到「设置 → 数据源与检查更新」填入远端 apps.json 地址');
    }
    if (!NetworkService.isOnline()) {
      return UpdateCenter.snapshotFailed('当前无网络', '连上网络后再试一次');
    }

    const repo = new StoreRepository(this.context);
    const service = new RemoteStoreService(this.context);
    try {
      const local: StoreData = await repo.load();
      const got = await service.fetchText(settings.snapshotEtag);

      if (got.notModified) {
        // 304：服务端确认快照没变，写回 ETag 即可，不必再解析
        SettingsStore.shared().apply({ lastCheckAt: Date.now() });
        HLog.i('快照未变化（304）');
        const same: SnapshotCheckOutcome = {
          status: CHECK_OK,
          message: '应用数据已是最新',
          reason: '',
          applied: false,
          added: 0,
          versionChanged: 0,
          removed: 0
        };
        return same;
      }

      const remote: StoreData = repo.parseText(got.text);
      const result: StoreDiff = diffStore(local, remote);

      // 直接生效，不再让用户点第二次
      repo.applyRemoteJson(got.text);
      const epoch: number = AppStorage.get<number>('storeEpoch') ?? 0;
      AppStorage.setOrCreate('storeEpoch', epoch + 1);
      AppStorage.setOrCreate('updateCount', 0);

      SettingsStore.shared().apply({
        lastCheckAt: Date.now(),
        lastRemoteGeneratedAt: remote.generatedAt ?? '',
        snapshotEtag: got.etag
      });

      const total: number = result.added.length + result.versionChanged.length + result.removed.length;
      if (total === 0) {
        const same2: SnapshotCheckOutcome = {
          status: CHECK_OK,
          message: '应用数据已是最新',
          reason: '',
          applied: false,
          added: 0,
          versionChanged: 0,
          removed: 0
        };
        return same2;
      }

      HLog.i(`快照已更新：新增 ${result.added.length}、版本变化 ${result.versionChanged.length}、移除 ${result.removed.length}`);
      const out: SnapshotCheckOutcome = {
        status: CHECK_UPDATED,
        message: `更新成功：新增 ${result.added.length} 个、版本更新 ${result.versionChanged.length} 个、移除 ${result.removed.length} 个`,
        reason: '',
        applied: true,
        added: result.added.length,
        versionChanged: result.versionChanged.length,
        removed: result.removed.length
      };
      return out;
    } catch (e) {
      const err: Error = e as Error;
      HLog.w(`快照检查失败：${err.message}`);
      return UpdateCenter.snapshotFailed('更新失败', err.message ?? '未知错误');
    }
  }

  /** App 自身版本检查。只读 manifest（约 700B），不下载任何东西。 */
  async checkSelfVersion(): Promise<SelfUpdateOutcome> {
    const currentName: string = AppUpdateService.selfVersionName();
    if (!NetworkService.isOnline()) {
      return UpdateCenter.selfFailed(currentName, '当前无网络');
    }
    try {
      const r: AppUpdateResult = await new AppUpdateService(this.context).check();
      if (r.snapshotNeedsNewerApp) {
        return UpdateCenter.selfFailed(currentName, r.message);
      }
      if (r.hasUpdate) {
        const out: SelfUpdateOutcome = {
          status: CHECK_UPDATED,
          message: `HapStore 有新版本 v${r.latest?.versionName ?? ''}（当前 v${currentName}）`,
          reason: '',
          hasUpdate: true,
          versionName: r.latest?.versionName ?? '',
          currentVersionName: currentName
        };
        return out;
      }
      const ok: SelfUpdateOutcome = {
        status: CHECK_OK,
        message: `HapStore 已是最新（v${currentName}）`,
        reason: '',
        hasUpdate: false,
        versionName: r.latest?.versionName ?? currentName,
        currentVersionName: currentName
      };
      return ok;
    } catch (e) {
      const err: Error = e as Error;
      return UpdateCenter.selfFailed(currentName, err.message ?? '未知错误');
    }
  }

  /**
   * 手动「检查更新」：一次跑完两条链路，并弹 tips 告诉用户结果。
   *
   * 这是更新页按钮的唯一入口 —— 用户不需要再点「应用更新到本机数据」。
   */
  async runFullCheck(showTips: boolean): Promise<CheckOutcome> {
    const snapshot: SnapshotCheckOutcome = await this.checkAndApplySnapshot();
    const self: SelfUpdateOutcome = await this.checkSelfVersion();
    const outcome: CheckOutcome = {
      snapshot: snapshot,
      self: self,
      selfVersionName: self.currentVersionName,
      notable: snapshot.status === CHECK_UPDATED || self.status === CHECK_UPDATED
    };
    if (showTips) {
      UpdateCenter.showOutcomeTips(outcome);
    }
    return outcome;
  }

  /**
   * 启动时自动检查。
   *
   * 只在开关打开、距上次检查超过间隔、且有网络时跑。
   * 有更新或失败时才弹 tips 提示（已是最新就静默，免得每次开 App 都被弹一下）。
   */
  async autoCheckOnLaunch(): Promise<CheckOutcome | null> {
    if (UpdateCenter.autoChecked) {
      return null;
    }
    const s = SettingsStore.shared().get();
    if (!s.autoCheckOnLaunch) {
      return null;
    }
    if (s.sourceUrl.trim().length === 0) {
      return null;
    }
    if (Date.now() - s.lastCheckAt < s.checkIntervalHours * 3600 * 1000) {
      return null;
    }
    if (!NetworkService.isOnline()) {
      return null;
    }
    UpdateCenter.autoChecked = true;
    HLog.i('启动自动检查开始');
    const outcome: CheckOutcome = await this.runFullCheck(false);
    // 有更新才主动提示；失败也提示原因，用户能知道为什么没更新
    if (outcome.notable || outcome.snapshot.status === CHECK_FAILED) {
      UpdateCenter.showOutcomeTips(outcome);
    }
    return outcome;
  }

  /** 结果提示文案：成功给结论，失败给原因。 */
  static outcomeText(outcome: CheckOutcome): string {
    const s: SnapshotCheckOutcome = outcome.snapshot;
    if (s.status === CHECK_FAILED) {
      return `更新失败：${s.reason}`;
    }
    if (s.status === CHECK_UPDATED) {
      return s.message;
    }
    if (outcome.self.status === CHECK_UPDATED) {
      return outcome.self.message;
    }
    if (outcome.self.status === CHECK_FAILED) {
      return `HapStore 版本检查失败：${outcome.self.reason}`;
    }
    return s.message;
  }

  /** 弹出结果 tips。失败时带原因，方便用户判断是网络问题还是地址问题。 */
  static showOutcomeTips(outcome: CheckOutcome): void {
    const text: string = UpdateCenter.outcomeText(outcome);
    if (text.length === 0) {
      return;
    }
    promptAction.showToast({ message: text });
  }

  private static snapshotFailed(reason: string, detail: string): SnapshotCheckOutcome {
    const out: SnapshotCheckOutcome = {
      status: CHECK_FAILED,
      message: reason,
      reason: detail,
      applied: false,
      added: 0,
      versionChanged: 0,
      removed: 0
    };
    return out;
  }

  private static selfFailed(currentName: string, reason: string): SelfUpdateOutcome {
    const out: SelfUpdateOutcome = {
      status: CHECK_FAILED,
      message: '版本检查失败',
      reason: reason,
      hasUpdate: false,
      versionName: '',
      currentVersionName: currentName
    };
    return out;
  }
}
