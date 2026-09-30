import { common } from '@kit.AbilityKit';
import { DownloadStore } from '../service/DownloadStore';
import { RemoteStoreService } from '../service/RemoteStoreService';
import { SettingsStore } from '../service/SettingsStore';
import { NetworkService } from '../service/NetworkService';
import { StoreDiff } from '../model/UpdateInfo';
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

  /** 启动时按需静默检查一次远端更新，只更新「更新」Tab 的红点。 */
  private autoCheck(): void {
    const s = SettingsStore.shared().get();
    if (!s.autoCheckOnLaunch || s.sourceUrl.length === 0) {
      return;
    }
    if (Date.now() - s.lastCheckAt < s.checkIntervalHours * 3600 * 1000) {
      return;
    }
    if (!NetworkService.isOnline()) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    new RemoteStoreService(ctx).check().then((diff: StoreDiff | null) => {
      if (diff === null) {
        // 304：快照没变，不写红点，但记一次检查时间
        SettingsStore.shared().apply({ lastCheckAt: Date.now() });
        return;
      }
      AppStorage.setOrCreate('updateCount', diff.changeCount);
      SettingsStore.shared().apply({ lastCheckAt: Date.now() });
    }).catch(() => {
      // 静默检查失败不打扰用户
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
