import { connection } from '@kit.NetworkKit';

/** 网络状态判断。GET_NETWORK_INFO 权限已在 module.json5 声明。 */
export class NetworkService {
  static isOnline(): boolean {
    try {
      return connection.hasDefaultNetSync();
    } catch (e) {
      return false;
    }
  }

  /** 是否蜂窝网络（用于「移动网络下载提醒」）。 */
  static isCellular(): boolean {
    if (!NetworkService.isOnline()) {
      return false;
    }
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
      return caps.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
    } catch (e) {
      return false;
    }
  }

  static netLabel(): string {
    if (!NetworkService.isOnline()) {
      return '无网络';
    }
    if (NetworkService.isCellular()) {
      return '移动网络';
    }
    return 'Wi-Fi';
  }
}
