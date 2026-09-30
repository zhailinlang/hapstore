import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  DownloadRecord,
  DL_CANCELED,
  DL_DONE,
  DL_DOWNLOADING,
  DL_FAILED,
  DL_PAUSED,
  normalizeRecord
} from '../model/DownloadRecord';

const STORE_FILE: string = 'downloads.json';
const MAX_RECORDS: number = 100;

/** 下载历史：直接落 filesDir 的 JSON，避免依赖 preferences 的版本差异。 */
export class DownloadStore {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 最近在前，最多 100 条。 */
  list(): DownloadRecord[] {
    const all: DownloadRecord[] = this.read();
    all.sort((a: DownloadRecord, b: DownloadRecord) => b.startedAt - a.startedAt);
    return all;
  }

  activeCount(): number {
    const all: DownloadRecord[] = this.read();
    let n: number = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i].status === DL_DOWNLOADING) {
        n++;
      }
    }
    return n;
  }

  find(tid: string): DownloadRecord | null {
    const all: DownloadRecord[] = this.read();
    for (let i = 0; i < all.length; i++) {
      if (all[i].tid === tid) {
        return all[i];
      }
    }
    return null;
  }

  add(record: DownloadRecord): void {
    const all: DownloadRecord[] = this.read();
    all.push(record);
    this.write(all);
  }

  /** 只改状态，不动进度（暂停/继续用，避免把进度清零）。 */
  updateStatus(tid: string, status: string): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.status = status;
    });
  }

  /** 只改进度，不动状态。 */
  updateProgress(tid: string, processed: number): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.processed = processed;
    });
  }

  /** 终态收口：写 finishedAt、错误码与说明。 */
  finish(tid: string, status: string, errCode: number, errMsg: string): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.status = status;
      rec.finishedAt = Date.now();
      rec.errCode = errCode;
      rec.errMsg = errMsg;
    });
  }

  /** 换链路重试会生成新任务，记录主键跟着换。 */
  retag(oldTid: string, newTid: string): void {
    this.patch(oldTid, (rec: DownloadRecord): void => {
      rec.tid = newTid;
    });
  }

  /** 记录沙箱内的正式文件路径（下载完成改完名后写）。 */
  setLocalPath(tid: string, localPath: string): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.localPath = localPath;
    });
  }

  /** 记录实际使用的下载链接与链路描述。 */
  setFinalUrl(tid: string, finalUrl: string, via: string): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.finalUrl = finalUrl;
      rec.via = via;
    });
  }

  /** 导出到用户目录后更新保存位置。 */
  setSaveUri(tid: string, saveUri: string, fileName: string): void {
    this.patch(tid, (rec: DownloadRecord): void => {
      rec.saveUri = saveUri;
      if (fileName.length > 0) {
        rec.fileName = fileName;
      }
    });
  }

  remove(tid: string): void {
    const all: DownloadRecord[] = this.read();
    const next: DownloadRecord[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].tid !== tid) {
        next.push(all[i]);
      }
    }
    this.write(next);
  }

  /** 清空全部记录（设置页「清空下载记录」用）。 */
  clearAll(): void {
    this.write([]);
  }

  /** 清掉已结束的，保留进行中与暂停的。 */
  clearFinished(): void {
    const all: DownloadRecord[] = this.read();
    const next: DownloadRecord[] = [];
    for (let i = 0; i < all.length; i++) {
      const st: string = all[i].status;
      if (st === DL_DOWNLOADING || st === DL_PAUSED) {
        next.push(all[i]);
      }
    }
    this.write(next);
  }

  /** 把 downloading 但系统里已经查不到的僵尸记录收敛成失败，返回被修正的条数。 */
  normalizeZombies(aliveTids: string[]): number {
    let fixed: number = 0;
    const all: DownloadRecord[] = this.read();
    for (let i = 0; i < all.length; i++) {
      const rec: DownloadRecord = all[i];
      if (rec.status !== DL_DOWNLOADING && rec.status !== DL_PAUSED) {
        continue;
      }
      if (aliveTids.indexOf(rec.tid) >= 0) {
        continue;
      }
      rec.status = rec.status === DL_PAUSED ? DL_PAUSED : DL_FAILED;
      rec.errCode = -1;
      rec.errMsg = '任务已不在系统下载服务中';
      all[i] = rec;
      fixed++;
    }
    if (fixed > 0) {
      this.write(all);
    }
    return fixed;
  }

  private patch(tid: string, fn: (rec: DownloadRecord) => void): void {
    const all: DownloadRecord[] = this.read();
    for (let i = 0; i < all.length; i++) {
      if (all[i].tid === tid) {
        const rec: DownloadRecord = all[i];
        fn(rec);
        all[i] = rec;
        break;
      }
    }
    this.write(all);
  }

  private path(): string {
    return `${this.context.filesDir}/${STORE_FILE}`;
  }

  private read(): DownloadRecord[] {
    try {
      if (!fileIo.accessSync(this.path())) {
        return [];
      }
      const file: fileIo.File = fileIo.openSync(this.path(), fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(this.path());
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buf));
      const parsed: DownloadRecord[] = JSON.parse(text) as DownloadRecord[];
      const out: DownloadRecord[] = [];
      for (let i = 0; i < parsed.length; i++) {
        out.push(normalizeRecord(parsed[i]));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private write(list: DownloadRecord[]): void {
    try {
      const trimmed: DownloadRecord[] = list.length > MAX_RECORDS ?
        list.slice(list.length - MAX_RECORDS) : list;
      const file: fileIo.File = fileIo.openSync(this.path(),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(trimmed));
      fileIo.closeSync(file);
    } catch (e) {
      // 写失败只影响历史记录，不影响下载本身
    }
  }
}
