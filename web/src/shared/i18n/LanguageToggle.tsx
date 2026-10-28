import { Languages } from "lucide-react";
import { useTranslation } from "react-i18next";

import { setLanguage } from "@/shared/i18n";
import { Button } from "@/shared/ui/button";

export function LanguageToggle({ className }: { className?: string }) {
  const { t, i18n } = useTranslation();
  const next = i18n.resolvedLanguage === "ko" ? "en" : "ko";
  const nextLabel = t(`language.${next}`);

  return (
    <Button
      variant="ghost"
      size="sm"
      className={`h-8 gap-1.5 px-2 text-xs text-black/60 hover:text-black dark:text-white/60 dark:hover:text-white ${className ?? ""}`}
      onClick={() => setLanguage(next)}
      aria-label={t("language.switchTo", { language: nextLabel })}
    >
      <Languages className="h-4 w-4" />
      {nextLabel}
    </Button>
  );
}
