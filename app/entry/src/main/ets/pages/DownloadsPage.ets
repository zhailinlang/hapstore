import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { DownloadItem } from '../model/DownloadRecord';
import { DownloadService } from '../service/DownloadService';
import { DownloadStore } from '../service/DownloadStore';
import { DownloadItemCard } from '../components/DownloadItemCard';
import { Theme } from '../common/constants/ThemeConstants';

/** 完整下载记录页：更新 Tab 的内嵌区块点「全部记录」进到这里。 */
@Entry
@Component
struct DownloadsPage {
  @State items: DownloadItem[] = [];
  @State loading: boolean = true;
  private store: DownloadStore | null = null;
  private timer: number = -1;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.store = new DownloadStore(ctx);
    this.refresh();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  onPageShow(): void {
    this.refresh();
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.refresh();
      }, 1500);
    }
  }

  onPageHide(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async refresh(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const service: DownloadService = DownloadService.shared(ctx);
    try {
      this.items = await service.snapshot(0);
    } catch (e) {
      // 保持上一次的列表
    }
    this.loading = false;
  }

  build() {
    Column() {
      Row() {
        this.BackButton()
        Text('下载管理')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .margin({ left: 4 })
          .layoutWeight(1)
        Text('清空已完成')
          .fontSize(12)
          .fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            if (this.store) {
              this.store.clearFinished();
              this.refresh();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 10, bottom: 10 })
      .backgroundColor(Theme.background)

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(Theme.primary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 8 }) {
          Text('还没有下载记录')
            .fontSize(15)
            .fontColor(Theme.textSub)
          Text('在应用详情页点「下载」后，任务会出现在这里')
            .fontSize(12)
            .fontColor(Theme.textSub)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (item: DownloadItem) => {
            ListItem() {
              DownloadItemCard({ item: item, onChanged: (): void => {
                this.refresh();
              } })
            }
            .padding({ left: 16, right: 16 })
          }, (item: DownloadItem) => `${item.tid}|${item.status}|${item.percent}|${item.alive}|${item.stateText}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background)
  }

  @Builder
  BackButton() {
    Text('←')
      .fontSize(20)
      .fontColor(Theme.textMain)
      .width(36)
      .height(36)
      .textAlign(TextAlign.Center)
      .borderRadius(18)
      .backgroundColor(Theme.card)
      .onClick(() => {
        router.back();
      })
  }
}
