import { expect, test } from "@playwright/test";

const FEEDBACK = {
  id: "11111111-1111-1111-1111-111111111111",
  communityId: "6d474feb-c50a-44e4-a0b5-f30532df49bc",
  communityHost: "design.buzz.xyz",
  submitterPubkey: "21".repeat(32),
  category: "bug",
  bodySummary: "Composer froze on paste.",
  status: "new",
  receivedAt: "2026-10-01T12:00:00Z",
};

test("Korean UI follows ?lang=ko and the language toggle", async ({ page }) => {
  // Every admin API call returns 200, so the probe resolves to disabled mode.
  await page.route("**/api/admin/v1/**", (route) =>
    route.fulfill({
      contentType: "application/json",
      body: new URL(route.request().url()).pathname.endsWith("/feedback")
        ? JSON.stringify([FEEDBACK])
        : "[]",
    }),
  );

  await page.goto("/reports?lang=ko");
  await expect(page.locator("html")).toHaveAttribute("lang", "ko");
  await expect(
    page.getByRole("heading", { name: "처리 대기 신고" }),
  ).toBeVisible();
  await expect(page.getByText("기록이 없어요.")).toBeVisible();

  await page.getByRole("link", { name: "피드백" }).click();
  await expect(page.getByText("전체 1건 중 1건")).toBeVisible();
  await expect(page.getByText("버그")).toBeVisible();

  // The choice persists, so the next visit without ?lang= stays in English.
  await page.getByRole("button", { name: /English/ }).click();
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await page.goto("/reports");
  await expect(
    page.getByRole("heading", { name: "Open reports" }),
  ).toBeVisible();
});
