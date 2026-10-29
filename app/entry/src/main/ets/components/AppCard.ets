import { AppInfo, appDisplayDate, appReleases, formatDate, formatSize, preferredAsset, statusText } from '../model/AppInfo';
import { Theme } from '../common/constants/ThemeConstants';
import { AppIconView } from './AppIcon';

/** 最新 release 的版本号标签；没有就空串。 */
function latestTag(app: AppInfo): string {
  const rels = appReleases(app);
  return rels.length > 0 ? (rels[0].tag ?? '') : '';
}

/** 列表卡片。用全局 @Builder 而非 @Prop，避免对象深拷贝开销。density 为 compact 时更紧凑。 */
@Builder
export function AppCardView(app: AppInfo, onClick: () => void, density?: string) {
  Row() {
    AppIconView(app, 48, 12)

    Column({ space: 4 }) {
      Row() {
        Text(app.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(statusText(app.status))
          .fontSize(11)
          .fontColor(app.status === 'ok' ? Theme.success : Theme.textSub)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(app.status === 'ok' ? Theme.successBg : Theme.chipBg)
      }
      .width('100%')

      Text(app.desc)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .maxLines(density === 'compact' ? 1 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 8 }) {
        // 版本号取最新 release 的 tag，跟详情页「最近发布」保持一致
        if (latestTag(app).length > 0) {
          Text(latestTag(app))
            .fontSize(11)
            .fontColor(Theme.primary)
        }
        Text(formatSize(preferredAsset(app)?.size ?? 0))
          .fontSize(11)
          .fontColor(Theme.textSub)
        if (preferredAsset(app)?.isZip === true) {
          Text('压缩包')
            .fontSize(10)
            .fontColor(Theme.textSub)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(Theme.chipBg)
        }
        // 日期跟「最近更新」排序用同一个时间源，排序和显示才一致
        Text(formatDate(appDisplayDate(app)))
          .fontSize(11)
          .fontColor(Theme.textSub)
      }
      .width('100%')

      if ((app.funcType ?? '').length > 0 || (app.tags ?? []).length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          if ((app.funcType ?? '').length > 0) {
            Text(app.funcType ?? '')
              .fontSize(10)
              .fontColor(Theme.primary)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor(Theme.primaryLight)
              .margin({ right: 6, bottom: 4 })
          }
          ForEach(app.tags ?? [], (t: string) => {
            Text(t)
              .fontSize(10)
              .fontColor(Theme.textSub)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor(Theme.chipBg)
              .margin({ right: 6, bottom: 4 })
          }, (t: string) => t)
        }
        .width('100%')
        .margin({ top: 2 })
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .margin({ left: 12 })
  }
  .width('100%')
  .padding(density === 'compact' ? 10 : 14)
  .borderRadius(Theme.radius)
  .backgroundColor(Theme.card)
  .alignItems(VerticalAlign.Center)
  .onClick(onClick)
}
