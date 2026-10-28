import { i18n } from "@/shared/i18n";

/** Format a Unix timestamp (seconds) as a human-readable relative time string. */
export function relativeTime(unix: number): string {
  const diff = Date.now() - unix * 1000;
  const seconds = Math.floor(diff / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 30) {
    return i18n.t("time.monthsAgo", { count: Math.floor(days / 30) });
  }
  if (days > 0) return i18n.t("time.daysAgo", { count: days });
  if (hours > 0) return i18n.t("time.hoursAgo", { count: hours });
  if (minutes > 0) return i18n.t("time.minutesAgo", { count: minutes });
  return i18n.t("time.justNow");
}
