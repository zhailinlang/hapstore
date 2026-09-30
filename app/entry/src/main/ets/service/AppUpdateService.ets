import { bundleManager, common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HLog } from '../common/HLog';
import {
  ALT_MANIFEST_URL,
  DEFAULT_MANIFEST_URL,
  SELF_APP_ID,
  SELF_APP_NAME
} from '../common/constants/AppConstants';
import { AssetInfo } from '../model/AppInfo';
import { AppReleaseInfo, AppUpdateResult, ManifestInfo } from '../model/ManifestData';
import { DownloadMeta, DownloadService } from './DownloadService';
import { MirrorService } from './MirrorService';
import { SettingsStore } from './SettingsStore';

/** 条件请求结果：notModified=true 表示服务端回了 304，text 为空。 */
export interface FetchedText {
  notModified: boolean;
  text: string;
  etag: string;
}

/**
 * App 自身版本更新。
 *
 * 能力边界：鸿蒙不允许第三方应用静默安装（INSTALL_BUNDLE 是 system_basic 权限，
 * SDK 里也没有 installer 接口），所以这里只做到「发现新版 → 下载 → 交给安装引导页」，
 * 最后一步装包仍由用户在系统安装器里确认。
 */
export class AppUpdateService {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // ---------- 本机版本 ----------

  static selfVersionCode(): number {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return Number(info.versionCode);
    } catch (e) {
      HLog.w(`读取本机 versionCode 失败：${(e as Error).message}`);
      return 0;
    }
  }

  static selfVersionName(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      HLog.w(`读取本机 versionName 失败：${(e as Error).message}`);
      return '';
    }
  }

  // ---------- manifest ----------

  /**
   * 拉 manifest（700B）。主地址失败自动换 raw 兜底。
   *
   * 命中 304 时服务端不给正文，这时读上次存下来的 manifest 缓存；
   * 缓存也没有就丢掉 ETag 重拉一次。
   */
  async fetchManifest(): Promise<ManifestInfo> {
    const etag: string = SettingsStore.shared().get().manifestEtag;
    let got: FetchedText;
    try {
      got = await AppUpdateService.requestText(DEFAULT_MANIFEST_URL, etag);
    } catch (e) {
      HLog.w(`manifest 主地址失败，换 raw 兜底：${(e as Error).message}`);
      // 换域名了，ETag 不能沿用
      got = await AppUpdateService.requestText(ALT_MANIFEST_URL, '');
    }
    if (got.notModified) {
      const cached: string = this.readManifestCache();
      if (cached.length > 0) {
        return AppUpdateService.parseManifest(cached);
      }
      HLog.i('manifest 304 但本地无缓存，重拉一次');
      got = await AppUpdateService.requestText(DEFAULT_MANIFEST_URL, '');
    }
    if (got.etag.length > 0) {
      SettingsStore.shared().apply({ manifestEtag: got.etag });
    }
    const data: ManifestInfo = AppUpdateService.parseManifest(got.text);
    this.writeManifestCache(got.text);
    return data;
  }

  private static parseManifest(text: string): ManifestInfo {
    const data: ManifestInfo = JSON.parse(text) as ManifestInfo;
    if (!data.app || !data.snapshot) {
      throw new Error('manifest 结构不完整');
    }
    return data;
  }

  private manifestPath(): string {
    return `${this.context.filesDir}/manifest.json`;
  }

  private writeManifestCache(text: string): void {
    try {
      const path: string = this.manifestPath();
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (e) {
      // 缓存写失败不影响检查
    }
  }

  private readManifestCache(): string {
    const path: string = this.manifestPath();
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buf));
      return text;
    } catch (e) {
      return '';
    }
  }

  // ---------- 检查更新 ----------

  async check(): Promise<AppUpdateResult> {
    const currentCode: number = AppUpdateService.selfVersionCode();
    const currentName: string = AppUpdateService.selfVersionName();
    try {
      const m: ManifestInfo = await this.fetchManifest();
      const latest: AppReleaseInfo = m.app;
      const hasUpdate: boolean = latest.versionCode > currentCode && latest.downloadUrl.length > 0;
      const snapshotNeedsNewerApp: boolean = m.snapshot.minAppVersionCode > currentCode;

      let message: string = '';
      if (snapshotNeedsNewerApp) {
        message = `新数据需要 HapStore v${latest.versionName} 以上，请先升级再拉快照`;
      } else if (hasUpdate) {
        message = `发现新版本 v${latest.versionName}，当前 v${currentName}`;
      } else {
        message = `已是最新（v${currentName}）`;
      }

      const out: AppUpdateResult = {
        currentVersionCode: currentCode,
        currentVersionName: currentName,
        hasUpdate: hasUpdate,
        latest: latest,
        snapshotNeedsNewerApp: snapshotNeedsNewerApp,
        message: message
      };
      HLog.i(`App 更新检查：${message}`);
      return out;
    } catch (e) {
      const out: AppUpdateResult = {
        currentVersionCode: currentCode,
        currentVersionName: currentName,
        hasUpdate: false,
        latest: null,
        snapshotNeedsNewerApp: false,
        message: `检查失败：${(e as Error).message}`
      };
      return out;
    }
  }

  // ---------- 下载新版 ----------

  /**
   * 下载新版 HAP。复用 DownloadService：后台下载、进度、镜像自动回退、
   * 沙箱 .part 中转 + 校验后落盘全是现成的。返回落盘 URI。
   */
  async downloadUpdate(release: AppReleaseInfo,
    onStage?: (text: string) => void): Promise<string> {
    const asset: AssetInfo = {
      name: `${SELF_APP_NAME}-v${release.versionName}.hap`,
      size: release.size,
      downloadUrl: release.downloadUrl,
      contentType: 'application/octet-stream'
    };
    const meta: DownloadMeta = {
      appName: SELF_APP_NAME,
      asset: asset,
      tag: release.versionName,
      appId: SELF_APP_ID
    };
    return DownloadService.shared(this.context).download(meta, { onStage: onStage });
  }

  // ---------- HTTP ----------

  /** 带 If-None-Match 的 GET。304 返回 notModified=true。 */
  static async requestText(rawUrl: string, etag: string): Promise<FetchedText> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000,
        usingCache: false
      };
      if (etag.length > 0) {
        const h: Record<string, string> = { 'If-None-Match': etag };
        options.header = h;
      }
      const resp: http.HttpResponse = await req.request(MirrorService.apply(rawUrl), options);
      const code: number = Number(resp.responseCode);
      // http.ResponseCode.NOT_MODIFIED = 304；这里写字面量避免枚举与 number 比较的类型问题
      if (code === 304) {
        const none: FetchedText = { notModified: true, text: '', etag: etag };
        return none;
      }
      if (code !== 200) {
        throw new Error(`返回 ${code}`);
      }
      if (typeof resp.result !== 'string') {
        throw new Error('返回的不是文本');
      }
      const got: string = AppUpdateService.readEtag(resp);
      const out: FetchedText = { notModified: false, text: resp.result, etag: got };
      return out;
    } finally {
      req.destroy();
    }
  }

  /** 从响应头里取 ETag：SDK 声明 header 为 Object，统一 stringify 再按小写取值。 */
  static readEtag(resp: http.HttpResponse): string {
    try {
      const raw: string = JSON.stringify(resp.header);
      const map: Record<string, string> = JSON.parse(raw) as Record<string, string>;
      let v: string = map['etag'] ?? '';
      if (v.length === 0) {
        v = map['ETag'] ?? '';
      }
      if (v.length === 0) {
        v = map['Etag'] ?? '';
      }
      return v;
    } catch (e) {
      return '';
    }
  }
}
