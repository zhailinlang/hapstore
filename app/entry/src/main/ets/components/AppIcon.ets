import { AppInfo } from '../model/AppInfo';
import { Theme } from '../common/constants/ThemeConstants';

/** 无图标时的兜底色板（与蓝白主题协调，深浅接近，白色字都压得住）。 */
const FALLBACK_COLORS: string[] = [
  '#2F6BFF', '#3E8EFA', '#00A6A6', '#5B8FF9', '#7A6BF0',
  '#E8684A', '#F5A623', '#52A927', '#13A8C2', '#8B5CF6'
];

/** 名字 → 稳定色，保证同一个应用每次进来颜色一致。 */
function hashColor(name: string): string {
  let h: number = 0;
  const s: string = name ?? '';
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) % 1000003;
  }
  return FALLBACK_COLORS[h % FALLBACK_COLORS.length];
}

/**
 * 应用图标。
 *
 * iconUrl 由同步服务生成，是 `data:image/png;base64,...` 的内嵌字符串
 * （不走网络，所以不受 raw.githubusercontent.com 国内可达性影响）。
 * 抓不到图标时退回首字母色块。
 */
@Builder
export function AppIconView(app: AppInfo, size: number, radius: number) {
  if ((app.iconUrl ?? '').length > 0) {
    Image(app.iconUrl)
      .width(size)
      .height(size)
      .borderRadius(radius)
      .objectFit(ImageFit.Cover)
      .backgroundColor(Theme.iconBg)
      .draggable(false)
  } else {
    Text((app.name ?? '?').substring(0, 1))
      .width(size)
      .height(size)
      .borderRadius(radius)
      .fontSize(size * 0.45)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .backgroundColor(hashColor(app.name ?? ''))
  }
}
