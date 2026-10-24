import { common } from '@kit.AbilityKit';
import { DownloadStore } from '../service/DownloadStore';
import { SettingsStore } from '../service/SettingsStore';
import { UpdateCenter } from '../service/UpdateCenter';
import { AppsTabView } from '../components/AppsTabView';
import { UpdatesTabView } from '../components/UpdatesTabView';
import { SettingsTabView } from '../components/SettingsTabView';
import { Theme } from '../common/constants/ThemeConstants';

/**
 * 壳页面：底部三个 Tab（应用 / 更新 / 设置）。
 *
 * 这里是唯一的 @Entry，所以只有它能收到 onPageShow —— 下载角标在这里刷进
 * AppStorage，AppsTabView 用 @StorageLink 订阅（子组件收不到页面生命周期）。
 */
@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @StorageLink('updateCount') updateCount: number = 0;
  private controller: TabsController = new TabsController();

  aboutToAppear(): void {
    this.autoCheck();
  }

  onPageShow(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const store: DownloadStore = new DownloadStore(ctx);
    AppStorage.setOrCreate('activeDownloads', store.activeCount());
  }

  /**
   * 启动时自动检查更新。
   *
   * 走 UpdateCenter 的统一编排：拉远端快照 → 比对 → 直接写入本机生效，
   * 同时检查 App 自身有没有新版本；有更新或失败时弹 tips 说明结果。
   * 用户在设置里关掉开关就不会触发。
   */
  private autoCheck(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    new UpdateCenter(ctx).autoCheckOnLaunch().then((outcome) => {
      if (outcome === null) {
        return;
      }
      // 快照已经生效过，这里只需要刷新一下列表与红点
      const epoch: number = AppStorage.get<number>('storeEpoch') ?? 0;
      AppStorage.setOrCreate('storeEpoch', epoch + 1);
      AppStorage.setOrCreate('updateCount', 0);
    }).catch(() => {
      // 静默检查失败不打扰用户（UpdateCenter 内部已经处理过提示）
    });
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.controller }) {
      TabContent() {
        AppsTabView()
      }
      .tabBar(this.TabItem(0, '应用', 0))

      TabContent() {
        UpdatesTabView()
      }
      .tabBar(this.TabItem(1, '更新', this.updateCount))

      TabContent() {
        SettingsTabView()
      }
      .tabBar(this.TabItem(2, '设置', 0))
    }
    .width('100%')
    .height('100%')
    .barHeight(56)
    .scrollable(false)
    .animationDuration(0)
    .barBackgroundColor(Theme.card)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
    .onTabBarClick((index: number) => {
      this.currentIndex = index;
    })
  }

  @Builder
  TabItem(index: number, label: string, badge: number) {
    Stack() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? Theme.primary : Theme.textSub)
      if (badge > 0) {
        Text(`${badge}`)
          .fontSize(10)
          .fontColor(Theme.white)
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(Theme.danger)
          .margin({ left: 34, bottom: 18 })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
