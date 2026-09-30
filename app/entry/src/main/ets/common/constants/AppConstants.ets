/**
 * 仓库坐标与默认地址。
 *
 * ⚠️  REPO_OWNER 要改成你自己的 GitHub 用户名；下面所有地址都从它推导，改这一处即可。
 *     仓库里的 data/manifest.json 也是按同一坐标生成的（sync/manifest.py --repo OWNER/REPO）。
 */

export const REPO_OWNER: string = 'maxzhai';
export const REPO_NAME: string = 'hapstore';
export const REPO_PATH: string = `${REPO_OWNER}/${REPO_NAME}`;

/** 滚动快照 tag：URL 永久稳定，且与 release 下载链接同域，能被 ghfast 等镜像代理 */
export const SNAPSHOT_TAG: string = 'snapshot-latest';
/** raw 兜底分支：每轮单提交强推，历史只有 1 个 commit，不撑大仓库 */
export const ALT_BRANCH: string = 'snapshot-data';

/** 快照主地址（Release 资产） */
export const DEFAULT_SOURCE_URL: string =
  `https://github.com/${REPO_PATH}/releases/download/${SNAPSHOT_TAG}/apps.json`;
/** 快照兜底地址（raw） */
export const ALT_SOURCE_URL: string =
  `https://raw.githubusercontent.com/${REPO_PATH}/${ALT_BRANCH}/apps.json`;

/** 指针文件主地址（约 700B，含快照 sha256 与 App 最新版本） */
export const DEFAULT_MANIFEST_URL: string =
  `https://github.com/${REPO_PATH}/releases/download/${SNAPSHOT_TAG}/manifest.json`;
/** 指针文件兜底地址 */
export const ALT_MANIFEST_URL: string =
  `https://raw.githubusercontent.com/${REPO_PATH}/${ALT_BRANCH}/manifest.json`;

/** 当前这个 App 能正确解析的最高快照 schema；超过就提示升级而不是硬解析 */
export const SUPPORTED_SCHEMA_VERSION: number = 2;

/** 自更新下载记录用的 appId：不会命中任何快照应用，避免混进「已下载应用的新版本提醒」 */
export const SELF_APP_ID: string = '__self__';
export const SELF_APP_NAME: string = 'HapStore';
