import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { AssetInfo } from '../model/AppInfo';
import {
  DownloadItem,
  DownloadRecord,
  DL_CANCELED,
  DL_DONE,
  DL_DOWNLOADING,
  DL_FAILED,
  DL_PAUSED,
  downloadStatusText
} from '../model/DownloadRecord';
import { nameHasVersion, uriDisplayName } from '../model/SettingsData';
import { DownloadStore } from './DownloadStore';
import { DownloadFileManager } from './DownloadFileManager';
import { MirrorService } from './MirrorService';
import { SettingsStore } from './SettingsStore';
import { HLog } from '../common/HLog';

export interface DownloadCallbacks {
  onProgress?: (processed: number, total: number) => void;
  onStage?: (text: string) => void;
}

/** 发起下载需要的最小上下文，供下载管理页「重新下载」复用。 */
export interface DownloadMeta {
  appName: string;
  asset: AssetInfo;
  tag: string;
  /** 应用 id，用于「已下载应用的新版本提醒」 */
  appId?: string;
}

interface LaunchResult {
  tid: string;
  ok: boolean;
  errCode: number;
  errMsg: string;
}

/**
 * 下载 HAP。
 *
 * 两条硬约束（SDK 26，已核对 @ohos.request.d.ts）：
 * - pause() 只接受 WAITING / RUNNING / RETRYING，resume() 只接受 PAUSED，
 *   stop() 只接受 RUNNING / WAITING / RETRYING，否则一律抛 21900007。
 *   所以每个控制动作前都先 show(tid) 看状态，不匹配就给中文提示而不是把异常抛给用户。
 * - 下到用户目录必须 Mode.FOREGROUND + overwrite=true。
 *
 * 落盘走沙箱中转：xxx.hap.part → 校验 → 改名 → 复制到用户选的位置（可覆盖）。
 */
export class DownloadService {
  private static inst: DownloadService | null = null;
  private context: common.UIAbilityContext;
  private store: DownloadStore;
  private files: DownloadFileManager;
  private tasks: Map<string, request.agent.Task> = new Map();

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = new DownloadStore(context);
    this.files = new DownloadFileManager(context);
  }

  static shared(context?: common.UIAbilityContext): DownloadService {
    if (!DownloadService.inst) {
      const ctx: common.UIAbilityContext = context ?? (getContext() as common.UIAbilityContext);
      DownloadService.inst = new DownloadService(ctx);
    }
    return DownloadService.inst;
  }

  async download(meta: DownloadMeta, cb?: DownloadCallbacks): Promise<string> {
    const asset: AssetInfo = meta.asset;
    const fileName: string = this.files.safeName(asset.name);
    const temp: string = this.files.tempPath(asset.name);
    const final: string = this.files.finalPath(asset.name);

    cb?.onStage?.('准备保存位置');
    const named: string = this.versionedName(fileName, meta.tag);
    let targetUri: string = await this.resolveTarget(meta.appName, named);

    const rawUrl: string = asset.downloadUrl;
    const primary: string = MirrorService.apply(rawUrl);
    HLog.i(`下载 ${fileName} 走 ${MirrorService.describe()} -> ${primary}`);

    let r: LaunchResult = await this.launch(meta, asset, primary, temp, cb, '');

    // 失败且开了自动回退：换另一条链路（镜像 ↔ 直连）再试一次
    if (!r.ok && SettingsStore.shared().get().mirrorFallback) {
      const alt: string = MirrorService.fallback(rawUrl);
      if (alt.length > 0 && alt !== primary) {
        HLog.w(`链路失败，改走备用：${alt}`);
        cb?.onStage?.('换用备用链路重试');
        this.store.updateStatus(r.tid, DL_DOWNLOADING);
        r = await this.launch(meta, asset, alt, temp, cb, r.tid);
      }
    }

    if (!r.ok) {
      this.store.finish(r.tid, DL_FAILED, r.errCode, r.errMsg);
      this.files.deleteLocal(temp);
      this.forget(r.tid);
      throw new Error(r.errMsg.length > 0 ? r.errMsg : '下载失败');
    }

    cb?.onStage?.('校验文件');
    if (!this.files.verify(temp, asset.size)) {
      const real: number = this.files.sizeOf(temp);
      const msg: string = `文件不完整（${real} / ${asset.size} 字节），已保留临时文件`;
      HLog.e(msg);
      this.store.finish(r.tid, DL_FAILED, -2, msg);
      this.forget(r.tid);
      throw new Error(msg);
    }

    if (!this.files.promote(temp, final)) {
      const msg: string = '文件改名失败，请重试';
      this.store.finish(r.tid, DL_FAILED, -3, msg);
      this.forget(r.tid);
      throw new Error(msg);
    }
    this.store.setLocalPath(r.tid, final);

    cb?.onStage?.('写入目标位置');
    if (!this.files.copyToUri(final, targetUri)) {
      // 直接写不进去（目标 URI 没有授权）时，退回系统选择器再确认一次
      HLog.w('直接写入失败，改用文件选择器');
      cb?.onStage?.('确认保存位置');
      const picked: string =
        await this.pickFileUri('', DownloadService.flatName(meta.appName, named));
      if (!this.files.copyToUri(final, picked)) {
        const msg: string = '写入目标位置失败，文件仍在应用沙箱里，可点「另存为」重试';
        this.store.finish(r.tid, DL_FAILED, -4, msg);
        this.forget(r.tid);
        throw new Error(msg);
      }
      targetUri = picked;
    }

    this.store.setSaveUri(r.tid, targetUri, fileName);
    this.store.finish(r.tid, DL_DONE, 0, '');
    HLog.i(`下载完成 ${fileName}`);
    this.forget(r.tid);
    return targetUri;
  }

  /**
   * 文件名里没有版本号就补上（entry-default-unsigned.hap → entry-default-unsigned-1.2.5.hap）。
   *
   * 一堆鸿蒙应用都叫 entry-default-unsigned.hap，光靠应用名前缀也不好区分版本，
   * 补上版本号后同一应用的多个版本能并存。设置里可以关掉。
   */
  private versionedName(fileName: string, version: string): string {
    if (!SettingsStore.shared().get().appendVersionToName) {
      return fileName;
    }
    if (version.length === 0 || nameHasVersion(fileName, version)) {
      return fileName;
    }
    const out: string = this.files.safeName(this.files.insertBeforeExt(fileName, version));
    HLog.i(`文件名补版本号 ${fileName} -> ${out}`);
    return out;
  }

  /**
   * 定出本次下载的目标 URI。
   *
   * 优先在根目录下按应用名建子文件夹（鸿蒙只给到具体文件授权时建不了，返回空串）；
   * 建不了就退回「文件选择器 + 应用名前缀」，一样能避免一堆 entry-default-unsigned.hap 撞名。
   */
  private async resolveTarget(appName: string, fileName: string): Promise<string> {
    const root: string = await this.ensureRootUri(fileName);
    const sub: string = this.files.mkdirUnder(root, appName);
    if (sub.length > 0) {
      HLog.i(`使用应用子目录 ${sub}`);
      const target: string = this.files.childUri(sub, fileName);
      if (this.files.existsUri(target)) {
        const overwrite: boolean = await this.confirmOverwrite(fileName);
        if (!overwrite) {
          throw new Error('已取消保存');
        }
      }
      return target;
    }
    HLog.w('无法在用户目录建子文件夹，改用应用名前缀命名');
    const flat: string = this.files.safeName(DownloadService.flatName(appName, fileName));
    return this.pickFileUri(root, this.files.uniqueNameUnder(root, flat));
  }

  /**
   * 拼「应用名-文件名」前缀。
   *
   * 文件名本身已经以应用名开头、且后面紧跟分隔符时不再重复加前缀，
   * 免得出现 MindustryArk-MindustryArk-v1.0.0.2-unsigned.hap 这种叠字。
   * 要求后面必须有分隔符，否则 Fl + FlClash-1.hap 会被误判成同一族。
   */
  static flatName(appName: string, fileName: string): string {
    const head: string = appName.trim().toLowerCase();
    if (head.length === 0) {
      return fileName;
    }
    if (!fileName.toLowerCase().startsWith(head)) {
      return `${appName}-${fileName}`;
    }
    const rest: string = fileName.substring(head.length);
    const c: string = rest.length > 0 ? rest.charAt(0) : '';
    if (c === '-' || c === '_' || c === ' ') {
      return fileName;
    }
    return `${appName}-${fileName}`;
  }

  /** 下载根目录：没记过、或已失效（权限回收）就让用户重新选一次。 */
  async ensureRootUri(hintName: string): Promise<string> {
    const settings = SettingsStore.shared().get();
    if (settings.downloadRootUri.length > 0 && this.files.existsUri(settings.downloadRootUri)) {
      return settings.downloadRootUri;
    }
    if (settings.downloadRootUri.length > 0) {
      HLog.w('已保存的下载目录不可访问，需要重新选择');
    }
    return this.changeRootUri(hintName);
  }

  /** 主动更换下载根目录（设置页「更改」也走这里）。 */
  async changeRootUri(hintName: string): Promise<string> {
    const picked: string = await this.pickFileUri('', hintName.length > 0 ? hintName : 'download-location.hap');
    // 万一系统版本不支持 autoCreateEmptyFile，把占位文件清掉
    if (this.files.existsUri(picked)) {
      this.files.deleteLocal(picked);
    }
    const root: string = DownloadService.parentUriOf(picked);
    if (root.length === 0) {
      throw new Error('无法确定下载目录');
    }
    SettingsStore.shared().apply({
      downloadRootUri: root,
      downloadRootName: uriDisplayName(root)
    });
    return root;
  }

  /** 从文件 URI 推导父目录 URI（截掉最后一段与查询参数）。 */
  static parentUriOf(fileUri: string): string {
    let s: string = fileUri;
    const q: number = s.indexOf('?');
    if (q > 0) {
      s = s.substring(0, q);
    }
    const slash: number = s.lastIndexOf('/');
    return slash > 0 ? s.substring(0, slash) : '';
  }

  /**
   * 兜底：用系统选择器确认文件名与位置。
   *
   * autoCreateEmptyFile 必须给 false —— 它默认 true，Picker 会在用户点确认的那一刻
   * 就在目标位置造一个 0 字节文件，这正是"下载中看到 0 字节/不完整文件"的来源。
   */
  async pickFileUri(dirUri: string, fileName: string): Promise<string> {
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    saveOptions.pickerMode = picker.DocumentPickerMode.DEFAULT;
    saveOptions.autoCreateEmptyFile = false;
    if (dirUri.length > 0) {
      saveOptions.defaultFilePathUri = dirUri;
    }
    const docPicker = new picker.DocumentViewPicker(this.context);
    const uris: string[] = await docPicker.save(saveOptions);
    if (uris.length === 0) {
      throw new Error('已取消保存');
    }
    return uris[0];
  }

  /** 已完成的文件再导出一份到别的位置（沙箱里始终留着原文件）。 */
  async exportAgain(tid: string, appName: string): Promise<boolean> {
    const rec: DownloadRecord | null = this.store.find(tid);
    if (!rec || rec.localPath.length === 0 || !this.files.existsLocal(rec.localPath)) {
      throw new Error('本地文件已不存在，只能重新下载');
    }
    const uri: string = await this.resolveTarget(appName, rec.fileName);
    if (!this.files.copyToUri(rec.localPath, uri)) {
      throw new Error('写入目标位置失败');
    }
    this.store.setSaveUri(tid, uri, rec.fileName);
    return true;
  }

  /** 删掉沙箱里的 HAP 副本（用户已经装完、想省空间时用）。 */
  deleteLocalFile(tid: string): boolean {
    const rec: DownloadRecord | null = this.store.find(tid);
    if (!rec || rec.localPath.length === 0) {
      return false;
    }
    const ok: boolean = this.files.deleteLocal(rec.localPath);
    if (ok) {
      this.store.setLocalPath(tid, '');
    }
    return ok;
  }

  /** 失败/取消后重来一次：记录里有足够信息重建任务。 */
  async retry(tid: string, cb?: DownloadCallbacks): Promise<string> {
    const rec: DownloadRecord | null = this.store.find(tid);
    if (!rec) {
      throw new Error('记录不存在');
    }
    // 系统里可能还留着旧的 FAILED 任务，先清掉再重下
    try {
      await request.agent.remove(tid);
    } catch (e) {
      // 已经不在系统里了，忽略
    }
    const asset: AssetInfo = {
      name: rec.assetName,
      size: rec.size,
      downloadUrl: rec.url,
      contentType: 'application/octet-stream'
    };
    this.store.remove(tid);
    return this.download({ appName: rec.appName, asset: asset, tag: rec.tag, appId: rec.appId }, cb);
  }

  /** 暂停：只有 waiting/running/retrying 能暂停，其它状态直接给中文提示。 */
  async pause(tid: string): Promise<void> {
    const st: number = await this.stateOf(tid);
    if (st < 0) {
      throw new Error('任务已结束，无需暂停');
    }
    if (st !== request.agent.State.WAITING && st !== request.agent.State.RUNNING &&
      st !== request.agent.State.RETRYING) {
      throw new Error(`当前状态「${DownloadService.stateText(st)}」不能暂停`);
    }
    try {
      const task: request.agent.Task = await this.resolveTask(tid);
      await task.pause();
      this.store.updateStatus(tid, DL_PAUSED);
      HLog.i(`暂停 ${tid}`);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      HLog.e(`暂停失败 ${tid} code=${err.code} ${err.message}`);
      throw new Error(`暂停失败（${err.code}）：${DownloadService.codeHint(err.code)}`);
    }
  }

  /** 继续：只有 paused 能继续。 */
  async resume(tid: string): Promise<void> {
    const st: number = await this.stateOf(tid);
    if (st < 0) {
      throw new Error('任务已结束，无法继续');
    }
    if (st !== request.agent.State.PAUSED) {
      throw new Error(`当前状态「${DownloadService.stateText(st)}」不需要继续`);
    }
    try {
      const task: request.agent.Task = await this.resolveTask(tid);
      await task.resume();
      this.store.updateStatus(tid, DL_DOWNLOADING);
      HLog.i(`继续 ${tid}`);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      HLog.e(`继续失败 ${tid} code=${err.code} ${err.message}`);
      throw new Error(`继续失败（${err.code}）：${DownloadService.codeHint(err.code)}`);
    }
  }

  /** 取消：暂停中的任务要先唤醒再停（stop 不接受 paused），最后删掉 .part。 */
  async cancel(tid: string): Promise<void> {
    const st: number = await this.stateOf(tid);
    if (st >= 0) {
      try {
        const task: request.agent.Task = await this.resolveTask(tid);
        if (st === request.agent.State.PAUSED) {
          await task.resume().catch(() => {
            // 唤醒失败也继续尝试停止
          });
        }
        await task.stop();
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        HLog.w(`stop 失败 ${tid} code=${err.code}，改用 remove`);
      }
    }
    try {
      await request.agent.remove(tid);
    } catch (e) {
      // 已经不在系统里了，忽略
    }
    const rec: DownloadRecord | null = this.store.find(tid);
    if (rec && rec.fileName.length > 0) {
      this.files.deleteLocal(this.files.tempPath(rec.fileName));
    }
    this.store.finish(tid, DL_CANCELED, 0, '已取消');
    this.forget(tid);
    HLog.i(`取消 ${tid}`);
  }

  /**
   * 列表快照：把本地记录与系统下载服务的实时状态合成一份。
   *
   * 顺手做两件事：把系统里已经查不到的僵尸任务收敛成失败；刷 AppStorage 的下载角标。
   * limit > 0 时只取最近 N 条。
   */
  async snapshot(limit: number): Promise<DownloadItem[]> {
    const tids: string[] = await this.aliveTids();
    this.store.normalizeZombies(tids);
    const records: DownloadRecord[] = this.store.list();
    const out: DownloadItem[] = [];
    let active: number = 0;
    for (let i = 0; i < records.length; i++) {
      const rec: DownloadRecord = records[i];
      const alive: boolean = tids.indexOf(rec.tid) >= 0;
      let percent: number = rec.size > 0 ? Math.floor(rec.processed * 100 / rec.size) : 0;
      if (percent > 100) {
        percent = 100;
      }
      let stateText: string = downloadStatusText(rec.status);
      let sysState: number = -1;
      if (alive) {
        sysState = await this.stateOf(rec.tid);
        if (sysState >= 0) {
          stateText = DownloadService.stateText(sysState);
        }
        if (rec.status === DL_DOWNLOADING || rec.status === DL_PAUSED) {
          active++;
        }
      }
      out.push({
        tid: rec.tid,
        appId: rec.appId,
        appName: rec.appName,
        assetName: rec.assetName,
        tag: rec.tag,
        url: rec.url,
        size: rec.size,
        status: rec.status,
        saveUri: rec.saveUri,
        fileName: rec.fileName,
        localPath: rec.localPath,
        finalUrl: rec.finalUrl,
        errCode: rec.errCode,
        errMsg: rec.errMsg,
        via: rec.via,
        startedAt: rec.startedAt,
        finishedAt: rec.finishedAt,
        processed: rec.processed,
        percent: percent,
        stateText: stateText,
        alive: alive,
        sysState: sysState
      });
      if (limit > 0 && out.length >= limit) {
        break;
      }
    }
    AppStorage.setOrCreate<number>('activeDownloads', active);
    return out;
  }

  /** 系统里还活着的 tid，列表页用它判断能不能操作。 */
  async aliveTids(): Promise<string[]> {
    try {
      return await request.agent.search();
    } catch (e) {
      return [];
    }
  }

  /** 取实时状态；查不到返回 -1。 */
  async stateOf(tid: string): Promise<number> {
    try {
      const info: request.agent.TaskInfo = await request.agent.show(tid);
      return Number(info.progress.state);
    } catch (e) {
      return -1;
    }
  }

  private async launch(meta: DownloadMeta, asset: AssetInfo, url: string, temp: string,
    cb: DownloadCallbacks | undefined, prevTid: string): Promise<LaunchResult> {
    const config: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: url,
      // 沙箱临时文件：没下完绝不暴露成 .hap
      saveas: temp,
      mode: request.agent.Mode.FOREGROUND,
      overwrite: true,
      network: request.agent.Network.ANY,
      title: meta.appName,
      description: `${meta.tag} · ${asset.name}`,
      metered: false,
      roaming: false,
      retry: true
    };

    const task: request.agent.Task = await request.agent.create(this.context, config);
    this.tasks.set(task.tid, task);

    const fileName: string = this.files.safeName(asset.name);
    if (prevTid.length === 0) {
      const record: DownloadRecord = {
        tid: task.tid,
        appId: meta.appId ?? '',
        appName: meta.appName,
        assetName: asset.name,
        tag: meta.tag,
        url: asset.downloadUrl,
        size: asset.size,
        status: DL_DOWNLOADING,
        saveUri: '',
        fileName: fileName,
        localPath: '',
        finalUrl: url,
        errCode: 0,
        errMsg: '',
        via: url === asset.downloadUrl ? '直连' : '镜像',
        startedAt: Date.now(),
        finishedAt: 0,
        processed: 0
      };
      this.store.add(record);
    } else {
      this.store.retag(prevTid, task.tid);
      this.store.updateStatus(task.tid, DL_DOWNLOADING);
      this.store.setFinalUrl(task.tid, url, url === asset.downloadUrl ? '直连' : '镜像');
    }

    cb?.onStage?.('开始下载');

    return new Promise<LaunchResult>((resolve: (r: LaunchResult) => void) => {
      task.on('progress', (progress: request.agent.Progress) => {
        const total: number = progress.sizes.length > 0 ? progress.sizes[0] : 0;
        this.store.updateProgress(task.tid, progress.processed);
        cb?.onProgress?.(progress.processed, total);
      });
      task.on('completed', () => {
        resolve({ tid: task.tid, ok: true, errCode: 0, errMsg: '' });
      });
      task.on('failed', (progress: request.agent.Progress) => {
        const state: number = Number(progress.state);
        const msg: string = `下载失败（${DownloadService.stateText(state)}）`;
        HLog.e(`${msg} url=${url}`);
        resolve({ tid: task.tid, ok: false, errCode: state, errMsg: msg });
      });
      task.start().catch((err: Error) => {
        HLog.e(`启动失败 ${err.message} url=${url}`);
        resolve({ tid: task.tid, ok: false, errCode: -1, errMsg: `启动失败：${err.message}` });
      });
    });
  }

  private async resolveTask(tid: string): Promise<request.agent.Task> {
    const cached: request.agent.Task | undefined = this.tasks.get(tid);
    if (cached) {
      return cached;
    }
    const task: request.agent.Task = await request.agent.getTask(this.context, tid);
    this.tasks.set(tid, task);
    return task;
  }

  private forget(tid: string): void {
    if (this.tasks.has(tid)) {
      this.tasks.delete(tid);
    }
  }

  private async confirmOverwrite(fileName: string): Promise<boolean> {
    try {
      const res = await promptAction.showDialog({
        title: '目标位置已存在同名文件',
        message: `${fileName}\n覆盖会替换原来的文件，也可以取消后换个位置。`,
        buttons: [
          { text: '取消', color: '#8A8F99' },
          { text: '覆盖', color: '#0F62FE' }
        ]
      });
      return res.index === 1;
    } catch (e) {
      return false;
    }
  }

  static stateText(state: number): string {
    switch (state) {
      case request.agent.State.INITIALIZED:
        return '排队中';
      case request.agent.State.WAITING:
        return '等待中';
      case request.agent.State.RUNNING:
        return '下载中';
      case request.agent.State.RETRYING:
        return '重试中';
      case request.agent.State.PAUSED:
        return '已暂停';
      case request.agent.State.STOPPED:
        return '已停止';
      case request.agent.State.COMPLETED:
        return '已完成';
      case request.agent.State.FAILED:
        return '失败';
      default:
        return '未知';
    }
  }

  /** 把常见错误码翻成人话，别让用户对着 21900007 发呆。 */
  static codeHint(code: number): string {
    if (code === 21900007) {
      return '任务当前状态不允许该操作';
    }
    if (code === 21900005) {
      return '任务模式不支持该操作';
    }
    if (code === 13400003) {
      return '下载服务异常';
    }
    if (code === 201) {
      return '缺少网络权限';
    }
    return '未知错误';
  }
}
