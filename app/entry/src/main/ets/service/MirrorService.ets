import { http } from '@kit.NetworkKit';
import {
  BUILTIN_MIRRORS,
  DEFAULT_PROBE_URL,
  MIRROR_CUSTOM_ID,
  MIRROR_DIRECT_ID,
  MirrorItem,
  mirrorById,
  validCustomTemplate
} from '../model/SettingsData';
import { SettingsStore } from './SettingsStore';
import { StoreCache } from './StoreCache';
import { StoreData } from '../model/AppInfo';
import { HLog } from '../common/HLog';

export interface SpeedResult {
  id: string;
  name: string;
  template: string;
  ok: boolean;
  ms: number;
}

/**
 * GitHub 直连 / 镜像代理。
 *
 * 所有公开镜像都是「前缀式」：镜像地址 + 原始完整链接，所以统一用 {url} 占位符表达。
 * 镜像随时可能失效，所以提供测速；下载失败还会自动换另一条链路重试一次。
 */
export class MirrorService {
  /**
   * 只对 github.com / raw.githubusercontent.com 这类"可被镜像代理"的域名改写。
   * objects.githubusercontent.com 是 CDN 裸链，镜像站普遍不认，必须排除。
   */
  static isGithubUrl(url: string): boolean {
    const host: string = MirrorService.hostOf(url);
    if (host.length === 0) {
      return false;
    }
    if (host === 'objects.githubusercontent.com' || host.endsWith('.objects.githubusercontent.com')) {
      return false;
    }
    return host === 'github.com' || host.endsWith('.github.com') ||
      host === 'raw.githubusercontent.com' || host.endsWith('.raw.githubusercontent.com') ||
      host === 'api.github.com';
  }

  /** 当前生效链路的一句话描述，日志与设置页都用它。 */
  static describe(): string {
    const data = SettingsStore.shared().get();
    if (!data.mirrorEnabled || data.mirrorId === MIRROR_DIRECT_ID) {
      return '直连 GitHub';
    }
    if (data.mirrorTemplate.length === 0) {
      return '直连 GitHub（镜像模板无效）';
    }
    const item: MirrorItem = mirrorById(data.mirrorId);
    let name: string = item.name;
    if (data.mirrorId === MIRROR_CUSTOM_ID) {
      name = '自定义镜像';
    }
    return `镜像 ${name}`;
  }

  /** 把原始链接改写成镜像链接；直连或模板无效时原样返回。 */
  static apply(rawUrl: string): string {
    const data = SettingsStore.shared().get();
    if (!data.mirrorEnabled) {
      return rawUrl;
    }
    return MirrorService.forced(rawUrl, true);
  }

  /** 明确指定走不走镜像：下载失败重试时用（自动回退到另一条链路）。 */
  static forced(rawUrl: string, useMirror: boolean): string {
    const data = SettingsStore.shared().get();
    if (!useMirror) {
      return rawUrl;
    }
    const tpl: string = data.mirrorTemplate;
    if (tpl.length === 0 || tpl.indexOf('{url}') < 0) {
      return rawUrl;
    }
    if (!MirrorService.isGithubUrl(rawUrl)) {
      return rawUrl;
    }
    // 用 split/join 而不是 replace：replace 只替换第一处，模板里出现多个 {url} 会漏
    return tpl.split('{url}').join(rawUrl);
  }

  /** 另一条链路的 URL：当前走镜像就返回直连，当前直连就返回镜像；拿不到返回空串。 */
  static fallback(rawUrl: string): string {
    const data = SettingsStore.shared().get();
    if (!data.mirrorEnabled || !data.mirrorFallback) {
      return '';
    }
    if (MirrorService.apply(rawUrl) !== rawUrl) {
      return rawUrl;
    }
    const mirrored: string = MirrorService.forced(rawUrl, true);
    return mirrored === rawUrl ? '' : mirrored;
  }

  /** 设置页里实时预览转换结果。 */
  static preview(template: string, sample: string): string {
    if (template.length === 0 || template.indexOf('{url}') < 0) {
      return sample;
    }
    return template.split('{url}').join(sample);
  }

  /**
   * 测速目标：优先用快照里真实的 release asset 直链。
   *
   * 用 raw README 测出来的"最快镜像"常常下不动 HAP——raw 与 release 在镜像站上是两条后端。
   */
  static realProbeUrl(): string {
    const data: StoreData | null = StoreCache.get();
    if (data) {
      for (let i = 0; i < data.categories.length; i++) {
        const apps = data.categories[i].apps;
        for (let j = 0; j < apps.length; j++) {
          const assets = apps[j].hapAssets;
          if (assets && assets.length > 0 && assets[0].downloadUrl.length > 0) {
            return assets[0].downloadUrl;
          }
        }
      }
    }
    return DEFAULT_PROBE_URL;
  }

  /** 对所有候选镜像（含直连）并发测速，可用优先、耗时升序。 */
  static async speedTest(probeUrl: string): Promise<SpeedResult[]> {
    const custom: string = SettingsStore.shared().get().customTemplate;
    const target: string = probeUrl.length > 0 ? probeUrl : MirrorService.realProbeUrl();
    HLog.i(`测速目标 ${target}`);
    const jobs: Promise<SpeedResult>[] = [];
    for (let i = 0; i < BUILTIN_MIRRORS.length; i++) {
      const item: MirrorItem = BUILTIN_MIRRORS[i];
      let tpl: string = item.template;
      if (item.id === MIRROR_CUSTOM_ID) {
        if (!validCustomTemplate(custom)) {
          continue;
        }
        tpl = custom;
      }
      jobs.push(MirrorService.probe(item, tpl, target));
    }
    const results: SpeedResult[] = await Promise.all(jobs);
    results.sort((a: SpeedResult, b: SpeedResult) => {
      if (a.ok !== b.ok) {
        return a.ok ? -1 : 1;
      }
      return a.ms - b.ms;
    });
    return results;
  }

  /** 自定模板是否合法。 */
  static validTemplate(tpl: string): boolean {
    return validCustomTemplate(tpl);
  }

  static directId(): string {
    return MIRROR_DIRECT_ID;
  }

  private static hostOf(url: string): string {
    const s: string = url.trim();
    const at: number = s.indexOf('://');
    const rest: string = at >= 0 ? s.substring(at + 3) : s;
    let end: number = rest.length;
    for (let i = 0; i < rest.length; i++) {
      const c: string = rest.charAt(i);
      if (c === '/' || c === '?' || c === '#' || c === ':') {
        end = i;
        break;
      }
    }
    return rest.substring(0, end).toLowerCase();
  }

  private static async probe(item: MirrorItem, template: string, probeUrl: string): Promise<SpeedResult> {
    const url: string = template.length > 0 ? template.split('{url}').join(probeUrl) : probeUrl;
    const req: http.HttpRequest = http.createHttp();
    const t0: number = Date.now();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        // 只取前 2KB，避免把整个 HAP 拉下来测速
        header: { 'Range': 'bytes=0-2047' },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 4000,
        readTimeout: 6000,
        usingCache: false
      });
      const code: number = Number(resp.responseCode);
      let len: number = 0;
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result;
        len = body.length;
      }
      const good: boolean = (code === 200 || code === 206) && len > 0 &&
        body.indexOf('<html') < 0 && body.indexOf('<!DOCTYPE') < 0;
      const result: SpeedResult = {
        id: item.id,
        name: item.name,
        template: template,
        ok: good,
        ms: Date.now() - t0
      };
      return result;
    } catch (e) {
      const result: SpeedResult = {
        id: item.id,
        name: item.name,
        template: template,
        ok: false,
        ms: Date.now() - t0
      };
      return result;
    } finally {
      req.destroy();
    }
  }
}
