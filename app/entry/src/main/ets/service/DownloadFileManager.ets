import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { HLog } from '../common/HLog';

const SUB_DIR: string = 'hap';
const CHUNK: number = 1024 * 1024;

/**
 * HAP 落盘：沙箱临时文件中转。
 *
 * 之前 request.agent 直接写用户 Picker 给的 URI，带来两个问题：
 * 1. 中断后目录里留下一个看似完整实则不完整的 .hap；
 * 2. 目标已存在同名文件时只能由系统弹提示，App 没有覆盖能力。
 *
 * 现在改成：下载 → 沙箱 xxx.hap.part → 校验大小 → rename 成正式名 → 复制到用户选的位置（可覆盖）。
 */
export class DownloadFileManager {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 沙箱内 HAP 存放目录，不存在就建。 */
  dir(): string {
    const path: string = `${this.context.filesDir}/${SUB_DIR}`;
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (e) {
      HLog.w(`创建沙箱目录失败 ${path}`);
    }
    return path;
  }

  /** 把可能带非法字符的资产名收拾成能落盘的文件名。 */
  safeName(name: string): string {
    let out: string = '';
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      if (c === '/' || c === '\\' || c === ':' || c === '*' || c === '?' ||
        c === '"' || c === '<' || c === '>' || c === '|' || c === '\n' || c === '\r') {
        out += '_';
      } else {
        out += c;
      }
    }
    if (out.length === 0) {
      out = 'app.hap';
    }
    if (out.length > 80) {
      out = out.substring(out.length - 80);
    }
    return out;
  }

  /**
   * 文件夹名：比文件名宽松（冒号、空格都能用），只挡真正会破坏路径的字符。
   * 用应用名当文件夹名，一堆 entry-default-unsigned.hap 就不会挤在一起了。
   */
  folderName(name: string): string {
    let out: string = '';
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      if (c === '/' || c === '\\' || c === '*' || c === '?' ||
        c === '"' || c === '<' || c === '>' || c === '|' || c === '\n' || c === '\r') {
        out += '_';
      } else {
        out += c;
      }
    }
    out = out.trim();
    if (out.length === 0) {
      out = 'HAP';
    }
    if (out.length > 60) {
      out = out.substring(0, 60).trim();
    }
    return out;
  }

  /** 父 URI + 名字 → 子 URI。名字要编码，中文名才不会把 URI 拆坏。 */
  childUri(parentUri: string, name: string): string {
    if (parentUri.length === 0) {
      return '';
    }
    let base: string = parentUri;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return `${base}/${encodeURIComponent(name)}`;
  }

  /**
   * 在用户目录（Picker 给的目录 URI）下建子文件夹，返回它的 URI；建不了返回空串。
   *
   * 目录权限不总是允许自建子项，所以调用方必须有兜底（回退到 Picker 选文件）。
   */
  mkdirUnder(parentUri: string, name: string): string {
    if (parentUri.length === 0) {
      return '';
    }
    const child: string = this.childUri(parentUri, this.folderName(name));
    try {
      if (fileIo.accessSync(child)) {
        return child;
      }
    } catch (e) {
      // 不存在或不可访问，继续尝试创建
    }
    try {
      fileIo.mkdirSync(child, true);
      HLog.i(`建目录 ${child}`);
      return child;
    } catch (e) {
      const err: Error = e as Error;
      HLog.w(`建目录失败 ${child} : ${err.message}`);
    }
    // 再试一次：部分文件提供者在「写文件」时会自动补齐中间目录。
    // 用一个临时探针文件探一下，成功就把目录拿下来，探针立刻删掉。
    if (this.probeWritable(child)) {
      HLog.i(`目录可用（写文件时自动补齐）${child}`);
      return child;
    }
    return '';
  }

  /** 目录里能不能落文件：写一个空探针再删掉。用于判断目录是否真的可用。 */
  private probeWritable(dirUri: string): boolean {
    const probe: string = this.childUri(dirUri, '.hapstore-probe');
    let f: fileIo.File | null = null;
    try {
      f = fileIo.openSync(probe,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.closeSync(f);
      f = null;
      try {
        fileIo.unlinkSync(probe);
      } catch (e) {
        HLog.w(`探针文件没删掉 ${probe}`);
      }
      return true;
    } catch (e) {
      const err: Error = e as Error;
      HLog.w(`目录不可写 ${dirUri} : ${err.message}`);
      if (f) {
        try {
          fileIo.closeSync(f);
        } catch (e2) {
          // 关闭失败不影响结果
        }
      }
      return false;
    }
  }

  /**
   * 目录里已经有同名文件时自动加 -2 / -3 后缀。
   *
   * 系统的保存对话框遇到重名会停在「已有重名文件」，确认按钮点不动，
   * 等于把重新下载同一个版本这条路堵死。这里先躲开重名，让流程能走完。
   */
  uniqueNameUnder(dirUri: string, name: string): string {
    if (dirUri.length === 0) {
      return name;
    }
    if (!this.existsUri(this.childUri(dirUri, name))) {
      return name;
    }
    const stem: string = this.stripExt(name);
    const ext: string = this.extOf(name);
    let n: number = 2;
    while (n < 50) {
      const candidate: string = `${stem}-${n}${ext}`;
      if (!this.existsUri(this.childUri(dirUri, candidate))) {
        HLog.i(`目标位置已有同名文件，改用 ${candidate}`);
        return candidate;
      }
      n++;
    }
    return `${stem}-${Date.now()}${ext}`;
  }

  /** 在扩展名之前插一段（补版本号用）：a.hap + 1.2.5 → a-1.2.5.hap。 */
  insertBeforeExt(name: string, suffix: string): string {
    const s: string = suffix.trim();
    if (s.length === 0) {
      return name;
    }
    const ext: string = this.extOf(name);
    const stem: string = this.stripExt(name);
    return `${stem}-${s}${ext}`;
  }

  /** 下载中的临时文件名：正式名 + .part，未完成绝不暴露成 .hap。 */
  tempPath(fileName: string): string {
    return `${this.dir()}/${this.safeName(fileName)}.part`;
  }

  /** 沙箱内的正式路径；撞车就加序号，避免覆盖上一次下载的文件。 */
  finalPath(fileName: string): string {
    const base: string = this.safeName(fileName);
    let target: string = `${this.dir()}/${base}`;
    let n: number = 1;
    while (this.existsLocal(target)) {
      n++;
      target = `${this.dir()}/${this.stripExt(base)}-${n}${this.extOf(base)}`;
      if (n > 50) {
        break;
      }
    }
    return target;
  }

  existsLocal(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /**
   * 目标 URI 上是否已存在（决定要不要弹覆盖确认）。
   * 目录 URI 上 accessSync 不一定买账，所以再加一层 statSync 兜底。
   */
  existsUri(uri: string): boolean {
    if (uri.length === 0) {
      return false;
    }
    try {
      if (fileIo.accessSync(uri)) {
        return true;
      }
    } catch (e) {
      // 换下一种判断方式
    }
    try {
      fileIo.statSync(uri);
      return true;
    } catch (e) {
      return false;
    }
  }

  sizeOf(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  /** 大小校验：GitHub 给的 size 偶尔有出入，允许 1% 误差；期望值为 0 时不校验。 */
  verify(path: string, expect: number): boolean {
    const real: number = this.sizeOf(path);
    if (real <= 0) {
      return false;
    }
    if (expect <= 0) {
      return true;
    }
    const diff: number = real > expect ? real - expect : expect - real;
    return diff * 100 <= expect;
  }

  /** .part → 正式名。 */
  promote(temp: string, final: string): boolean {
    try {
      if (this.existsLocal(final)) {
        fileIo.unlinkSync(final);
      }
      fileIo.renameSync(temp, final);
      return true;
    } catch (e) {
      HLog.e(`改名失败 ${temp} -> ${final}`);
      return false;
    }
  }

  /**
   * 把沙箱文件写到用户选的位置，存在即覆盖。
   *
   * 不用 copyFileSync：它对 document URI 的支持不稳，这里手动分块读写更可控，
   * 打开时带 TRUNC，这就是「覆盖」的落点。
   */
  copyToUri(srcPath: string, destUri: string): boolean {
    let src: fileIo.File | null = null;
    let dst: fileIo.File | null = null;
    try {
      src = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
      dst = fileIo.openSync(destUri,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const total: number = this.sizeOf(srcPath);
      let offset: number = 0;
      while (offset < total) {
        const want: number = total - offset > CHUNK ? CHUNK : total - offset;
        const buf: ArrayBuffer = new ArrayBuffer(want);
        const got: number = fileIo.readSync(src.fd, buf, { offset: offset, length: want });
        if (got <= 0) {
          break;
        }
        fileIo.writeSync(dst.fd, buf, { length: got });
        offset += got;
      }
      return offset >= total;
    } catch (e) {
      const err: Error = e as Error;
      HLog.e(`复制失败 ${srcPath} -> ${destUri} : ${err.message}`);
      return false;
    } finally {
      if (src) {
        try {
          fileIo.closeSync(src);
        } catch (e) {
          // 关闭失败不影响结果
        }
      }
      if (dst) {
        try {
          fileIo.closeSync(dst);
        } catch (e) {
          // 关闭失败不影响结果
        }
      }
    }
  }

  /** 删掉沙箱里的文件（取消下载删 .part，用户主动清理删正式文件）。 */
  deleteLocal(path: string): boolean {
    if (path.length === 0 || !this.existsLocal(path)) {
      return false;
    }
    try {
      fileIo.unlinkSync(path);
      return true;
    } catch (e) {
      HLog.w(`删除失败 ${path}`);
      return false;
    }
  }

  private extOf(name: string): string {
    const idx: number = name.lastIndexOf('.');
    return idx > 0 ? name.substring(idx) : '';
  }

  private stripExt(name: string): string {
    const idx: number = name.lastIndexOf('.');
    return idx > 0 ? name.substring(0, idx) : name;
  }
}
