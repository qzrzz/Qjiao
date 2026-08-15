import { describe, test, expect } from "bun:test";

/**
 * 顶部固定 Header 触发逻辑测试
 */
describe("StickyHeader 显示状态逻辑测试", () => {
  test("当 Hero download 按钮滚出视口上方 (boundingClientRect.top < 0 且 isIntersecting 为 false) 时应为显示状态", () => {
    // 模拟脱离视口且滚动到了可视区上方
    const entry = {
      isIntersecting: false,
      boundingClientRect: { top: -100 },
    };

    const isOutOfView = !entry.isIntersecting && entry.boundingClientRect.top < 0;
    expect(isOutOfView).toBe(true);
  });

  test("当 Hero download 按钮在视口内 (isIntersecting 为 true) 时应为隐藏状态", () => {
    // 模拟在视口内
    const entry = {
      isIntersecting: true,
      boundingClientRect: { top: 200 },
    };

    const isOutOfView = !entry.isIntersecting && entry.boundingClientRect.top < 0;
    expect(isOutOfView).toBe(false);
  });
});
