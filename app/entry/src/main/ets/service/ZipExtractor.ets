import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { HLog } from '../common/HLog';

/**
 * zip 包解压：从「装着 HAP 的 .zip」里把 HAP 挖出来。
 *
 * 有些上游不直接发 .hap，而是把 HAP 打包成 .zip 发（发布方不想直接暴露 .hap）。
 * 这类包不处理的话，等于整个应用收不到 —— 之前 7 个应用就卡在这。
 *
 * 实测到的三种包结构：
 *   1. zip 里直接是 xxx.hap            → 解压即得（HiSH）
 *   2. zip 里是 xxx.app，而 .app 本身又是 zip，里面才有 entry-default.hap → 两层
 *      （CanPlayer、Nexus）
 *   3. zip 里是整个目录树              → 递归找
 *
 * 所以要递归解包：碰到 .app 就再解一次，直到拿到 .hap。
 */

/** 解压结果：找到的 HAP 路径（沙箱内绝对路径）。 */
export interface ExtractResult {
  /** 找到的 HAP 沙箱路径，没找到为空串 */
  hapPath: string;
  /** 解压出的目录（便于后续查找/清理） */
  outDir: string;
  /** 人话说明 */
  message: string;
}

/** 最多递归解几层包，防止异常包把目录树走穿。 */
const MAX_DEPTH: number = 3;

export class ZipExtractor {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 解压目录：filesDir/unzip/<包名>/，同名目录先清空。 */
  private targetDir(zipName: string): string {
    const stem: string = zipName.replace(/\.zip$/i, '').replace(/[^\w.-]/g, '_');
    const dir: string = `${this.context.filesDir}/unzip/${stem}`;
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      // 删不掉就往下走，解压会覆盖
    }
    try {
      fileIo.mkdirSync(dir, true);
    } catch (e) {
      HLog.w(`建解压目录失败 ${dir}`);
    }
    return dir;
  }

  /**
   * 解压并找出里面的 HAP。
   *
   * @param zipPath 沙箱内的 zip 绝对路径
   */
  async extract(zipPath: string): Promise<ExtractResult> {
    const outDir: string = this.targetDir(zipPath.substring(zipPath.lastIndexOf('/') + 1));
    try {
      await zlib.decompressFile(zipPath, outDir);
    } catch (e) {
      const err: Error = e as Error;
      HLog.e(`解压失败 ${zipPath} : ${err.message}`);
      return { hapPath: '', outDir: outDir, message: '解压失败，可能是包损坏或不是标准 zip' };
    }
    const found: string = await this.findHap(outDir, 0);
    if (found.length === 0) {
      HLog.w(`zip 里没有 HAP：${zipPath}`);
      return { hapPath: '', outDir: outDir, message: '压缩包里没找到 HAP' };
    }
    HLog.i(`从 zip 解出 HAP：${found}`);
    return { hapPath: found, outDir: outDir, message: '已解压' };
  }

  /**
   * 递归找 HAP。
   *
   * 优先找 .hap（直接能装）；碰到 .app 就再解一层（.app 本身是 zip 容器）。
   */
  private async findHap(dir: string, depth: number): Promise<string> {
    if (depth > MAX_DEPTH) {
      return '';
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return '';
    }
    // 先扫当前层的 .hap
    for (let i = 0; i < names.length; i++) {
      if (names[i].toLowerCase().endsWith('.hap')) {
        return `${dir}/${names[i]}`;
      }
    }
    // 再进子目录找
    for (let i = 0; i < names.length; i++) {
      const sub: string = `${dir}/${names[i]}`;
      try {
        if (!fileIo.accessSync(sub)) {
          continue;
        }
        const stat: fileIo.Stat = fileIo.statSync(sub);
        if (stat.isDirectory()) {
          const hit: string = await this.findHap(sub, depth + 1);
          if (hit.length > 0) {
            return hit;
          }
        }
      } catch (e) {
        // 跳过读不了的项
      }
    }
    // 最后看当前层有没有 .app —— 它是 zip 容器，再解一层
    for (let i = 0; i < names.length; i++) {
      if (!names[i].toLowerCase().endsWith('.app')) {
        continue;
      }
      const appPath: string = `${dir}/${names[i]}`;
      const inner: string = `${dir}/_app_${i}`;
      try {
        fileIo.mkdirSync(inner, true);
        await zlib.decompressFile(appPath, inner);
        const hit: string = await this.findHap(inner, depth + 1);
        if (hit.length > 0) {
          return hit;
        }
      } catch (e) {
        HLog.w(`.app 解包失败 ${appPath}`);
      }
    }
    return '';
  }

  /** 清掉解压目录（用户装完后省空间）。 */
  cleanup(outDir: string): void {
    if (outDir.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(outDir)) {
        fileIo.rmdirSync(outDir);
      }
    } catch (e) {
      HLog.w(`清理解压目录失败 ${outDir}`);
    }
  }
}
