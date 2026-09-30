import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { StoreData } from '../model/AppInfo';
import { StoreDiff, VersionChange } from '../model/UpdateInfo';
import { ALT_SOURCE_URL, SUPPORTED_SCHEMA_VERSION } from '../common/constants/AppConstants';
import { HLog } from '../common/HLog';
import { MirrorService } from './MirrorService';
import { SettingsStore } from './SettingsStore';
import { StoreRepository } from './StoreRepository';
import { diffStore } from './UpdateCompare';

/** 一次文本请求的结果。notModified=true 表示服务端返回 304，本地内容仍是最新。 */
export interface FetchedText {
  notModified: boolean;
  text: string;
  etag: string;
}

/**
 * 远端数据源：拉一份新的 apps.json 下来，跟本地快照比一比。
 *
 * 数据源 URL 为空时「更新」页只做离线比对，不联网。
 * 请求带 If-None-Match，快照没变时服务端返回 304，省掉 500KB 流量。
 */
export class RemoteStoreService {
  private context: common.UIAbilityContext;
  private repo: StoreRepository;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.repo = new StoreRepository(context);
  }

  /** 拉取远端文本（已应用镜像）。带 ETag，304 时 notModified=true。 */
  async fetchText(etag: string): Promise<FetchedText> {
    const url: string = SettingsStore.shared().get().sourceUrl.trim();
    if (url.length === 0) {
      throw new Error('还没有配置数据源地址');
    }
    let got: FetchedText;
    try {
      got = await RemoteStoreService.requestText(MirrorService.apply(url), etag);
    } catch (e) {
      if (url === ALT_SOURCE_URL) {
        throw e as Error;
      }
      // 主地址（Release 资产）整个失败（404/超时/断网），换 raw 兜底地址重试一次
      HLog.i(`主数据源失败，改用 raw 兜底：${(e as Error).message}`);
      got = await RemoteStoreService.requestText(MirrorService.apply(ALT_SOURCE_URL), '');
    }
    if (!got.notModified && got.text.length === 0 && url !== ALT_SOURCE_URL) {
      // 主地址通了但没内容，同样换兜底
      HLog.i('主数据源无内容，改用 raw 兜底地址');
      got = await RemoteStoreService.requestText(MirrorService.apply(ALT_SOURCE_URL), '');
    }
    return got;
  }

  /**
   * 拉远端并与本地快照比对；不落盘，只出差异。
   * 返回 null 表示「快照没变化（304）」，调用方不要弹更新提示。
   */
  async check(): Promise<StoreDiff | null> {
    const local: StoreData = await this.repo.load();
    const got: FetchedText = await this.fetchText(SettingsStore.shared().get().snapshotEtag);
    if (got.notModified) {
      HLog.i('快照未变化（304）');
      if (got.etag.length > 0) {
        SettingsStore.shared().apply({ snapshotEtag: got.etag });
      }
      return null;
    }
    const remote: StoreData = this.repo.parseText(got.text);
    if (!remote.categories || remote.categories.length === 0) {
      throw new Error('远端数据里没有应用分类，可能镜像返回了错误页');
    }
    if ((remote.schemaVersion ?? 0) !== SUPPORTED_SCHEMA_VERSION) {
      throw new Error(`快照格式版本为 ${remote.schemaVersion ?? 0}，当前 App 只支持 ${SUPPORTED_SCHEMA_VERSION}，请先更新 HapStore`);
    }
    if (got.etag.length > 0) {
      SettingsStore.shared().apply({ snapshotEtag: got.etag });
    }
    return diffStore(local, remote);
  }

  /** 把拉到的远端数据写进缓存并生效。返回应用后的数据。 */
  applyRemote(text: string): StoreData {
    return this.repo.applyRemoteJson(text);
  }

  async loadLocal(): Promise<StoreData> {
    return this.repo.load();
  }

  /** 通用文本 GET：带 If-None-Match，304 时不带 body。 */
  static async requestText(rawUrl: string, etag: string): Promise<FetchedText> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 20000,
        usingCache: false
      };
      if (etag.length > 0) {
        const headers: Record<string, string> = { 'If-None-Match': etag };
        options.header = headers;
      }
      const resp: http.HttpResponse = await req.request(rawUrl, options);
      const code: number = Number(resp.responseCode);
      if (code === 304) {
        const noChange: FetchedText = {
          notModified: true,
          text: '',
          etag: RemoteStoreService.readEtag(resp)
        };
        return noChange;
      }
      if (code !== 200) {
        throw new Error(`数据源返回 ${code}`);
      }
      if (typeof resp.result !== 'string') {
        throw new Error('数据源返回的不是文本');
      }
      const ok: FetchedText = {
        notModified: false,
        text: resp.result,
        etag: RemoteStoreService.readEtag(resp)
      };
      return ok;
    } finally {
      req.destroy();
    }
  }

  /** 响应头里取 ETag；各层代理返回的大小写不统一，这里都试一遍。 */
  static readEtag(resp: http.HttpResponse): string {
    try {
      const raw: string = JSON.stringify(resp.header);
      const map: Record<string, string> = JSON.parse(raw) as Record<string, string>;
      const keys: string[] = ['etag', 'ETag', 'Etag', 'ETAG'];
      for (let i = 0; i < keys.length; i++) {
        const v: string = map[keys[i]] ?? '';
        if (v.length > 0) {
          return v;
        }
      }
    } catch (e) {
      // 解析失败当没有 ETag
    }
    return '';
  }
}
