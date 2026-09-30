import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { AppInfo, StoreData, appReleases, formatDate } from '../model/AppInfo';
import { InstalledUpdate, StoreDiff, VersionChange } from '../model/UpdateInfo';
import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadStore } from '../service/DownloadStore';
import { FetchedText, RemoteStoreService } from '../service/RemoteStoreService';
import { SettingsStore } from '../service/SettingsStore';
import { SUPPORTED_SCHEMA_VERSION } from '../common/constants/AppConstants';
import { NetworkService } from '../service/NetworkService';
import { StoreRepository } from '../service/StoreRepository';
import { DownloadPanel } from './DownloadPanel';
import {
  buildTimeline,
  diffStore,
  findAppById,
  findInstalledUpdates
} from '../service/UpdateCompare';
import { Theme } from '../common/constants/ThemeConstants';
import { AppIconView } from './AppIcon';

const TIMELINE_LIMIT: number = 20;

function daysAgo(iso: string): string {
  if (iso.length === 0) {
    return '未知';
  }
  const t: number = Date.parse(iso);
  if (t <= 0) {
    return formatDate(iso);
  }
  const days: number = Math.floor((Date.now() - t) / 86400000);
  if (days <= 0) {
    return '今天';
  }
  if (days === 1) {
    return '昨天';
  }
  return `${days} 天前`;
}

function latestTagOf(app: AppInfo): string {
  const rel = appReleases(app);
  return rel.length > 0 ? (rel[0].tag ?? '') : '—';
}

function latestPublishedAtOf(app: AppInfo): string {
  const rel = appReleases(app);
  return rel.length > 0 ? (rel[0].publishedAt ?? '') : '';
}

function stamp(ms: number): string {
  if (ms <= 0) {
    return '从未检查';
  }
  const d: Date = new Date(ms);
  const hh: string = `${d.getHours()}`.padStart(2, '0');
  const mm: string = `${d.getMinutes()}`.padStart(2, '0');
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()} ${hh}:${mm}`;
}

/**
 * 「更新」Tab：离线优先。
 *
 * 不配数据源也能用：展示快照新鲜度、已下载应用的新版本提醒、最近更新时间线。
 * 配了数据源 URL 后「检查更新」才真正联网拉远端 apps.json 并做差异比对。
 */
@Component
export struct UpdatesTabView {
  @State data: StoreData | null = null;
  @State loading: boolean = true;
  @State checking: boolean = false;
  @State diff: StoreDiff | null = null;
  @State timeline: AppInfo[] = [];
  @State installed: InstalledUpdate[] = [];
  @State sourceLabel: string = '';
  @State msg: string = '';
  @StorageLink('updateCount') updateCount: number = 0;
  @StorageProp('sourceUrl') sourceUrl: string = '';
  @StorageProp('lastCheckAt') lastCheckAt: number = 0;
  private pendingText: string = '';

  aboutToAppear(): void {
    this.refreshLocal();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private refreshLocal(): void {
    const ctx: common.UIAbilityContext = this.ctx();
    const repo: StoreRepository = new StoreRepository(ctx);
    repo.load().then((d: StoreData) => {
      this.data = d;
      this.loading = false;
      this.timeline = buildTimeline(d, TIMELINE_LIMIT);
      const records: DownloadRecord[] = new DownloadStore(ctx).list();
      this.installed = findInstalledUpdates(d, records);
      this.sourceLabel = repo.lastSource === 'cache' ? '本地缓存（远端同步过）' : '内置快照';
    }).catch((e: Error) => {
      this.msg = `数据加载失败：${e.message}`;
      this.loading = false;
    });
  }

  private async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    if (!NetworkService.isOnline()) {
      promptAction.showToast({ message: '当前无网络' });
      return;
    }
    if (this.sourceUrl.length === 0) {
      promptAction.showToast({ message: '请先在「设置」里配置数据源地址' });
      return;
    }
    this.checking = true;
    this.msg = '正在检查…';
    try {
      const ctx: common.UIAbilityContext = this.ctx();
      const service: RemoteStoreService = new RemoteStoreService(ctx);
      const got: FetchedText = await service.fetchText(SettingsStore.shared().get().snapshotEtag);
      if (got.notModified) {
        // 304：服务端说快照没变，不用解析也不用落盘
        this.pendingText = '';
        this.diff = null;
        this.updateCount = 0;
        SettingsStore.shared().apply({ lastCheckAt: Date.now() });
        this.msg = '已是最新，快照没有变化';
        return;
      }
      const remote: StoreData = new StoreRepository(ctx).parseText(got.text);
      if ((remote.schemaVersion ?? 0) !== SUPPORTED_SCHEMA_VERSION) {
        throw new Error(`快照格式为 v${remote.schemaVersion ?? 0}，当前 App 只支持 v${SUPPORTED_SCHEMA_VERSION}，请先更新 HapStore`);
      }
      const local: StoreData = this.data ?? await service.loadLocal();
      this.pendingText = got.text;
      const result: StoreDiff = diffStore(local, remote);
      this.diff = result;
      this.updateCount = result.changeCount;
      SettingsStore.shared().apply({ lastCheckAt: Date.now(), lastRemoteGeneratedAt: remote.generatedAt });
      if (result.changeCount === 0 && result.removed.length === 0) {
        this.msg = '已是最新，没有变化';
      } else {
        this.msg = `新增 ${result.added.length} 个、版本更新 ${result.versionChanged.length} 个、移除 ${result.removed.length} 个`;
      }
    } catch (e) {
      this.msg = `检查失败：${(e as Error).message}`;
    } finally {
      this.checking = false;
    }
  }

  private applyUpdate(): void {
    if (this.pendingText.length === 0) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = this.ctx();
      const service: RemoteStoreService = new RemoteStoreService(ctx);
      service.applyRemote(this.pendingText);
      const epoch: number = AppStorage.get<number>('storeEpoch') ?? 0;
      AppStorage.setOrCreate('storeEpoch', epoch + 1);
      this.updateCount = 0;
      this.diff = null;
      this.pendingText = '';
      this.msg = '已应用更新';
      this.refreshLocal();
      promptAction.showToast({ message: '已更新到最新数据' });
    } catch (e) {
      this.msg = `应用失败：${(e as Error).message}`;
    }
  }

  private openApp(id: string): void {
    if (!this.data) {
      return;
    }
    const app: AppInfo | null = findAppById(this.data, id);
    if (!app) {
      return;
    }
    router.pushUrl({ url: 'pages/DetailPage', params: { app: JSON.stringify(app) } });
  }

  build() {
    Column() {
      Text('更新')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 2 })
      Text('快照新鲜度、已下载应用的新版本提醒与最近发布时间线')
        .fontSize(12)
        .fontColor(Theme.textSub)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(Theme.primary)
        }
        .width('100%')
        .height('50%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 10 }) {
            this.FreshnessCard()
            this.CheckRow()
            if (this.diff) {
              this.DiffCard(this.diff as StoreDiff)
            }
            DownloadPanel({
              installed: this.installed,
              onOpenApp: (id: string): void => {
                this.openApp(id);
              }
            })
            this.TimelineCard()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 20 })
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background)
  }

  @Builder
  FreshnessCard() {
    Column({ space: 6 }) {
      Row() {
        Text('数据快照')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Blank()
        if (this.data && this.data.stale) {
          Text('数据可能过期')
            .fontSize(11)
            .fontColor(Theme.warning)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor(Theme.chipBg)
        }
      }
      .width('100%')

      Text(`生成于 ${formatDate(this.data?.generatedAt ?? '')}（${daysAgo(this.data?.generatedAt ?? '')}）`)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width('100%')
      Text(`共 ${this.data?.totalApps ?? 0} 个应用，${this.data?.availableApps ?? 0} 个可下载`)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width('100%')
      Text(`当前来源：${this.sourceLabel}`)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width('100%')
      Text(`上次检查：${stamp(this.lastCheckAt)}`)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  CheckRow() {
    Column({ space: 6 }) {
      Button(this.checking ? '检查中…' : '检查更新')
        .width('100%')
        .height(44)
        .fontSize(15)
        .borderRadius(22)
        .backgroundColor(this.sourceUrl.length > 0 ? Theme.primary : Theme.chipBg)
        .fontColor(this.sourceUrl.length > 0 ? Theme.white : Theme.textSub)
        .enabled(!this.checking)
        .onClick(() => {
          this.checkUpdate();
        })
      Text(this.sourceUrl.length > 0 ?
        `数据源：${this.sourceUrl}` : '未配置数据源，当前只做离线比对')
        .fontSize(12)
        .fontColor(Theme.textSub)
        .width('100%')
      if (this.msg.length > 0) {
        Text(this.msg)
          .fontSize(12)
          .fontColor(Theme.primary)
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  DiffCard(diff: StoreDiff) {
    Column({ space: 8 }) {
      Text('远端差异')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
        .width('100%')

      Text(`远端快照 ${formatDate(diff.newGeneratedAt)} · schema ${diff.newSchemaVersion}`)
        .fontSize(12)
        .fontColor(Theme.textSub)
        .width('100%')

      if (diff.added.length > 0) {
        Text(`新增 ${diff.added.length} 个应用`)
          .fontSize(13)
          .fontColor(Theme.success)
          .width('100%')
        ForEach(diff.added, (app: AppInfo) => {
          Text(`${app.name} · ${app.category}`)
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
            .padding({ left: 8 })
        }, (app: AppInfo) => app.id)
      }

      if (diff.versionChanged.length > 0) {
        Text(`${diff.versionChanged.length} 个应用有版本更新`)
          .fontSize(13)
          .fontColor(Theme.primary)
          .width('100%')
          .margin({ top: 4 })
        ForEach(diff.versionChanged, (c: VersionChange) => {
          Text(`${c.name}：${c.oldTag} → ${c.newTag}`)
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
            .padding({ left: 8 })
        }, (c: VersionChange) => c.id)
      }

      if (diff.removed.length > 0) {
        Text(`移除 ${diff.removed.length} 个应用`)
          .fontSize(13)
          .fontColor(Theme.danger)
          .width('100%')
          .margin({ top: 4 })
      }

      Button('应用更新到本机数据')
        .width('100%')
        .height(40)
        .fontSize(14)
        .borderRadius(20)
        .backgroundColor(Theme.primaryLight)
        .fontColor(Theme.primary)
        .margin({ top: 6 })
        .onClick(() => {
          this.applyUpdate();
        })
    }
    .width('100%')
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TimelineCard() {
    Column({ space: 8 }) {
      Text('最近更新')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
        .width('100%')

      ForEach(this.timeline, (app: AppInfo) => {
        Row({ space: 10 }) {
          AppIconView(app, 36, 9)
          Column({ space: 2 }) {
            Text(app.name)
              .fontSize(14)
              .fontColor(Theme.textMain)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${latestTagOf(app)} · ${formatDate(latestPublishedAtOf(app))}`)
              .fontSize(12)
              .fontColor(Theme.textSub)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .onClick(() => {
          this.openApp(app.id);
        })
      }, (app: AppInfo) => app.id)
    }
    .width('100%')
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
    .alignItems(HorizontalAlign.Start)
  }
}
