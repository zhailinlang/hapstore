/** 设置项结构，持久化在 filesDir/settings.json。 */

/** 一个镜像选项。template 里用 {url} 占位原始链接，直连为空串。 */
export interface MirrorItem {
  id: string;
  name: string;
  template: string;
  /** 备注，UI 上作为副标题 */
  note: string;
  /** 实测可用且优先推荐，UI 上打「推荐」标 */
  recommend?: boolean;
}

export const MIRROR_DIRECT_ID: string = 'direct';
export const MIRROR_CUSTOM_ID: string = 'custom';

/** 测速兜底目标。真实测速会优先用快照里的 release 直链，见 MirrorService.realProbeUrl()。 */
export const DEFAULT_PROBE_URL: string =
  'https://github.com/Zitann/HarmonyOS-Haps/releases/latest';

/**
 * 候选镜像。
 *
 * 只保留实测能通的：2026-09 实测 gh-proxy.com / gh-proxy.org / mirror.ghproxy.com /
 * hub.gitmirror.com / gh.llkk.cc / moeyy.cn 已全部失效（403 或连不上），
 * 留着只会让人选到死的链路，所以直接删掉。默认直连，需要加速再手动开镜像。
 */
export const BUILTIN_MIRRORS: MirrorItem[] = [
  { id: MIRROR_DIRECT_ID, name: '直连 GitHub', template: '', note: '默认，不经过任何代理' },
  {
    id: 'ghfast',
    name: 'ghfast.top',
    template: 'https://ghfast.top/{url}',
    note: '实测可用，公益镜像',
    recommend: true
  },
  { id: 'ghproxy_net', name: 'ghproxy.net', template: 'https://ghproxy.net/{url}', note: '实测可用，支持 Release / Raw' },
  { id: MIRROR_CUSTOM_ID, name: '自定义', template: '', note: '自己填模板，必须含 {url}' }
];

export interface SettingsData {
  schemaVersion: number;
  /** 远端 apps.json 地址；为空则更新页只做离线比对 */
  sourceUrl: string;
  autoCheckOnLaunch: boolean;
  checkIntervalHours: number;
  lastCheckAt: number;
  lastRemoteGeneratedAt: string;
  /** system / light / dark */
  themeMode: string;
  /** compact / normal */
  listDensity: string;
  mirrorEnabled: boolean;
  mirrorId: string;
  /** 生效中的模板，由 mirrorId 或自定义推导（不落盘，每次启动时重算，避免残缺模板被持久化） */
  mirrorTemplate: string;
  customTemplate: string;
  /** 镜像下载失败时自动换另一条链路重试一次 */
  mirrorFallback: boolean;
  probeUrl: string;
  autoOpenInstallGuide: boolean;
  meteredWarn: boolean;
  /**
   * 下载根目录（系统文件选择器给的目录 URI）。
   * 每个应用会在它下面按应用名建子文件夹，避免一堆 entry-default-unsigned.hap 撞车。
   */
  downloadRootUri: string;
  /** 根目录的展示名（从 URI 尾巴上截的），只用于设置页显示 */
  downloadRootName: string;
  /** 文件名里没有版本号时，自动补上（entry-default-unsigned.hap → entry-default-unsigned-1.2.5.hap） */
  appendVersionToName: boolean;
}

export function DEFAULT_SETTINGS(): SettingsData {
  return {
    schemaVersion: 1,
    sourceUrl: '',
    autoCheckOnLaunch: false,
    checkIntervalHours: 24,
    lastCheckAt: 0,
    lastRemoteGeneratedAt: '',
    themeMode: 'system',
    listDensity: 'normal',
    mirrorEnabled: false,
    mirrorId: MIRROR_DIRECT_ID,
    mirrorTemplate: '',
    customTemplate: '',
    mirrorFallback: true,
    probeUrl: DEFAULT_PROBE_URL,
    autoOpenInstallGuide: true,
    meteredWarn: true,
    downloadRootUri: '',
    downloadRootName: '',
    appendVersionToName: true
  };
}

/** 单点更新用：字段全可选，避免对象展开（ArkTS 不支持）。 */
export interface SettingsPatch {
  schemaVersion?: number;
  sourceUrl?: string;
  autoCheckOnLaunch?: boolean;
  checkIntervalHours?: number;
  lastCheckAt?: number;
  lastRemoteGeneratedAt?: string;
  themeMode?: string;
  listDensity?: string;
  mirrorEnabled?: boolean;
  mirrorId?: string;
  mirrorTemplate?: string;
  customTemplate?: string;
  mirrorFallback?: boolean;
  probeUrl?: string;
  autoOpenInstallGuide?: boolean;
  meteredWarn?: boolean;
  downloadRootUri?: string;
  downloadRootName?: string;
  appendVersionToName?: boolean;
}

/**
 * 文件名里是否已经带了版本号。
 *
 * 比对前把「-」「_」「空格」都抹掉再比，这样 v1.0.0.2 能匹配到 xxx-v1.0.0.2-unsigned 里的
 * 那一段；同时拿「原始 tag」和「去掉 v 前缀的 tag」各比一次，v1.2.5 / 1.2.5 都能认出来。
 */
export function nameHasVersion(fileName: string, version: string): boolean {
  if (fileName.length === 0 || version.length === 0) {
    return false;
  }
  const hay: string = compact(fileName);
  if (hay.length === 0) {
    return false;
  }
  const full: string = compact(version);
  if (full.length > 0 && hay.indexOf(full) >= 0) {
    return true;
  }
  const bare: string = compact(stripVersionPrefix(version));
  return bare.length > 0 && hay.indexOf(bare) >= 0;
}

/** 去掉版本号前面的 v / V / release- 之类前缀。 */
function stripVersionPrefix(version: string): string {
  let s: string = version.trim();
  if (s.length > 1 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
    s = s.substring(1);
  }
  return s;
}

/** 抹掉分隔符并转小写，只留字母数字点加号，用于「文件名里有没有版本号」的模糊比对。 */
function compact(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === '-' || c === '_' || c === ' ' || c === '(' || c === ')') {
      continue;
    }
    out += c.toLowerCase();
  }
  return out;
}

/**
 * 从目录 URI 尾巴上取个能给人看的名字。
 * URI 形如 file://docs/storage/Users/currentUser/Download，取最后一段即可。
 */
export function uriDisplayName(uri: string): string {
  if (uri.length === 0) {
    return '';
  }
  let s: string = uri;
  const q: number = s.indexOf('?');
  if (q > 0) {
    s = s.substring(0, q);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  const slash: number = s.lastIndexOf('/');
  let name: string = slash >= 0 ? s.substring(slash + 1) : s;
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 解码失败就用原始串
  }
  return name.length > 0 ? name : uri;
}

/** 运行时全局状态（不落盘）的 key。 */
export class Keys {
  static readonly activeDownloads: string = 'activeDownloads';
  static readonly storeEpoch: string = 'storeEpoch';
  static readonly updateCount: string = 'updateCount';
}

/** 自定义模板必须带协议、带 {url} 占位，否则一律视为无效（不生效）。 */
export function validCustomTemplate(tpl: string): boolean {
  const s: string = tpl.trim();
  if (s.indexOf('{url}') < 0) {
    return false;
  }
  return s.indexOf('http://') === 0 || s.indexOf('https://') === 0;
}

/** 无效模板的人话解释，设置页直接显示。 */
export function templateProblem(tpl: string): string {
  const s: string = tpl.trim();
  if (s.length === 0) {
    return '还没填模板';
  }
  if (s.indexOf('{url}') < 0) {
    return '缺少 {url} 占位符，无法拼接原始链接';
  }
  if (s.indexOf('http://') !== 0 && s.indexOf('https://') !== 0) {
    return '要以 http:// 或 https:// 开头';
  }
  return '';
}

export function mirrorById(id: string): MirrorItem {
  for (let i = 0; i < BUILTIN_MIRRORS.length; i++) {
    if (BUILTIN_MIRRORS[i].id === id) {
      return BUILTIN_MIRRORS[i];
    }
  }
  return BUILTIN_MIRRORS[0];
}
