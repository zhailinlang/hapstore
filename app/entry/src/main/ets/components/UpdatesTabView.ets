import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { AppInfo, StoreData, formatDate } from '../model/AppInfo';
import { InstalledUpdate } from '../model/UpdateInfo';
import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadStore } from '../service/DownloadStore';
import { NetworkService } from '../service/NetworkService';
import { StoreRepository } from '../service/StoreRepository';
import { DownloadPanel } from './DownloadPanel';
import {
  findAppById,
  findInstalledUpdates
} from '../service/UpdateCompare';
import { Theme } from '../common/constants/ThemeConstants';
import { UpdateCenter } from '../service/UpdateCenter';
import { AppUpdateService } from '../service/AppUpdateService';
import { CheckOutcome } from '../model/UpdateOutcome';

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
 * 不配数据源也能用：展示快照新鲜度、已下载应用的新版本提醒。
 * 配了数据源 URL 后「检查更新」才真正联网拉远端 apps.json 并做差异比对。
 */
@Component
export struct UpdatesTabView {
  @State data: StoreData | null = null;
  @State loading: boolean = true;
  @State checking: boolean = false;
  @State installed: InstalledUpdate[] = [];
  @State sourceLabel: string = '';
  @State msg: string = '';
  @State selfVersion: string = '';
  @StorageLink('updateCount') updateCount: number = 0;
  @StorageProp('sourceUrl') sourceUrl: string = '';
  @StorageProp('lastCheckAt') lastCheckAt: number = 0;

  aboutToAppear(): void {
    this.refreshLocal();
    // 页面再次露出时也刷新一次，避免用户在外面改了设置回来看到旧数据
    this.selfVersion = AppUpdateService.selfVersionName();
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
      const records: DownloadRecord[] = new DownloadStore(ctx).list();
      this.installed = findInstalledUpdates(d, records);
      this.sourceLabel = repo.lastSource === 'cache' ? '本地缓存（远端同步过）' : '内置快照';
    }).catch((e: Error) => {
      this.msg = `数据加载失败：${e.message}`;
      this.loading = false;
    });
  }

  /**
   * 「检查更新」按钮：一次点完整个流程。
   *
   * 拉远端快照 → 比对 → 直接写入本机生效 → 检查 App 自身版本 → 弹结果 tips。
   * 不再有「应用更新到本机数据」这种需要用户再点一次的中间步骤。
   */
  private async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    if (!NetworkService.isOnline()) {
      promptAction.showToast({ message: '当前无网络' });
      this.msg = '当前无网络';
      return;
    }
    if (this.sourceUrl.trim().length === 0) {
      promptAction.showToast({ message: '请先在「设置」里配置数据源地址' });
      this.msg = '未配置数据源地址';
      return;
    }
    this.checking = true;
    this.msg = '正在检查并更新…';
    try {
      const ctx: common.UIAbilityContext = this.ctx();
      const outcome: CheckOutcome = await new UpdateCenter(ctx).runFullCheck(false);
      // 结论写进页面，tips 也弹一次，两边都能看到结果
      this.msg = UpdateCenter.outcomeText(outcome);
      this.selfVersion = outcome.selfVersionName;
      this.updateCount = 0;
      // 快照可能已经换掉了，重新加载本地数据与时间线
      this.refreshLocal();
      promptAction.showToast({ message: this.msg });
    } catch (e) {
      const err: Error = e as Error;
      this.msg = `更新失败：${err.message ?? '未知错误'}`;
      promptAction.showToast({ message: this.msg });
    } finally {
      this.checking = false;
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
      Text('快照新鲜度、已下载应用的新版本提醒')
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
            DownloadPanel({
              installed: this.installed,
              onOpenApp: (id: string): void => {
                this.openApp(id);
              }
            })
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
      Text(`HapStore 当前版本：v${this.selfVersion.length > 0 ? this.selfVersion : '—'}`)
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
      Button(this.checking ? '正在检查并更新…' : '检查更新')
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
      Text('点一次即完成：拉取最新快照 → 比对差异 → 直接写入本机生效 → 同时检查 HapStore 自身版本')
        .fontSize(11)
        .fontColor(Theme.textSub)
        .width('100%')
      if (this.msg.length > 0) {
        Text(this.msg)
          .fontSize(12)
          .fontColor(this.msg.indexOf('失败') >= 0 ? Theme.danger : Theme.primary)
          .width('100%')
      }
    }
    .width('100%')
  }
}
