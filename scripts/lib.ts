// 发布脚本共用的轻量终端辅助方法。

/** 输出带高亮的发布进度。 */
export const say = (msg: string): void =>
  console.log(`\n\x1b[1;34m==>\x1b[0m ${msg}`);

/** 输出错误并以非零状态退出。 */
export const die = (msg: string): never => {
  console.error(`\x1b[1;31merror:\x1b[0m ${msg}`);
  process.exit(1);
};

/** 确认发布依赖的命令已安装。 */
export const need = (tool: string): void => {
  if (!Bun.which(tool)) die(`missing required tool: ${tool}`);
};
