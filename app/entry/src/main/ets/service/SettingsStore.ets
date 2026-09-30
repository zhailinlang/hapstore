import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  BUILTIN_MIRRORS,
  DEFAULT_SETTINGS,
  MIRROR_CUSTOM_ID,
  MIRROR_DIRECT_ID,
  MirrorItem,
  SettingsData,
  SettingsPatch,
  mirrorById,
  validCustomTemplate
} from '../model/SettingsData';

const SETTINGS_FILE: string = 'settings.json';

/**
 * 设置持久化：与工程现有风格一致，直接落 filesDir 的 JSON，不用 preferences。
 * 在 EntryAbility.onCreate 里 init 一次，之后全局通过 AppStorage 读，避免每个 Tab 各读一次盘。
 */
export class SettingsStore {
  private static inst: SettingsStore | null = null;
  private context: common.UIAbilityContext;
  private data: SettingsData;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.data = DEFAULT_SETTINGS();
    this.read();
  }

  static init(context: common.UIAbilityContext): SettingsStore {
    if (!SettingsStore.inst) {
      SettingsStore.inst = new SettingsStore(context);
    }
    return SettingsStore.inst;
  }

  static shared(): SettingsStore {
    if (SettingsStore.inst) {
      return SettingsStore.inst;
    }
    // 兜底：理论上不会走到，UI 都在 Ability 之后创建
    const ctx: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    return SettingsStore.init(ctx);
  }

  get(): SettingsData {
    return this.data;
  }

  /** 单点更新：逐字段显式赋值 + 同步 AppStorage + 落盘。 */
  apply(patch: SettingsPatch): void {
    if (patch.schemaVersion !== undefined) {
      this.data.schemaVersion = patch.schemaVersion;
    }
    if (patch.sourceUrl !== undefined) {
      this.data.sourceUrl = patch.sourceUrl.trim();
      AppStorage.setOrCreate<string>('sourceUrl', this.data.sourceUrl);
    }
    if (patch.autoCheckOnLaunch !== undefined) {
      this.data.autoCheckOnLaunch = patch.autoCheckOnLaunch;
      AppStorage.setOrCreate<boolean>('autoCheckOnLaunch', this.data.autoCheckOnLaunch);
    }
    if (patch.checkIntervalHours !== undefined) {
      this.data.checkIntervalHours = patch.checkIntervalHours;
      AppStorage.setOrCreate<number>('checkIntervalHours', this.data.checkIntervalHours);
    }
    if (patch.lastCheckAt !== undefined) {
      this.data.lastCheckAt = patch.lastCheckAt;
      AppStorage.setOrCreate<number>('lastCheckAt', this.data.lastCheckAt);
    }
    if (patch.lastRemoteGeneratedAt !== undefined) {
      this.data.lastRemoteGeneratedAt = patch.lastRemoteGeneratedAt;
      AppStorage.setOrCreate<string>('lastRemoteGeneratedAt', this.data.lastRemoteGeneratedAt);
    }
    if (patch.themeMode !== undefined) {
      this.data.themeMode = patch.themeMode;
      AppStorage.setOrCreate<string>('themeMode', this.data.themeMode);
    }
    if (patch.listDensity !== undefined) {
      this.data.listDensity = patch.listDensity;
      AppStorage.setOrCreate<string>('listDensity', this.data.listDensity);
    }
    if (patch.mirrorEnabled !== undefined) {
      this.data.mirrorEnabled = patch.mirrorEnabled;
      AppStorage.setOrCreate<boolean>('mirrorEnabled', this.data.mirrorEnabled);
    }
    if (patch.mirrorId !== undefined) {
      this.data.mirrorId = patch.mirrorId;
      this.data.mirrorTemplate = SettingsStore.templateOf(this.data);
      AppStorage.setOrCreate<string>('mirrorId', this.data.mirrorId);
      AppStorage.setOrCreate<string>('mirrorTemplate', this.data.mirrorTemplate);
    }
    if (patch.mirrorTemplate !== undefined) {
      this.data.mirrorTemplate = patch.mirrorTemplate;
      AppStorage.setOrCreate<string>('mirrorTemplate', this.data.mirrorTemplate);
    }
      if (patch.customTemplate !== undefined) {
        this.data.customTemplate = patch.customTemplate.trim();
        // 只有合法模板才允许生效；输入过程中的残缺字符串不会污染 mirrorTemplate
        this.data.mirrorTemplate = SettingsStore.templateOf(this.data);
        AppStorage.setOrCreate<string>('mirrorTemplate', this.data.mirrorTemplate);
        AppStorage.setOrCreate<string>('customTemplate', this.data.customTemplate);
      }
      if (patch.mirrorFallback !== undefined) {
        this.data.mirrorFallback = patch.mirrorFallback;
        AppStorage.setOrCreate<boolean>('mirrorFallback', this.data.mirrorFallback);
      }
    if (patch.probeUrl !== undefined) {
      this.data.probeUrl = patch.probeUrl.trim();
      AppStorage.setOrCreate<string>('probeUrl', this.data.probeUrl);
    }
    if (patch.autoOpenInstallGuide !== undefined) {
      this.data.autoOpenInstallGuide = patch.autoOpenInstallGuide;
      AppStorage.setOrCreate<boolean>('autoOpenInstallGuide', this.data.autoOpenInstallGuide);
    }
    if (patch.meteredWarn !== undefined) {
      this.data.meteredWarn = patch.meteredWarn;
      AppStorage.setOrCreate<boolean>('meteredWarn', this.data.meteredWarn);
    }
    if (patch.downloadRootUri !== undefined) {
      this.data.downloadRootUri = patch.downloadRootUri;
      AppStorage.setOrCreate<string>('downloadRootUri', this.data.downloadRootUri);
    }
    if (patch.downloadRootName !== undefined) {
      this.data.downloadRootName = patch.downloadRootName;
      AppStorage.setOrCreate<string>('downloadRootName', this.data.downloadRootName);
    }
    if (patch.appendVersionToName !== undefined) {
      this.data.appendVersionToName = patch.appendVersionToName;
      AppStorage.setOrCreate<boolean>('appendVersionToName', this.data.appendVersionToName);
    }
    if (patch.snapshotEtag !== undefined) {
      this.data.snapshotEtag = patch.snapshotEtag;
      AppStorage.setOrCreate<string>('snapshotEtag', this.data.snapshotEtag);
    }
    if (patch.manifestEtag !== undefined) {
      this.data.manifestEtag = patch.manifestEtag;
      AppStorage.setOrCreate<string>('manifestEtag', this.data.manifestEtag);
    }
    this.persist();
  }

  /** 选中镜像后推导生效模板：始终由 mirrorId + customTemplate 现算，不落盘。 */
  static templateOf(data: SettingsData): string {
    if (data.mirrorId === MIRROR_DIRECT_ID) {
      return '';
    }
    if (data.mirrorId === MIRROR_CUSTOM_ID) {
      return validCustomTemplate(data.customTemplate) ? data.customTemplate.trim() : '';
    }
    const item: MirrorItem = mirrorById(data.mirrorId);
    return item.id === MIRROR_DIRECT_ID ? '' : item.template;
  }

  /** 当前生效的镜像项（UI 展示用）。 */
  static currentMirror(data: SettingsData): MirrorItem {
    if (!data.mirrorEnabled) {
      return BUILTIN_MIRRORS[0];
    }
    const item: MirrorItem = mirrorById(data.mirrorId);
    if (data.mirrorId === MIRROR_CUSTOM_ID) {
      const custom: MirrorItem = {
        id: MIRROR_CUSTOM_ID,
        name: '自定义',
        template: data.customTemplate,
        note: data.customTemplate
      };
      return custom;
    }
    return item;
  }

  pushAll(): void {
    AppStorage.setOrCreate<string>('sourceUrl', this.data.sourceUrl);
    AppStorage.setOrCreate<boolean>('autoCheckOnLaunch', this.data.autoCheckOnLaunch);
    AppStorage.setOrCreate<number>('checkIntervalHours', this.data.checkIntervalHours);
    AppStorage.setOrCreate<number>('lastCheckAt', this.data.lastCheckAt);
    AppStorage.setOrCreate<string>('lastRemoteGeneratedAt', this.data.lastRemoteGeneratedAt);
    AppStorage.setOrCreate<string>('themeMode', this.data.themeMode);
    AppStorage.setOrCreate<string>('listDensity', this.data.listDensity);
    AppStorage.setOrCreate<boolean>('mirrorEnabled', this.data.mirrorEnabled);
    AppStorage.setOrCreate<string>('mirrorId', this.data.mirrorId);
    AppStorage.setOrCreate<string>('mirrorTemplate', this.data.mirrorTemplate);
      AppStorage.setOrCreate<string>('customTemplate', this.data.customTemplate);
      AppStorage.setOrCreate<boolean>('mirrorFallback', this.data.mirrorFallback);
      AppStorage.setOrCreate<string>('probeUrl', this.data.probeUrl);
    AppStorage.setOrCreate<boolean>('autoOpenInstallGuide', this.data.autoOpenInstallGuide);
    AppStorage.setOrCreate<boolean>('meteredWarn', this.data.meteredWarn);
    AppStorage.setOrCreate<string>('downloadRootUri', this.data.downloadRootUri);
    AppStorage.setOrCreate<string>('downloadRootName', this.data.downloadRootName);
    AppStorage.setOrCreate<boolean>('appendVersionToName', this.data.appendVersionToName);
    AppStorage.setOrCreate<string>('snapshotEtag', this.data.snapshotEtag);
    AppStorage.setOrCreate<string>('manifestEtag', this.data.manifestEtag);
  }

  private path(): string {
    return `${this.context.filesDir}/${SETTINGS_FILE}`;
  }

  private read(): void {
    try {
      if (!fileIo.accessSync(this.path())) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(this.path(), fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(this.path());
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buf));
      const parsed: SettingsData = JSON.parse(text) as SettingsData;
      const base: SettingsData = DEFAULT_SETTINGS();
      // 逐字段兜底，老版本文件缺字段时不至于崩
      base.schemaVersion = parsed.schemaVersion ?? base.schemaVersion;
      // 老版本存的是空串（那时还没有官方数据源）；空串一律迁到默认地址，
      // 想纯离线的话关掉「启动时自动检查」即可，不影响手动检查
      const migratedUrl: string = (parsed.sourceUrl ?? '').trim();
      base.sourceUrl = migratedUrl.length > 0 ? migratedUrl : base.sourceUrl;
      base.autoCheckOnLaunch = parsed.autoCheckOnLaunch ?? false;
      base.checkIntervalHours = parsed.checkIntervalHours ?? 24;
      base.lastCheckAt = parsed.lastCheckAt ?? 0;
      base.lastRemoteGeneratedAt = parsed.lastRemoteGeneratedAt ?? '';
      base.themeMode = parsed.themeMode ?? 'system';
      base.listDensity = parsed.listDensity ?? 'normal';
      base.mirrorEnabled = parsed.mirrorEnabled ?? false;
      base.mirrorId = parsed.mirrorId ?? MIRROR_DIRECT_ID;
      base.customTemplate = parsed.customTemplate ?? '';
      base.mirrorFallback = parsed.mirrorFallback ?? true;
      base.probeUrl = parsed.probeUrl ?? base.probeUrl;
      base.autoOpenInstallGuide = parsed.autoOpenInstallGuide ?? true;
      base.meteredWarn = parsed.meteredWarn ?? true;
      base.downloadRootUri = parsed.downloadRootUri ?? '';
      base.downloadRootName = parsed.downloadRootName ?? '';
      base.appendVersionToName = parsed.appendVersionToName ?? true;
      base.snapshotEtag = parsed.snapshotEtag ?? '';
      base.manifestEtag = parsed.manifestEtag ?? '';
      // 文件里的 mirrorTemplate 一律不信：残缺模板（不含 {url}）会让镜像静默失效
      base.mirrorTemplate = SettingsStore.templateOf(base);
      this.data = base;
    } catch (e) {
      // 读坏了也保留默认骨架，不再整体回落导致用户设置凭空消失
      this.data.schemaVersion = 1;
      this.data.mirrorTemplate = SettingsStore.templateOf(this.data);
    }
  }

  private persist(): void {
    try {
      const file: fileIo.File = fileIo.openSync(this.path(),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(this.data));
      fileIo.closeSync(file);
    } catch (e) {
      // 设置写失败只影响持久化，不影响本次会话
    }
  }
}
