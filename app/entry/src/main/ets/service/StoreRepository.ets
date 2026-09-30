import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppInfo, StoreData } from '../model/AppInfo';
import { StoreCache } from './StoreCache';

const RAW_FILE = 'apps.json';
const CACHE_FILE = 'apps.json';

/** 缓存文件信息，设置页「数据管理」展示用。mtime 已换算成毫秒。 */
export interface CacheStat {
  size: number;
  mtime: number;
}

/** 数据来源：内置 rawfile 快照 + filesDir 缓存 + 远端同步。 */
export class StoreRepository {
  private context: common.UIAbilityContext;
  /** 最近一次 load() 实际用的是哪份数据，更新页展示「当前来源」 */
  lastSource: string = 'bundle';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 取较新的一份数据。
   *
   * 之前直接「有缓存就用缓存」，导致打包进去的 rawfile 更新了（比如新增图标/标签），
   * 老缓存仍然压着不生效，界面上表现为「新字段没显示」。这里按 schemaVersion +
   * generatedAt 比大小，远端同步写进来的缓存更新时才优先用缓存。
   */
  async load(): Promise<StoreData> {
    if (StoreCache.has()) {
      return StoreCache.get() as StoreData;
    }
    const bundled: StoreData = this.readRawFile();
    const cached: StoreData | null = this.readCache();
    if (cached && this.isNewer(cached, bundled)) {
      this.lastSource = 'cache';
      StoreCache.set(cached);
      return cached;
    }
    this.lastSource = 'bundle';
    this.writeCache(bundled);
    StoreCache.set(bundled);
    return bundled;
  }

  /** candidate 是否比 base 新：先比 schemaVersion，再比 generatedAt。 */
  private isNewer(candidate: StoreData, base: StoreData): boolean {
    const cv: number = candidate.schemaVersion ?? 0;
    const bv: number = base.schemaVersion ?? 0;
    if (cv !== bv) {
      return cv > bv;
    }
    return (candidate.generatedAt ?? '') > (base.generatedAt ?? '');
  }

  /** 强制用内置快照覆盖缓存（设置页「恢复内置数据」用）。 */
  reloadFromBundle(): StoreData {
    const bundled = this.readRawFile();
    this.writeCache(bundled);
    this.lastSource = 'bundle';
    StoreCache.set(bundled);
    return bundled;
  }

  /** 远端拉到的 JSON 文本 → 解析、校验、写入缓存并生效。 */
  applyRemoteJson(text: string): StoreData {
    const data: StoreData = this.parse(text);
    if (!data.categories || data.categories.length === 0) {
      throw new Error('远端数据里没有应用分类，可能不是有效的 apps.json');
    }
    this.writeCache(data);
    this.lastSource = 'cache';
    StoreCache.set(data);
    return data;
  }

  /** 给外部（更新页）解析文本用，字段兜底逻辑与内部一致。 */
  parseText(text: string): StoreData {
    return this.parse(text);
  }

  /** 缓存文件大小与修改时间，设置页展示用。 */
  cacheStat(): CacheStat | null {
    const path: string = `${this.context.filesDir}/${CACHE_FILE}`;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      const info: CacheStat = { size: stat.size, mtime: stat.mtime * 1000 };
      return info;
    } catch (e) {
      return null;
    }
  }

  clearCache(): void {
    const path: string = `${this.context.filesDir}/${CACHE_FILE}`;
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 删除失败忽略
    }
    StoreCache.invalidate();
  }

  private readRawFile(): StoreData {
    const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync(RAW_FILE);
    const decoder = new util.TextDecoder('utf-8');
    const text: string = decoder.decodeToString(bytes);
    return this.parse(text);
  }

  private readCache(): StoreData | null {
    const path = `${this.context.filesDir}/${CACHE_FILE}`;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder = new util.TextDecoder('utf-8');
      return this.parse(decoder.decodeToString(new Uint8Array(buf)));
    } catch (e) {
      return null;
    }
  }

  private writeCache(data: StoreData): void {
    try {
      const path = `${this.context.filesDir}/${CACHE_FILE}`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(data));
      fileIo.closeSync(file);
    } catch (e) {
      // 缓存写失败不影响主流程
    }
  }

  private parse(text: string): StoreData {
    const data: StoreData = JSON.parse(text) as StoreData;
    if (!data.categories) {
      data.categories = [];
    }
    for (let i = 0; i < data.categories.length; i++) {
      const apps: AppInfo[] = data.categories[i].apps ?? [];
      for (let j = 0; j < apps.length; j++) {
        if (!apps[j].hapAssets) {
          apps[j].hapAssets = [];
        }
        if (!apps[j].otherAssets) {
          apps[j].otherAssets = [];
        }
        if (!apps[j].releases) {
          apps[j].releases = [];
        }
        if (!apps[j].deviceTypes) {
          apps[j].deviceTypes = [];
        }
        if (!apps[j].tags) {
          apps[j].tags = [];
        }
        if (!apps[j].funcType) {
          apps[j].funcType = '';
        }
      }
    }
    return data;
  }
}
