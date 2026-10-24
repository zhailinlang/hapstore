import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import {
  AppInfo,
  AssetInfo,
  ReleaseInfo,
  appReleases,
  formatDate,
  formatSize,
  preferredAsset,
  statusText
} from '../model/AppInfo';
import { uriDisplayName } from '../model/SettingsData';
import { DownloadRecord, DL_DONE, DL_DOWNLOADING, DL_PAUSED } from '../model/DownloadRecord';
import { DownloadMeta, DownloadService } from '../service/DownloadService';
import { DownloadStore } from '../service/DownloadStore';
import { ExtractResult, ZipExtractor } from '../service/ZipExtractor';
import { MirrorService } from '../service/MirrorService';
import { NetworkService } from '../service/NetworkService';
import { SettingsStore } from '../service/SettingsStore';
import { AppIconView } from '../components/AppIcon';
import { Theme } from '../common/constants/ThemeConstants';

@Entry
@Component
struct DetailPage {
  @State app: AppInfo | null = null;
  @State downloading: boolean = false;
  @State progressText: string = '';
  @State percent: number = 0;
  /** 移动网络下跳过了自动下载，页面上给个提示 */
  @State autoSkipped: boolean = false;

  aboutToAppear(): void {
    const params: object = router.getParams() as object;
    if (params) {
      const raw: string = (params as Record<string, string>)['app'];
      if (raw) {
        this.app = JSON.parse(raw) as AppInfo;
      }
    }
    // 打开应用即拉取最新版：进详情页就自动下，下完直接进装机流程
    this.autoFetchLatest();
  }

  /**
   * 自动下载最新版。
   *
   * 条件：开关开着、当前有可下的包、这个版本本地还没下过、且不是移动网络。
   * 已经下过的（同一资产 + 同一版本）不再重复消耗流量。
   *
   * 移动网络下不自动下：不少 HAP 有上百 MB，用户可能只是想看看详情。
   * 这种情况下在页面上留个按钮，手动一点更稳妥（见 build 里的「下载最新版」按钮）。
   */
  private async autoFetchLatest(): Promise<void> {
    const settings = SettingsStore.shared().get();
    if (!settings.autoDownloadLatest) {
      return;
    }
    if (NetworkService.isCellular()) {
      this.autoSkipped = true;
      return;
    }
    const app: AppInfo | null = this.app;
    if (!app) {
      return;
    }
    const asset: AssetInfo | undefined = preferredAsset(app);
    if (!asset) {
      return;
    }
    const tag: string = this.latestTag();
    if (this.alreadyDownloaded(app.id, asset.name, tag)) {
      return;
    }
    await this.startDownload(asset, tag, true);
  }

  /** 本地是否已有这个应用这个版本的下载记录（成功或进行中都算）。 */
  private alreadyDownloaded(appId: string, assetName: string, tag: string): boolean {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const records: DownloadRecord[] = new DownloadStore(ctx).list();
    for (let i = 0; i < records.length; i++) {
      const rec: DownloadRecord = records[i];
      if (rec.appId !== appId) {
        continue;
      }
      if (rec.assetName !== assetName) {
        continue;
      }
      if (rec.tag !== tag) {
        continue;
      }
      if (rec.status === DL_DONE || rec.status === DL_DOWNLOADING || rec.status === DL_PAUSED) {
        return true;
      }
    }
    return false;
  }

  /** 最新版的 HAP，用于详情页顶部的主下载按钮。 */
  private latestAsset(): AssetInfo | undefined {
    if (!this.app) {
      return undefined;
    }
    return preferredAsset(this.app);
  }

  private latestTag(): string {
    const rels: ReleaseInfo[] = this.app ? appReleases(this.app) : [];
    return rels.length > 0 ? rels[0].tag : '';
  }

  async startDownload(asset: AssetInfo, tag: string, auto: boolean = false): Promise<void> {
    if (!this.app || this.downloading) {
      return;
    }
    const settings = SettingsStore.shared().get();
    if (settings.meteredWarn && NetworkService.isCellular()) {
      promptAction.showDialog({
        title: '当前是移动网络',
        message: `要继续下载 ${asset.name} 吗？（可在设置里关闭提醒）`,
        buttons: [{ text: '取消', color: '#8A8F99' }, { text: '继续', color: '#0F62FE' }]
      }).then((res) => {
        if (res.index === 1) {
          this.doDownload(asset, tag, auto);
        }
      }).catch(() => {
        // 用户取消
      });
      return;
    }
    this.doDownload(asset, tag, auto);
  }

  async doDownload(asset: AssetInfo, tag: string, auto: boolean = false): Promise<void> {
    if (!this.app || this.downloading) {
      return;
    }
    this.downloading = true;
    this.percent = 0;
    this.progressText = '准备中…';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const service: DownloadService = DownloadService.shared(ctx);
    const meta: DownloadMeta = {
      appName: this.app.name,
      asset: asset,
      tag: tag,
      appId: this.app.id
    };
    try {
      const savedUri: string = await service.download(meta, {
        onProgress: (processed: number, total: number) => {
          if (total > 0) {
            this.percent = Math.floor(processed * 100 / total);
            this.progressText =
              `${formatSize(processed)} / ${formatSize(total)}`;
          }
        },
        onStage: (text: string) => {
          this.progressText = text;
        }
      });
      const localPath: string = service.latestLocalPath(meta.appId ?? '', asset.name);
      // zip 包：先解压出里面的 HAP，再走同一条装机流程
      let installPath: string = localPath;
      // 引导页展示的文件名：要指向真正要装的那个文件（zip 场景是解出来的 HAP）
      let installName: string = asset.name;
      if (asset.isZip === true && localPath.length > 0) {
        const ex: ExtractResult = await new ZipExtractor(ctx).extract(localPath);
        if (ex.hapPath.length > 0) {
          installPath = ex.hapPath;
          installName = ex.hapPath.substring(ex.hapPath.lastIndexOf('/') + 1);
        } else {
          promptAction.showToast({ message: `压缩包已下载，但${ex.message}` });
        }
      }
      const guideName: string = installPath.length > 0
        ? installName
        : (savedUri.length > 0 ? uriDisplayName(savedUri) : asset.name);
      if (auto) {
        // 自动下载：不打扰用户，进度条走完就转到装机页
        promptAction.showToast({ message: '最新版已下载' });
        router.pushUrl({
          url: 'pages/InstallGuidePage',
          params: {
            fileName: guideName,
            saveUri: savedUri,
            localPath: installPath
          }
        });
        return;
      }
      if (SettingsStore.shared().get().autoOpenInstallGuide) {
        router.pushUrl({
          url: 'pages/InstallGuidePage',
          params: {
            fileName: guideName,
            saveUri: savedUri,
            localPath: installPath
          }
        });
      } else {
        promptAction.showToast({ message: '下载完成，可在「更新 → 下载」里查看' });
      }
    } catch (e) {
      const err: Error = e as Error;
      promptAction.showToast({ message: err.message ?? '下载失败' });
    } finally {
      this.downloading = false;
    }
  }

  copyLink(url: string): void {
    const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, MirrorService.apply(url));
    board.setData(data).then(() => {
      promptAction.showToast({ message: '下载链接已复制' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  openUrl(url: string): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url
    }).catch(() => {
      promptAction.showToast({ message: '无法打开链接' });
    });
  }

  build() {
    Column() {
      if (!this.app) {
        Row() {
          this.BackButton()
        }
        .width('100%')
        .padding({ left: 12, top: 12 })

        Column() {
          Text('未找到应用信息').fontSize(15).fontColor(Theme.textSub)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 顶部返回栏（固定，不随内容滚动）
        Row() {
          this.BackButton()
          Text('应用详情')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textMain)
            .margin({ left: 4 })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 10, bottom: 10 })
        .backgroundColor(Theme.background)

        Scroll() {
          Column() {
            // 应用头部
            Row() {
              AppIconView(this.app, 64, 16)

              Column({ space: 4 }) {
                Text(this.app.name)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textMain)
                Text(`${this.app.owner}/${this.app.repo}`)
                  .fontSize(12)
                  .fontColor(Theme.textSub)
                Text(statusText(this.app.status))
                  .fontSize(12)
                  .fontColor(this.app.status === 'ok' ? Theme.success : Theme.textSub)
              }
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 14 })
              .layoutWeight(1)
            }
            .width('100%')
            .padding(16)
            .alignItems(VerticalAlign.Center)

            // 打标信息
            if ((this.app.funcType ?? '').length > 0 || (this.app.tags ?? []).length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                if ((this.app.funcType ?? '').length > 0) {
                  Text(this.app.funcType ?? '')
                    .fontSize(11)
                    .fontColor(Theme.primary)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(5)
                    .backgroundColor(Theme.primaryLight)
                    .margin({ right: 6, bottom: 6 })
                }
                ForEach(this.app.tags ?? [], (t: string) => {
                  Text(t)
                    .fontSize(11)
                    .fontColor(Theme.textSub)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(5)
                    .backgroundColor(Theme.card)
                    .margin({ right: 6, bottom: 6 })
                }, (t: string) => t)
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 12 })
            }

            // 直接下载最新版：系统限制第三方静默安装，这里只负责把 HAP 拉下来
            if (this.latestAsset() !== undefined) {
              if (this.autoSkipped) {
                Text('当前是移动网络，已跳过自动下载，可手动点下面的按钮')
                  .fontSize(11)
                  .fontColor(Theme.warning)
                  .width('100%')
                  .padding({ left: 16, right: 16, bottom: 6 })
              }
              Button(`下载最新版 · ${formatSize(this.latestAsset()?.size ?? 0)}`)
                .width('100%')
                .height(46)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .borderRadius(23)
                .backgroundColor(Theme.primary)
                .enabled(!this.downloading)
                .margin({ left: 16, right: 16, bottom: 8 })
                .onClick(() => {
                  const asset: AssetInfo | undefined = this.latestAsset();
                  if (asset) {
                    this.startDownload(asset, this.latestTag());
                  }
                })
              Text(this.latestAsset()?.name ?? '')
                .fontSize(11)
                .fontColor(Theme.textSub)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ left: 16, right: 16, bottom: 4 })
              if (this.latestAsset()?.isZip === true) {
                Text('上游发布的是压缩包，下载后会自动解压出 HAP')
                  .fontSize(11)
                  .fontColor(Theme.primary)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ left: 16, right: 16, bottom: 12 })
              }
            }

            Text(this.app.desc)
              .fontSize(14)
              .fontColor(Theme.textMain)
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 12 })

            Text('最近发布')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textMain)
              .width('100%')
              .padding({ left: 16, bottom: 4 })

            // 最近若干个 Release，按新→旧排列
            ForEach(appReleases(this.app), (rel: ReleaseInfo, idx: number) => {
              this.ReleaseBlock(rel, idx === 0)
            }, (rel: ReleaseInfo, idx: number) => `${idx}_${rel.tag}`)

            Text('仅展示最近 2 个版本，更多历史版本请前往 Release 页面查看')
              .fontSize(11)
              .fontColor(Theme.textSub)
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 12 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')

        // 下载进度
        if (this.downloading) {
          Column({ space: 4 }) {
            Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(4)
              .color(Theme.primary)
            Text(`${this.percent}%  ${this.progressText}`)
              .fontSize(12)
              .fontColor(Theme.textSub)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }

        // 底部操作（固定）
        Row({ space: 12 }) {
          Button('Release 页面')
            .fontSize(14)
            .layoutWeight(1)
            .backgroundColor(Theme.primaryLight)
            .fontColor(Theme.primary)
            .onClick(() => {
              this.openUrl(this.app ? this.app.releaseUrl : '');
            })
          Button('项目主页')
            .fontSize(14)
            .layoutWeight(1)
            .backgroundColor(Theme.primaryLight)
            .fontColor(Theme.primary)
            .onClick(() => {
              this.openUrl(this.app ? this.app.repoUrl : '');
            })
        }
        .width('100%')
        .padding(16)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background)
  }

  /** 单个资产行：名称、体积、复制链接、下载。zip 会多一个「解压后安装」标注。 */
  @Builder
  AssetRow(asset: AssetInfo, tag: string) {
    Row() {
      Column({ space: 2 }) {
        Text(asset.name)
          .fontSize(14)
          .fontColor(Theme.textMain)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(formatSize(asset.size))
            .fontSize(12)
            .fontColor(Theme.textSub)
          if (asset.isZip === true) {
            Text('压缩包 · 下载后自动解压安装')
              .fontSize(11)
              .fontColor(Theme.primary)
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('复制链接')
        .fontSize(12)
        .fontColor(Theme.primary)
        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .borderRadius(14)
        .backgroundColor(Theme.primaryLight)
        .flexShrink(0)
        .onClick(() => {
          this.copyLink(asset.downloadUrl);
        })

      Button(this.downloading ? '下载中' : '下载')
        .fontSize(13)
        .height(34)
        .borderRadius(17)
        .enabled(!this.downloading)
        .flexShrink(0)
        .onClick(() => {
          this.startDownload(asset, tag.length > 0 ? tag : '');
        })
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(Theme.card)
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

  @Builder
  ReleaseBlock(rel: ReleaseInfo, isLatest: boolean) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(rel.tag.length > 0 ? rel.tag : '未命名版本')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        if (isLatest) {
          Text('最新')
            .fontSize(10)
            .fontColor(Theme.white)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(Theme.primary)
        }
        Blank()
        if (rel.publishedAt.length > 0) {
          Text(formatDate(rel.publishedAt))
            .fontSize(11)
            .fontColor(Theme.textSub)
        }
      }
      .width('100%')

      if ((rel.hapAssets ?? []).length === 0 && (rel.hapZipAssets ?? []).length === 0) {
        Text('该版本没有 HAP 文件')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
          .padding({ left: 12, top: 12, bottom: 12 })
      } else {
        Column({ space: 8 }) {
          ForEach(rel.hapAssets ?? [], (asset: AssetInfo) => {
            this.AssetRow(asset, rel.tag)
          }, (asset: AssetInfo) => asset.name)

          ForEach(rel.hapZipAssets ?? [], (asset: AssetInfo) => {
            this.AssetRow(asset, rel.tag)
          }, (asset: AssetInfo) => `zip_${asset.name}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }
}
