import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { StoreData } from '../model/AppInfo';
import { StoreDiff, VersionChange } from '../model/UpdateInfo';
import { MirrorService } from './MirrorService';
import { SettingsStore } from './SettingsStore';
import { StoreRepository } from './StoreRepository';
import { diffStore } from './UpdateCompare';

/**
 * 远端数据源：拉一份新的 apps.json 下来，跟本地快照比一比。
 *
 * 数据源 URL 为空时「更新」页只做离线比对，不联网。
 */
export class RemoteStoreService {
  private context: common.UIAbilityContext;
  private repo: StoreRepository;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.repo = new StoreRepository(context);
  }

  /** 拉取远端文本（已应用镜像）。 */
  async fetchText(): Promise<string> {
    const url: string = SettingsStore.shared().get().sourceUrl.trim();
    if (url.length === 0) {
      throw new Error('还没有配置数据源地址');
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(MirrorService.apply(url), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 20000,
        usingCache: false
      });
      const code: number = Number(resp.responseCode);
      if (code !== 200) {
        throw new Error(`数据源返回 ${code}`);
      }
      if (typeof resp.result !== 'string') {
        throw new Error('数据源返回的不是文本');
      }
      return resp.result;
    } finally {
      req.destroy();
    }
  }

  /** 拉远端并与本地快照比对；不落盘，只出差异。 */
  async check(): Promise<StoreDiff> {
    const local: StoreData = await this.repo.load();
    const text: string = await this.fetchText();
    const remote: StoreData = this.repo.parseText(text);
    if (!remote.categories || remote.categories.length === 0) {
      throw new Error('远端数据里没有应用分类，可能镜像返回了错误页');
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
}
