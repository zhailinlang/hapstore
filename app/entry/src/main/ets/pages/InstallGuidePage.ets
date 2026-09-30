import { promptAction, router } from '@kit.ArkUI';
import { SettingsStore } from '../service/SettingsStore';
import { Theme } from '../common/constants/ThemeConstants';

@Entry
@Component
struct InstallGuidePage {
  @State fileName: string = '';
  @State saveUri: string = '';
  @State neverAgain: boolean = false;

  aboutToAppear(): void {
    const params: object = router.getParams() as object;
    if (params) {
      const map: Record<string, string> = params as Record<string, string>;
      const name: string = map['fileName'];
      const uri: string = map['saveUri'];
      this.fileName = name ?? '';
      this.saveUri = uri ?? '';
    }
  }

  /** 关掉自动弹出；设置页里同名开关会同步，随时能改回来。 */
  private disableAutoGuide(): void {
    SettingsStore.shared().apply({ autoOpenInstallGuide: false });
    promptAction.showToast({ message: '以后不再自动弹出，可在设置里改回来' });
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor(Theme.primaryLight)
          .fontColor(Theme.primary)
          .onClick(() => {
            router.back();
          })
        Blank()
      }
      .width('100%')
      .padding({ left: 16, top: 12, bottom: 8 })

      Text('HAP 已下载，接下来手动安装')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 6 })

      Text('鸿蒙不允许第三方应用直接安装 HAP（安装权限是系统级权限），所以最后一步需要你在系统上确认一次。')
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })

      if (this.fileName.length > 0) {
        Column({ space: 4 }) {
          Text('刚下载的文件')
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
          Text(this.fileName)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.primary)
            .width('100%')
        }
        .width('100%')
        .padding(14)
        .borderRadius(Theme.radius)
        .backgroundColor(Theme.card)
        .margin({ left: 16, right: 16, bottom: 10 })
        .alignItems(HorizontalAlign.Start)
      }

      Row({ space: 8 }) {
        Checkbox()
          .select(this.neverAgain)
          .selectedColor(Theme.primary)
          .width(22)
          .height(22)
          .onChange((v: boolean) => {
            this.neverAgain = v;
            if (v) {
              this.disableAutoGuide();
            }
          })
        Text('下载完成后不再自动弹出')
          .fontSize(13)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
        Button('以后不再提示')
          .fontSize(12)
          .height(32)
          .borderRadius(16)
          .backgroundColor(Theme.primaryLight)
          .fontColor(Theme.primary)
          .onClick(() => {
            this.neverAgain = true;
            this.disableAutoGuide();
            router.back();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      this.Step('1', '开启开发者模式',
        '设置 → 关于本机 → 连续点击「软件版本」7 次，按提示重启后生效。')
      this.Step('2', '打开本地安装入口',
        '设置 → 应用 → 应用管理 → 本地安装（部分机型在「应用」页面右上角的菜单里）。')
      this.Step('3', this.fileName.length > 0 ? `选择 ${this.fileName}` : '选择刚下载的 HAP',
        this.fileName.length > 0 ?
          `在文件选择界面找到「${this.fileName}」→ 安装 → 系统提示「未经应用市场检测」时选择继续。` :
          '在文件选择界面找到你刚才保存的 .hap 文件 → 安装 → 系统提示「未经应用市场检测」时选择继续。')

      Text('备选方式')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
        .width('100%')
        .padding({ left: 16, top: 20, bottom: 8 })

      this.Step('A', 'hdc 命令（需连电脑）',
        '手机开 USB 调试并授权电脑，电脑上执行：hdc install 包名.hap')
      this.Step('B', '小白调试助手类工具',
        '手机开「无线调试」记下 IP 和端口，在工具里填设备地址并登录华为开发者账号，选中 HAP 开始调试安装。')

      Text('注意：侧载应用依赖开发者签名，未实名认证有效期约 14 天，实名后约 180 天；到期需要重新安装。')
        .fontSize(12)
        .fontColor(Theme.warning)
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background)
  }

  @Builder
  Step(no: string, title: string, detail: string) {
    Row() {
      Column() {
        Text(no)
          .fontSize(15)
          .fontColor(Theme.primary)
          .fontWeight(FontWeight.Bold)
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(Theme.primaryLight)
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Text(detail)
          .fontSize(13)
          .fontColor(Theme.textSub)
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(14)
    .borderRadius(Theme.radius)
    .backgroundColor(Theme.card)
    .margin({ left: 16, right: 16, bottom: 10 })
  }
}
