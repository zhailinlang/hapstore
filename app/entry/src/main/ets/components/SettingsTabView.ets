import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import {
  BUILTIN_MIRRORS,
  MIRROR_CUSTOM_ID,
  MirrorItem,
  templateProblem,
  uriDisplayName
} from '../model/SettingsData';
import { AppReleaseInfo, AppUpdateResult } from '../model/ManifestData';
import { SpeedResult, MirrorService } from '../service/MirrorService';
import { NetworkService } from '../service/NetworkService';
import { SettingsStore } from '../service/SettingsStore';
import { StoreRepository } from '../service/StoreRepository';
import { DownloadStore } from '../service/DownloadStore';
import { DownloadService } from '../service/DownloadService';
import { AppUpdateService } from '../service/AppUpdateService';
import { DEFAULT_SOURCE_URL } from '../common/constants/AppConstants';
import { Theme } from '../common/constants/ThemeConstants';

const SAMPLE_URL: string = 'https://github.com/owner/repo/releases/download/v1.0/app.hap';
const THEME_OPTIONS: string[] = ['system', 'light', 'dark'];
const THEME_LABELS: string[] = ['跟随系统', '浅色', '深色'];
const INTERVALS: number[] = [6, 12, 24, 72];
const INTERVAL_LABELS: string[] = ['6 小时', '12 小时', '24 小时', '72 小时'];

function colorModeOf(mode: string): ConfigurationConstant.ColorMode {
  if (mode === 'light') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  if (mode === 'dark') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

function sizeText(bytes: number): string {
  if (bytes <= 0) {
    return '0 KB';
  }
  if (bytes < 1024 * 1024) {
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function timeText(ms: number): string {
  if (ms <= 0) {
    return '未知';
  }
  const d: Date = new Date(ms);
  const hh: string = `${d.getHours()}`.padStart(2, '0');
  const mm: string = `${d.getMinutes()}`.padStart(2, '0');
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()} ${hh}:${mm}`;
}

/** 单选 chips。@Component + @Prop 才能随选中态刷新（@Builder 按值传参是快照）。 */
@Component
struct ChipPickView {
  @Prop options: string[] = [];
  @Prop selected: string = '';
  onPick: (v: string) => void = (v: string) => {};

  build() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.options, (opt: string) => {
        Text(opt)
          .fontSize(13)
          .fontColor(opt === this.selected ? Theme.primary : Theme.textMain)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(opt === this.selected ? Theme.primaryLight : Theme.chipBg)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.onPick(opt);
          })
      }, (opt: string) => opt)
    }
    .width('100%')
  }
}

/** 「设置」Tab：镜像加速 / 数据源与检查 / 数据管理 / 外观 / 下载行为 / 关于。 */
@Component
export struct SettingsTabView {
  @StorageProp('mirrorEnabled') mirrorEnabled: boolean = false;
  @StorageProp('mirrorId') mirrorId: string = 'direct';
  @StorageProp('mirrorTemplate') mirrorTemplate: string = '';
  @StorageProp('customTemplate') customTemplate: string = '';
  @StorageProp('mirrorFallback') mirrorFallback: boolean = true;
  @StorageProp('sourceUrl') sourceUrl: string = '';
  @StorageProp('autoCheckOnLaunch') autoCheckOnLaunch: boolean = false;
  @StorageProp('checkIntervalHours') checkIntervalHours: number = 24;
  @StorageProp('lastCheckAt') lastCheckAt: number = 0;
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('listDensity') listDensity: string = 'normal';
  @StorageProp('probeUrl') probeUrl: string = '';
  @StorageProp('autoOpenInstallGuide') autoOpenInstallGuide: boolean = true;
  @StorageProp('meteredWarn') meteredWarn: boolean = true;
  @StorageProp('downloadRootUri') downloadRootUri: string = '';
  @StorageProp('downloadRootName') downloadRootName: string = '';
  @StorageProp('appendVersionToName') appendVersionToName: boolean = true;

  @State testing: boolean = false;
  @State results: SpeedResult[] = [];
  @State testNote: string = '';
  @State cacheInfo: string = '读取中…';
  @State urlDraft: string = '';
  @State customDraft: string = '';
  @State probeDraft: string = '';
  @State appChecking: boolean = false;
  @State appUpdateMsg: string = '';
  @State selfVersionText: string = '';
  @State pendingRelease: AppReleaseInfo | null = null;

  aboutToAppear(): void {
    const s = SettingsStore.shared().get();
    this.urlDraft = s.sourceUrl;
    this.customDraft = s.customTemplate;
    this.probeDraft = s.probeUrl;
    this.selfVersionText = AppUpdateService.selfVersionName();
    this.refreshCacheInfo();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private refreshCacheInfo(): void {
    const stat = new StoreRepository(this.ctx()).cacheStat();
    if (!stat) {
      this.cacheInfo = '暂无缓存（使用内置快照）';
      return;
    }
    this.cacheInfo = `${sizeText(stat.size)} · 更新于 ${timeText(stat.mtime)}`;
  }

  /** 恢复默认快照地址（改动过地址后又想回到 Release 滚动资产时用）。 */
  private restoreDefaultSource(): void {
    this.urlDraft = DEFAULT_SOURCE_URL;
    SettingsStore.shared().apply({ sourceUrl: DEFAULT_SOURCE_URL, snapshotEtag: '' });
    promptAction.showToast({ message: '已恢复默认数据源地址' });
  }

  /** 检查 HapStore 自身有没有新版本。只读 manifest（700B），不做任何下载。 */
  private async checkAppUpdate(): Promise<void> {
    if (this.appChecking) {
      return;
    }
    if (!NetworkService.isOnline()) {
      promptAction.showToast({ message: '当前无网络' });
      return;
    }
    this.appChecking = true;
    this.appUpdateMsg = '正在检查…';
    try {
      const r: AppUpdateResult = await new AppUpdateService(this.ctx()).check();
      this.selfVersionText = r.currentVersionName;
      this.appUpdateMsg = r.message;
      this.pendingRelease = r.hasUpdate ? r.latest : null;
    } catch (e) {
      this.appUpdateMsg = `检查失败：${(e as Error).message}`;
    } finally {
      this.appChecking = false;
    }
  }

  /** 下载新版 HAP，完成后跳安装引导页（系统不允许第三方静默安装）。 */
  private async downloadAppUpdate(): Promise<void> {
    const rel: AppReleaseInfo | null = this.pendingRelease;
    if (!rel) {
      return;
    }
    if (!NetworkService.isOnline()) {
      promptAction.showToast({ message: '当前无网络' });
      return;
    }
    this.appChecking = true;
    this.appUpdateMsg = '正在下载…';
    try {
      const uri: string = await new AppUpdateService(this.ctx()).downloadUpdate(rel, (t: string) => {
        this.appUpdateMsg = t;
      });
      this.appUpdateMsg = `已下载：${uriDisplayName(uri)}`;
      this.pendingRelease = null;
      router.pushUrl({
        url: 'pages/InstallGuidePage',
        params: { fileName: uriDisplayName(uri), saveUri: uri }
      });
    } catch (e) {
      this.appUpdateMsg = `下载失败：${(e as Error).message}`;
    } finally {
      this.appChecking = false;
    }
  }

  private async runSpeedTest(): Promise<void> {
    if (this.testing) {
      return;
    }
    if (!NetworkService.isOnline()) {
      promptAction.showToast({ message: '当前无网络' });
      return;
    }
    this.testing = true;
    this.testNote = '正在测速…';
    this.results = [];
    try {
      const list: SpeedResult[] = await MirrorService.speedTest(this.probeUrl);
      this.results = list;
      const ok: number = list.filter((r: SpeedResult) => r.ok).length;
      this.testNote = `可用 ${ok} / ${list.length}，点结果即可选用`;
    } catch (e) {
      this.testNote = `测速失败：${(e as Error).message}`;
    } finally {
      this.testing = false;
    }
  }

  private pickMirror(id: string): void {
    SettingsStore.shared().apply({ mirrorId: id });
  }

  private pickResult(r: SpeedResult): void {
    if (r.id === MIRROR_CUSTOM_ID) {
      SettingsStore.shared().apply({ customTemplate: r.template, mirrorId: MIRROR_CUSTOM_ID });
    } else {
      SettingsStore.shared().apply({ mirrorId: r.id });
    }
    SettingsStore.shared().apply({ mirrorEnabled: true });
    promptAction.showToast({ message: `已选用 ${r.name}` });
  }

  private applyTheme(mode: string): void {
    SettingsStore.shared().apply({ themeMode: mode });
    this.ctx().getApplicationContext().setColorMode(colorModeOf(mode));
  }

  private restoreBundle(): void {
    promptAction.showDialog({
      title: '恢复内置数据',
      message: '会用 App 内置的快照覆盖本地缓存，远端同步过的数据将被丢弃。',
      buttons: [{ text: '取消', color: '#8A8F99' }, { text: '恢复', color: '#0F62FE' }]
    }).then((res) => {
      if (res.index === 1) {
        new StoreRepository(this.ctx()).reloadFromBundle();
        const epoch: number = AppStorage.get<number>('storeEpoch') ?? 0;
        AppStorage.setOrCreate('storeEpoch', epoch + 1);
        this.refreshCacheInfo();
        promptAction.showToast({ message: '已恢复内置数据' });
      }
    }).catch(() => {
      // 用户取消
    });
  }

  private clearCache(): void {
    new StoreRepository(this.ctx()).clearCache();
    const epoch: number = AppStorage.get<number>('storeEpoch') ?? 0;
    AppStorage.setOrCreate('storeEpoch', epoch + 1);
    this.refreshCacheInfo();
    promptAction.showToast({ message: '缓存已清除，重启后回到内置数据' });
  }

  /** 换下载根目录：每个应用会在它下面建同名子文件夹。 */
  private async pickDownloadRoot(): Promise<void> {
    try {
      const root: string = await DownloadService.shared(this.ctx()).changeRootUri('download-location.hap');
      promptAction.showToast({ message: `下载位置已设为 ${uriDisplayName(root)}` });
    } catch (e) {
      const err: Error = e as Error;
      if (err.message !== '已取消保存') {
        promptAction.showToast({ message: '选择下载位置失败' });
      }
    }
  }

  private clearDownloads(): void {
    promptAction.showDialog({
      title: '清空下载记录',
      message: '只删除本 App 里的下载历史，不会删除已下载的文件。',
      buttons: [{ text: '取消', color: '#8A8F99' }, { text: '清空', color: '#E5484D' }]
    }).then((res) => {
      if (res.index === 1) {
        new DownloadStore(this.ctx()).clearAll();
        AppStorage.setOrCreate('activeDownloads', 0);
        promptAction.showToast({ message: '下载记录已清空' });
      }
    }).catch(() => {
      // 用户取消
    });
  }

  build() {
    Column() {
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          this.MirrorSection()
          this.SourceSection()
          this.DataSection()
          this.AppearanceSection()
          this.DownloadSection()
          this.AboutSection()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background)
  }

  @Builder
  GroupTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.textSub)
      .width('100%')
      .margin({ bottom: 2 })
  }

  @Builder
  SwitchRow(title: string, desc: string, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.textMain)
        if (desc.length > 0) {
          Text(desc)
            .fontSize(12)
            .fontColor(Theme.textSub)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Theme.primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  ActionButton(text: string, enabled: boolean, onTap: () => void) {
    Text(text)
      .fontSize(13)
      .fontColor(enabled ? Theme.primary : Theme.textSub)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(10)
      .backgroundColor(Theme.chipBg)
      .onClick(() => {
        if (enabled) {
          onTap();
        }
      })
  }

  @Builder
  MirrorSection() {
    Column({ space: 8 }) {
      this.GroupTitle('GitHub 访问方式')
      Column({ space: 6 }) {
        this.SwitchRow('使用镜像代理下载', '关闭则直连 github.com', this.mirrorEnabled, (v: boolean) => {
          SettingsStore.shared().apply({ mirrorEnabled: v });
        })

        Text(`当前链路：${MirrorService.describe()}`)
          .fontSize(12)
          .fontColor(this.mirrorEnabled && this.mirrorTemplate.length > 0 ?
            Theme.primary : Theme.textSub)
          .width('100%')

        if (this.mirrorEnabled) {
          Text(this.mirrorTemplate.length > 0 ?
            `生效模板：${this.mirrorTemplate}` : '生效模板：无（等价直连，请选一个镜像或填自定义模板）')
            .fontSize(12)
            .fontColor(this.mirrorTemplate.length > 0 ? Theme.textSub : Theme.danger)
            .width('100%')

          this.SwitchRow('下载失败自动换另一条链路重试',
            '镜像下不动就直连再试一次，反之亦然', this.mirrorFallback, (v: boolean) => {
              SettingsStore.shared().apply({ mirrorFallback: v });
            })

          Column({ space: 2 }) {
            ForEach(BUILTIN_MIRRORS, (m: MirrorItem) => {
              Row() {
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text(m.name)
                      .fontSize(14)
                      .fontColor(this.mirrorId === m.id ? Theme.primary : Theme.textMain)
                    if (m.recommend === true) {
                      Text('推荐')
                        .fontSize(10)
                        .fontColor(Theme.white)
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                        .borderRadius(4)
                        .backgroundColor(Theme.success)
                    }
                  }
                  Text(m.note)
                    .fontSize(11)
                    .fontColor(Theme.textSub)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (this.mirrorId === m.id) {
                  Text('✓')
                    .fontSize(14)
                    .fontColor(Theme.primary)
                }
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                this.pickMirror(m.id);
              })
            }, (m: MirrorItem) => m.id)
          }
          .width('100%')

          if (this.mirrorId === MIRROR_CUSTOM_ID) {
            TextInput({ placeholder: '自定义模板，例如 https://your.mirror/{url}', text: this.customDraft })
              .width('100%')
              .height(40)
              .fontSize(13)
              .backgroundColor(Theme.chipBg)
              .borderRadius(10)
              .onChange((v: string) => {
                this.customDraft = v;
                SettingsStore.shared().apply({ customTemplate: v });
              })
            Text(MirrorService.preview(this.customDraft, SAMPLE_URL))
              .fontSize(11)
              .fontColor(Theme.textSub)
              .width('100%')
            if (templateProblem(this.customDraft).length > 0) {
              Text(`当前不会生效：${templateProblem(this.customDraft)}`)
                .fontSize(11)
                .fontColor(Theme.danger)
                .width('100%')
            }
          }

          Text(`测速目标：${this.probeDraft.length > 0 ? this.probeDraft : MirrorService.realProbeUrl()}`)
            .fontSize(11)
            .fontColor(Theme.textSub)
            .width('100%')
            .margin({ top: 4 })

          TextInput({ placeholder: '测速目标 URL（留空用真实 HAP 直链）', text: this.probeDraft })
            .width('100%')
            .height(40)
            .fontSize(13)
            .backgroundColor(Theme.chipBg)
            .borderRadius(10)
            .margin({ top: 4 })
            .onChange((v: string) => {
              this.probeDraft = v;
              SettingsStore.shared().apply({ probeUrl: v });
            })

          Button(this.testing ? '测速中…' : '一键测速')
            .width('100%')
            .height(40)
            .fontSize(14)
            .borderRadius(20)
            .backgroundColor(Theme.primaryLight)
            .fontColor(Theme.primary)
            .enabled(!this.testing)
            .onClick(() => {
              this.runSpeedTest();
            })

          if (this.testNote.length > 0) {
            Text(this.testNote)
              .fontSize(12)
              .fontColor(Theme.textSub)
              .width('100%')
          }

          if (this.results.length > 0) {
            ForEach(this.results, (r: SpeedResult) => {
              Row() {
                Text(r.ok ? '✓' : '✗')
                  .fontSize(13)
                  .fontColor(r.ok ? Theme.success : Theme.danger)
                Text(r.name)
                  .fontSize(13)
                  .fontColor(Theme.textMain)
                  .layoutWeight(1)
                  .margin({ left: 8 })
                Text(r.ok ? `${r.ms} ms` : '不可用')
                  .fontSize(12)
                  .fontColor(Theme.textSub)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                this.pickResult(r);
              })
            }, (r: SpeedResult) => r.id)
          }
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }

  @Builder
  SourceSection() {
    Column({ space: 8 }) {
      this.GroupTitle('数据源与检查更新')
      Column({ space: 8 }) {
        TextInput({ placeholder: '远端 apps.json 地址（留空则只离线使用）', text: this.urlDraft })
          .width('100%')
          .height(40)
          .fontSize(13)
          .backgroundColor(Theme.chipBg)
          .borderRadius(10)
          .onChange((v: string) => {
            this.urlDraft = v;
            SettingsStore.shared().apply({ sourceUrl: v });
          })

        this.SwitchRow('启动时自动检查', '仅在配置了数据源时生效', this.autoCheckOnLaunch,
          (v: boolean) => {
            SettingsStore.shared().apply({ autoCheckOnLaunch: v });
          })

        Text('检查间隔')
          .fontSize(13)
          .fontColor(Theme.textSub)
          .width('100%')
        ChipPickView({
          options: INTERVAL_LABELS,
          selected: `${this.checkIntervalHours} 小时`,
          onPick: (v: string) => {
            const idx: number = INTERVAL_LABELS.indexOf(v);
            if (idx >= 0) {
              SettingsStore.shared().apply({ checkIntervalHours: INTERVALS[idx] });
            }
          }
        })

        Text(`上次检查：${timeText(this.lastCheckAt)}`)
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
        Row({ space: 8 }) {
          this.ActionButton('恢复默认地址', this.urlDraft !== DEFAULT_SOURCE_URL, () => {
            this.restoreDefaultSource();
          })
          this.ActionButton('清空 ETag', true, () => {
            SettingsStore.shared().apply({ snapshotEtag: '', manifestEtag: '' });
            promptAction.showToast({ message: '已清空 ETag，下次检查将全量拉取' });
          })
        }
        .width('100%')
        Text('检查动作在「更新」页执行；快照没变时服务端返回 304，不再重复下载')
          .fontSize(11)
          .fontColor(Theme.textSub)
          .width('100%')
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }

  @Builder
  DataSection() {
    Column({ space: 8 }) {
      this.GroupTitle('数据管理')
      Column({ space: 4 }) {
        Text(`缓存：${this.cacheInfo}`)
          .fontSize(13)
          .fontColor(Theme.textMain)
          .width('100%')
        Row({ space: 10 }) {
          Button('恢复内置数据')
            .fontSize(13)
            .height(36)
            .borderRadius(18)
            .backgroundColor(Theme.chipBg)
            .fontColor(Theme.textMain)
            .layoutWeight(1)
            .onClick(() => {
              this.restoreBundle();
            })
          Button('清除缓存')
            .fontSize(13)
            .height(36)
            .borderRadius(18)
            .backgroundColor(Theme.chipBg)
            .fontColor(Theme.textMain)
            .layoutWeight(1)
            .onClick(() => {
              this.clearCache();
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Button('清空下载记录')
          .fontSize(13)
          .width('100%')
          .height(36)
          .borderRadius(18)
          .backgroundColor(Theme.dangerBg)
          .fontColor(Theme.danger)
          .margin({ top: 6 })
          .onClick(() => {
            this.clearDownloads();
          })
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }

  @Builder
  AppearanceSection() {
    Column({ space: 8 }) {
      this.GroupTitle('外观与显示')
      Column({ space: 8 }) {
        Text('主题')
          .fontSize(13)
          .fontColor(Theme.textSub)
          .width('100%')
        ChipPickView({
          options: THEME_LABELS,
          selected: THEME_LABELS[THEME_OPTIONS.indexOf(this.themeMode)],
          onPick: (v: string) => {
            const idx: number = THEME_LABELS.indexOf(v);
            if (idx >= 0) {
              this.applyTheme(THEME_OPTIONS[idx]);
            }
          }
        })
        Text('列表密度')
          .fontSize(13)
          .fontColor(Theme.textSub)
          .width('100%')
        ChipPickView({
          options: ['舒适', '紧凑'],
          selected: this.listDensity === 'compact' ? '紧凑' : '舒适',
          onPick: (v: string) => {
            SettingsStore.shared().apply({ listDensity: v === '紧凑' ? 'compact' : 'normal' });
          }
        })
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }

  @Builder
  DownloadSection() {
    Column({ space: 8 }) {
      this.GroupTitle('下载行为')
      Column({ space: 6 }) {
        Row() {
          Column({ space: 2 }) {
            Text('下载位置')
              .fontSize(15)
              .fontColor(Theme.textMain)
            Text(this.downloadRootUri.length > 0 ?
              `${this.downloadRootName} / 应用名 /` : '未设置，首次下载时会让你选一次')
              .fontSize(12)
              .fontColor(Theme.textSub)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button('更改')
            .fontSize(13)
            .height(32)
            .borderRadius(16)
            .backgroundColor(Theme.primaryLight)
            .fontColor(Theme.primary)
            .onClick(() => {
              this.pickDownloadRoot();
            })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })

        Text('优先在该目录下按应用名建子文件夹，避免不同应用的 HAP 撞名；'
          + '系统不允许自建文件夹时（部分机型/目录没给到目录级写权限），'
          + '会自动退化成「应用名-文件名」命名，一样不会撞名。'
          + '下载中途目标位置不留任何文件，只有下完并校验通过才写入。')
          .fontSize(11)
          .fontColor(Theme.textSub)
          .width('100%')

        this.SwitchRow('文件名自动补版本号',
          '文件名里没有版本号时补上（entry-default-unsigned.hap → entry-default-unsigned-1.2.5.hap），'
          + '已有版本号的不会重复加',
          this.appendVersionToName, (v: boolean) => {
            SettingsStore.shared().apply({ appendVersionToName: v });
          })

        this.SwitchRow('下载完成后弹出安装引导', '关闭则只提示完成；引导页里也能一键「不再提示」',
          this.autoOpenInstallGuide, (v: boolean) => {
            SettingsStore.shared().apply({ autoOpenInstallGuide: v });
          })
        this.SwitchRow('移动网络下载前提醒', `当前网络：${NetworkService.netLabel()}`, this.meteredWarn,
          (v: boolean) => {
            SettingsStore.shared().apply({ meteredWarn: v });
          })
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }

  @Builder
  AboutSection() {
    Column({ space: 8 }) {
      this.GroupTitle('关于')
      Column({ space: 6 }) {
        Text(`HapStore ${this.selfVersionText.length > 0 ? 'v' + this.selfVersionText : ''}`)
          .fontSize(14)
          .fontColor(Theme.textMain)
          .width('100%')
        Row({ space: 8 }) {
          this.ActionButton(this.appChecking ? '处理中…' : '检查 App 更新', !this.appChecking, () => {
            this.checkAppUpdate();
          })
          if (this.pendingRelease !== null) {
            this.ActionButton('下载新版', !this.appChecking, () => {
              this.downloadAppUpdate();
            })
          }
        }
        .width('100%')
        if (this.appUpdateMsg.length > 0) {
          Text(this.appUpdateMsg)
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
        }
        Text('数据来源：github.com/Zitann/HarmonyOS-Haps（社区维护的未上架 HAP 聚合）')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
        Text('本应用不托管、不修改、不分发任何安装包；第三方应用的安全与合规请自行判断。')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
        Text('镜像服务均为第三方公益站点，随时可能失效；已移除实测不可用的 gh-proxy / '
          + 'mirror.ghproxy 等，默认直连，需要加速再按测速结果选用。')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
      }
      .width('100%')
      .padding(14)
      .borderRadius(Theme.radius)
      .backgroundColor(Theme.card)
    }
    .width('100%')
  }
}
