/**
 * 浅色蓝白主题。
 *
 * 颜色一律走资源（$r），这样设置页切换深色模式时 setColorMode 才能生效；
 * 硬编码的 #RRGGBB 不会随系统配置变化。
 */
export class Theme {
  static readonly primary: ResourceColor = $r('app.color.primary');
  static readonly primaryLight: ResourceColor = $r('app.color.primary_light');
  static readonly background: ResourceColor = $r('app.color.background');
  static readonly card: ResourceColor = $r('app.color.card');
  static readonly textMain: ResourceColor = $r('app.color.text_main');
  static readonly textSub: ResourceColor = $r('app.color.text_sub');
  static readonly divider: ResourceColor = $r('app.color.divider');
  static readonly success: ResourceColor = $r('app.color.success');
  static readonly warning: ResourceColor = $r('app.color.warning');
  static readonly danger: ResourceColor = $r('app.color.danger');
  /** 灰底 chip / 标签底 */
  static readonly chipBg: ResourceColor = $r('app.color.chip_bg');
  static readonly successBg: ResourceColor = $r('app.color.success_bg');
  static readonly dangerBg: ResourceColor = $r('app.color.danger_bg');
  /** 图标占位底 */
  static readonly iconBg: ResourceColor = $r('app.color.icon_bg');
  static readonly white: ResourceColor = $r('app.color.white');
  static readonly radius: number = 12;
}
