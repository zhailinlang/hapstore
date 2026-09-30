import { StoreData } from '../model/AppInfo';

/**
 * 内存里缓存一份已解析好的 StoreData。
 *
 * TabContent 切换时子组件状态是保留的，但「应用」Tab 如果因为远端更新而重载，
 * 走这里可以避免重复解析 500KB+ 的 JSON。
 */
export class StoreCache {
  private static data: StoreData | null = null;

  static has(): boolean {
    return StoreCache.data !== null;
  }

  static get(): StoreData | null {
    return StoreCache.data;
  }

  static set(data: StoreData): void {
    StoreCache.data = data;
  }

  static invalidate(): void {
    StoreCache.data = null;
  }
}
