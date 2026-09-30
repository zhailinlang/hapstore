import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { DownloadItem } from '../model/DownloadRecord';
import { InstalledUpdate } from '../model/UpdateInfo';
import { DownloadService } from '../service/DownloadService';
import { Theme } from '../common/constants/ThemeConstants';
import { DownloadItemCard } from './DownloadItemCard';

const POLL_MS: number = 1500;
const MAX_SHOW: number = 5;

/**
 * 「更新」Tab 里的「下载与新版本」区块。
 *
 * 下载管理原来只藏在应用 Tab 右上角的 ↓ 里，不好找；这里直接把进行中的任务摆出来，
 * 下面接已下载应用的新版本提醒，右上角再给一个进完整列表的口子。
 *
 * Tab 内组件没有 onPageShow，所以用定时器轮询；离开页面时清理。
 */
@Component
export struct DownloadPanel {
  @State items: DownloadItem[] = [];
  @Prop installed: InstalledUpdate[] = [];
  onOpenApp: (appId: string) => void = (): void => {};
  private timer: number = -1;
  private busy: boolean = false;

  aboutToAppear(): void {
    this.refresh();
    this.startPoll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  startPoll(): void {
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.refresh();
      }, POLL_MS);
    }
  }

  stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async refresh(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const service: DownloadService = DownloadService.shared(ctx);
      this.items = await service.snapshot(MAX_SHOW);
    } catch (e) {
      // 刷新失败保持上一次的列表
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('下载与新版本')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
        Text('全部记录 →')
          .fontSize(12)
          .fontColor(Theme.primary)
          .onClick(() => {
            router.pushUrl({ url: 'pages/DownloadsPage' });
          })
      }
      .width('100%')

      if (this.items.length === 0) {
        Text('还没有下载任务，在应用详情页点「下载」后会出现在这里')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
      } else {
        ForEach(this.items, (item: DownloadItem) => {
          DownloadItemCard({ item: item, onChanged: (): void => {
            this.refresh();
          } })
        }, (item: DownloadItem) => `${item.tid}|${item.status}|${item.percent}|${item.alive}|${item.stateText}`)
      }

      Column({ space: 6 }) {
        Text('已下载应用的新版本')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .width('100%')

        if (this.installed.length === 0) {
          Text('已下载的应用都是最新版本')
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
        } else {
          ForEach(this.installed, (item: InstalledUpdate) => {
            Row() {
              Column({ space: 2 }) {
                Text(item.appName)
                  .fontSize(14)
                  .fontColor(Theme.textMain)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${item.downloadedTag} → ${item.latestTag}`)
                  .fontSize(12)
                  .fontColor(Theme.primary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('去下载')
                .fontSize(12)
                .fontColor(Theme.primary)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(14)
                .backgroundColor(Theme.primaryLight)
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.onOpenApp(item.appId);
            })
          }, (item: InstalledUpdate) => item.appId)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
    .alignItems(HorizontalAlign.Start)
  }
}
