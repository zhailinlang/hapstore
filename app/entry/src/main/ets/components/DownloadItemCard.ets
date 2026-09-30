import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { formatSize } from '../model/AppInfo';
import { DownloadItem, DL_DONE, DL_DOWNLOADING, DL_FAILED, DL_PAUSED } from '../model/DownloadRecord';
import { uriDisplayName } from '../model/SettingsData';
import { DownloadService } from '../service/DownloadService';
import { DownloadStore } from '../service/DownloadStore';
import { MirrorService } from '../service/MirrorService';
import { Theme } from '../common/constants/ThemeConstants';

const EMPTY_ITEM: DownloadItem = {
  tid: '',
  appId: '',
  appName: '',
  assetName: '',
  tag: '',
  url: '',
  size: 0,
  status: '',
  saveUri: '',
  fileName: '',
  localPath: '',
  finalUrl: '',
  errCode: 0,
  errMsg: '',
  via: '',
  startedAt: 0,
  finishedAt: 0,
  processed: 0,
  percent: 0,
  stateText: '',
  alive: false,
  sysState: 0
};

/**
 * 一条下载记录。
 *
 * 做成 @Component 而不是 @Builder：@Builder 按值传参是快照，状态变化后内部不刷新，
 * 之前筛选 chip 不亮就是栽在这。列表项要跟着进度实时变，必须用 @Prop。
 */
@Component
export struct DownloadItemCard {
  @Prop item: DownloadItem = EMPTY_ITEM;
  onChanged: () => void = () => {};

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.item.appName.length > 0 ? this.item.appName : this.item.fileName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.item.stateText)
          .fontSize(11)
          .fontColor(this.statusColor())
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(this.statusBg())
          .flexShrink(0)
      }
      .width('100%')

      Text(`${this.item.tag.length > 0 ? this.item.tag : '未知版本'} · ${this.item.assetName}`)
        .fontSize(12)
        .fontColor(Theme.textSub)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 10 }) {
        Text(formatSize(this.item.size))
          .fontSize(12)
          .fontColor(Theme.textSub)
        if ((this.item.status === DL_DOWNLOADING || this.item.status === DL_PAUSED) &&
          this.item.percent > 0) {
          Text(`${this.item.percent}%`)
            .fontSize(12)
            .fontColor(Theme.primary)
        }
        if (this.item.via.length > 0) {
          Text(this.item.via)
            .fontSize(11)
            .fontColor(Theme.textSub)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(Theme.chipBg)
        }
      }
      .width('100%')

      if (this.item.status === DL_DOWNLOADING || this.item.status === DL_PAUSED) {
        Progress({ value: this.item.percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color(Theme.primary)
      }

      if (this.item.status === DL_FAILED && this.item.errMsg.length > 0) {
        Column({ space: 2 }) {
          Text(this.item.errMsg)
            .fontSize(12)
            .fontColor(Theme.danger)
            .width('100%')
          Text(this.item.finalUrl)
            .fontSize(11)
            .fontColor(Theme.textSub)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .onClick(() => {
              this.copy(this.item.finalUrl);
            })
        }
        .width('100%')
      }

      if (this.item.status === DL_DONE && this.item.fileName.length > 0) {
        Text(this.item.fileName)
          .fontSize(11)
          .fontColor(Theme.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.item.alive && this.item.status === DL_DOWNLOADING) {
          this.ActionChip('暂停', 'pause')
        }
        if (this.item.alive && this.item.status === DL_PAUSED) {
          this.ActionChip('继续', 'resume')
        }
        if (this.item.alive && (this.item.status === DL_DOWNLOADING || this.item.status === DL_PAUSED)) {
          this.ActionChip('取消', 'cancel')
        }
        if (this.item.status === DL_FAILED || (!this.item.alive && this.item.status === 'canceled')) {
          this.ActionChip('重试', 'retry')
        }
        if (this.item.status === DL_DONE) {
          this.ActionChip('安装引导', 'guide')
        }
        if (this.item.status === DL_DONE && this.item.localPath.length > 0) {
          this.ActionChip('另存为', 'export')
          this.ActionChip('删本地文件', 'purge')
        }
        this.ActionChip('复制链接', 'copy')
        this.ActionChip('删除记录', 'remove')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
  }

  @Builder
  ActionChip(label: string, action: string) {
    Text(label)
      .fontSize(12)
      .fontColor(Theme.primary)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(14)
      .backgroundColor(Theme.primaryLight)
      .margin({ right: 8, bottom: 4 })
      .onClick(() => {
        this.act(action);
      })
  }

  private async act(action: string): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const service: DownloadService = DownloadService.shared(ctx);
    try {
      if (action === 'pause') {
        await service.pause(this.item.tid);
      } else if (action === 'resume') {
        await service.resume(this.item.tid);
      } else if (action === 'cancel') {
        await service.cancel(this.item.tid);
        promptAction.showToast({ message: '已取消' });
      } else if (action === 'retry') {
        await service.retry(this.item.tid);
        promptAction.showToast({ message: '已重新发起下载' });
      } else if (action === 'guide') {
        router.pushUrl({
          url: 'pages/InstallGuidePage',
          params: {
            fileName: this.item.saveUri.length > 0 ? uriDisplayName(this.item.saveUri) : this.item.fileName,
            saveUri: this.item.saveUri
          }
        });
        return;
      } else if (action === 'export') {
        const ok: boolean = await service.exportAgain(this.item.tid, this.item.appName);
        promptAction.showToast({ message: ok ? '已保存' : '已取消保存' });
      } else if (action === 'purge') {
        service.deleteLocalFile(this.item.tid);
        promptAction.showToast({ message: '沙箱副本已删除' });
      } else if (action === 'copy') {
        this.copy(MirrorService.apply(this.item.url));
        return;
      } else if (action === 'remove') {
        // 还在跑的先停掉系统任务，再删记录；终态直接删
        if (this.item.alive) {
          service.cancel(this.item.tid).catch(() => {
            // 停不掉也照样删记录
          });
        }
        new DownloadStore(ctx).remove(this.item.tid);
        promptAction.showToast({ message: '记录已删除' });
      }
    } catch (e) {
      const err: Error = e as Error;
      promptAction.showToast({ message: err.message ?? '操作失败' });
    }
    this.onChanged();
  }

  private copy(url: string): void {
    const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    board.setData(data).then(() => {
      promptAction.showToast({ message: '下载链接已复制' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private statusColor(): ResourceColor {
    if (this.item.status === DL_DONE) {
      return Theme.success;
    }
    if (this.item.status === DL_FAILED) {
      return Theme.danger;
    }
    if (this.item.status === DL_DOWNLOADING) {
      return Theme.primary;
    }
    return Theme.textSub;
  }

  private statusBg(): ResourceColor {
    if (this.item.status === DL_DONE) {
      return Theme.successBg;
    }
    if (this.item.status === DL_FAILED) {
      return Theme.dangerBg;
    }
    if (this.item.status === DL_DOWNLOADING) {
      return Theme.primaryLight;
    }
    return Theme.chipBg;
  }
}
