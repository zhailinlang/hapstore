import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志出口。
 *
 * 下载与镜像这两块链路长、分支多（沙箱落盘 / 镜像改写 / 任务状态机），
 * 没有日志几乎无法定位，所以统一从这里出，用 `hdc shell hilog | grep HapStore` 看。
 */
const DOMAIN: number = 0x1A5B;
const TAG: string = 'HapStore';

export class HLog {
  static i(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}
