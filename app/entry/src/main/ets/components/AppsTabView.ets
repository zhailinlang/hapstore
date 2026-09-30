import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppInfo, CategoryInfo, Dimensions, StoreData } from '../model/AppInfo';
import { StoreRepository } from '../service/StoreRepository';
import { DownloadStore } from '../service/DownloadStore';
import { AppCardView } from './AppCard';
import { Theme } from '../common/constants/ThemeConstants';

/** 顶部免责声明。 */
const DISCLAIMER: string =
  '本应用仅聚合开源社区公开的 HAP 信息，不托管、不修改、不分发任何安装包。' +
  '第三方应用的安全性与合规性请自行判断，安装与使用的风险由使用者承担。';

/**
 * 可选中状态的小 chip。
 *
 * 必须是 @Component + @Prop：@Builder 按值传参是快照，@State 变化后
 * @Builder 内部的选中高亮不会刷新（这就是之前「选中后不高亮」的根因）。
 */
@Component
struct OptionChipView {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.active ? Theme.primary : Theme.textMain)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.active ? Theme.primaryLight : Theme.chipBg)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 分类横滑 chip，同样需要 @Prop 才能随选中态刷新。 */
@Component
struct CategoryChipView {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.active ? Theme.primary : Theme.textSub)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(this.active ? Theme.primaryLight : Theme.card)
      .flexShrink(0)
      .onClick(() => {
        this.onTap();
      })
  }
}

/**
 * 「应用」Tab：原来 pages/Index.ets 的全部内容。
 *
 * 注意：作为 TabContent 的子组件后收不到 onPageShow（只对 @Entry 生效），
 * 下载角标改为由壳页面写入 AppStorage、这里用 @StorageLink 订阅。
 */
@Component
export struct AppsTabView {
  @State data: StoreData | null = null;
  @State loading: boolean = true;
  @State errorMsg: string = '';
  /** 分类：默认筛选维度，横滑 Tab */
  @State activeCategory: string = 'all';
  /** 功能类型：单选，放在筛选面板里 */
  @State activeFunc: string = 'all';
  /** 可运行设备：多选 */
  @State selectedDevices: string[] = [];
  /** 属性标签：多选 */
  @State selectedTags: string[] = [];
  @State keyword: string = '';
  @State showFilter: boolean = false;
  @StorageLink('activeDownloads') activeDownloads: number = 0;
  /** 远端数据应用后由设置/更新页自增，这里感知并重载 */
  @StorageLink('storeEpoch') @Watch('onStoreEpoch') epoch: number = 0;
  @StorageProp('listDensity') listDensity: string = 'normal';

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const repo: StoreRepository = new StoreRepository(ctx);
    repo.load().then((d: StoreData) => {
      this.data = d;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
    });
    const store: DownloadStore = new DownloadStore(ctx);
    this.activeDownloads = store.activeCount();
  }

  onStoreEpoch(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const repo: StoreRepository = new StoreRepository(ctx);
    repo.load().then((d: StoreData) => {
      this.data = d;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
    });
  }

  getCategories(): CategoryInfo[] {
    return this.data ? this.data.categories : [];
  }

  /** 打标维度：优先用同步服务算好的统计，没有就本地聚合兜底。 */
  private optionsOf(field: string): string[] {
    const out: string[] = [];
    if (!this.data) {
      return out;
    }
    const dims: Dimensions | undefined = this.data.dimensions;
    if (dims) {
      if (field === 'funcType' && dims.funcType) {
        for (let i = 0; i < dims.funcType.length; i++) {
          out.push(dims.funcType[i].name);
        }
        return out;
      }
      if (field === 'deviceType' && dims.deviceType) {
        for (let i = 0; i < dims.deviceType.length; i++) {
          out.push(dims.deviceType[i].name);
        }
        return out;
      }
      if (field === 'tag' && dims.tag) {
        for (let i = 0; i < dims.tag.length; i++) {
          out.push(dims.tag[i].name);
        }
        return out;
      }
    }
    const apps: AppInfo[] = this.allApps();
    for (let i = 0; i < apps.length; i++) {
      const vals: string[] = this.valuesOf(apps[i], field);
      for (let j = 0; j < vals.length; j++) {
        if (vals[j].length > 0 && out.indexOf(vals[j]) < 0) {
          out.push(vals[j]);
        }
      }
    }
    return out;
  }

  private valuesOf(app: AppInfo, field: string): string[] {
    if (field === 'funcType') {
      const f: string = app.funcType ?? '';
      return f.length > 0 ? [f] : [];
    }
    if (field === 'deviceType') {
      return app.deviceTypes ?? [];
    }
    return app.tags ?? [];
  }

  private allApps(): AppInfo[] {
    const list: AppInfo[] = [];
    if (!this.data) {
      return list;
    }
    for (let i = 0; i < this.data.categories.length; i++) {
      const apps: AppInfo[] = this.data.categories[i].apps ?? [];
      for (let j = 0; j < apps.length; j++) {
        list.push(apps[j]);
      }
    }
    return list;
  }

  /** 筛选面板里生效的条件数量，用于按钮角标。 */
  filterCount(): number {
    let n: number = 0;
    if (this.activeFunc !== 'all') {
      n++;
    }
    if (this.selectedDevices.length > 0) {
      n++;
    }
    if (this.selectedTags.length > 0) {
      n++;
    }
    return n;
  }

  hasFilter(): boolean {
    return this.activeCategory !== 'all' || this.filterCount() > 0 ||
      this.keyword.trim().length > 0;
  }

  /** 多选维度用「命中任一」语义，符合筛选直觉。 */
  private hitAny(selected: string[], values: string[]): boolean {
    if (selected.length === 0) {
      return true;
    }
    for (let i = 0; i < selected.length; i++) {
      if (values.indexOf(selected[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private matchApp(app: AppInfo): boolean {
    if (this.activeFunc !== 'all' && (app.funcType ?? '') !== this.activeFunc) {
      return false;
    }
    if (!this.hitAny(this.selectedDevices, app.deviceTypes ?? [])) {
      return false;
    }
    if (!this.hitAny(this.selectedTags, app.tags ?? [])) {
      return false;
    }
    const kw: string = this.keyword.trim().toLowerCase();
    if (kw.length > 0) {
      const hay: string =
        `${app.name} ${app.desc} ${app.repo} ${app.category} ` +
        `${app.funcType ?? ''} ${(app.tags ?? []).join(' ')} ` +
        `${(app.deviceTypes ?? []).join(' ')}`.toLowerCase();
      if (hay.indexOf(kw) < 0) {
        return false;
      }
    }
    return true;
  }

  getApps(): AppInfo[] {
    if (!this.data) {
      return [];
    }
    const list: AppInfo[] = [];
    const cats: CategoryInfo[] = this.data.categories;
    for (let i = 0; i < cats.length; i++) {
      if (this.activeCategory !== 'all' && cats[i].id !== this.activeCategory) {
        continue;
      }
      const apps: AppInfo[] = cats[i].apps ?? [];
      for (let j = 0; j < apps.length; j++) {
        if (this.matchApp(apps[j])) {
          list.push(apps[j]);
        }
      }
    }
    return list;
  }

  clearFilter(): void {
    this.activeCategory = 'all';
    this.activeFunc = 'all';
    this.selectedDevices = [];
    this.selectedTags = [];
    this.keyword = '';
  }

  toggleDevice(d: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.selectedDevices.length; i++) {
      if (this.selectedDevices[i] !== d) {
        next.push(this.selectedDevices[i]);
      }
    }
    if (next.length === this.selectedDevices.length) {
      next.push(d);
    }
    this.selectedDevices = next;
  }

  toggleTag(t: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.selectedTags.length; i++) {
      if (this.selectedTags[i] !== t) {
        next.push(this.selectedTags[i]);
      }
    }
    if (next.length === this.selectedTags.length) {
      next.push(t);
    }
    this.selectedTags = next;
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Column({ space: 3 }) {
            Text('HAP 目录')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textMain)
            Text(DISCLAIMER)
              .fontSize(10)
              .fontColor(Theme.textSub)
              .lineHeight(14)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.DownloadEntry()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 10 })
        .alignItems(VerticalAlign.Top)

        TextInput({ placeholder: '搜索应用 / 描述 / 标签' })
          .width('100%')
          .height(40)
          .fontSize(14)
          .backgroundColor(Theme.card)
          .borderRadius(10)
          .margin({ left: 16, right: 16, bottom: 10 })
          .onChange((value: string) => {
            this.keyword = value;
          })

        // 分类：默认筛选维度，横向可滚动 + 右侧筛选按钮
        Row({ space: 8 }) {
          Scroll() {
            Row({ space: 8 }) {
              CategoryChipView({
                label: '全部',
                active: this.activeCategory === 'all',
                onTap: () => {
                  this.activeCategory = 'all';
                }
              })
              ForEach(this.getCategories(), (cat: CategoryInfo) => {
                CategoryChipView({
                  label: cat.name,
                  active: this.activeCategory === cat.id,
                  onTap: () => {
                    this.activeCategory = cat.id;
                  }
                })
              }, (cat: CategoryInfo) => cat.id)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)

          this.FilterButton()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10 })

        if (this.loading) {
          Column() {
            LoadingProgress().width(36).height(36).color(Theme.primary)
            Text('加载中…').fontSize(13).fontColor(Theme.textSub).margin({ top: 8 })
          }
          .width('100%')
          .height('60%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text('数据加载失败').fontSize(15).fontColor(Theme.textMain)
            Text(this.errorMsg).fontSize(12).fontColor(Theme.textSub).margin({ top: 6 })
          }
          .width('100%')
          .height('60%')
          .justifyContent(FlexAlign.Center)
        } else if (this.getApps().length === 0) {
          Column({ space: 10 }) {
            Text('没有匹配的应用').fontSize(15).fontColor(Theme.textSub)
            if (this.hasFilter()) {
              Button('清除筛选')
                .fontSize(13)
                .height(34)
                .borderRadius(17)
                .backgroundColor(Theme.primaryLight)
                .fontColor(Theme.primary)
                .onClick(() => {
                  this.clearFilter();
                })
            }
          }
          .width('100%')
          .height('60%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.getApps(), (app: AppInfo) => {
              ListItem() {
                AppCardView(app, () => {
                  router.pushUrl({
                    url: 'pages/DetailPage',
                    params: { app: JSON.stringify(app) }
                  });
                }, this.listDensity);
              }
              .padding({ left: 16, right: 16 })
            }, (app: AppInfo) => app.id)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ bottom: 16 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.background)

      // 筛选浮层：不用 bindSheet —— bindSheet 的 builder 是快照，
      // @State 变化后面板内的选中高亮不会刷新（列表却会变），改为页面内浮层。
      if (this.showFilter) {
        Column() {
          Column()
            .layoutWeight(1)
            .width('100%')
            .backgroundColor('#99000000')
            .onClick(() => {
              this.showFilter = false;
            })
          Column() {
            this.FilterSheet()
          }
          .width('100%')
          .height('62%')
          .backgroundColor(Theme.card)
          .borderRadius({ topLeft: 16, topRight: 16 })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DownloadEntry() {
    Stack() {
      Text('↓')
        .fontSize(18)
        .fontColor(Theme.primary)
        .fontWeight(FontWeight.Bold)
      if (this.activeDownloads > 0) {
        Text(`${this.activeDownloads}`)
          .fontSize(10)
          .fontColor(Theme.white)
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(Theme.danger)
          .margin({ left: 20, bottom: 20 })
      }
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(Theme.card)
    .onClick(() => {
      router.pushUrl({ url: 'pages/DownloadsPage' });
    })
  }

  @Builder
  FilterButton() {
    Row({ space: 4 }) {
      Text('筛选')
        .fontSize(13)
        .fontColor(this.filterCount() > 0 ? Theme.primary : Theme.textSub)
      if (this.filterCount() > 0) {
        Text(`${this.filterCount()}`)
          .fontSize(10)
          .fontColor(Theme.white)
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(Theme.primary)
      }
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(16)
    .backgroundColor(this.filterCount() > 0 ? Theme.primaryLight : Theme.card)
    .flexShrink(0)
    .onClick(() => {
      this.showFilter = true;
    })
  }

  @Builder
  FilterSheet() {
    Column() {
      Row() {
        Text('筛选')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textMain)
        Blank()
        Text('重置')
          .fontSize(13)
          .fontColor(Theme.primary)
          .onClick(() => {
            this.activeFunc = 'all';
            this.selectedDevices = [];
            this.selectedTags = [];
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 4 }) {
          this.SectionTitle('功能类型（单选）')
          Flex({ wrap: FlexWrap.Wrap }) {
            OptionChipView({
              label: '不限',
              active: this.activeFunc === 'all',
              onTap: () => {
                this.activeFunc = 'all';
              }
            })
            ForEach(this.optionsOf('funcType'), (fn: string) => {
              OptionChipView({
                label: fn,
                active: this.activeFunc === fn,
                onTap: () => {
                  this.activeFunc = this.activeFunc === fn ? 'all' : fn;
                }
              })
            }, (fn: string) => fn)
          }
          .width('100%')

          this.SectionTitle('可运行设备（可多选）')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.optionsOf('deviceType'), (d: string) => {
              OptionChipView({
                label: d,
                active: this.selectedDevices.indexOf(d) >= 0,
                onTap: () => {
                  this.toggleDevice(d);
                }
              })
            }, (d: string) => d)
          }
          .width('100%')

          this.SectionTitle('属性标签（可多选）')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.optionsOf('tag'), (t: string) => {
              OptionChipView({
                label: t,
                active: this.selectedTags.indexOf(t) >= 0,
                onTap: () => {
                  this.toggleTag(t);
                }
              })
            }, (t: string) => t)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }
      .layoutWeight(1)
      .width('100%')

      Button(`查看 ${this.getApps().length} 个应用`)
        .width('100%')
        .height(44)
        .fontSize(15)
        .borderRadius(22)
        .backgroundColor(Theme.primary)
        .onClick(() => {
          this.showFilter = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder
  SectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.textSub)
      .width('100%')
      .margin({ top: 12, bottom: 8 })
  }
}
