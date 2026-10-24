import { common, Want, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HLog } from '../common/HLog';

/**
 * 把下载好的 HAP 交给装机工具完成安装。
 *
 * 鸿蒙不允许三方应用自己装 HAP（INSTALL_BUNDLE 是 system_core，拿不到），
 * 但可以把文件通过 want 转交给已经拿到调试授权的工具应用。
 * 这里对接的是小白调试助手（auto-installer）鸿蒙版，它内置了 hdc 客户端，
 * 用户在系统弹窗点一次「始终允许使用本机调试」后即可在手机上完成安装。
 *
 * 本模块只做「转交」，不碰签名、不改包、不申请任何新权限。
 */

/** 小白调试助手鸿蒙版包名 */
export const INSTALLER_PACKAGE: string = 'com.xiaobai.hap_installer';

/** 官方发布页，未安装时引导用户去获取 */
export const INSTALLER_RELEASE_URL: string =
  'https://github.com/likuai2010/auto-installer/releases/latest';

export type HandOffResult = 'ok' | 'no-file' | 'missing' | 'failed';

/** 目标应用声明的两个 action，逐个试，命中一个就够 */
const ACTION_VIEW: string = 'ohos.want.action.viewData';
const ACTION_SEND: string = 'ohos.want.action.sendData';

/** 目标应用 skills 里声明的文件类型 */
const TYPE_PACKAGE: string = 'openharmony.package';

/** 目标 Ability 不存在 / 无匹配，基本等于「没装」 */
const ERR_ABILITY_NOT_FOUND: number = 16000001;
const ERR_NO_MATCH_ABILITY: number = 16000050;

export class InstallerBridge {
  /**
   * 可选的来源：沙箱里的正式文件优先，其次用户另存的位置。
   *
   * 沙箱文件要先转成 file:// URI，否则对方拿不到读权限。
   */
  private static candidates(localPath: string, saveUri: string): string[] {
    const list: string[] = [];
    if (localPath.length > 0) {
      try {
        list.push(fileUri.getUriFromPath(localPath));
      } catch (e) {
        HLog.w(`沙箱文件转 URI 失败 ${localPath}`);
      }
    }
    if (saveUri.length > 0) {
      list.push(saveUri);
    }
    return list;
  }

  /**
   * 转交安装。
   *
   * 两个来源 × 两个 action 逐个试，第一个成功就返回。
   * 顺序是「沙箱 viewData → 沙箱 sendData → 另存位置 viewData → 另存位置 sendData」。
   */
  static async handOff(ctx: common.UIAbilityContext, localPath: string,
    saveUri: string): Promise<HandOffResult> {
    const uris: string[] = InstallerBridge.candidates(localPath, saveUri);
    if (uris.length === 0) {
      return 'no-file';
    }

    let last: BusinessError | null = null;
    for (let i = 0; i < uris.length; i++) {
      const uri: string = uris[i];
      const actions: string[] = [ACTION_VIEW, ACTION_SEND];
      for (let j = 0; j < actions.length; j++) {
        const want: Want = {
          action: actions[j],
          uri: uri,
          type: TYPE_PACKAGE,
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
        };
        try {
          await ctx.startAbility(want);
          HLog.i(`已转交装机工具 ${actions[j]}`);
          return 'ok';
        } catch (e) {
          last = e as BusinessError;
          HLog.w(`转交失败 ${actions[j]} code=${last.code}`);
        }
      }
    }

    if (last && (last.code === ERR_ABILITY_NOT_FOUND || last.code === ERR_NO_MATCH_ABILITY)) {
      return 'missing';
    }
    return 'failed';
  }

  /** 结果转一句人话，UI 直接用。 */
  static messageOf(result: HandOffResult): string {
    if (result === 'ok') {
      return '已交给装机工具';
    }
    if (result === 'no-file') {
      return '本地文件已不在，请重新下载';
    }
    if (result === 'missing') {
      return '没找到装机工具，请先安装小白调试助手';
    }
    return '转交失败，可先「另存为」到公共目录再试';
  }
}
